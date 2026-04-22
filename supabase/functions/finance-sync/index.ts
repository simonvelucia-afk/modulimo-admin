// Edge Function finance-sync : worker periodique qui pull les nouvelles
// transactions CoHabitat des immeubles avec dual_write_enabled=true et
// les rejoue sur la centrale via adjust_balance.
//
// Trigger : GET /finance-sync/run (auth : Bearer service_role centrale)
// Planning recommande : pg_cron toutes les 5 min (voir la migration 011).
//
// Variables env requises :
//   SUPABASE_URL                     URL du projet central (auto-injectee)
//   FINANCE_SERVICE_ROLE_KEY         service_role legacy JWT de la centrale
//                                    (meme secret que finance-bridge)
//   FINANCE_SYNC_COHABITAT_KEYS      JSON : {"<building_id>":"<service_role>"}
//                                    service_role des projets CoHabitat
//                                    dont on doit pouvoir lire transactions.

import { syncBuilding } from './lib/sync.ts';
import {
  listBuildingsToSync,
  loadCohabitatKeys,
  makeCentralAdapters,
  makeCohabitatFetcher,
} from './lib/adapters.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'GET' && req.method !== 'POST') {
    return json({ error: 'METHOD_NOT_ALLOWED' }, 405);
  }

  // Auth stricte : seul service_role peut declencher.
  const auth = req.headers.get('authorization') ?? '';
  const token = auth.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token || token !== SERVICE_ROLE) {
    return json({ error: 'UNAUTHORIZED' }, 401);
  }

  if (!CENTRAL_URL || !SERVICE_ROLE) {
    return json({ error: 'SERVER_MISCONFIGURED' }, 500);
  }

  let cohabitatKeys: Map<string, string>;
  try {
    cohabitatKeys = loadCohabitatKeys();
  } catch (e) {
    return json({ error: 'INVALID_COHABITAT_KEYS', detail: (e as Error).message }, 500);
  }

  const central = { url: CENTRAL_URL, serviceRole: SERVICE_ROLE };
  const centralAdapters = makeCentralAdapters(central);
  const fetcher = makeCohabitatFetcher(cohabitatKeys);

  let buildings;
  try {
    buildings = await listBuildingsToSync(central);
  } catch (e) {
    return json({ error: 'LIST_BUILDINGS_FAILED', detail: (e as Error).message }, 500);
  }

  const results = [];
  for (const b of buildings) {
    const r = await syncBuilding(b, {
      ...centralAdapters,
      fetchCohabitatTxSince: fetcher,
    });
    results.push(r);
  }

  return json({ ok: true, buildings: results });
});
