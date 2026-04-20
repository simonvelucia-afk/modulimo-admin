// Tests du handler /get-balance avec un CentralCaller fake.
// Valide : passage du dependent_id, refus du client_id forge, propagation
// des erreurs RPC, transformation de la reponse.

import { assertEquals } from './_assert.ts';
import { handleGetBalance } from '../handlers/get_balance.ts';
import type { CentralCaller, CentralRpcResult } from '../lib/central.ts';
import type { ResolvedClaims } from '../lib/types.ts';

const CLAIMS: ResolvedClaims = {
  client_id: 'client-a-uuid',
  building_id: 'building-a-uuid',
  cohabitat_user_id: 'user-a-uuid',
};

function fakeCaller(
  impl: (name: string, params: Record<string, unknown>) => CentralRpcResult<unknown>,
): CentralCaller & { calls: Array<{ name: string; params: Record<string, unknown>; jwt: string }> } {
  const calls: Array<{ name: string; params: Record<string, unknown>; jwt: string }> = [];
  return {
    calls,
    async callRpc(name, params, jwt) {
      calls.push({ name, params, jwt });
      return impl(name, params) as CentralRpcResult<unknown>;
    },
  } as ReturnType<typeof fakeCaller>;
}

Deno.test('get-balance : happy path solde principal', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{ virtual_balance: '42.00', source_kind: 'main', updated_at: '2026-01-01T00:00:00Z' }],
  }));
  const out = await handleGetBalance(CLAIMS, null, caller, 'jwt-central');
  assertEquals(out.status, 200);
  assertEquals((out.body as { virtual_balance: number }).virtual_balance, 42);
  assertEquals((out.body as { source_kind: string }).source_kind, 'main');
  assertEquals(caller.calls[0].name, 'get_balance');
  assertEquals(caller.calls[0].params, {
    p_client_id: 'client-a-uuid',
    p_building_id: 'building-a-uuid',
    p_external_dep_id: null,
  });
  assertEquals(caller.calls[0].jwt, 'jwt-central');
});

Deno.test('get-balance : client non provisionne => missing/0', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{ virtual_balance: '0.00', source_kind: 'missing', updated_at: null }],
  }));
  const out = await handleGetBalance(CLAIMS, null, caller, 'jwt');
  assertEquals(out.status, 200);
  assertEquals((out.body as { virtual_balance: number }).virtual_balance, 0);
  assertEquals((out.body as { source_kind: string }).source_kind, 'missing');
});

Deno.test('get-balance : dependent_id passe en parametre RPC', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{ virtual_balance: '15.50', source_kind: 'dependent', updated_at: '2026-01-01T00:00:00Z' }],
  }));
  const out = await handleGetBalance(CLAIMS, { dependent_id: 'dep-42' }, caller, 'jwt');
  assertEquals(out.status, 200);
  assertEquals(caller.calls[0].params, {
    p_client_id: 'client-a-uuid',
    p_building_id: 'building-a-uuid',
    p_external_dep_id: 'dep-42',
  });
  assertEquals((out.body as { dependent_id: string }).dependent_id, 'dep-42');
});

Deno.test('get-balance : body reclame un autre client_id => 403', async () => {
  const caller = fakeCaller(() => {
    throw new Error('RPC ne devrait pas etre appele');
  });
  const out = await handleGetBalance(CLAIMS, { client_id: 'client-b-uuid' }, caller, 'jwt');
  assertEquals(out.status, 403);
  assertEquals((out.body as { error: string }).error, 'CLIENT_ID_MISMATCH');
  assertEquals(caller.calls.length, 0);
});

Deno.test('get-balance : RPC echoue en 401 => propage 401', async () => {
  const caller = fakeCaller(() => ({
    ok: false, status: 401, error: 'RPC_FAILED', body: { message: 'JWT expired' },
  }));
  const out = await handleGetBalance(CLAIMS, null, caller, 'jwt');
  assertEquals(out.status, 401);
  assertEquals((out.body as { error: string }).error, 'CENTRAL_RPC_FAILED');
});

Deno.test('get-balance : RPC echoue en 500 => 502 bad gateway', async () => {
  const caller = fakeCaller(() => ({
    ok: false, status: 500, error: 'RPC_FAILED', body: { message: 'internal' },
  }));
  const out = await handleGetBalance(CLAIMS, null, caller, 'jwt');
  assertEquals(out.status, 502);
});

Deno.test('get-balance : RPC retourne tableau vide => 502', async () => {
  const caller = fakeCaller(() => ({ ok: true, data: [] }));
  const out = await handleGetBalance(CLAIMS, null, caller, 'jwt');
  assertEquals(out.status, 502);
  assertEquals((out.body as { error: string }).error, 'CENTRAL_RPC_EMPTY');
});
