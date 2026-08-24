// Types partages de la passerelle finance Modulimo.
// Aucune dependance externe : ce fichier doit rester importable depuis les
// tests unitaires sans avoir besoin de Deno ni de Supabase.

export type BuildingStatus = 'active' | 'suspended' | 'offboarded';

// Comment l'immeuble prouve l'identite de ses residents :
//   'jwks'    projet Supabase heberge — jeton du resident verifie via
//             les JWKS du projet (mode historique, defaut).
//   'ed25519' instance auto-hebergee — elle signe en HS256 avec un
//             secret local, sans JWKS. Elle verifie donc le jeton chez
//             elle et presente une assertion signee avec la cle privee
//             de sa federation ; la centrale n'a que la cle publique.
export type BuildingAuthMode = 'jwks' | 'ed25519';

export interface BuildingRegistryEntry {
  id: string;               // building_registry.id (UUID)
  name: string;
  supabase_url: string;     // https://<ref>.supabase.co ou URL VPN
  jwt_issuer: string;       // <supabase_url>/auth/v1
  jwks_url: string;         // <supabase_url>/auth/v1/.well-known/jwks.json
  status: BuildingStatus;
  auth_mode?: BuildingAuthMode;
  federation_public_key?: string | null;  // SPKI base64url, mode ed25519
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
