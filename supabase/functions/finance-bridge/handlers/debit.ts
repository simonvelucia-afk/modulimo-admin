// Endpoint generique POST /finance-bridge/debit.
// Wrap adjust_balance avec whitelist de types pour que les residents
// puissent debiter leurs comptes (reservations, etc.) mais jamais se
// crediter hors des refunds prevus.

import type { ResolvedClaims } from '../lib/types.ts';
import type { CentralCaller } from '../lib/central.ts';

// Types autorises en tant que debit resident (amount doit etre < 0).
const ALLOWED_DEBIT_TYPES = [
  'space_reservation',
  'trip_booking',
  'trip_cancel_charge',
  'trip_driver_charge',
] as const;

// Types autorises en tant que refund resident (amount doit etre > 0).
// Un user ne peut refund qu'une transaction existante qu'il a lui-meme
// faite ; cela est garanti par le RLS + le reference_id fourni, pas
// par cette fonction. On whitelist juste les types.
//
// lunch_cancel_refund : utilise par le kiosque LunchMachine (P3) quand
// l'usager appuie "Annuler" en zone de cueillette apres une livraison
// pre-debitee a confirmReservation. Le robot remet le plateau et
// central recoit un refund idempotent qui annule le debit. La cle
// d'idempotence cote client est 'lunch:refund:' + idempotency_key
// d'origine, garantissant qu'un seul refund est applique meme si
// cancelPickup est rejoue par l'outbox.
const ALLOWED_REFUND_TYPES = [
  'space_cancel_refund',
  'trip_cancel_refund',
  'trip_driver_earning',
  'lunch_cancel_refund',
] as const;

type AllowedType =
  | typeof ALLOWED_DEBIT_TYPES[number]
  | typeof ALLOWED_REFUND_TYPES[number];

export interface DebitRequest {
  client_id?: string;          // optionnel, verifie == claims.client_id
  dependent_id?: string | null;
  amount: number;              // < 0 pour debit, > 0 pour refund
  type: AllowedType;
  description?: string | null;
  reference_id?: string | null;
  reference_type?: string | null;
  idempotency_key: string;
}

interface RpcRow {
  transaction_id: string;
  virtual_balance: number | string;
  dependent_id: string | null;
  idempotent_replay: boolean;
}

export interface DebitResponse {
  client_id: string;
  building_id: string;
  transaction_id: string;
  virtual_balance: number;
  idempotent_replay: boolean;
}

function isAllowedType(t: unknown): t is AllowedType {
  if (typeof t !== 'string') return false;
  return (ALLOWED_DEBIT_TYPES as readonly string[]).includes(t)
    || (ALLOWED_REFUND_TYPES as readonly string[]).includes(t);
}

function isDebitType(t: AllowedType): boolean {
  return (ALLOWED_DEBIT_TYPES as readonly string[]).includes(t);
}

export async function handleDebit(
  claims: ResolvedClaims,
  body: DebitRequest | null,
  caller: CentralCaller,
  serviceRole: string,
): Promise<{
  status: number;
  body: DebitResponse | { error: string; detail?: unknown };
}> {
  if (!body) return { status: 400, body: { error: 'MISSING_BODY' } };
  if (body.client_id && body.client_id !== claims.client_id) {
    return { status: 403, body: { error: 'CLIENT_ID_MISMATCH' } };
  }
  if (!isAllowedType(body.type)) {
    return { status: 400, body: { error: 'TYPE_NOT_ALLOWED' } };
  }
  if (typeof body.amount !== 'number' || !Number.isFinite(body.amount) || body.amount === 0) {
    return { status: 400, body: { error: 'INVALID_AMOUNT' } };
  }
  // Enforcement signe vs type : un debit_type doit avoir un amount < 0,
  // un refund_type doit avoir un amount > 0. Evite qu'un client tape
  // space_reservation avec +100 pour se crediter.
  const shouldBeNegative = isDebitType(body.type);
  if (shouldBeNegative && body.amount >= 0) {
    return { status: 400, body: { error: 'AMOUNT_SIGN_MISMATCH' } };
  }
  if (!shouldBeNegative && body.amount <= 0) {
    return { status: 400, body: { error: 'AMOUNT_SIGN_MISMATCH' } };
  }
  if (!body.idempotency_key || typeof body.idempotency_key !== 'string') {
    return { status: 400, body: { error: 'MISSING_IDEMPOTENCY_KEY' } };
  }

  const res = await caller.callRpc<RpcRow[]>(
    'adjust_balance',
    {
      p_client_id: claims.client_id,
      p_building_id: claims.building_id,
      p_dep_external_id: body.dependent_id ?? null,
      p_amount: body.amount,
      p_type: body.type,
      p_reference_id: body.reference_id ?? null,
      p_reference_type: body.reference_type ?? null,
      p_description: body.description ?? null,
      p_idempotency_key: body.idempotency_key,
      p_created_by: null,
    },
    serviceRole,
  );

  if (!res.ok) {
    const detail = res.body as { code?: string; message?: string } | undefined;
    const code = detail?.code;
    if (code === '23514' || detail?.message?.includes('insufficient_funds')) {
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
      transaction_id: row.transaction_id,
      virtual_balance: Number(row.virtual_balance),
      idempotent_replay: row.idempotent_replay,
    },
  };
}
