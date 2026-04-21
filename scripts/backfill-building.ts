#!/usr/bin/env -S deno run --allow-env --allow-net
// =====================================================================
// backfill-building.ts — Migration des soldes d'un immeuble CoHabitat
//                       vers la DB centrale Modulimo (Phase 3 step 2).
//
// Contexte : chaque immeuble (ex. Pointe Est = uwyhrdjlwetcbtskijrs)
// tient aujourd'hui les soldes residents dans sa propre DB Supabase
// (profiles.virtual_balance + transactions). Avant d'activer la bascule
// vers central.balances, on copie l'etat existant sans rien perdre.
//
// Idempotence : chaque transaction CoHabitat est re-jouee via le RPC
// adjust_balance central avec un idempotency_key stable de la forme
// `backfill:<cohabitat_tx_id>`. Relancer le script ne produit pas de
// double debit.
//
// Pre-requis :
//   * clients.building_id + clients.cohabitat_user_id doivent deja
//     etre remplis pour tous les residents (mapping manuel ou via un
//     script de provisionnement). Les profiles CoHabitat sans ligne
//     clients correspondante sont skippes + reportes dans le rapport.
//   * L'Edge Function finance-bridge ne peut PAS etre utilisee ici car
//     elle valide un JWT d'utilisateur. On appelle PostgREST central
//     directement avec le service_role JWT (celui-la meme configure
//     comme FINANCE_SERVICE_ROLE_KEY sur la fonction, ou legacy du
//     dashboard).
//
// Usage :
//   CENTRAL_URL=https://bpxscgrbxjscicpnheep.supabase.co \
//   CENTRAL_SERVICE_ROLE=<legacy JWT service_role centrale> \
//   COHABITAT_URL=https://uwyhrdjlwetcbtskijrs.supabase.co \
//   COHABITAT_SERVICE_ROLE=<legacy JWT service_role immeuble> \
//   BUILDING_ID=a41b3b31-1681-4cb1-b54c-69486d27e132 \
//   deno run --allow-env --allow-net scripts/backfill-building.ts
//
// Options (env) :
//   DRY_RUN=1           n'ecrit rien sur central, affiche le plan
//   BATCH_SIZE=100      taille de page pour scanner les transactions
// =====================================================================

interface CohabitatProfile {
  id: string;               // cohabitat_user_id
  email: string;
  full_name: string | null;
  virtual_balance: string;
}

interface CohabitatTransaction {
  id: string;
  user_id: string;
  amount: string;
  balance_after: string;
  type: string;
  reference_id: string | null;
  reference_type: string | null;
  description: string | null;
  created_at: string;
  created_by: string | null;
  is_demo: boolean;
}

interface CentralClientRow {
  id: string;
  cohabitat_user_id: string;
}

interface AdjustBalanceResult {
  transaction_id: string;
  virtual_balance: string;
  dependent_id: string | null;
  idempotent_replay: boolean;
}

