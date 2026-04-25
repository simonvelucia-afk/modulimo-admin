// Endpoint POST /finance-bridge/transfer-to-dep : transfere un montant
// du solde principal du resident vers le solde d'un de ses dependants,
// atomique cote central via la RPC transfer_to_dependent_central.
//
// Le resident agit sur LUI-MEME (claims.client_id == cible debit) et
// designe le dependant via dependent_id (mappe a external_dep_id cote
// central). Une seule cle d'idempotence cote client pilote les deux
// jambes de l'ecriture (parent/dep) — la RPC en derive ":out" et ":in".

import type { ResolvedClaims } from '../lib/types.ts';
import type { CentralCaller } from '../lib/central.ts';

export interface TransferToDepRequest {
  client_id?: string;          // optionnel, doit matcher claims.client_id
  dependent_id: string;        // external_dep_id (uuid CoHabitat dependents.id)
  amount: number;              // strictement > 0
  description?: string | null;
  idempotency_key: string;     // unique par tentative de transfert
}

interface RpcRow {
  parent_transaction_id: string;
  dep_transaction_id: string;
  parent_balance_after: number | string;
  dep_balance_after: number | string;
  dep_id: string;
  idempotent_replay: boolean;
}

export interface TransferToDepResponse {
  client_id: string;
  building_id: string;
  parent_transaction_id: string;
  dep_transaction_id: string;
  parent_balance_after: number;
  dep_balance_after: number;
  dep_id: string;
  idempotent_replay: boolean;
}

export async function handleTransferToDep(
  claims: ResolvedClaims,
  body: TransferToDepRequest | null,
  caller: CentralCaller,
  serviceRole: string,
): Promise<{
  status: number;
  body: TransferToDepResponse | { error: string; detail?: unknown };
}> {
  if (!body) return { status: 400, body: { error: 'MISSING_BODY' } };
  if (body.client_id && body.client_id !== claims.client_id) {
    return { status: 403, body: { error: 'CLIENT_ID_MISMATCH' } };
  }
  if (!body.dependent_id || typeof body.dependent_id !== 'string') {
    return { status: 400, body: { error: 'MISSING_DEPENDENT_ID' } };
  }
  if (typeof body.amount !== 'number' || !Number.isFinite(body.amount) || body.amount <= 0) {
    return { status: 400, body: { error: 'INVALID_AMOUNT' } };
  }
  if (!body.idempotency_key || typeof body.idempotency_key !== 'string') {
    return { status: 400, body: { error: 'MISSING_IDEMPOTENCY_KEY' } };
  }

  const res = await caller.callRpc<RpcRow[]>(
    'transfer_to_dependent_central',
    {
      p_client_id: claims.client_id,
      p_building_id: claims.building_id,
      p_dep_external_id: body.dependent_id,
      p_amount: body.amount,
      p_idempotency_key: body.idempotency_key,
      p_description: body.description ?? null,
      p_created_by: null,
    },
    serviceRole,
  );

  if (!res.ok) {
    const detail = res.body as { code?: string; message?: string } | undefined;
    const code = detail?.code;
    const msg  = detail?.message ?? '';
    if (code === '23514' || msg.includes('insufficient_funds')) {
      return { status: 402, body: { error: 'INSUFFICIENT_FUNDS', detail: res.body } };
    }
    if (code === '22023') return { status: 400, body: { error: 'INVALID_PARAMETER', detail: res.body } };
    if (code === '23505') return { status: 409, body: { error: 'IDEMPOTENCY_KEY_COLLISION', detail: res.body } };
    return { status: 502, body: { error: 'CENTRAL_RPC_FAILED', detail: res.body } };
  }

  const row = Array.isArray(res.data) ? res.data[0] : null;
  if (!row) return { status: 502, body: { error: 'CENTRAL_RPC_EMPTY' } };

  return {
    status: 200,
    body: {
      client_id: claims.client_id,
      building_id: claims.building_id,
      parent_transaction_id: row.parent_transaction_id,
      dep_transaction_id: row.dep_transaction_id,
      parent_balance_after: Number(row.parent_balance_after),
      dep_balance_after: Number(row.dep_balance_after),
      dep_id: row.dep_id,
      idempotent_replay: row.idempotent_replay,
    },
  };
}
