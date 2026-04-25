// Fixtures de test : chaque "immeuble" est une paire de cles ES256 + un
// issuer fictif + un JWKS derive de la cle publique. Aucun reseau, tout
// est en memoire.

import {
  SignJWT,
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  type KeyLike,
} from 'npm:jose@5';

import type { BuildingRegistryEntry } from '../lib/resolve.ts';
import type { ResolveDeps } from '../lib/resolve.ts';
import type { BuildingStatus } from '../lib/types.ts';

export interface BuildingFixture {
  entry: BuildingRegistryEntry;
  publicKey: KeyLike;
  privateKey: KeyLike;
  // Les tests utilisent createLocalJWKSet : on evite ainsi toute requete
  // reseau. Le resolver renvoie la cle publique selon le `kid` du header.
  keyResolver: ReturnType<typeof createLocalJWKSet>;
  kid: string;
}

export async function makeBuilding(
  name: string,
  overrides: Partial<Pick<BuildingRegistryEntry, 'status' | 'id'>> = {},
): Promise<BuildingFixture> {
  const { publicKey, privateKey } = await generateKeyPair('ES256');
  const jwk = await exportJWK(publicKey);
  const kid = `${name}-kid`;
  jwk.kid = kid;
  jwk.alg = 'ES256';
  jwk.use = 'sig';
  const keyResolver = createLocalJWKSet({ keys: [jwk] });
  const supabase_url = `https://${name}.supabase.co`;
  const jwt_issuer = `${supabase_url}/auth/v1`;
  return {
    entry: {
      id: overrides.id ?? crypto.randomUUID(),
      name,
      supabase_url,
      jwt_issuer,
      jwks_url: `${jwt_issuer}/.well-known/jwks.json`,
      status: overrides.status ?? 'active',
    },
    publicKey,
    privateKey,
    keyResolver,
    kid,
  };
}

// Signe un JWT comme si c'etait l'Auth Supabase de cet immeuble.
export async function signAsBuilding(
  b: BuildingFixture,
  sub: string,
  opts: {
    exp?: string;             // '1h' par defaut
    issuerOverride?: string;  // pour tester un iss force
    audienceOverride?: string;
    signWithKey?: KeyLike;    // pour tester une signature avec la mauvaise cle
    kidOverride?: string;
  } = {},
): Promise<string> {
  return await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: opts.kidOverride ?? b.kid })
    .setSubject(sub)
    .setIssuer(opts.issuerOverride ?? b.entry.jwt_issuer)
    .setAudience(opts.audienceOverride ?? 'authenticated')
    .setIssuedAt()
    .setExpirationTime(opts.exp ?? '1h')
    .sign(opts.signWithKey ?? b.privateKey);
}

// Fabrique des ResolveDeps in-memory a partir d'un ensemble de fixtures et
// d'une table cohabitat_user_id -> client_id.
export interface ResolveFixtures {
  buildings: BuildingFixture[];
  // Pre-existing clients rows. Le tableau est mute par provisionClient
  // (auto-provision) — par defaut, makeResolveDeps installe un
  // provisionClient qui ajoute la nouvelle row dans ce tableau pour que
  // les findClient ulterieurs la trouvent (mime le comportement DB
  // post-INSERT).
  clients: Array<{
    cohabitat_user_id: string;
    building_id: string;
    client_id: string;
  }>;
  // Si fourni, override le provisionClient default. Permet aux tests de
  // simuler un echec DB (retourne null) sans avoir a forger une fonction
  // entiere.
  provisionClient?: ResolveDeps['provisionClient'];
}

export function makeResolveDeps(fx: ResolveFixtures): ResolveDeps {
  const byIssuer = new Map(fx.buildings.map((b) => [b.entry.jwt_issuer, b]));
  const buildingActive = (buildingId: string) =>
    fx.buildings.some((b) => b.entry.id === buildingId && b.entry.status === 'active');
  return {
    findBuildingByIssuer: async (iss) => {
      const b = byIssuer.get(iss);
      return b ? b.entry : null;
    },
    getKeyResolver: (entry) => {
      const b = fx.buildings.find((x) => x.entry.id === entry.id);
      if (!b) throw new Error(`fixture missing for building ${entry.id}`);
      return b.keyResolver;
    },
    findClient: async (cohabitatUserId, buildingId) => {
      const row = fx.clients.find(
        (c) => c.cohabitat_user_id === cohabitatUserId && c.building_id === buildingId,
      );
      return row ? { client_id: row.client_id } : null;
    },
    provisionClient: fx.provisionClient ?? (async (cohabitatUserId, buildingId) => {
      // Mime ensure_client cote DB : refus si building inactif, sinon
      // INSERT...ON CONFLICT DO NOTHING + retour de la row gagnante.
      if (!buildingActive(buildingId)) return null;
      const existing = fx.clients.find(
        (c) => c.cohabitat_user_id === cohabitatUserId && c.building_id === buildingId,
      );
      if (existing) return { client_id: existing.client_id };
      const row = {
        cohabitat_user_id: cohabitatUserId,
        building_id: buildingId,
        client_id: crypto.randomUUID(),
      };
      fx.clients.push(row);
      return { client_id: row.client_id };
    }),
  };
}

export function setStatus(b: BuildingFixture, status: BuildingStatus): BuildingFixture {
  b.entry = { ...b.entry, status };
  return b;
}
