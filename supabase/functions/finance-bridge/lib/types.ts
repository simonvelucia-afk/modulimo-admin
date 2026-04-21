// Types partages de la passerelle finance Modulimo.
// Aucune dependance externe : ce fichier doit rester importable depuis les
// tests unitaires sans avoir besoin de Deno ni de Supabase.

export type BuildingStatus = 'active' | 'suspended' | 'offboarded';

export interface BuildingRegistryEntry {
  id: string;               // building_registry.id (UUID)
  name: string;
  supabase_url: string;     // https://<ref>.supabase.co
  jwt_issuer: string;       // <supabase_url>/auth/v1
  jwks_url: string;         // <supabase_url>/auth/v1/.well-known/jwks.json
  status: BuildingStatus;
}

export interface ResolvedClaims {
  client_id: string;        // central clients.id
  building_id: string;      // building_registry.id
  cohabitat_user_id: string;
}

// Codes d'erreur stables : utilises par les tests et par les alertes
// (un UNKNOWN_ISSUER frequent = tentative de forge, un CLIENT_NOT_FOUND
// frequent = resident non approvisionne).
export type ResolveErrorCode =
  | 'MALFORMED_JWT'
  | 'MISSING_ISSUER'
  | 'MISSING_SUBJECT'
  | 'INVALID_SIGNATURE'
  | 'UNKNOWN_ISSUER'
  | 'BUILDING_INACTIVE'
  | 'CLIENT_NOT_FOUND';

export type ResolveResult =
  | { ok: true; claims: ResolvedClaims; building: BuildingRegistryEntry }
  | { ok: false; status: number; error: ResolveErrorCode };
