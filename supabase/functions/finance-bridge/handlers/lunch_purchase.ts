// Endpoint POST /lunch-purchase : debit atomique pour un achat kiosk.
// Le client (kiosque) fournit un idempotency_key stable pour chaque
// tentative d'achat ; les retries avec la meme cle ne re-debitent pas.

import type { ResolvedClaims } from '../lib/types.ts';
import type { CentralCaller } from '../lib/central.ts';

export interface LunchPurchaseRequest {
  client_id?: string;            // optionnel, doit matcher claims.client_id
  machine_id: string;
  amount: number;                // toujours positif ; la RPC convertit en debit
  idempotency_key: string;       // requis ; unique par tentative d'achat
  dependent_id?: string | null;  // external_dep_id dans la terminologie RPC
  slot_id?: string | null;
  buyer_name?: string | null;
}

interface RpcRow {
  transaction_id: string;
  lunch_audit_id: string;
  virtual_balance: number | string;
  idempotent_replay: boolean;
}

export interface LunchPurchaseResponse {
  client_id: string;
  building_id: string;
  transaction_id: string;
  lunch_audit_id: string;
  virtual_balance: number;
  idempotent_replay: boolean;
}

export async function handleLunchPurchase(
  claims: ResolvedClaims,
  body: LunchPurchaseRequest | null,
  caller: CentralCaller,
  serviceRole: string,
): Promise<{
  status: number;
  body: LunchPurchaseResponse | { error: string; detail?: unknown };
}> {
  if (!body) {
    return { status: 400, body: { error: 'MISSING_BODY' } };
  }
  if (body.client_id && body.client_id !== claims.client_id) {
    return { status: 403, body: { error: 'CLIENT_ID_MISMATCH' } };
  }
  if (!body.machine_id || typeof body.machine_id !== 'string') {
    return { status: 400, body: { error: 'MISSING_MACHINE_ID' } };
  }
  if (typeof body.amount !== 'number' || !Number.isFinite(body.amount) || body.amount <= 0) {
    return { status: 400, body: { error: 'INVALID_AMOUNT' } };
  }
  if (!body.idempotency_key || typeof body.idempotency_key !== 'string') {
    return { status: 400, body: { error: 'MISSING_IDEMPOTENCY_KEY' } };
  }

  const res = await caller.callRpc<RpcRow[]>(
    'lunch_purchase',
    {
      p_client_id: claims.client_id,
      p_building_id: claims.building_id,
      p_machine_id: body.machine_id,
      p_amount: body.amount,
      p_idempotency_key: body.idempotency_key,
      p_dep_external_id: body.dependent_id ?? null,
      p_slot_id: body.slot_id ?? null,
      p_buyer_name: body.buyer_name ?? null,
    },
    serviceRole,
  );

  if (!res.ok) {
    // Mapping des erreurs metier :
    //   insufficient_funds  (SQLSTATE 23514)     -> 402 Payment Required
    //   invalid_parameter   (SQLSTATE 22023)     -> 400
    //   unique_violation    (SQLSTATE 23505, idempotency_key_collision) -> 409
    //   autre               -> 502
    const detail = res.body as { code?: string; message?: string } | undefined;
    const code = detail?.code;
    const msg = detail?.message ?? '';
    if (code === '23514' || msg.includes('insufficient_funds')) {
      return { status: 402, body: { error: 'INSUFFICIENT_FUNDS', detail: res.body } };
    }
    if (code === '22023') {
      return { status: 400, body: { error: 'INVALID_PARAMETER', detail: res.body } };
    }
    if (code === '23505') {
      return { status: 409, body: { error: 'IDEMPOTENCY_KEY_COLLISION', detail: res.body } };
    }
    return { status: 502, body: { error: 'CENTRAL_RPC_FAILED', detail: res.body } };
  }

  const row = Array.isArray(res.data) ? res.data[0] : null;
  if (!row) {
    return { status: 502, body: { error: 'CENTRAL_RPC_EMPTY' } };
  }

  return {
    status: 200,
    body: {
      client_id: claims.client_id,
      building_id: claims.building_id,
      transaction_id: row.transaction_id,
      lunch_audit_id: row.lunch_audit_id,
      virtual_balance: Number(row.virtual_balance),
      idempotent_replay: row.idempotent_replay,
    },
  };
}
