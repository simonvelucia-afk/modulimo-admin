// Endpoint POST /finance-bridge/record-real-payment : permet a l'admin de
// l'immeuble (CoHabitat tab Admin > Paiements) de creer un credit virtuel
// pour un resident contre un paiement reel recu (cash, virement, etc.) en
// passant par la RPC centrale record_real_payment.
//
// Securite : le caller fournit son JWT CoHabitat (Bearer). On l'utilise
// pour :
//   1. Resoudre claims via le building_registry (existant)
//   2. Verifier que le caller est admin de l'immeuble en lisant son
//      profile.role via PostgREST cote building avec le meme JWT (RLS
//      autorise un user a lire son propre profile).
//   3. Resoudre le target user_id (fourni dans le body) -> client_id
//      central via clients.cohabitat_user_id.
//   4. Appeler record_real_payment(service_role) avec target_client_id.
//
// Le caller ne peut pas crediter quelqu'un en dehors de son propre
// immeuble (find_client filtre par building_id) ni quelqu'un sans row
// clients (404 explicite).

import type { ResolvedClaims, BuildingRegistryEntry } from '../lib/types.ts';
import type { CentralCaller } from '../lib/central.ts';

const ADMIN_ROLES = new Set(['admin', 'principal_admin']);

type FindClient = (cohabitatUserId: string, buildingId: string) =>
  Promise<{ client_id: string } | null>;

export interface RecordRealPaymentRequest {
  target_user_id: string;        // cohabitat profiles.id du resident credite
  amount_real: number;           // > 0
  amount_virtual: number;        // > 0 (peut differ d'amount_real, p.ex. frais)
  payment_method: 'cash' | 'transfer' | 'cheque' | 'credit_card' | 'debit_card' | 'other';
  reference?: string | null;
  notes?: string | null;
  idempotency_key: string;
}

interface RpcRow {
  transaction_id: string;
  real_payment_id: string;
  virtual_balance: number | string;
  idempotent_replay: boolean;
}

export interface RecordRealPaymentResponse {
  client_id: string;             // target client_id (le resident credite)
  building_id: string;
  transaction_id: string;
  real_payment_id: string;
  virtual_balance: number;
  idempotent_replay: boolean;
}

async function fetchAdminRole(
  buildingUrl: string,
  cohabitatUserId: string,
  bearerJwt: string,
): Promise<string | null> {
  const url = new URL('/rest/v1/profiles', buildingUrl);
  url.searchParams.set('select', 'role');
  url.searchParams.set('id', `eq.${cohabitatUserId}`);
  url.searchParams.set('limit', '1');
  // PostgREST cote building exige apikey. On reutilise le JWT du caller
  // comme apikey ET Bearer — ca evite d'avoir besoin de la clé anon
  // building dans finance-bridge. Le JWT user satisfait le PostgREST
  // gateway (verifie la signature) puis la RLS autorise SELECT du propre
  // profil.
  const res = await fetch(url, {
    headers: {
      apikey: bearerJwt,
      Authorization: `Bearer ${bearerJwt}`,
    },
  });
  if (!res.ok) return null;
  const rows = (await res.json()) as Array<{ role?: string }>;
  return rows[0]?.role ?? null;
}

export async function handleRecordRealPayment(
  claims: ResolvedClaims,
  body: RecordRealPaymentRequest | null,
  building: BuildingRegistryEntry,
  callerJwt: string,
  findClient: FindClient,
  caller: CentralCaller,
  serviceRole: string,
): Promise<{
  status: number;
  body: RecordRealPaymentResponse | { error: string; detail?: unknown };
}> {
  if (!body) return { status: 400, body: { error: 'MISSING_BODY' } };
  if (!body.target_user_id || typeof body.target_user_id !== 'string') {
    return { status: 400, body: { error: 'MISSING_TARGET_USER_ID' } };
  }
  if (typeof body.amount_real !== 'number' || !Number.isFinite(body.amount_real) || body.amount_real <= 0) {
    return { status: 400, body: { error: 'INVALID_AMOUNT_REAL' } };
  }
  if (typeof body.amount_virtual !== 'number' || !Number.isFinite(body.amount_virtual) || body.amount_virtual <= 0) {
    return { status: 400, body: { error: 'INVALID_AMOUNT_VIRTUAL' } };
  }
  const validMethods = ['cash', 'transfer', 'cheque', 'credit_card', 'debit_card', 'other'];
  if (!validMethods.includes(body.payment_method)) {
    return { status: 400, body: { error: 'INVALID_PAYMENT_METHOD' } };
  }
  if (!body.idempotency_key || typeof body.idempotency_key !== 'string') {
    return { status: 400, body: { error: 'MISSING_IDEMPOTENCY_KEY' } };
  }

  // 1. Verifier que le caller est admin de l'immeuble
  const role = await fetchAdminRole(building.supabase_url, claims.cohabitat_user_id, callerJwt);
  if (!role || !ADMIN_ROLES.has(role)) {
    return { status: 403, body: { error: 'NOT_ADMIN', detail: { role } } };
  }

  // 2. Resoudre target_user_id -> target client_id (central)
  const targetClient = await findClient(body.target_user_id, claims.building_id);
  if (!targetClient) {
    return { status: 404, body: { error: 'TARGET_CLIENT_NOT_FOUND' } };
  }

  // 3. Appeler record_real_payment
  const res = await caller.callRpc<RpcRow[]>(
    'record_real_payment',
    {
      p_client_id: targetClient.client_id,
      p_building_id: claims.building_id,
      p_amount_real: body.amount_real,
      p_amount_virtual: body.amount_virtual,
      p_payment_method: body.payment_method,
      p_reference: body.reference ?? null,
      p_notes: body.notes ?? null,
      // recorded_by est l'auth.uid CoHabitat de l'admin. La FK sur
      // auth.users(id) a ete relaxee dans sql/015 — c'est un champ
      // d'audit sans FK, peut pointer cote building OU cote central.
      p_recorded_by: claims.cohabitat_user_id,
      p_idempotency_key: body.idempotency_key,
    },
    serviceRole,
  );

  if (!res.ok) {
    const detail = res.body as { code?: string; message?: string } | undefined;
    const code = detail?.code;
    if (code === '22023') return { status: 400, body: { error: 'INVALID_PARAMETER', detail: res.body } };
    if (code === '23505') return { status: 409, body: { error: 'IDEMPOTENCY_KEY_COLLISION', detail: res.body } };
    return { status: 502, body: { error: 'CENTRAL_RPC_FAILED', detail: res.body } };
  }

  const row = Array.isArray(res.data) ? res.data[0] : null;
  if (!row) return { status: 502, body: { error: 'CENTRAL_RPC_EMPTY' } };

  return {
    status: 200,
    body: {
      client_id: targetClient.client_id,
      building_id: claims.building_id,
      transaction_id: row.transaction_id,
      real_payment_id: row.real_payment_id,
      virtual_balance: Number(row.virtual_balance),
      idempotent_replay: row.idempotent_replay,
    },
  };
}
