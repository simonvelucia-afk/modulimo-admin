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

// Lookup building_registry par issuer. Reception par apikey (sb_secret_ ou
// legacy service_role JWT). Pas de Bearer — PostgREST mappe l'apikey au
// role et gere la RLS en consequence.
export function makeFindBuildingByIssuer(
  centralUrl: string,
  apiKey: string,
): (iss: string) => Promise<BuildingRegistryEntry | null> {
  return async (iss: string) => {
    const url = new URL('/rest/v1/building_registry', centralUrl);
    url.searchParams.set('select', 'id,name,supabase_url,jwt_issuer,jwks_url,status');
    url.searchParams.set('jwt_issuer', `eq.${iss}`);
    url.searchParams.set('limit', '1');
    const res = await fetch(url, {
      headers: { apikey: apiKey },
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

// Resolution cohabitat_user_id -> client_id. Utilise sb_secret_ (ou legacy
// service_role JWT) pour bypasser RLS sur clients — on est le gardien de
// l'autorisation, pas la DB.
export function makeFindClient(
  centralUrl: string,
  apiKey: string,
): (cohabitatUserId: string, buildingId: string) => Promise<{ client_id: string } | null> {
  return async (cohabitatUserId: string, buildingId: string) => {
    const url = new URL('/rest/v1/clients', centralUrl);
    url.searchParams.set('select', 'id');
    url.searchParams.set('cohabitat_user_id', `eq.${cohabitatUserId}`);
    url.searchParams.set('building_id', `eq.${buildingId}`);
    url.searchParams.set('limit', '1');
    const res = await fetch(url, {
      headers: { apikey: apiKey },
    });
    if (!res.ok) return null;
    const rows = (await res.json()) as Array<{ id: string }>;
    return rows[0] ? { client_id: rows[0].id } : null;
  };
}

// Auto-provisionnement de la row clients via la RPC centrale ensure_client
// (sql/016). Idempotente cote DB : un 2eme appel concurrent pour le meme
// resident retourne la meme client_id. Retourne null si la RPC echoue
// (building inactif, parametres invalides, panne reseau) — l'appelant
// surface CLIENT_NOT_FOUND.
export function makeProvisionClient(
  centralUrl: string,
  apiKey: string,
): (cohabitatUserId: string, buildingId: string) => Promise<{ client_id: string } | null> {
  return async (cohabitatUserId: string, buildingId: string) => {
    const url = new URL('/rest/v1/rpc/ensure_client', centralUrl);
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        apikey: apiKey,
        'Content-Type': 'application/json',
        Prefer: 'return=representation',
      },
      body: JSON.stringify({
        p_cohabitat_user_id: cohabitatUserId,
        p_building_id: buildingId,
      }),
    });
    if (!res.ok) return null;
    const text = await res.text();
    if (!text) return null;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return null;
    }
    // PostgREST renvoie la valeur scalaire d'une RPC comme string brut
    // (le uuid) ou parfois un objet { ensure_client: <uuid> } selon les
    // versions. On gere les deux pour resilience.
    let id: string | null = null;
    if (typeof parsed === 'string') id = parsed;
    else if (parsed && typeof parsed === 'object') {
      const obj = parsed as Record<string, unknown>;
      const v = obj.ensure_client;
      if (typeof v === 'string') id = v;
    }
    return id ? { client_id: id } : null;
  };
}
