// Passerelle finance Modulimo — point d'entree HTTP.
// -----------------------------------------------------------------------
// Role : recevoir un JWT signe par l'Auth Supabase d'un immeuble CoHabitat,
// le valider contre la JWKS de cet immeuble, resoudre le cohabitat_user_id
// en client_id + building_id via la base centrale, puis appeler la RPC
// financiere centrale correspondante avec un JWT re-mint court.
//
// Phase 0 : seul /get-balance est branche, en stub (retourne 0.00).
// Phase 1+ : on ajoutera /list-transactions, /lunch-purchase, etc.
//
// Deploiement :
//   supabase functions deploy finance-bridge --project-ref bpxscgrbxjscicpnheep
//   supabase secrets set SUPABASE_JWT_SECRET=...  --project-ref bpxscgrbxjscicpnheep
//
// Variables env requises :
//   SUPABASE_URL               Central project URL (preset par Supabase)
//   SUPABASE_ANON_KEY          Lecture building_registry (preset par Supabase)
//   SUPABASE_SERVICE_ROLE_KEY  Utilise comme Bearer pour les RPC finance
//                              (les RPC sont SECURITY DEFINER + GRANT cible
//                              uniquement service_role). L'Edge Function
//                              est la frontiere de confiance ; elle a deja
//                              valide le JWT entrant avant d'appeler.
// -----------------------------------------------------------------------

import { resolveClaims } from './lib/resolve.ts';
import {
  jwksResolverFor,
  makeFindBuildingByIssuer,
  makeFindClient,
} from './lib/registry.ts';
import { makePostgrestCaller } from './lib/central.ts';
import { handleGetBalance } from './handlers/get_balance.ts';
import { handleLunchPurchase } from './handlers/lunch_purchase.ts';
import { log, requestId } from './lib/logger.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info, idempotency-key',
  'Access-Control-Max-Age': '86400',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json' },
  });
}

const CENTRAL_URL = Deno.env.get('SUPABASE_URL') ?? '';
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
// Priorite au secret explicite : le runtime Supabase auto-injecte
// SUPABASE_SERVICE_ROLE_KEY au nouveau format court (sb_secret_...),
// qui n'est PAS un JWT et que PostgREST refuse comme Bearer. Le secret
// FINANCE_SERVICE_ROLE_KEY doit contenir la legacy service_role au
// format JWT (eyJ...), signee avec la cle JWT precedente encore acceptee.
const SERVICE_ROLE = Deno.env.get('FINANCE_SERVICE_ROLE_KEY')
  || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  || '';

// Log de diagnostic au boot : on affiche la LONGUEUR des variables (pas
// leur valeur) pour detecter un SERVICE_ROLE vide sans jamais logger la
// cle elle-meme. jwt_format distingue un JWT valide (3 parts) d'une cle
// au format court (sb_secret_...) qui ne marchera pas en Bearer.
log('info', 'finance_bridge_boot', {
  has_url: CENTRAL_URL.length > 0,
  url_host: CENTRAL_URL ? new URL(CENTRAL_URL).host : null,
  anon_len: ANON_KEY.length,
  service_role_len: SERVICE_ROLE.length,
  service_role_source: Deno.env.get('FINANCE_SERVICE_ROLE_KEY')
    ? 'secret'
    : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
      ? 'auto'
      : 'missing',
  service_role_jwt_format: SERVICE_ROLE.split('.').length === 3,
});

const deps = {
  findBuildingByIssuer: makeFindBuildingByIssuer(CENTRAL_URL, ANON_KEY),
  findClient: makeFindClient(CENTRAL_URL, SERVICE_ROLE),
  getKeyResolver: jwksResolverFor,
};

// Pour les appels RPC finance on utilise le service_role : il bypasse la
// RLS et permet a PostgREST d'executer la RPC sans re-verifier un JWT.
// La securite tient parce que les RPC sont GRANTed uniquement a
// service_role et que seule cette Edge Function detient la cle.
const caller = makePostgrestCaller(CENTRAL_URL, ANON_KEY);

// Liste blanche des endpoints exposes. Toute route inconnue retourne 404.
type EndpointName = 'get-balance' | 'lunch-purchase';
const ENDPOINTS: Record<EndpointName, true> = {
  'get-balance': true,
  'lunch-purchase': true,
};

function extractEndpoint(pathname: string): EndpointName | null {
  const parts = pathname.split('/').filter(Boolean);
  // Supabase route: /finance-bridge/<endpoint>
  const last = parts[parts.length - 1];
  return last && last in ENDPOINTS ? (last as EndpointName) : null;
}

Deno.serve(async (req) => {
  const rid = requestId();
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'METHOD_NOT_ALLOWED', rid }, 405);

  const url = new URL(req.url);
  const endpoint = extractEndpoint(url.pathname);
  if (!endpoint) return json({ error: 'UNKNOWN_ENDPOINT', rid }, 404);

  const auth = req.headers.get('authorization') ?? '';
  const m = auth.match(/^Bearer\s+(.+)$/i);
  if (!m) return json({ error: 'MISSING_BEARER', rid }, 401);
  const token = m[1];

  const resolved = await resolveClaims(token, deps);
  if (!resolved.ok) {
    log(resolved.error === 'INVALID_SIGNATURE' ? 'warn' : 'info', 'resolve_failed', {
      rid, endpoint, error: resolved.error,
    });
    return json({ error: resolved.error, rid }, resolved.status);
  }

  let body: unknown = null;
  const ct = req.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) {
    try {
      body = await req.json();
    } catch {
      return json({ error: 'INVALID_JSON', rid }, 400);
    }
  }

  if (!SERVICE_ROLE) {
    log('error', 'service_role_missing', { rid });
    return json({
      error: 'SERVICE_ROLE_MISSING',
      rid,
      hint: 'set supabase secrets set FINANCE_SERVICE_ROLE_KEY=<service_role_key>',
    }, 500);
  }

  switch (endpoint) {
    case 'get-balance': {
      const result = await handleGetBalance(
        resolved.claims,
        body as never,
        caller,
        SERVICE_ROLE,
      );
      log('info', 'get_balance_done', {
        rid,
        endpoint,
        status: result.status,
        building_id: resolved.claims.building_id,
        client_id: resolved.claims.client_id,
      });
      return json(result.body, result.status);
    }
    case 'lunch-purchase': {
      const result = await handleLunchPurchase(
        resolved.claims,
        body as never,
        caller,
        SERVICE_ROLE,
      );
      log(result.status >= 500 ? 'error' : 'info', 'lunch_purchase_done', {
        rid,
        endpoint,
        status: result.status,
        building_id: resolved.claims.building_id,
        client_id: resolved.claims.client_id,
        replay: (result.body as { idempotent_replay?: boolean }).idempotent_replay,
      });
      return json(result.body, result.status);
    }
  }
});
