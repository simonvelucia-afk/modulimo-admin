// Endpoint pilote : POST /finance-bridge/get-balance
// But de la Phase 0 : prouver que l'aller-retour JWT fonctionne de bout
// en bout. La RPC central `get_balance` n'existe pas encore — on retourne
// 0.00 en attendant la Phase 1.

import type { ResolvedClaims } from '../lib/types.ts';

export interface GetBalanceRequest {
  // Optionnel : verification defensive — le body ne peut pas reclamer un
  // client_id different de celui que le JWT a prouve.
  client_id?: string;
  dependent_id?: string | null;
}

export interface GetBalanceResponse {
  client_id: string;
  building_id: string;
  dependent_id: string | null;
  virtual_balance: number;  // stub Phase 0
  source: 'central';
}

export function handleGetBalance(
  claims: ResolvedClaims,
  body: GetBalanceRequest | null,
): { status: number; body: GetBalanceResponse | { error: string } } {
  if (body && body.client_id && body.client_id !== claims.client_id) {
    return { status: 403, body: { error: 'CLIENT_ID_MISMATCH' } };
  }
  return {
    status: 200,
    body: {
      client_id: claims.client_id,
      building_id: claims.building_id,
      dependent_id: body?.dependent_id ?? null,
      virtual_balance: 0.00,
      source: 'central',
    },
  };
}
