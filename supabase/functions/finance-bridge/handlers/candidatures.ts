// Endpoints /candidatures-list et /candidatures-decide : l'admin d'un
// immeuble (CoHabitat, onglet Demandes) lit et decide les candidatures de
// SON immeuble.
//
// Ils remplacent l'appel direct, avec la cle anon publique, aux RPC
// list_candidatures_for_building / decide_candidature_for_building
// (sql/024). Leur seule garde etait le building_id passe en parametre —
// public, puisqu'il figure dans la page /postuler/. sql/029 retire
// l'acces anon ; ces RPC ne sont plus appelables que par service_role,
// c'est-a-dire par ici.
//
// Securite :
//   1. Le jeton CoHabitat de l'appelant est verifie (resolveClaims, en
//      amont) : il donne l'immeuble et l'utilisateur.
//   2. Le role d'admin est lu dans la base de l'immeuble (lib/admin.ts).
//   3. Le building_id passe aux RPC est celui du jeton verifie. Celui que
//      le navigateur enverrait est ignore : un admin ne peut pas viser
//      un autre immeuble.

import type { BuildingRegistryEntry, ResolvedClaims } from '../lib/types.ts';
import type { CentralCaller } from '../lib/central.ts';
import { ADMIN_ROLES, type FetchAdminRole } from '../lib/admin.ts';

type Result = { status: number; body: unknown };

const DECISIONS = new Set(['accepte', 'refuse', 'en_evaluation']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface CandidaturesDeps {
  fetchAdminRole: FetchAdminRole;
  caller: CentralCaller;
  serviceRole: string;
}

async function exigerAdmin(
  claims: ResolvedClaims,
  building: BuildingRegistryEntry,
  callerJwt: string,
  deps: CandidaturesDeps,
): Promise<Result | null> {
  const role = await deps.fetchAdminRole(building.supabase_url, claims.cohabitat_user_id, callerJwt);
  if (!role || !ADMIN_ROLES.has(role)) {
    return { status: 403, body: { error: 'NOT_ADMIN' } };
  }
  return null;
}

export async function handleCandidaturesList(
  claims: ResolvedClaims,
  building: BuildingRegistryEntry,
  callerJwt: string,
  deps: CandidaturesDeps,
): Promise<Result> {
  const refus = await exigerAdmin(claims, building, callerJwt, deps);
  if (refus) return refus;

  const res = await deps.caller.callRpc<unknown[]>(
    'list_candidatures_for_building',
    { p_building_id: claims.building_id },
    deps.serviceRole,
  );
  if (!res.ok) {
    return { status: 502, body: { error: 'CENTRAL_RPC_FAILED', detail: res.body } };
  }
  return {
    status: 200,
    body: {
      building_id: claims.building_id,
      candidatures: Array.isArray(res.data) ? res.data : [],
    },
  };
}

export interface CandidaturesDecideRequest {
  candidature_id: string;
  decision: 'accepte' | 'refuse' | 'en_evaluation';
}

export async function handleCandidaturesDecide(
  claims: ResolvedClaims,
  body: CandidaturesDecideRequest | null,
  building: BuildingRegistryEntry,
  callerJwt: string,
  deps: CandidaturesDeps,
): Promise<Result> {
  if (!body) return { status: 400, body: { error: 'MISSING_BODY' } };
  if (typeof body.candidature_id !== 'string' || !UUID_RE.test(body.candidature_id)) {
    return { status: 400, body: { error: 'INVALID_CANDIDATURE_ID' } };
  }
  if (typeof body.decision !== 'string' || !DECISIONS.has(body.decision)) {
    return { status: 400, body: { error: 'INVALID_DECISION' } };
  }

  const refus = await exigerAdmin(claims, building, callerJwt, deps);
  if (refus) return refus;

  const res = await deps.caller.callRpc<{ id?: string; status?: string } | null>(
    'decide_candidature_for_building',
    {
      p_candidature_id: body.candidature_id,
      p_decision: body.decision,
      p_building_id: claims.building_id,
    },
    deps.serviceRole,
  );
  if (!res.ok) {
    // La RPC leve no_data_found quand la candidature n'existe pas ou
    // appartient a un autre immeuble : meme reponse dans les deux cas,
    // pour ne pas reveler l'existence d'une candidature hors perimetre.
    const detail = res.body as { code?: string } | null;
    if (detail && (detail.code === 'P0002' || detail.code === 'no_data_found')) {
      return { status: 404, body: { error: 'CANDIDATURE_NOT_FOUND' } };
    }
    return { status: 502, body: { error: 'CENTRAL_RPC_FAILED' } };
  }
  // La RPC renvoie la ligne complete, donnees personnelles comprises :
  // on ne retransmet que ce dont l'interface a besoin.
  return {
    status: 200,
    body: { id: res.data?.id ?? body.candidature_id, status: res.data?.status ?? body.decision },
  };
}
