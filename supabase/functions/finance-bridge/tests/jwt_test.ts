// Tests du mint central : garantit que les claims injectes sont bien ceux
// qui seront verifies par PostgREST avec SUPABASE_JWT_SECRET.

import { assertEquals, assertRejects } from './_assert.ts';
import { jwtVerify } from 'npm:jose@5';
import { mintCentralJwt, secretFromEnv } from '../lib/jwt.ts';

const SECRET = new TextEncoder().encode('test-secret-at-least-32-chars-long-xx');

Deno.test('mint : roundtrip verify avec le bon secret', async () => {
  const token = await mintCentralJwt(
    {
      client_id: 'c1',
      building_id: 'b1',
      cohabitat_user_id: 'u1',
    },
    { secret: SECRET, ttlSeconds: 60 },
  );
  const { payload } = await jwtVerify(token, SECRET, {
    issuer: 'modulimo-bridge',
    audience: 'authenticated',
  });
  assertEquals(payload.client_id, 'c1');
  assertEquals(payload.building_id, 'b1');
  assertEquals(payload.cohabitat_user_id, 'u1');
  assertEquals(payload.sub, 'c1');
});

Deno.test('mint : verify echoue avec un mauvais secret', async () => {
  const token = await mintCentralJwt(
    { client_id: 'c1', building_id: 'b1', cohabitat_user_id: 'u1' },
    { secret: SECRET },
  );
  const wrong = new TextEncoder().encode('another-secret-at-least-32-chars-xxxx');
  await assertRejects(() => jwtVerify(token, wrong));
});

Deno.test('mint : expiration respectee', async () => {
  const token = await mintCentralJwt(
    { client_id: 'c1', building_id: 'b1', cohabitat_user_id: 'u1' },
    { secret: SECRET, ttlSeconds: 1 },
  );
  // Attend au-dela de l'expiration.
  await new Promise((r) => setTimeout(r, 1500));
  await assertRejects(() => jwtVerify(token, SECRET, { issuer: 'modulimo-bridge' }));
});

Deno.test('secretFromEnv : erreur claire si absent', () => {
  const prev = Deno.env.get('TEST_MISSING_SECRET');
  Deno.env.delete('TEST_MISSING_SECRET');
  try {
    secretFromEnv('TEST_MISSING_SECRET');
    throw new Error('devait throw');
  } catch (e) {
    assertEquals((e as Error).message.includes('TEST_MISSING_SECRET'), true);
  }
  if (prev) Deno.env.set('TEST_MISSING_SECRET', prev);
});
