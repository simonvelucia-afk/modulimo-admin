// Tests de fuite inter-immeuble. Ce fichier est la garantie en CI que
// l'Edge Function ne peut pas etre utilisee par un immeuble A pour lire
// ou ecrire les donnees d'un immeuble B. Chaque scenario correspond a
// une tentative d'attaque plausible.

import { assertEquals } from './_assert.ts';
import { resolveClaims } from '../lib/resolve.ts';
import { mintCentralJwt } from '../lib/jwt.ts';
import { handleGetBalance } from '../handlers/get_balance.ts';
import {
  makeBuilding,
  makeResolveDeps,
  setStatus,
  signAsBuilding,
} from './fixtures.ts';

async function setup() {
  const buildingA = await makeBuilding('building-a');
  const buildingB = await makeBuilding('building-b');
  const clients = [
    {
      cohabitat_user_id: '11111111-1111-1111-1111-111111111111',
      building_id: buildingA.entry.id,
      client_id: 'client-a-uuid',
    },
    {
      cohabitat_user_id: '22222222-2222-2222-2222-222222222222',
      building_id: buildingB.entry.id,
      client_id: 'client-b-uuid',
    },
  ];
  const deps = makeResolveDeps({ buildings: [buildingA, buildingB], clients });
  return { buildingA, buildingB, clients, deps };
}

Deno.test('happy path : JWT valide de A resout vers client A', async () => {
  const { buildingA, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id);
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, true);
  if (res.ok) {
    assertEquals(res.claims.client_id, 'client-a-uuid');
    assertEquals(res.claims.building_id, buildingA.entry.id);
  }
});

Deno.test('fuite #1 : JWT de A avec iss reecrit vers B => INVALID_SIGNATURE', async () => {
  // Un attaquant qui detient un JWT valide de A tente de se faire passer
  // pour un utilisateur de B en swappant le claim `iss`. La signature ne
  // correspondra pas a la JWKS de B, donc rejet.
  const { buildingA, buildingB, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id, {
    issuerOverride: buildingB.entry.jwt_issuer,
  });
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'INVALID_SIGNATURE');
});

Deno.test('fuite #2 : JWT forge avec la mauvaise cle => INVALID_SIGNATURE', async () => {
  const { buildingA, buildingB, clients, deps } = await setup();
  // Attaquant signe un JWT "de A" mais avec la cle privee de B.
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id, {
    signWithKey: buildingB.privateKey,
  });
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'INVALID_SIGNATURE');
});

Deno.test('fuite #3 : JWT valide de A mais body reclame le client de B => CLIENT_ID_MISMATCH', async () => {
  const { buildingA, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id);
  const resolved = await resolveClaims(token, deps);
  assertEquals(resolved.ok, true);
  if (!resolved.ok) return;
  const out = handleGetBalance(resolved.claims, { client_id: 'client-b-uuid' });
  assertEquals(out.status, 403);
  assertEquals((out.body as { error: string }).error, 'CLIENT_ID_MISMATCH');
});

Deno.test('fuite #4 : iss inconnu du registry => UNKNOWN_ISSUER', async () => {
  const { buildingA, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id, {
    issuerOverride: 'https://rogue-building.supabase.co/auth/v1',
  });
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'UNKNOWN_ISSUER');
});

Deno.test('fuite #5 : immeuble suspendu => BUILDING_INACTIVE', async () => {
  const { buildingA, clients, deps } = await setup();
  setStatus(buildingA, 'suspended');
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id);
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'BUILDING_INACTIVE');
});

Deno.test('fuite #6 : cohabitat_user_id sans row clients => CLIENT_NOT_FOUND', async () => {
  const { buildingA, deps } = await setup();
  const token = await signAsBuilding(buildingA, '99999999-9999-9999-9999-999999999999');
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'CLIENT_NOT_FOUND');
});

Deno.test('fuite #7 : JWT expire => INVALID_SIGNATURE (jose rejette sur exp)', async () => {
  const { buildingA, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id, {
    exp: '-1s',
  });
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'INVALID_SIGNATURE');
});

Deno.test('fuite #8 : mauvaise audience => INVALID_SIGNATURE', async () => {
  const { buildingA, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id, {
    audienceOverride: 'service_role',
  });
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, false);
  if (!res.ok) assertEquals(res.error, 'INVALID_SIGNATURE');
});

Deno.test('fuite #9 : un meme cohabitat_user_id existe par hasard dans deux immeubles => on lie au bon building_id', async () => {
  // Scenario subtil : si par coincidence l'UUID d'un user de A existe
  // aussi dans la table clients de B, il ne faut pas que le JWT de A
  // deverrouille l'acces a B.
  const buildingA = await makeBuilding('building-a');
  const buildingB = await makeBuilding('building-b');
  const sharedUserId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const deps = makeResolveDeps({
    buildings: [buildingA, buildingB],
    clients: [
      { cohabitat_user_id: sharedUserId, building_id: buildingA.entry.id, client_id: 'A' },
      { cohabitat_user_id: sharedUserId, building_id: buildingB.entry.id, client_id: 'B' },
    ],
  });
  const tokenFromA = await signAsBuilding(buildingA, sharedUserId);
  const res = await resolveClaims(tokenFromA, deps);
  assertEquals(res.ok, true);
  if (res.ok) {
    assertEquals(res.claims.client_id, 'A');
    assertEquals(res.claims.building_id, buildingA.entry.id);
  }
});

Deno.test('mint central : claims portent building_id + client_id', async () => {
  const { buildingA, clients, deps } = await setup();
  const token = await signAsBuilding(buildingA, clients[0].cohabitat_user_id);
  const res = await resolveClaims(token, deps);
  assertEquals(res.ok, true);
  if (!res.ok) return;
  const secret = new TextEncoder().encode('test-secret-at-least-32-chars-long-xx');
  const minted = await mintCentralJwt(res.claims, { secret, ttlSeconds: 60 });
  const [, payloadB64] = minted.split('.');
  const b64 = payloadB64.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const payload = JSON.parse(atob(padded));
  assertEquals(payload.building_id, buildingA.entry.id);
  assertEquals(payload.client_id, 'client-a-uuid');
  assertEquals(payload.aud, 'authenticated');
  assertEquals(payload.iss, 'modulimo-bridge');
  assertEquals(payload.sub, 'client-a-uuid');
});
