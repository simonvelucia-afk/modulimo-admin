// Passerelle finance Modulimo — point d'entree HTTP.
// -----------------------------------------------------------------------
// Variables env requises :
//   SUPABASE_URL               Central project URL (preset par Supabase)
//   FINANCE_SERVICE_ROLE_KEY   apikey avec role service_role pour les
//                              appels PostgREST centraux. Format :
//                                - sb_secret_... (nouveau format recomande)
//                                - OU legacy service_role JWT (eyJ...)
//                              Fallback auto vers SUPABASE_SERVICE_ROLE_KEY
//                              si pas configure, mais le fallback peut
//                              ramener le format court auto-injecte.
// -----------------------------------------------------------------------

import { resolveClaims } from './lib/resolve.ts';
import {
  jwksResolverFor,
  makeFindBuildingByIssuer,
  makeFindClient,
  makeProvisionClient,
} from './lib/registry.ts';
import { makePostgrestCaller } from './lib/central.ts';
import { handleGetBalance } from './handlers/get_balance.ts';
import { handleLunchPurchase } from './handlers/lunch_purchase.ts';
import { handleDebit } from './handlers/debit.ts';
import { handleTransferToDep } from './handlers/transfer.ts';
import { handleRecordRealPayment } from './handlers/record_real_payment.ts';
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
const SERVICE_ROLE = Deno.env.get('FINANCE_SERVICE_ROLE_KEY')
  || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  || '';

log('info', 'finance_bridge_boot', {
  has_url: CENTRAL_URL.length > 0,
  url_host: CENTRAL_URL ? new URL(CENTRAL_URL).host : null,
  service_role_len: SERVICE_ROLE.length,
  service_role_source: Deno.env.get('FINANCE_SERVICE_ROLE_KEY')
    ? 'secret'
    : Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
      ? 'auto'
      : 'missing',
  service_role_format: SERVICE_ROLE.startsWith('sb_secret_')
    ? 'new'
    : SERVICE_ROLE.split('.').length === 3 ? 'legacy_jwt' : 'other',
});

const deps = {
  findBuildingByIssuer: makeFindBuildingByIssuer(CENTRAL_URL, SERVICE_ROLE),
  findClient: makeFindClient(CENTRAL_URL, SERVICE_ROLE),
  provisionClient: makeProvisionClient(CENTRAL_URL, SERVICE_ROLE),
  getKeyResolver: jwksResolverFor,
};

const caller = makePostgrestCaller(CENTRAL_URL);

// Liste blanche des endpoints exposes. Toute route inconnue retourne 404.
type EndpointName = 'get-balance' | 'lunch-purchase' | 'debit' | 'transfer-to-dep' | 'record-real-payment';
const ENDPOINTS: Record<EndpointName, true> = {
  'get-balance': true,
  'lunch-purchase': true,
  'debit': true,
  'transfer-to-dep': true,
  'record-real-payment': true,
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
    case 'debit': {
      const result = await handleDebit(
        resolved.claims,
        body as never,
        caller,
        SERVICE_ROLE,
      );
      log(result.status >= 500 ? 'error' : 'info', 'debit_done', {
        rid,
        endpoint,
        status: result.status,
        building_id: resolved.claims.building_id,
        client_id: resolved.claims.client_id,
        type: (body as { type?: string } | null)?.type,
        replay: (result.body as { idempotent_replay?: boolean }).idempotent_replay,
      });
      return json(result.body, result.status);
    }
    case 'transfer-to-dep': {
      const result = await handleTransferToDep(
        resolved.claims,
        body as never,
        caller,
        SERVICE_ROLE,
      );
      log(result.status >= 500 ? 'error' : 'info', 'transfer_to_dep_done', {
        rid,
        endpoint,
        status: result.status,
        building_id: resolved.claims.building_id,
        client_id: resolved.claims.client_id,
        replay: (result.body as { idempotent_replay?: boolean }).idempotent_replay,
      });
      return json(result.body, result.status);
    }
    case 'record-real-payment': {
      const result = await handleRecordRealPayment(
        resolved.claims,
        body as never,
        resolved.building,
        token,
        deps.findClient,
        caller,
        SERVICE_ROLE,
      );
      log(result.status >= 500 ? 'error' : 'info', 'record_real_payment_done', {
        rid,
        endpoint,
        status: result.status,
        building_id: resolved.claims.building_id,
        admin_user_id: resolved.claims.cohabitat_user_id,
        target_user_id: (body as { target_user_id?: string } | null)?.target_user_id,
        replay: (result.body as { idempotent_replay?: boolean }).idempotent_replay,
      });
      return json(result.body, result.status);
    }
  }
});
