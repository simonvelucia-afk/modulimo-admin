// Edge Function loi25-process — orchestration Loi 25 (Quebec)
// -----------------------------------------------------------------------
// Endpoints :
//   POST /loi25-process/export    body: { client_id }
//     -> retourne le JSON complet (PII + analytics) pour le client.
//   POST /loi25-process/anonymize body: { client_id }
//     -> efface les PII centrales et fige anonymized_at.
//   POST /loi25-process/health
//     -> ping (no auth)
//
// Auth :
//   - Bearer JWT signe par Supabase central (admins modulimo).
//   - Validation via PostgREST avec le JWT (s'il est valide, on resout
//     auth.users.email pour l'audit log).
//   - Pas de check de role specifique — le simple fait d'avoir un
//     compte sur le projet central est suffisant (aucun resident
//     normal n'a de compte ici).
//
// Variables env requises :
//   SUPABASE_URL                Central project URL
//   FINANCE_SERVICE_ROLE_KEY    apikey service_role (reutilise depuis
//                               finance-bridge ; meme projet, meme cle)
//
// Securite :
//   - Les RPC SQL appelees sont SECURITY DEFINER + service_role only.
//     L'Edge Function est l'unique chemin pour les invoquer depuis un
//     client authentifie.
//   - L'export est lecture seule, l'anonymisation est destructive mais
//     idempotente : un retry ne corrompt rien.
// -----------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Max-Age': '86400',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}

const CENTRAL_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE = Deno.env.get('FINANCE_SERVICE_ROLE_KEY')
  || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  || '';

// Resout l'email de l'admin appelant via /auth/v1/user en utilisant le
// JWT entrant. Echec = JWT invalide ou expire.
async function resolveAdmin(token: string): Promise<{ ok: true; email: string; user_id: string } | { ok: false; error: string }> {
  const res = await fetch(CENTRAL_URL + '/auth/v1/user', {
    headers: { apikey: SERVICE_ROLE, Authorization: 'Bearer ' + token },
  });
  if (!res.ok) {
    return { ok: false, error: 'INVALID_JWT' };
  }
  const u = await res.json() as { id?: string; email?: string };
  if (!u || !u.id) return { ok: false, error: 'NO_USER' };
  return { ok: true, email: u.email ?? '', user_id: u.id };
}

// Wrapper PostgREST RPC avec service_role.
async function callRpc(name: string, params: Record<string, unknown>): Promise<{ ok: true; data: unknown } | { ok: false; status: number; body: unknown }> {
  const res = await fetch(CENTRAL_URL + '/rest/v1/rpc/' + name, {
    method: 'POST',
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: 'Bearer ' + SERVICE_ROLE,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(params),
  });
  const text = await res.text();
  let parsed: unknown;
  try { parsed = text ? JSON.parse(text) : null; } catch { parsed = text; }
  if (!res.ok) return { ok: false, status: res.status, body: parsed };
  return { ok: true, data: parsed };
}

