// Minting du JWT central apres resolution des claims. Le secret HS256 du
// projet central (SUPABASE_JWT_SECRET) ne sort jamais d'ici : il est
// injecte au demarrage de l'Edge Function et passe aux tests via fixture.

import { SignJWT } from 'npm:jose@5';
import type { ResolvedClaims } from './types.ts';

export interface MintOptions {
  secret: Uint8Array;
  ttlSeconds?: number;   // defaut 60s
  issuer?: string;       // defaut 'modulimo-bridge'
}

export async function mintCentralJwt(
  claims: ResolvedClaims,
  opts: MintOptions,
): Promise<string> {
  const ttl = opts.ttlSeconds ?? 60;
  const iss = opts.issuer ?? 'modulimo-bridge';
  return await new SignJWT({
    building_id: claims.building_id,
    client_id: claims.client_id,
    cohabitat_user_id: claims.cohabitat_user_id,
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setSubject(claims.client_id)
    .setAudience('authenticated')
    .setIssuer(iss)
    .setIssuedAt()
    .setExpirationTime(`${ttl}s`)
    .sign(opts.secret);
}

export function secretFromEnv(name = 'SUPABASE_JWT_SECRET'): Uint8Array {
  const raw = (typeof Deno !== 'undefined' ? Deno.env.get(name) : undefined) ?? '';
  if (!raw) throw new Error(`Missing env ${name}`);
  return new TextEncoder().encode(raw);
}
