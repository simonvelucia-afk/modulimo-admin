// Edge Function Supabase : proxy d'envoi de courriels via Resend
// -----------------------------------------------------------------------
// Pourquoi : l'API Resend (api.resend.com) bloque les appels browser-origin
// par CORS. Cette fonction s'exécute côté serveur (Deno), tient la clé
// RESEND_KEY en secret et retourne les headers CORS nécessaires pour que
// modulimo-admin et cohabitat puissent l'appeler depuis le navigateur.
//
// Déploiement :
//   supabase functions deploy send-email --project-ref bpxscgrbxjscicpnheep
//   supabase secrets set RESEND_KEY=re_xxx   --project-ref bpxscgrbxjscicpnheep
//   supabase secrets set RESEND_FROM='Modulimo <no-reply@modulimo.com>' --project-ref bpxscgrbxjscicpnheep
//
// Alternative dashboard : Supabase → Edge Functions → New Function
// "send-email" → coller ce fichier → Deploy, puis configurer les secrets.
//
// Appel côté client (JS) :
//   const { data, error } = await sb.functions.invoke('send-email', {
//     body: { to, subject, html }
//   });
// -----------------------------------------------------------------------

const RESEND_KEY  = Deno.env.get('RESEND_KEY')  ?? '';
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Modulimo <no-reply@modulimo.com>';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Max-Age':       '86400',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST')    return json({ error: 'Method not allowed' }, 405);

  if (!RESEND_KEY) {
    return json({ error: 'RESEND_KEY secret non configuré sur la fonction' }, 500);
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'Corps JSON invalide' }, 400);
  }

  const { to, subject, html, from, reply_to } = payload ?? {};
  if (!to || !subject || !html) {
    return json({ error: 'Champs requis: to, subject, html' }, 400);
  }
  const recipients = Array.isArray(to) ? to : [to];

  const resendRes = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${RESEND_KEY}`,
      'Content-Type':  'application/json',
    },
    body: JSON.stringify({
      from:     from || RESEND_FROM,
      to:       recipients,
      subject,
      html,
      reply_to: reply_to || undefined,
    }),
  });

  const text = await resendRes.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* keep text */ }

  return json(
    resendRes.ok
      ? { ok: true, provider: 'resend', data: body }
      : { ok: false, provider: 'resend', status: resendRes.status, error: body },
    resendRes.ok ? 200 : resendRes.status
  );
});
