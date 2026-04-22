#!/usr/bin/env -S deno run --allow-env --allow-net
// =====================================================================
// backfill-building-snapshot.ts — Alternative au backfill en ledger.
//
// Contexte : si le ledger CoHabitat historique ne balance pas avec la
// valeur actuelle de profiles.virtual_balance (ex : admin a UPDATE
// directement au lieu de passer par la RPC), le replay tx-par-tx echoue
// avec insufficient_funds. Ce script fait plutot un "snapshot" : une
// seule transaction admin_credit par resident, de montant = balance
// CoHabitat actuelle. Le solde central matche CoHabitat par
// construction, et le ledger central repart propre a partir de ce point.
//
// Historique detaille : reste dans CoHabitat (aucune modification), les
// futurs mouvements post-migration sont traces normalement via
// finance-sync + dual-write.
//
// Idempotent : idempotency_key="backfill-snapshot:<client_id>". Relancer
// ne re-credite pas. ATTENTION : si la balance CoHabitat a change entre
// deux runs, le 2e ne corrige PAS le delta (voir --force-delta si besoin).
//
// Usage :
//   CENTRAL_URL=https://bpxscgrbxjscicpnheep.supabase.co \
//   CENTRAL_SERVICE_ROLE=<jwt> \
//   COHABITAT_URL=https://uwyhrdjlwetcbtskijrs.supabase.co \
//   COHABITAT_SERVICE_ROLE=<jwt> \
//   BUILDING_ID=a41b3b31-1681-4cb1-b54c-69486d27e132 \
//   deno run --allow-env --allow-net scripts/backfill-building-snapshot.ts
//
// Options :
//   DRY_RUN=1  montre le plan sans ecrire
// =====================================================================

interface CohabitatProfile {
  id: string;               // = cohabitat_user_id
  email: string;
  full_name: string | null;
  virtual_balance: string;  // numeric en string depuis PostgREST
}

interface CentralClientRow {
  id: string;
  cohabitat_user_id: string;
}

interface CentralBalanceRow {
  client_id: string;
  virtual_balance: string;
}

interface SnapshotReport {
  building_id: string;
  dry_run: boolean;
  profiles_scanned: number;
  profiles_without_client: string[];
  credited: Array<{ client_id: string; amount: number; replayed: boolean }>;
  skipped_zero_balance: number;
  skipped_already_credited: Array<{ client_id: string; central: number; cohabitat: number }>;
  errors: number;
  cursor_initialized_at: string | null;
  cursor_initialized_tx_id: string | null;
}

function env(name: string, required = true): string {
  const v = Deno.env.get(name) ?? '';
  if (required && !v) {
    console.error(`Missing required env: ${name}`);
    Deno.exit(1);
  }
  return v;
}

async function pgGet<T>(base: string, key: string, path: string): Promise<T> {
  const res = await fetch(`${base}${path}`, {
    headers: { apikey: key },
  });
  if (!res.ok) throw new Error(`GET ${path} => ${res.status}: ${await res.text()}`);
  return await res.json() as T;
}

