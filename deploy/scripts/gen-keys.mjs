// gen-keys.mjs — fabrique les secrets de la centrale.
//
//   node scripts/gen-keys.mjs > .env.secrets
//
// Produit le secret JWT partage par GoTrue et PostgREST, les deux cles
// d'API derivees de ce secret (anon et service_role, au format attendu
// par supabase-js) et les mots de passe des roles Postgres.

import { createHmac, randomBytes } from 'node:crypto';

const b64url = (buf) => Buffer.from(buf).toString('base64url');

function apiKey(role, secret) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({
    role,
    iss: 'modulimo',
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 20 * 365 * 24 * 3600,
  }));
  const sig = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${sig}`;
}

const jwtSecret = randomBytes(48).toString('base64url');
const pg = () => randomBytes(24).toString('base64url');

process.stdout.write([
  '# Secrets generes par scripts/gen-keys.mjs — a conserver hors du depot.',
  `JWT_SECRET=${jwtSecret}`,
  `ANON_KEY=${apiKey('anon', jwtSecret)}`,
  `SERVICE_ROLE_KEY=${apiKey('service_role', jwtSecret)}`,
  `POSTGRES_PASSWORD=${pg()}`,
  `AUTHENTICATOR_PASSWORD=${pg()}`,
  `AUTH_ADMIN_PASSWORD=${pg()}`,
  '',
].join('\n'));
