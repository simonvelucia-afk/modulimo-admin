// Tests du handler /health avec un CentralCaller fake.
// Valide : ok quand ping ok, 503 quand ping ko, 503 quand service_role manque.

import { assertEquals } from './_assert.ts';
import { handleHealth } from '../handlers/health.ts';
import type { CentralCaller, CentralPingResult, CentralRpcResult } from '../lib/central.ts';

function fakeCaller(ping: () => CentralPingResult): CentralCaller {
  return {
    async callRpc<T>(): Promise<CentralRpcResult<T>> {
      throw new Error('callRpc ne devrait pas etre appele par /health');
    },
    async ping() {
      return ping();
    },
  };
}

Deno.test('health : 200 quand ping ok', async () => {
  const caller = fakeCaller(() => ({ ok: true, status: 200, latency_ms: 17 }));
  const out = await handleHealth(caller, 'sb_secret_xxx');
  assertEquals(out.status, 200);
  const body = out.body as { ok: boolean; latency_ms: number };
  assertEquals(body.ok, true);
  assertEquals(body.latency_ms, 17);
});

Deno.test('health : 503 quand ping ko', async () => {
  const caller = fakeCaller(() => ({
    ok: false,
    status: 0,
    latency_ms: 3001,
    error: 'aborted',
  }));
  const out = await handleHealth(caller, 'sb_secret_xxx');
  assertEquals(out.status, 503);
  const body = out.body as { ok: boolean; error: string; latency_ms?: number };
  assertEquals(body.ok, false);
  assertEquals(body.error, 'CENTRAL_UNREACHABLE');
  assertEquals(body.latency_ms, 3001);
});

Deno.test('health : 503 quand service_role absent', async () => {
  const caller = fakeCaller(() => ({ ok: true, status: 200, latency_ms: 5 }));
  const out = await handleHealth(caller, '');
  assertEquals(out.status, 503);
  const body = out.body as { ok: boolean; error: string };
  assertEquals(body.ok, false);
  assertEquals(body.error, 'SERVICE_ROLE_MISSING');
});
