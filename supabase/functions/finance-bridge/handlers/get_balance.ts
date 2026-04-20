// Endpoint /get-balance : appelle la RPC centrale get_balance avec un JWT
// re-mint. Le body client reclame optionnellement un dependent_id ; on
// verifie qu'il ne reclame pas un client_id different du JWT.

import type { ResolvedClaims } from '../lib/types.ts';
import type { CentralCaller } from '../lib/central.ts';

export interface GetBalanceRequest {
  client_id?: string;        // optionnel, verifie == claims.client_id
  dependent_id?: string | null;
}

// Retour de la RPC PostgREST (table function => array de rows).
interface RpcRow {
  virtual_balance: number;
  source_kind: 'main' | 'dependent' | 'missing';
  updated_at: string | null;
}

export interface GetBalanceResponse {
  client_id: string;
  building_id: string;
  dependent_id: string | null;
  virtual_balance: number;
  source: 'central';
  source_kind: 'main' | 'dependent' | 'missing';
  updated_at: string | null;
}

export async function handleGetBalance(
  claims: ResolvedClaims,
  body: GetBalanceRequest | null,
  caller: CentralCaller,
  centralJwt: string,
): Promise<{ status: number; body: GetBalanceResponse | { error: string; detail?: unknown } }> {
  if (body && body.client_id && body.client_id !== claims.client_id) {
    return { status: 403, body: { error: 'CLIENT_ID_MISMATCH' } };
  }

  const depId = body?.dependent_id ?? null;
  const res = await caller.callRpc<RpcRow[]>(
    'get_balance',
    { p_external_dep_id: depId },
    centralJwt,
  );

  if (!res.ok) {
    return {
      status: res.status === 401 || res.status === 403 ? res.status : 502,
      body: { error: 'CENTRAL_RPC_FAILED', detail: res.body },
    };
  }

  // PostgREST retourne un tableau pour les table-functions. Notre RPC
  // garantit toujours au moins un row (row 'missing' si pas de solde).
  const row = Array.isArray(res.data) ? res.data[0] : null;
  if (!row) {
    return { status: 502, body: { error: 'CENTRAL_RPC_EMPTY' } };
  }

  return {
    status: 200,
    body: {
      client_id: claims.client_id,
      building_id: claims.building_id,
      dependent_id: depId,
      virtual_balance: Number(row.virtual_balance),
      source: 'central',
      source_kind: row.source_kind,
      updated_at: row.updated_at,
    },
  };
}