async function pgRpc<T>(
  base: string,
  key: string,
  fn: string,
  params: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`${base}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: key,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify(params),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`RPC ${fn} => ${res.status}: ${text}`);
  return (text ? JSON.parse(text) : null) as T;
}

async function main() {
  const CENTRAL_URL = env('CENTRAL_URL');
  const CENTRAL_SR = env('CENTRAL_SERVICE_ROLE');
  const COHAB_URL = env('COHABITAT_URL');
  const COHAB_SR = env('COHABITAT_SERVICE_ROLE');
  const BUILDING_ID = env('BUILDING_ID');
  const DRY_RUN = Deno.env.get('DRY_RUN') === '1';

  const report: SnapshotReport = {
    building_id: BUILDING_ID,
    dry_run: DRY_RUN,
    profiles_scanned: 0,
    profiles_without_client: [],
    credited: [],
    skipped_zero_balance: 0,
    skipped_already_credited: [],
    errors: 0,
    cursor_initialized_at: null,
    cursor_initialized_tx_id: null,
  };

  console.error(`=== Snapshot building=${BUILDING_ID} dry_run=${DRY_RUN} ===`);

  // 1. Mapping cohabitat_user_id -> central client_id
  const clients = await pgGet<CentralClientRow[]>(
    CENTRAL_URL, CENTRAL_SR,
    `/rest/v1/clients?select=id,cohabitat_user_id&building_id=eq.${BUILDING_ID}&cohabitat_user_id=not.is.null`,
  );
  const byCohabId = new Map(clients.map((c) => [c.cohabitat_user_id, c.id]));

  // 2. Balance deja presente cote central (si non-zero, on skip pour pas
  //    doubler en cas de relance apres mouvements reels).
  const existing = await pgGet<CentralBalanceRow[]>(
    CENTRAL_URL, CENTRAL_SR,
    `/rest/v1/balances?select=client_id,virtual_balance&building_id=eq.${BUILDING_ID}`,
  );
  const existingByClient = new Map(existing.map((r) => [r.client_id, Number(r.virtual_balance)]));

  // 3. Tous les profiles CoHabitat avec leur balance actuelle
  const profiles = await pgGet<CohabitatProfile[]>(
    COHAB_URL, COHAB_SR,
    `/rest/v1/profiles?select=id,email,full_name,virtual_balance&limit=10000`,
  );
  report.profiles_scanned = profiles.length;

  for (const p of profiles) {
    const clientId = byCohabId.get(p.id);
    if (!clientId) {
      report.profiles_without_client.push(p.id);
      continue;
    }

    const bal = Number(p.virtual_balance);
    if (!Number.isFinite(bal) || bal === 0) {
      report.skipped_zero_balance++;
      continue;
    }

    // Safety rail : si central a deja une balance non-nulle differente,
    // on signale pour investigation manuelle (un snapshot avait deja tourne
    // avec une valeur differente, ou un mouvement s'est glisse entre).
    const centralBal = existingByClient.get(clientId) ?? 0;
    if (centralBal !== 0 && Math.abs(centralBal - bal) > 0.001) {
      report.skipped_already_credited.push({
        client_id: clientId, central: centralBal, cohabitat: bal,
      });
      continue;
    }

    if (DRY_RUN) {
      report.credited.push({ client_id: clientId, amount: bal, replayed: false });
      continue;
    }

    try {
      const rows = await pgRpc<Array<{ idempotent_replay: boolean }>>(
        CENTRAL_URL, CENTRAL_SR, 'adjust_balance',
        {
          p_client_id: clientId,
          p_building_id: BUILDING_ID,
          p_amount: bal,
          p_type: 'admin_credit',
          p_reference_type: 'backfill_snapshot',
          p_description: `Backfill initial balance (snapshot migration)`,
          p_idempotency_key: `backfill-snapshot:${clientId}`,
          p_created_by: null,
        },
      );
      const replayed = rows?.[0]?.idempotent_replay ?? false;
      report.credited.push({ client_id: clientId, amount: bal, replayed });
    } catch (e) {
      report.errors++;
      console.error(`adjust_balance failed for ${clientId}: ${(e as Error).message}`);
    }
  }

  console.log(JSON.stringify(report, null, 2));

  if (report.errors > 0) {
    console.error(`\n${report.errors} erreur(s) — voir ci-dessus.`);
    Deno.exit(2);
  }
  if (report.skipped_already_credited.length > 0) {
    console.error(
      `\nATTENTION : ${report.skipped_already_credited.length} resident(s) ont deja une balance centrale differente. Investigation requise.`,
    );
    Deno.exit(3);
  }

  // 4. Initialise le sync_cursor a la derniere tx CoHabitat => le worker
  //    finance-sync n'empilera PAS l'historique sur le snapshot, il ne
  //    reprendra qu'a partir des nouveaux mouvements post-snapshot.
  //    Sans cette etape, le premier run de sync rejoue les 26 anciennes
  //    tx par-dessus le credit initial et corrompt le solde.
  if (!DRY_RUN) {
    try {
      const lastTx = await pgGet<Array<{ id: string; created_at: string }>>(
        COHAB_URL, COHAB_SR,
        `/rest/v1/transactions?select=id,created_at&order=created_at.desc,id.desc&limit=1`,
      );
      if (lastTx[0]) {
        await pgRpc(
          CENTRAL_URL, CENTRAL_SR, 'record_sync_progress',
          {
            p_building_id: BUILDING_ID,
            p_last_synced_at: lastTx[0].created_at,
            p_last_synced_tx_id: lastTx[0].id,
            p_applied: 0,
            p_replayed: 0,
            p_errors: 0,
            p_error_message: 'cursor_init_by_snapshot',
          },
        );
        report.cursor_initialized_at = lastTx[0].created_at;
        report.cursor_initialized_tx_id = lastTx[0].id;
      } else {
        report.cursor_initialized_tx_id = null;
      }
    } catch (e) {
      console.error(`cursor init failed: ${(e as Error).message}`);
      report.errors++;
    }
  }

  console.error('\nSnapshot OK. cursor_init=' + (report.cursor_initialized_tx_id ?? 'none'));
}

if (import.meta.main) {
  main().catch((e) => {
    console.error('FATAL :', e.message);
    Deno.exit(1);
  });
}
