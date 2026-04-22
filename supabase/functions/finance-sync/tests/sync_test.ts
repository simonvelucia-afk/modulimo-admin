// Tests unitaires de syncBuilding avec des adapters in-memory.
// Aucune dependance reseau.

import { assertEquals } from './_assert.ts';
import { syncBuilding } from '../lib/sync.ts';
import type { SyncDeps } from '../lib/sync.ts';
import type {
  BuildingToSync,
  CohabitatTransaction,
  SyncResult,
} from '../lib/types.ts';

const BUILDING: BuildingToSync = {
  building_id: 'b1',
  supabase_url: 'https://x.local',
  last_synced_at: null,
  last_synced_tx_id: null,
};

function deps(overrides: Partial<SyncDeps> & {
  txs?: CohabitatTransaction[];
  clients?: Record<string, string>;
  recordProgressCalls?: SyncResult[];
  adjustResults?: Array<{ ok: true; replayed: boolean } | { ok: false; error: string }>;
} = {}): SyncDeps {
  const txs = overrides.txs ?? [];
  const clients = overrides.clients ?? {};
  const adjustResults = overrides.adjustResults ?? [];
  let i = 0;
  return {
    fetchCohabitatTxSince: overrides.fetchCohabitatTxSince
      ?? (async () => txs),
    loadClientMap: overrides.loadClientMap
      ?? (async () => new Map(Object.entries(clients))),
    callAdjustBalance: overrides.callAdjustBalance
      ?? (async () => adjustResults[i++] ?? { ok: true, replayed: false }),
    recordProgress: overrides.recordProgress
      ?? (async (r) => { overrides.recordProgressCalls?.push(r); }),
  };
}

function tx(id: string, user_id: string, amount: string, created_at: string): CohabitatTransaction {
  return {
    id, user_id, amount, created_at,
    type: 'admin_credit', reference_id: null, reference_type: null,
    description: null, created_by: null,
  };
}

Deno.test('sync : happy path, 2 tx appliquees, cursor avance', async () => {
  const result = await syncBuilding(BUILDING, deps({
    txs: [
      tx('tx1', 'u1', '10', '2026-04-01T00:00:00Z'),
      tx('tx2', 'u1', '-5', '2026-04-01T00:01:00Z'),
    ],
    clients: { 'u1': 'c1' },
    adjustResults: [
      { ok: true, replayed: false },
      { ok: true, replayed: false },
    ],
  }));
  assertEquals(result.applied, 2);
  assertEquals(result.replayed, 0);
  assertEquals(result.errors, 0);
  assertEquals(result.last_synced_tx_id, 'tx2');
  assertEquals(result.last_synced_at, '2026-04-01T00:01:00Z');
});

Deno.test('sync : replay idempotent compte comme replayed', async () => {
  const result = await syncBuilding(BUILDING, deps({
    txs: [tx('tx1', 'u1', '10', '2026-04-01T00:00:00Z')],
    clients: { 'u1': 'c1' },
    adjustResults: [{ ok: true, replayed: true }],
  }));
  assertEquals(result.applied, 0);
  assertEquals(result.replayed, 1);
  assertEquals(result.errors, 0);
});

Deno.test('sync : profile sans client central => skipped, cursor avance', async () => {
  const result = await syncBuilding(BUILDING, deps({
    txs: [
      tx('tx1', 'u-unknown', '10', '2026-04-01T00:00:00Z'),
      tx('tx2', 'u1', '20', '2026-04-01T00:01:00Z'),
    ],
    clients: { 'u1': 'c1' },
    adjustResults: [{ ok: true, replayed: false }],
  }));
  assertEquals(result.applied, 1);
  assertEquals(result.skipped, 1);
  assertEquals(result.errors, 0);
  assertEquals(result.last_synced_tx_id, 'tx2');
});

Deno.test('sync : erreur adjust_balance stoppe le run, cursor pas avance sur la tx en echec', async () => {
  const result = await syncBuilding(BUILDING, deps({
    txs: [
      tx('tx1', 'u1', '10', '2026-04-01T00:00:00Z'),
      tx('tx2', 'u1', '20', '2026-04-01T00:01:00Z'),
      tx('tx3', 'u1', '30', '2026-04-01T00:02:00Z'),
    ],
    clients: { 'u1': 'c1' },
    adjustResults: [
      { ok: true, replayed: false },
      { ok: false, error: 'timeout' },
      { ok: true, replayed: false }, // ne devrait pas etre appele
    ],
  }));
  assertEquals(result.applied, 1);
  assertEquals(result.errors, 1);
  assertEquals(result.last_synced_tx_id, 'tx1');
  assertEquals(result.error_message?.includes('tx2'), true);
});

Deno.test('sync : loadClientMap throw => erreur remontee sans applique', async () => {
  const result = await syncBuilding(BUILDING, deps({
    loadClientMap: async () => { throw new Error('network'); },
  }));
  assertEquals(result.applied, 0);
  assertEquals(result.errors, 1);
  assertEquals(result.error_message?.includes('loadClientMap'), true);
});

Deno.test('sync : amount invalide stoppe + error', async () => {
  const result = await syncBuilding(BUILDING, deps({
    txs: [tx('tx1', 'u1', 'NaN', '2026-04-01T00:00:00Z')],
    clients: { 'u1': 'c1' },
  }));
  assertEquals(result.applied, 0);
  assertEquals(result.errors, 1);
  assertEquals(result.error_message?.includes('invalid amount'), true);
});

Deno.test('sync : idempotency_key stable = backfill:<tx_id>', async () => {
  const calls: string[] = [];
  const result = await syncBuilding(BUILDING, deps({
    txs: [tx('abc123', 'u1', '10', '2026-04-01T00:00:00Z')],
    clients: { 'u1': 'c1' },
    callAdjustBalance: async (p) => {
      calls.push(p.idempotency_key);
      return { ok: true, replayed: false };
    },
  }));
  assertEquals(calls[0], 'backfill:abc123');
  assertEquals(result.applied, 1);
});

Deno.test('sync : recordProgress recoit le resultat final', async () => {
  const recorded: SyncResult[] = [];
  await syncBuilding(BUILDING, deps({
    txs: [tx('tx1', 'u1', '10', '2026-04-01T00:00:00Z')],
    clients: { 'u1': 'c1' },
    recordProgress: async (r) => { recorded.push(r); },
    adjustResults: [{ ok: true, replayed: false }],
  }));
  assertEquals(recorded.length, 1);
  assertEquals(recorded[0].applied, 1);
  assertEquals(recorded[0].last_synced_tx_id, 'tx1');
});
