// Tests des endpoints /candidatures-list et /candidatures-decide.
// Valide : refus des non-admins, building_id impose par le jeton (jamais
// par le corps de la requete), validation des entrees, reponse de
// decision expurgee des donnees personnelles.

import { assertEquals } from './_assert.ts';
import {
  handleCandidaturesDecide,
  handleCandidaturesList,
  type CandidaturesDeps,
} from '../handlers/candidatures.ts';
import type { CentralCaller, CentralRpcResult } from '../lib/central.ts';
import type { BuildingRegistryEntry, ResolvedClaims } from '../lib/types.ts';

const CLAIMS: ResolvedClaims = {
  client_id: 'client-a-uuid',
  building_id: 'building-a-uuid',
  cohabitat_user_id: 'user-a-uuid',
};

const BUILDING: BuildingRegistryEntry = {
  id: 'building-a-uuid',
  name: 'A',
  supabase_url: 'https://a.supabase.co',
  jwt_issuer: 'https://a.supabase.co/auth/v1',
  jwks_url: 'https://a.supabase.co/auth/v1/.well-known/jwks.json',
  status: 'active',
};

const CAND_ID = '11111111-2222-3333-4444-555555555555';

type Call = { name: string; params: Record<string, unknown>; key: string };

function makeDeps(
  role: string | null,
  impl: (name: string, params: Record<string, unknown>) => CentralRpcResult<unknown>,
): CandidaturesDeps & { calls: Call[]; roleCalls: Array<[string, string, string]> } {
  const calls: Call[] = [];
  const roleCalls: Array<[string, string, string]> = [];
  const caller = {
    callRpc(name: string, params: Record<string, unknown>, key: string) {
      calls.push({ name, params, key });
      return Promise.resolve(impl(name, params));
    },
    ping() {
      return Promise.resolve({ ok: true, status: 200, latency_ms: 1 });
    },
  } as unknown as CentralCaller;
  return {
    calls,
    roleCalls,
    caller,
    serviceRole: 'service-key',
    fetchAdminRole: (url, uid, jwt) => {
      roleCalls.push([url, uid, jwt]);
      return Promise.resolve(role);
    },
  };
}

Deno.test('candidatures-list : admin => liste de son immeuble', async () => {
  const deps = makeDeps('admin', () => ({ ok: true, data: [{ id: CAND_ID, status: 'recu' }] }));
  const out = await handleCandidaturesList(CLAIMS, BUILDING, 'jwt-user', deps);
  assertEquals(out.status, 200);
  assertEquals(out.body, { building_id: 'building-a-uuid', candidatures: [{ id: CAND_ID, status: 'recu' }] });
  assertEquals(deps.roleCalls[0], ['https://a.supabase.co', 'user-a-uuid', 'jwt-user']);
  assertEquals(deps.calls[0], {
    name: 'list_candidatures_for_building',
    params: { p_building_id: 'building-a-uuid' },
    key: 'service-key',
  });
});

Deno.test('candidatures-list : principal_admin accepte', async () => {
  const deps = makeDeps('principal_admin', () => ({ ok: true, data: [] }));
  const out = await handleCandidaturesList(CLAIMS, BUILDING, 'jwt', deps);
  assertEquals(out.status, 200);
});

Deno.test('candidatures-list : resident => 403, aucune RPC appelee', async () => {
  const deps = makeDeps('tenant', () => ({ ok: true, data: [{ id: 'fuite' }] }));
  const out = await handleCandidaturesList(CLAIMS, BUILDING, 'jwt', deps);
  assertEquals(out.status, 403);
  assertEquals(out.body, { error: 'NOT_ADMIN' });
  assertEquals(deps.calls.length, 0);
});

Deno.test('candidatures-list : role illisible (instance federee, panne) => 403', async () => {
  const deps = makeDeps(null, () => ({ ok: true, data: [] }));
  const out = await handleCandidaturesList(CLAIMS, BUILDING, 'jwt', deps);
  assertEquals(out.status, 403);
  assertEquals(deps.calls.length, 0);
});

Deno.test('candidatures-list : echec RPC => 502', async () => {
  const deps = makeDeps('admin', () => ({ ok: false, status: 500, error: 'RPC_FAILED', body: 'x' }));
  const out = await handleCandidaturesList(CLAIMS, BUILDING, 'jwt', deps);
  assertEquals(out.status, 502);
});

Deno.test('candidatures-decide : building_id du corps ignore, celui du jeton impose', async () => {
  const deps = makeDeps('admin', () => ({
    ok: true,
    data: { id: CAND_ID, status: 'accepte', applicant_email: 'pii@exemple.com', annual_income: 90000 },
  }));
  const body = { candidature_id: CAND_ID, decision: 'accepte', building_id: 'building-B-uuid' };
  const out = await handleCandidaturesDecide(CLAIMS, body as never, BUILDING, 'jwt', deps);
  assertEquals(out.status, 200);
  assertEquals(deps.calls[0].params, {
    p_candidature_id: CAND_ID,
    p_decision: 'accepte',
    p_building_id: 'building-a-uuid',
  });
  // Pas de donnees personnelles dans la reponse.
  assertEquals(out.body, { id: CAND_ID, status: 'accepte' });
});

Deno.test('candidatures-decide : resident => 403, aucune RPC appelee', async () => {
  const deps = makeDeps('tenant', () => ({ ok: true, data: {} }));
  const out = await handleCandidaturesDecide(
    CLAIMS, { candidature_id: CAND_ID, decision: 'refuse' }, BUILDING, 'jwt', deps,
  );
  assertEquals(out.status, 403);
  assertEquals(deps.calls.length, 0);
});

Deno.test('candidatures-decide : entrees invalides => 400 avant toute verification', async () => {
  const deps = makeDeps('admin', () => ({ ok: true, data: {} }));
  const cas: Array<[unknown, string]> = [
    [null, 'MISSING_BODY'],
    [{ candidature_id: 'pas-un-uuid', decision: 'accepte' }, 'INVALID_CANDIDATURE_ID'],
    [{ candidature_id: CAND_ID, decision: 'supprime' }, 'INVALID_DECISION'],
    [{ candidature_id: CAND_ID }, 'INVALID_DECISION'],
  ];
  for (const [body, code] of cas) {
    const out = await handleCandidaturesDecide(CLAIMS, body as never, BUILDING, 'jwt', deps);
    assertEquals(out.status, 400, code);
    assertEquals(out.body, { error: code });
  }
  assertEquals(deps.roleCalls.length, 0);
  assertEquals(deps.calls.length, 0);
});

Deno.test('candidatures-decide : candidature d\'un autre immeuble => 404 neutre', async () => {
  const deps = makeDeps('admin', () => ({
    ok: false, status: 400, error: 'RPC_FAILED',
    body: { code: 'P0002', message: 'Candidature introuvable ou hors scope' },
  }));
  const out = await handleCandidaturesDecide(
    CLAIMS, { candidature_id: CAND_ID, decision: 'en_evaluation' }, BUILDING, 'jwt', deps,
  );
  assertEquals(out.status, 404);
  assertEquals(out.body, { error: 'CANDIDATURE_NOT_FOUND' });
});
