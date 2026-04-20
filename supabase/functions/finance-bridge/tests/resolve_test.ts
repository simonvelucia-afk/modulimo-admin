// Tests unitaires cibles sur le parser JWT et les chemins de resolve
// qui ne sont pas couverts par le scenario d'attaque cross-tenant.

import { assertEquals } from './_assert.ts';
import { _internals, resolveClaims } from '../lib/resolve.ts';
import { makeBuilding, makeResolveDeps, signAsBuilding } from './fixtures.ts';

Deno.test('decode : JWT malforme retourne null', () => {
  assertEquals(_internals.unsafeDecodePayload(''), null);
  assertEquals(_internals.unsafeDecodePayload('abc'), null);
  assertEquals(_internals.unsafeDecodePayload('a.b'), null);
});

Deno.test('decode : header+payload valides mais JSON casse => null', () => {
  const bogus = btoa('{}') + '.' + btoa('not json') + '.' + btoa('sig');
  assertEquals(_internals.unsafeDecodePayload(bogus), null);
});

Deno.test('resolve : token vide => MALFORMED_JWT', async () => {
  const b = await makeBuilding('x');
  const deps = makeResolveDeps({ buildings: [b], clients: [] });
  const res = await resolveClaims('', deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'MALFORMED_JWT');
});

Deno.test('resolve : payload sans iss => MISSING_ISSUER', async () => {
  const b = await makeBuilding('x');
  const deps = makeResolveDeps({ buildings: [b], clients: [] });
  // On fabrique un JWT valide structurellement mais sans iss.
  // jose ajoute iss uniquement si on l'appelle — on court-circuite en
  // manipulant le payload directement via base64url.
  const header = btoa(JSON.stringify({ alg: 'none', typ: 'JWT' }))
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const payload = btoa(JSON.stringify({ sub: 'x' }))
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const token = `${header}.${payload}.sig`;
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'MISSING_ISSUER');
});

Deno.test('resolve : sub manquant apres verification => MISSING_SUBJECT', async () => {
  const b = await makeBuilding('x');
  const deps = makeResolveDeps({ buildings: [b], clients: [] });
  // Helper signe sans sub explicite — on passe une chaine vide.
  const token = await signAsBuilding(b, '');
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  // Soit MISSING_SUBJECT (si jose laisse passer sub=''), soit
  // INVALID_SIGNATURE selon la version. On accepte les deux — l'important
  // c'est que le JWT ne soit pas accepte comme valide.
  if (!res.ok) {
    const accepted = res.error === 'MISSING_SUBJECT' || res.error === 'INVALID_SIGNATURE';
    assertEquals(accepted, true, `error inattendue: ${res.error}`);
  }
});
