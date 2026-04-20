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
//   SUPABASE_SERVICE_ROLE_KEY  Lecture clients (preset par Supabase)
//   FINANCE_JWT_SECRET         Secret HS256 de la centrale pour minter
//                              le JWT passe a PostgREST. A definir via :
//                                supabase secrets set FINANCE_JWT_SECRET=...
//                              (la valeur est le JWT Secret du dashboard
//                              Supabase -> Project Settings -> API)
// -----------------------------------------------------------------------

import { resolveClaims } from './lib/resolve.ts';
import { mintCentralJwt, secretFromEnv } from './lib/jwt.ts';
import {
  jwksResolverFor,
  makeFindBuildingByIssuer,
  makeFindClient,
} from './lib/registry.ts';
import { makePostgrestCaller } from './lib/central.ts';
import { handleGetBalance } from './handlers/get_balance.ts';
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
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const deps = {
  findBuildingByIssuer: makeFindBuildingByIssuer(CENTRAL_URL, ANON_KEY),
  findClient: makeFindClient(CENTRAL_URL, SERVICE_ROLE),
  getKeyResolver: jwksResolverFor,
};

const caller = makePostgrestCaller(CENTRAL_URL, ANON_KEY);

// Liste blanche des endpoints exposes. Toute route inconnue retourne 404.
type EndpointName = 'get-balance';
const ENDPOINTS: Record<EndpointName, true> = { 'get-balance': true };

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

  // Mint du JWT central utilise par PostgREST pour valider les claims.
  const centralJwt = await mintCentralJwt(resolved.claims, { secret: secretFromEnv() });

  switch (endpoint) {
    case 'get-balance': {
      const result = await handleGetBalance(
        resolved.claims,
        body as never,
        caller,
        centralJwt,
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
  }
});
