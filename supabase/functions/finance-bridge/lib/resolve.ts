// Logique pure : du JWT brut jusqu'aux claims centraux resolus.
// Aucun appel reseau direct : tout passe par les adapters injectes,
// ce qui permet de tester chaque chemin d'echec sans mock HTTP.

import { jwtVerify, type JWTPayload, type KeyLike } from 'npm:jose@5';
import type {
  BuildingRegistryEntry,
  ResolveResult,
} from './types.ts';

// Re-exporte pour que les modules consommateurs (fixtures de tests,
// handlers) n'aient qu'un seul point d'import.
export type { BuildingRegistryEntry, ResolveResult } from './types.ts';

// Un KeyResolver est la fonction que jose appelle avec le header JWT pour
// obtenir la cle publique. En prod : createRemoteJWKSet(new URL(jwks_url)).
// En tests : createLocalJWKSet({ keys: [...] }) retourne la meme signature.
export type KeyResolver = Parameters<typeof jwtVerify>[1];

export interface ResolveDeps {
  findBuildingByIssuer: (iss: string) => Promise<BuildingRegistryEntry | null>;
  getKeyResolver: (entry: BuildingRegistryEntry) => KeyResolver;
  // Lookup strict : retourne null si la row clients n'existe pas. Garde sa
  // semantique pour les appels qui veulent verifier l'existence sans creer
  // (record-real-payment cible un user qui DOIT deja exister).
  findClient: (
    cohabitatUserId: string,
    buildingId: string,
  ) => Promise<{ client_id: string } | null>;
  // Find-or-create : appelee dans resolveClaims quand le JWT est valide
  // pour un building actif mais que le caller n'a pas encore de row
  // clients (resident ajoute apres la migration initiale). Doit etre
  // idempotente cote DB. Retourne null seulement sur echec DB hard
  // (que finance-bridge surface en CLIENT_NOT_FOUND).
  provisionClient: (
    cohabitatUserId: string,
    buildingId: string,
  ) => Promise<{ client_id: string } | null>;
}

// Decode sans verifier pour lire 'iss' — c'est sur car on verifie la
// signature juste apres. On ne fait rien confiance tant que jwtVerify
// n'a pas valide.
function unsafeDecodePayload(token: string): JWTPayload | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
    return JSON.parse(atob(padded)) as JWTPayload;
  } catch {
    return null;
  }
}

export async function resolveClaims(
  token: string,
  deps: ResolveDeps,
): Promise<ResolveResult> {
  const unverified = unsafeDecodePayload(token);
  if (!unverified) return { ok: false, status: 401, error: 'MALFORMED_JWT' };

  const iss = typeof unverified.iss === 'string' ? unverified.iss : null;
  if (!iss) return { ok: false, status: 401, error: 'MISSING_ISSUER' };

  const building = await deps.findBuildingByIssuer(iss);
  if (!building) return { ok: false, status: 403, error: 'UNKNOWN_ISSUER' };
  if (building.status !== 'active') {
    return { ok: false, status: 403, error: 'BUILDING_INACTIVE' };
  }

  let verified: JWTPayload;
  try {
    const res = await jwtVerify(token, deps.getKeyResolver(building), {
      issuer: building.jwt_issuer,
      audience: 'authenticated',
    });
    verified = res.payload;
  } catch {
    return { ok: false, status: 401, error: 'INVALID_SIGNATURE' };
  }

  const sub = typeof verified.sub === 'string' ? verified.sub : null;
  if (!sub) return { ok: false, status: 401, error: 'MISSING_SUBJECT' };

  let client = await deps.findClient(sub, building.id);
  if (!client) {
    // Auto-provision : JWT valide + building actif = resident legitime,
    // pas besoin d'attendre un bouton Sync manuel. La RPC centrale
    // ensure_client est idempotente, donc une race entre deux requetes
    // concurrentes pour le meme resident converge sur la meme client_id.
    client = await deps.provisionClient(sub, building.id);
    if (!client) return { ok: false, status: 403, error: 'CLIENT_NOT_FOUND' };
  }

  return {
    ok: true,
    building,
    claims: {
      client_id: client.client_id,
      building_id: building.id,
      cohabitat_user_id: sub,
    },
  };
}

// Exporte pour les tests — pas pour l'app.
export const _internals = { unsafeDecodePayload };

// Re-export de type uniquement pour eviter que KeyLike soit "unused" (jose
// l'expose, on l'annote pour les consommateurs).
export type { KeyLike };
