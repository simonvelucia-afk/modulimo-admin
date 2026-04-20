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
  findClient: (
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

  const client = await deps.findClient(sub, building.id);
  if (!client) return { ok: false, status: 403, error: 'CLIENT_NOT_FOUND' };

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
