// Resolution building_registry via PostgREST central, puis cache JWKS.
// Ce module assemble les adapters attendus par resolve.ts en piochant
// directement dans la base centrale. Il n'est PAS importe par les tests
// unitaires — les tests fabriquent leurs propres adapters in-memory.

import { createRemoteJWKSet, importSPKI } from 'npm:jose@5';
import type { BuildingRegistryEntry } from './types.ts';
import type { KeyResolver } from './resolve.ts';

interface BuildingRow {
  id: string;
  name: string;
  supabase_url: string;
  jwt_issuer: string;
  jwks_url: string;
  status: string;
  auth_mode?: string;
  federation_public_key?: string | null;
}

const JWKS_CACHE = new Map<string, KeyResolver>();

// SPKI base64url (ce que publie /federation/v1/identity cote CoHabitat)
// vers le PEM attendu par jose. Exporte pour etre testable isolement.
export function spkiToPem(b64url: string): string {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const lines = padded.match(/.{1,64}/g) ?? [];
  return `-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n`;
}

export function jwksResolverFor(entry: BuildingRegistryEntry): KeyResolver {
  const cached = JWKS_CACHE.get(entry.id);
  if (cached) return cached;

  let resolver: KeyResolver;

  if (entry.auth_mode === 'ed25519') {
    // Instance auto-hebergee : pas de JWKS a interroger, donc rien a
    // aller chercher sur le reseau au moment de la verification — ce qui
    // convient a un lien VPN qui peut etre lent ou intermittent. La cle
    // publique a ete echangee une fois, a l'enregistrement.
    //
    // On retourne une fonction plutot que la cle : jose accepte un
    // resolveur asynchrone, ce qui permet d'importer la cle a la
    // premiere verification sans rendre cette fonction async.
    const pem = entry.federation_public_key ? spkiToPem(entry.federation_public_key) : null;
    let imported: Promise<Awaited<ReturnType<typeof importSPKI>>> | null = null;
    resolver = ((header: { alg?: string }) => {
      if (!pem) throw new Error('MISSING_FEDERATION_KEY');
      // Le mode ed25519 n'accepte QUE EdDSA : sans ce garde-fou, une
      // instance pourrait presenter un jeton signe autrement et faire
      // porter la verification a une cle qui n'est pas la sienne.
      if (header.alg !== 'EdDSA') throw new Error('UNEXPECTED_ALG');
      imported ??= importSPKI(pem, 'EdDSA');
      return imported;
    }) as unknown as KeyResolver;
  } else {
    resolver = createRemoteJWKSet(new URL(entry.jwks_url), {
      // jose gere un cache interne 10 min + rotation sur kid miss.
      cooldownDuration: 30_000,
      timeoutDuration: 2_000,
    });
  }

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
    url.searchParams.set(
      'select',
      'id,name,supabase_url,jwt_issuer,jwks_url,status,auth_mode,federation_public_key',
    );
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