interface BackfillReport {
  building_id: string;
  profiles_scanned: number;
  profiles_without_client: string[];   // cohabitat_user_id list
  transactions_scanned: number;
  transactions_replayed: number;       // deja backfilles auparavant
  transactions_applied: number;        // nouvelles ecritures
  skipped_missing_client: number;
  divergences: Array<{
    client_id: string;
    central_balance: number;
    cohabitat_balance: number;
    diff: number;
  }>;
  dry_run: boolean;
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
    headers: { apikey: key, Authorization: `Bearer ${key}` },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GET ${path} => ${res.status}: ${body}`);
  }
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
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify(params),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`RPC ${fn} => ${res.status}: ${text}`);
  }
  return (text ? JSON.parse(text) : null) as T;
}

async function main() {
  const CENTRAL_URL = env('CENTRAL_URL');
  const CENTRAL_SR = env('CENTRAL_SERVICE_ROLE');
  const COHAB_URL = env('COHABITAT_URL');
  const COHAB_SR = env('COHABITAT_SERVICE_ROLE');
  const BUILDING_ID = env('BUILDING_ID');
  const DRY_RUN = Deno.env.get('DRY_RUN') === '1';
  const BATCH = Number(Deno.env.get('BATCH_SIZE') ?? '100');

  const report: BackfillReport = {
    building_id: BUILDING_ID,
    profiles_scanned: 0,
    profiles_without_client: [],
    transactions_scanned: 0,
    transactions_replayed: 0,
    transactions_applied: 0,
    skipped_missing_client: 0,
    divergences: [],
    dry_run: DRY_RUN,
  };

  console.error(`=== Backfill building=${BUILDING_ID} dry_run=${DRY_RUN} ===`);

  // 1. Charge le mapping cohabitat_user_id -> client_id (centrale)
  const clients = await pgGet<CentralClientRow[]>(
    CENTRAL_URL,
    CENTRAL_SR,
    `/rest/v1/clients?select=id,cohabitat_user_id&building_id=eq.${BUILDING_ID}&cohabitat_user_id=not.is.null`,
  );
  const clientByCohabUser = new Map(
    clients.map((c) => [c.cohabitat_user_id, c.id]),
  );
  console.error(`clients mappes : ${clientByCohabUser.size}`);

  // 2. Lit TOUS les profiles CoHabitat (pages de BATCH)
  const profiles: CohabitatProfile[] = [];
  for (let offset = 0; ; offset += BATCH) {
    const page = await pgGet<CohabitatProfile[]>(
      COHAB_URL,
      COHAB_SR,
      `/rest/v1/profiles?select=id,email,full_name,virtual_balance&limit=${BATCH}&offset=${offset}&order=created_at.asc`,
    );
    profiles.push(...page);
    if (page.length < BATCH) break;
  }
  report.profiles_scanned = profiles.length;
  console.error(`profiles CoHabitat : ${profiles.length}`);

  // 3. Verifie que chaque profile a un client central correspondant
  for (const p of profiles) {
    if (!clientByCohabUser.has(p.id)) {
      report.profiles_without_client.push(p.id);
    }
  }
  if (report.profiles_without_client.length > 0) {
    console.error(
      `ATTENTION : ${report.profiles_without_client.length} profile(s) sans row clients sur la centrale — seront skippes.`,
    );
  }

  // 4. Copie les transactions CoHabitat -> central, chronologiquement
  //    (pour que balance_after soit coherent a chaque pas). Utilise
  //    idempotency_key = `backfill:<cohabitat_tx_id>` pour que les runs
  //    successifs ne re-debitent pas.
  let offset = 0;
  while (true) {
    const page = await pgGet<CohabitatTransaction[]>(
      COHAB_URL,
      COHAB_SR,
      `/rest/v1/transactions?select=*&limit=${BATCH}&offset=${offset}&order=created_at.asc,id.asc`,
    );
    if (page.length === 0) break;

    for (const tx of page) {
      report.transactions_scanned++;
      const clientId = clientByCohabUser.get(tx.user_id);
      if (!clientId) {
        report.skipped_missing_client++;
        continue;
      }
      if (DRY_RUN) continue;

      const result = await pgRpc<AdjustBalanceResult[]>(
        CENTRAL_URL,
        CENTRAL_SR,
        'adjust_balance',
        {
          p_client_id: clientId,
          p_building_id: BUILDING_ID,
          p_amount: Number(tx.amount),
          p_type: tx.type === 'demo' ? 'demo' : tx.type,
          p_reference_id: tx.reference_id,
          p_reference_type: tx.reference_type,
          p_description: tx.description,
          p_idempotency_key: `backfill:${tx.id}`,
          p_created_by: tx.created_by,
        },
      );
      const row = result?.[0];
      if (row?.idempotent_replay) report.transactions_replayed++;
      else report.transactions_applied++;
    }
    offset += page.length;
    if (page.length < BATCH) break;
  }

  // 5. Compare central.balances avec le snapshot CoHabitat
  const snapshot = profiles
    .filter((p) => clientByCohabUser.has(p.id))
    .map((p) => ({
      cohabitat_user_id: p.id,
      virtual_balance: p.virtual_balance,
    }));

  if (!DRY_RUN) {
    const divergences = await pgRpc<Array<{
      client_id: string;
      central_balance: string;
      cohabitat_balance: string;
      diff: string;
    }>>(CENTRAL_URL, CENTRAL_SR, 'reconcile_vs_cohabitat', {
      p_building_id: BUILDING_ID,
      p_snapshot: snapshot,
      p_persist: true,
    });
    report.divergences = (divergences ?? []).map((d) => ({
      client_id: d.client_id,
      central_balance: Number(d.central_balance),
      cohabitat_balance: Number(d.cohabitat_balance),
      diff: Number(d.diff),
    }));
  }

  console.log(JSON.stringify(report, null, 2));

  if (report.divergences.length > 0) {
    console.error(
      `\nATTENTION : ${report.divergences.length} client(s) divergent apres backfill.`,
    );
    Deno.exit(2);
  }
  console.error('\nBackfill OK, aucune divergence.');
}

if (import.meta.main) {
  main().catch((e) => {
    console.error('FATAL :', e.message);
    Deno.exit(1);
  });
}
