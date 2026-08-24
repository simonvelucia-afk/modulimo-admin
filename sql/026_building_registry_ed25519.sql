-- 026_building_registry_ed25519.sql
-- Permet a la centrale d'authentifier les immeubles auto-heberges.
--
-- Jusqu'ici, finance-bridge verifiait le jeton d'un resident avec les
-- JWKS de son projet Supabase. Une instance CoHabitat installee chez le
-- client signe ses jetons en HS256 avec un secret local et n'expose
-- aucun JWKS : ce chemin ne peut pas fonctionner, et partager le secret
-- avec la centrale serait pire — il permettrait de fabriquer le jeton
-- de n'importe quel resident.
--
-- L'instance presente donc a la place une ASSERTION signee avec la cle
-- privee Ed25519 de sa federation, apres avoir verifie elle-meme le
-- jeton du resident. La centrale ne detient que la cle PUBLIQUE : elle
-- peut verifier, jamais usurper.
--
-- Les immeubles heberges sur Supabase gardent le mode 'jwks' : rien ne
-- change pour eux.

BEGIN;

ALTER TABLE building_registry
  ADD COLUMN IF NOT EXISTS auth_mode TEXT NOT NULL DEFAULT 'jwks',
  ADD COLUMN IF NOT EXISTS federation_public_key TEXT;

ALTER TABLE building_registry DROP CONSTRAINT IF EXISTS building_registry_auth_mode_check;
ALTER TABLE building_registry
  ADD CONSTRAINT building_registry_auth_mode_check
  CHECK (auth_mode IN ('jwks', 'ed25519'));

-- Un immeuble en mode ed25519 sans cle publique serait accepte par la
-- lecture puis rejete a la verification : autant l'interdire ici.
ALTER TABLE building_registry DROP CONSTRAINT IF EXISTS building_registry_ed25519_key_check;
ALTER TABLE building_registry
  ADD CONSTRAINT building_registry_ed25519_key_check
  CHECK (auth_mode <> 'ed25519' OR federation_public_key IS NOT NULL);

COMMENT ON COLUMN building_registry.auth_mode IS
  'jwks : immeuble heberge sur Supabase, jeton du resident verifie via
  les JWKS du projet. ed25519 : instance auto-hebergee, qui presente une
  assertion signee par sa cle de federation (elle a deja verifie le
  jeton du resident localement).';

COMMENT ON COLUMN building_registry.federation_public_key IS
  'Cle publique Ed25519 de l''instance, au format SPKI base64url —
  exactement ce que publie /federation/v1/identity cote CoHabitat.
  Publique : sa divulgation ne permet rien.';

COMMIT;

NOTIFY pgrst, 'reload schema';
