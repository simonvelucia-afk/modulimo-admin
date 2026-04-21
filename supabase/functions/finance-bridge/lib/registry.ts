// Resolution building_registry via PostgREST central, puis cache JWKS.
// Ce module assemble les adapters attendus par resolve.ts en piochant
// directement dans la base centrale. Il n'est PAS importe par les tests
// unitaires — les tests fabriquent leurs propres adapters in-memory.

import { createRemoteJWKSet } from 'npm:jose@5';
import type { BuildingRegistryEntry } from './types.ts';
import type { KeyResolver } from './resolve.ts';

interface BuildingRow {
  id: string;
  name: string;
  supabase_url: string;
  jwt_issuer: string;
  jwks_url: string;
  status: string;
}

const JWKS_CACHE = new Map<string, KeyResolver>();

export function jwksResolverFor(entry: BuildingRegistryEntry): KeyResolver {
  const cached = JWKS_CACHE.get(entry.id);
  if (cached) return cached;
  const resolver = createRemoteJWKSet(new URL(entry.jwks_url), {
    // jose gere un cache interne 10 min + rotation sur kid miss.
    cooldownDuration: 30_000,
    timeoutDuration: 2_000,
  });
  JWKS_CACHE.set(entry.id, resolver);
  return resolver;
}

export function clearJwksCache() {
  JWKS_CACHE.clear();
}

// Lookup building_registry par issuer. Utilise la cle anon du projet central
// avec une policy SELECT pour `authenticated` (cf. migration). On n'utilise
// PAS la service_role ici car on lit uniquement des metadonnees publiques
// entre immeubles.
export function makeFindBuildingByIssuer(
  centralUrl: string,
  anonKey: string,
): (iss: string) => Promise<BuildingRegistryEntry | null> {
  return async (iss: string) => {
    const url = new URL('/rest/v1/building_registry', centralUrl);
    url.searchParams.set('select', 'id,name,supabase_url,jwt_issuer,jwks_url,status');
    url.searchParams.set('jwt_issuer', `eq.${iss}`);
    url.searchParams.set('limit', '1');
    const res = await fetch(url, {
      headers: { apikey: anonKey, Authorization: `Bearer ${anonKey}` },
    });
    if (!res.ok) return null;
    const rows = (await res.json()) as BuildingRow[];
    const row = rows[0];
    if (!row) return null;
    if (row.status !== 'active' && row.status !== 'suspended' && row.status !== 'offboarded') {
      return null;
    }
    return row as BuildingRegistryEntry;
  };
}

// Resolution cohabitat_user_id -> client_id en utilisant la service_role du
// projet central. On bypasse la RLS ici volontairement : c'est notre role
// d'approuver la demande, pas celui de l'immeuble.
export function makeFindClient(
  centralUrl: string,
  serviceRoleKey: string,
): (cohabitatUserId: string, buildingId: string) => Promise<{ client_id: string } | null> {
  return async (cohabitatUserId: string, buildingId: string) => {
    const url = new URL('/rest/v1/clients', centralUrl);
    url.searchParams.set('select', 'id');
    url.searchParams.set('cohabitat_user_id', `eq.${cohabitatUserId}`);
    url.searchParams.set('building_id', `eq.${buildingId}`);
    url.searchParams.set('limit', '1');
    const res = await fetch(url, {
      headers: { apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}` },
    });
    if (!res.ok) return null;
    const rows = (await res.json()) as Array<{ id: string }>;
    return rows[0] ? { client_id: rows[0].id } : null;
  };
}
