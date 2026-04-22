// Implementations concretes des adapters pour finance-sync en prod.
// Toutes les requetes passent par PostgREST avec service_role.

import type {
  BuildingToSync,
  CohabitatTransaction,
  SyncResult,
} from './types.ts';
import type { SyncDeps } from './sync.ts';

export interface CentralEnv {
  url: string;
  serviceRole: string;
}

// Les credentials CoHabitat sont fournies en JSON via une env unique :
//   FINANCE_SYNC_COHABITAT_KEYS = {"<building_id>": "<service_role_jwt>"}
// Permet d'eviter de multiplier les secrets. A eviter en prod pour plus
// d'immeubles — voir Supabase Vault ou une table secrets chiffree.
export function loadCohabitatKeys(): Map<string, string> {
  const raw = Deno.env.get('FINANCE_SYNC_COHABITAT_KEYS') ?? '';
  if (!raw) return new Map();
  try {
    const obj = JSON.parse(raw) as Record<string, string>;
    return new Map(Object.entries(obj));
  } catch (e) {
    throw new Error(`FINANCE_SYNC_COHABITAT_KEYS is not valid JSON: ${(e as Error).message}`);
  }
}

export function makeCohabitatFetcher(cohabitatKeys: Map<string, string>) {
  return async (
    building: BuildingToSync,
    limit: number,
  ): Promise<CohabitatTransaction[]> => {
    const key = cohabitatKeys.get(building.building_id);
    if (!key) {
      throw new Error(`no FINANCE_SYNC_COHABITAT_KEYS entry for building ${building.building_id}`);
    }
    const url = new URL('/rest/v1/transactions', building.supabase_url);
    url.searchParams.set(
      'select',
      'id,user_id,amount,type,reference_id,reference_type,description,created_at,created_by',
    );
    if (building.last_synced_at) {
      url.searchParams.set('created_at', `gte.${building.last_synced_at}`);
    }
    url.searchParams.set('order', 'created_at.asc,id.asc');
    url.searchParams.set('limit', String(limit));

    const res = await fetch(url, {
      headers: { apikey: key },
    });
    if (!res.ok) {
      throw new Error(`cohabitat fetch ${res.status}: ${await res.text()}`);
    }
    const rows = await res.json() as CohabitatTransaction[];
    if (building.last_synced_tx_id && building.last_synced_at) {
      return rows.filter((r) => {
        if (r.created_at > building.last_synced_at!) return true;
        return r.id > building.last_synced_tx_id!;
      });
    }
    return rows;
  };
}

export function makeCentralAdapters(central: CentralEnv): Pick<
  SyncDeps,
  'loadClientMap' | 'callAdjustBalance' | 'recordProgress'
> {
  const headers = {
    apikey: central.serviceRole,
    'Content-Type': 'application/json',
  };

  return {
    loadClientMap: async (buildingId) => {
      const url = new URL('/rest/v1/clients', central.url);
      url.searchParams.set('select', 'id,cohabitat_user_id');
      url.searchParams.set('building_id', `eq.${buildingId}`);
      url.searchParams.set('cohabitat_user_id', 'not.is.null');
      const res = await fetch(url, { headers });
      if (!res.ok) {
        throw new Error(`loadClientMap ${res.status}: ${await res.text()}`);
      }
      const rows = await res.json() as Array<{ id: string; cohabitat_user_id: string }>;
      return new Map(rows.map((r) => [r.cohabitat_user_id, r.id]));
    },

    callAdjustBalance: async (params) => {
      const res = await fetch(`${central.url}/rest/v1/rpc/adjust_balance`, {
        method: 'POST',
        headers: { ...headers, Prefer: 'return=representation' },
        body: JSON.stringify({
          p_client_id: params.client_id,
          p_building_id: params.building_id,
          p_amount: params.amount,
          p_type: params.type,
          p_reference_id: params.reference_id,
          p_reference_type: params.reference_type,
          p_description: params.description,
          p_idempotency_key: params.idempotency_key,
          p_created_by: params.created_by,
        }),
      });
      if (!res.ok) {
        return { ok: false, error: `${res.status}: ${await res.text()}` };
      }
      const rows = await res.json() as Array<{ idempotent_replay: boolean }>;
      return { ok: true, replayed: rows[0]?.idempotent_replay ?? false };
    },

    recordProgress: async (r: SyncResult) => {
      await fetch(`${central.url}/rest/v1/rpc/record_sync_progress`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          p_building_id: r.building_id,
          p_last_synced_at: r.last_synced_at,
          p_last_synced_tx_id: r.last_synced_tx_id,
          p_applied: r.applied,
          p_replayed: r.replayed,
          p_errors: r.errors,
          p_error_message: r.error_message,
        }),
      });
    },
  };
}

export async function listBuildingsToSync(central: CentralEnv): Promise<BuildingToSync[]> {
  const res = await fetch(`${central.url}/rest/v1/rpc/list_buildings_to_sync`, {
    method: 'POST',
    headers: {
      apikey: central.serviceRole,
      'Content-Type': 'application/json',
    },
    body: '{}',
  });
  if (!res.ok) {
    throw new Error(`listBuildingsToSync ${res.status}: ${await res.text()}`);
  }
  return await res.json() as BuildingToSync[];
}
