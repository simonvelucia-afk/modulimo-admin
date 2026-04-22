// Tests du handler /debit avec un CentralCaller fake.

import { assertEquals } from './_assert.ts';
import { handleDebit } from '../handlers/debit.ts';
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

Deno.test('debit : happy path space_reservation', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{ transaction_id: 'tx-1', virtual_balance: '739.50', dependent_id: null, idempotent_replay: false }],
  }));
  const out = await handleDebit(
    CLAIMS,
    { amount: -11.50, type: 'space_reservation', idempotency_key: 'k1' },
    caller,
    'sr',
  );
  assertEquals(out.status, 200);
  assertEquals((out.body as { virtual_balance: number }).virtual_balance, 739.5);
  assertEquals(caller.calls[0].params.p_type, 'space_reservation');
});

Deno.test('debit : type non whitelist => 400', async () => {
  const caller = fakeCaller(() => { throw new Error('unreachable'); });
  const out = await handleDebit(
    CLAIMS,
    { amount: -10, type: 'admin_credit' as never, idempotency_key: 'k' },
    caller, 'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'TYPE_NOT_ALLOWED');
});

Deno.test('debit : debit_type avec amount positif => AMOUNT_SIGN_MISMATCH', async () => {
  const caller = fakeCaller(() => { throw new Error('unreachable'); });
  const out = await handleDebit(
    CLAIMS,
    { amount: 100, type: 'space_reservation', idempotency_key: 'k' },
    caller, 'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'AMOUNT_SIGN_MISMATCH');
});

Deno.test('debit : refund_type avec amount negatif => AMOUNT_SIGN_MISMATCH', async () => {
  const caller = fakeCaller(() => { throw new Error('unreachable'); });
  const out = await handleDebit(
    CLAIMS,
    { amount: -5, type: 'space_cancel_refund', idempotency_key: 'k' },
    caller, 'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'AMOUNT_SIGN_MISMATCH');
});

Deno.test('debit : space_cancel_refund accepte amount positif', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{ transaction_id: 'tx-2', virtual_balance: '750.00', dependent_id: null, idempotent_replay: false }],
  }));
  const out = await handleDebit(
    CLAIMS,
    { amount: 11.50, type: 'space_cancel_refund', idempotency_key: 'k2' },
    caller, 'sr',
  );
  assertEquals(out.status, 200);
});

Deno.test('debit : amount 0 refuse', async () => {
  const caller = fakeCaller(() => { throw new Error('unreachable'); });
  const out = await handleDebit(
    CLAIMS,
    { amount: 0, type: 'space_reservation', idempotency_key: 'k' },
    caller, 'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'INVALID_AMOUNT');
});

Deno.test('debit : INSUFFICIENT_FUNDS => 402', async () => {
  const caller = fakeCaller(() => ({
    ok: false, status: 400, error: 'RPC_FAILED',
    body: { code: '23514', message: 'insufficient_funds : requested -10000, available 10.00' },
  }));
  const out = await handleDebit(
    CLAIMS,
    { amount: -10000, type: 'space_reservation', idempotency_key: 'k' },
    caller, 'sr',
  );
  assertEquals(out.status, 402);
  assertEquals((out.body as { error: string }).error, 'INSUFFICIENT_FUNDS');
});

Deno.test('debit : client_id du body different du JWT => 403', async () => {
  const caller = fakeCaller(() => { throw new Error('unreachable'); });
  const out = await handleDebit(
    CLAIMS,
    { amount: -10, type: 'space_reservation', idempotency_key: 'k', client_id: 'other' },
    caller, 'sr',
  );
  assertEquals(out.status, 403);
  assertEquals((out.body as { error: string }).error, 'CLIENT_ID_MISMATCH');
});

Deno.test('debit : idempotency_key manquant => 400', async () => {
  const caller = fakeCaller(() => { throw new Error('unreachable'); });
  const out = await handleDebit(
    CLAIMS,
    { amount: -10, type: 'space_reservation' } as never,
    caller, 'sr',
  );
  assertEquals(out.status, 400);
  assertEquals((out.body as { error: string }).error, 'MISSING_IDEMPOTENCY_KEY');
});

Deno.test('debit : dependent_id passe en p_dep_external_id', async () => {
  const caller = fakeCaller(() => ({
    ok: true,
    data: [{ transaction_id: 't', virtual_balance: '0', dependent_id: 'd', idempotent_replay: false }],
  }));
  await handleDebit(
    CLAIMS,
    { amount: -2, type: 'space_reservation', idempotency_key: 'k', dependent_id: 'dep-42' },
    caller, 'sr',
  );
  assertEquals(caller.calls[0].params.p_dep_external_id, 'dep-42');
});
