// Tests du handler /lunch-purchase avec un CentralCaller fake.
// Valide : validation de payload, mapping des erreurs metier (402/409/400),
// transmission des parametres a la RPC, protection CLIENT_ID_MISMATCH.

import { assertEquals } from './_assert.ts';
import { handleLunchPurchase } from '../handlers/lunch_purchase.ts';
import type { CentralCaller, CentralRpcResult } from '../lib/central.ts';
import type { ResolvedClaims } from '../lib/types.ts';

const CLAIMS: ResolvedClaims = {
  client_id: 'client-a-uuid',
  building_id: 'building-a-uuid',
  cohabitat_user_id: 'user-a-uuid',
};

function fakeCaller(
  impl: (name: string, params: Record<string, unknown>) => CentralRpcResult<unknown>,
): CentralCaller & { calls: Array<{ name: string; params: Record<string, unknown> }> } {
  const calls: Array<{ name: string; params: Record<string, unknown> }> = [];
  return {
    calls,
    async callRpc(name, params) {
      calls.push({ name, params });
      return impl(name, params) as CentralRpcResult<unknown>;
    },
  } as ReturnType<typeof fakeCaller>;
}

const BASE_BODY = {
  machine_id: 'MACH-01',
  amount: 5.00,
  idempotency_key: 'key-xyz',
};

Deno.test('lunch-purchase : happy path', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{
      transaction_id: 'tx-1',
      lunch_audit_id: 'audit-1',
      virtual_balance: '25.00',
      idempotent_replay: false,
    }],
  }));
  const out = await handleLunchPurchase(CLAIMS, BASE_BODY, caller, 'sr');
  assertEquals(out.status, 200);
  const body = out.body as { virtual_balance: number; transaction_id: string };
  assertEquals(body.virtual_balance, 25);
  assertEquals(body.transaction_id, 'tx-1');
  assertEquals(caller.calls[0].name, 'lunch_purchase');
  assertEquals(caller.calls[0].params.p_client_id, 'client-a-uuid');
  assertEquals(caller.calls[0].params.p_building_id, 'building-a-uuid');
  assertEquals(caller.calls[0].params.p_amount, 5);
  assertEquals(caller.calls[0].params.p_idempotency_key, 'key-xyz');
});

Deno.test('lunch-purchase : replay retourne 200 avec idempotent_replay=true', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{
      transaction_id: 'tx-1', lunch_audit_id: 'audit-1',
      virtual_balance: '25.00', idempotent_replay: true,
    }],
  }));
  const out = await handleLunchPurchase(CLAIMS, BASE_BODY, caller, 'sr');
  assertEquals(out.status, 200);
  assertEquals((out.body as { idempotent_replay: boolean }).idempotent_replay, true);
});

Deno.test('lunch-purchase : solde insuffisant => 402', async () => {
  const caller = fakeCaller(() => ({
    ok: false, status: 400, error: 'RPC_FAILED',
    body: { code: '23514', message: 'insufficient_funds : requested -100, available 30' },
  }));
  const out = await handleLunchPurchase(CLAIMS, BASE_BODY, caller, 'sr');
  assertEquals(out.status, 402);
  assertEquals((out.body as { error: string }).error, 'INSUFFICIENT_FUNDS');
});

Deno.test('lunch-purchase : idempotency_key_collision => 409', async () => {
  const caller = fakeCaller(() => ({
    ok: false, status: 400, error: 'RPC_FAILED',
    body: { code: '23505', message: 'idempotency_key_collision' },
  }));
  const out = await handleLunchPurchase(CLAIMS, BASE_BODY, caller, 'sr');
  assertEquals(out.status, 409);
  assertEquals((out.body as { error: string }).error, 'IDEMPOTENCY_KEY_COLLISION');
});

Deno.test('lunch-purchase : body reclame un autre client_id => 403', async () => {
  const caller = fakeCaller(() => {
    throw new Error('ne doit pas etre appele');
  });
  const out = await handleLunchPurchase(
    CLAIMS,
    { ...BASE_BODY, client_id: 'client-b-uuid' },
    caller,
    'sr',
  );
  assertEquals(out.status, 403);
  assertEquals((out.body as { error: string }).error, 'CLIENT_ID_MISMATCH');
  assertEquals(caller.calls.length, 0);
});

Deno.test('lunch-purchase : machine_id manquant => 400', async () => {
  const caller = fakeCaller(() => { throw new Error('ne doit pas etre appele'); });
  const out = await handleLunchPurchase(
    CLAIMS,
    { ...BASE_BODY, machine_id: '' },
    caller,
    'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'MISSING_MACHINE_ID');
});

Deno.test('lunch-purchase : amount negatif ou zero => 400', async () => {
  const caller = fakeCaller(() => { throw new Error('ne doit pas etre appele'); });
  for (const amount of [0, -1, NaN, Infinity]) {
    const out = await handleLunchPurchase(
      CLAIMS,
      { ...BASE_BODY, amount },
      caller,
      'sr',
    );
    assertEquals(out.status, 400, `amount=${amount}`);
    assertEquals((out.body as { error: string }).error, 'INVALID_AMOUNT');
  }
});

Deno.test('lunch-purchase : idempotency_key manquant => 400', async () => {
  const caller = fakeCaller(() => { throw new Error('ne doit pas etre appele'); });
  const out = await handleLunchPurchase(
    CLAIMS,
    { ...BASE_BODY, idempotency_key: '' },
    caller,
    'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'MISSING_IDEMPOTENCY_KEY');
});

Deno.test('lunch-purchase : dependent_id passe en p_dep_external_id', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{
      transaction_id: 'tx-1', lunch_audit_id: 'audit-1',
      virtual_balance: '10.00', idempotent_replay: false,
    }],
  }));
  await handleLunchPurchase(
    CLAIMS,
    { ...BASE_BODY, dependent_id: 'dep-42', slot_id: 'slot-1', buyer_name: 'Lya' },
    caller,
    'sr',
  );
  assertEquals(caller.calls[0].params.p_dep_external_id, 'dep-42');
  assertEquals(caller.calls[0].params.p_slot_id, 'slot-1');
  assertEquals(caller.calls[0].params.p_buyer_name, 'Lya');
});

Deno.test('lunch-purchase : body null => 400', async () => {
  const caller = fakeCaller(() => { throw new Error('ne doit pas etre appele'); });
  const out = await handleLunchPurchase(CLAIMS, null, caller, 'sr');
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'MISSING_BODY');
});