function extractEndpoint(pathname: string): string | null {
  const parts = pathname.split('/').filter(Boolean);
  const last = parts[parts.length - 1];
  return last || null;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });

  const url = new URL(req.url);
  const endpoint = extractEndpoint(url.pathname);

  // Health public — pas d'auth, GET ou POST.
  if (endpoint === 'health') {
    return json({ ok: true, ts: new Date().toISOString() });
  }

  // Les autres endpoints exigent POST.
  if (req.method !== 'POST') return json({ error: 'METHOD_NOT_ALLOWED' }, 405);

  if (!SERVICE_ROLE) {
    return json({ ok: false, error: 'SERVICE_ROLE_MISSING' }, 500);
  }

  // Auth admin Modulimo : Bearer JWT signe par Supabase central.
  const authHeader = req.headers.get('authorization') ?? '';
  const m = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!m) return json({ ok: false, error: 'MISSING_BEARER' }, 401);
  const adminToken = m[1];

  const admin = await resolveAdmin(adminToken);
  if (!admin.ok) return json({ ok: false, error: admin.error }, 401);

  let body: { client_id?: string; name?: string } = {};
  try {
    if ((req.headers.get('content-type') ?? '').includes('application/json')) {
      body = await req.json();
    }
  } catch {
    return json({ ok: false, error: 'INVALID_JSON' }, 400);
  }

  // /lookup prend un name au lieu d'un client_id (cas : verifier si un
  // nom donne correspond a un certificat d'anonymisation existant).
  if (endpoint === 'lookup') {
    const name = (body.name || '').trim();
    if (!name || name.length < 3) {
      return json({ ok: false, error: 'NAME_TOO_SHORT', detail: 'Au moins 3 caracteres requis' }, 400);
    }
    const r = await callRpc('lookup_anonymization_by_name', { p_name: name });
    if (!r.ok) {
      console.error('[loi25-process] lookup failed', r);
      return json({ ok: false, error: 'CENTRAL_RPC_FAILED', detail: r.body }, 502);
    }
    console.info('[loi25-process] lookup', { admin: admin.email, name });
    return json({ ok: true, action: 'lookup', result: r.data });
  }

  // Tous les autres endpoints exigent un client_id valide.
  const clientId = body.client_id?.trim();
  if (!clientId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(clientId)) {
    return json({ ok: false, error: 'INVALID_CLIENT_ID' }, 400);
  }

  if (endpoint === 'export') {
    const r = await callRpc('export_client_data_central', { p_client_id: clientId });
    if (!r.ok) {
      console.error('[loi25-process] export_client_data_central failed', r);
      return json({ ok: false, error: 'CENTRAL_RPC_FAILED', detail: r.body }, 502);
    }
    console.info('[loi25-process] export', { admin: admin.email, client_id: clientId });
    return json({
      ok: true,
      action: 'export',
      admin_email: admin.email,
      exported_at: new Date().toISOString(),
      data: r.data,
    });
  }

  if (endpoint === 'anonymize') {
    const r = await callRpc('anonymize_client_central', {
      p_client_id: clientId,
      p_admin_id: admin.user_id,
    });
    if (!r.ok) {
      console.error('[loi25-process] anonymize_client_central failed', r);
      // Si la RPC a refuse pour cause de bail actif, on remonte un 409
      // (Conflict) pour que l'UI distingue ce cas du 502 generique.
      const detail = r.body as { code?: string; message?: string } | undefined;
      if (detail?.code === '23514' || detail?.message?.includes('contrat')) {
        return json({ ok: false, error: 'ACTIVE_CONTRACT', detail: detail.message }, 409);
      }
      return json({ ok: false, error: 'CENTRAL_RPC_FAILED', detail: r.body }, 502);
    }
    console.warn('[loi25-process] ANONYMIZE', { admin: admin.email, client_id: clientId });
    return json({
      ok: true,
      action: 'anonymize',
      admin_email: admin.email,
      result: r.data,
      note: 'Cote central uniquement. La RPC CoHabitat anonymize_profile doit etre declenchee separement par l\'admin local (UI CoHabitat) pour anonymiser aussi le profile resident.',
    });
  }

  // Re-telecharger un certificat existant (cas : admin a perdu l'onglet
  // original ou doit re-imprimer pour le resident).
  if (endpoint === 'certificate') {
    const r = await callRpc('get_anonymization_certificate', {
      p_client_id: clientId,
    });
    if (!r.ok) {
      console.error('[loi25-process] get_anonymization_certificate failed', r);
      return json({ ok: false, error: 'CENTRAL_RPC_FAILED', detail: r.body }, 502);
    }
    return json({ ok: true, action: 'certificate', certificate: r.data });
  }

  return json({ ok: false, error: 'UNKNOWN_ENDPOINT' }, 404);
});
