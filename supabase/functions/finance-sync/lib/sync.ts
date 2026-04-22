// Coeur du worker de sync : pour UN immeuble, pull les nouvelles
// transactions depuis CoHabitat et les rejoue sur central via
// adjust_balance avec idempotency_key stable.

import type {
  BuildingToSync,
  CohabitatTransaction,
  SyncResult,
} from './types.ts';

export interface SyncDeps {
  // Lecture des transactions CoHabitat nouvelles depuis le curseur.
  // Doit retourner les rows en ordre chronologique (created_at asc, id asc)
  // limite au batch. Vide => rien a sync.
  fetchCohabitatTxSince: (
    building: BuildingToSync,
    limit: number,
  ) => Promise<CohabitatTransaction[]>;

  // Resolution cohabitat_user_id -> central client_id pour un immeuble.
  // Un Map pre-charge au debut du run evite un roundtrip par tx.
  loadClientMap: (
    buildingId: string,
  ) => Promise<Map<string, string>>;

  // Appelle adjust_balance sur central. Doit retourner true si la tx a
  // ete appliquee (ou replay idempotent), false si erreur (la tx est
  // comptee dans errors et le cursor ne progresse pas).
  callAdjustBalance: (params: {
    client_id: string;
    building_id: string;
    amount: number;
    type: string;
    reference_id: string | null;
    reference_type: string | null;
    description: string | null;
    idempotency_key: string;
    created_by: string | null;
  }) => Promise<{ ok: true; replayed: boolean } | { ok: false; error: string }>;

  // Persiste la progression + metriques du run.
  recordProgress: (r: SyncResult) => Promise<void>;
}

export async function syncBuilding(
  building: BuildingToSync,
  deps: SyncDeps,
  batchSize = 200,
): Promise<SyncResult> {
  const result: SyncResult = {
    building_id: building.building_id,
    applied: 0,
    replayed: 0,
    skipped: 0,
    errors: 0,
    last_synced_tx_id: building.last_synced_tx_id,
    last_synced_at: building.last_synced_at,
    error_message: null,
  };

  let clientMap: Map<string, string>;
  try {
    clientMap = await deps.loadClientMap(building.building_id);
  } catch (e) {
    result.errors++;
    result.error_message = `loadClientMap failed: ${(e as Error).message}`;
    await deps.recordProgress(result).catch(() => {});
    return result;
  }

  let txs: CohabitatTransaction[];
  try {
    txs = await deps.fetchCohabitatTxSince(building, batchSize);
  } catch (e) {
    result.errors++;
    result.error_message = `fetchCohabitatTxSince failed: ${(e as Error).message}`;
    await deps.recordProgress(result).catch(() => {});
    return result;
  }

  // Applique dans l'ordre. Cursor ne progresse QUE pour les tx
  // successfully appliquees contigues. Une erreur interrompt l'avancee
  // pour que le prochain run reessaye la meme tx.
  for (const tx of txs) {
    const clientId = clientMap.get(tx.user_id);
    if (!clientId) {
      result.skipped++;
      // On skip mais on laisse le cursor avancer : le profile n'a pas
      // de mapping, ses tx ne seront jamais repliees tant que le
      // provisioning manuel n'a pas ete fait. C'est un etat connu,
      // pas une erreur qui bloque le pipeline.
      result.last_synced_tx_id = tx.id;
      result.last_synced_at = tx.created_at;
      continue;
    }

    const amount = Number(tx.amount);
    if (!Number.isFinite(amount) || amount === 0) {
      // Ne devrait pas arriver mais protege contre les donnees corrompues.
      result.errors++;
      result.error_message = `invalid amount on cohabitat tx ${tx.id}`;
      break;  // stop pour investigation
    }

    const res = await deps.callAdjustBalance({
      client_id: clientId,
      building_id: building.building_id,
      amount,
      type: tx.type,
      reference_id: tx.reference_id,
      reference_type: tx.reference_type,
      description: tx.description,
      idempotency_key: `backfill:${tx.id}`,
      created_by: tx.created_by,
    });

    if (!res.ok) {
      result.errors++;
      result.error_message = `adjust_balance failed on tx ${tx.id}: ${res.error}`;
      break;  // arret pour que la prochaine run reessaye
    }

    if (res.replayed) result.replayed++;
    else result.applied++;
    result.last_synced_tx_id = tx.id;
    result.last_synced_at = tx.created_at;
  }

  await deps.recordProgress(result).catch((e) => {
    // Si on ne peut pas persister, au moins ca remonte dans les logs.
    result.error_message = `recordProgress failed: ${(e as Error).message}`;
  });

  return result;
}
