-- parc_lunch_test.sql — vérifie la migration 036 : l'abonnement de location
-- suit le parc (nombre de machines en service), une location ne touche pas
-- aux modules de la licence, le parc est fermé à la clé anon.
-- Transaction annulée.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/parc_lunch_test.sql

BEGIN;

UPDATE modules SET prix_mensuel = 75 WHERE code = 'lunch_location';
INSERT INTO clients (id, name) VALUES
  ('e0000000-0000-0000-0000-0000000036c1', 'Immeuble A'),
  ('e0000000-0000-0000-0000-0000000036c2', 'Immeuble B');
INSERT INTO licences (client_id, domain, modules)
VALUES ('e0000000-0000-0000-0000-0000000036c1', 'test-036.example', '{"trips":true,"lunch":true,"serre":true}');

-- Deux machines en service chez A, une en stock
INSERT INTO parc_lunch (numero_serie, client_id, statut) VALUES
  ('LM-001', 'e0000000-0000-0000-0000-0000000036c1', 'en_service'),
  ('LM-002', 'e0000000-0000-0000-0000-0000000036c1', 'en_service'),
  ('LM-003', NULL, 'en_stock');

DO $$
DECLARE a abonnements_modules%ROWTYPE; m JSONB;
BEGIN
  SELECT * INTO a FROM abonnements_modules WHERE client_id = 'e0000000-0000-0000-0000-0000000036c1' AND module_code = 'lunch_location' AND statut = 'actif';
  IF a.id IS NULL OR a.quantite <> 2 OR a.prix_unitaire <> 75 THEN RAISE EXCEPTION 'ECHEC : location attendue 2 × 75, obtenu %', a; END IF;
  SELECT modules INTO m FROM licences WHERE domain = 'test-036.example';
  IF m->>'trips' <> 'true' OR m->>'lunch' <> 'true' OR m->>'serre' <> 'true' THEN
    RAISE EXCEPTION 'ECHEC : la location a modifié les modules de la licence (%)', m;
  END IF;
END $$;

-- Une machine part en entretien : quantité 1
UPDATE parc_lunch SET statut = 'entretien' WHERE numero_serie = 'LM-002';
DO $$ BEGIN
  IF (SELECT quantite FROM abonnements_modules WHERE client_id = 'e0000000-0000-0000-0000-0000000036c1' AND module_code = 'lunch_location' AND statut = 'actif') <> 1 THEN
    RAISE EXCEPTION 'ECHEC : entretien non retiré du loyer'; END IF;
END $$;

-- La dernière machine de A déménage chez B : A terminé, B abonné
UPDATE parc_lunch SET client_id = 'e0000000-0000-0000-0000-0000000036c2' WHERE numero_serie = 'LM-001';
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM abonnements_modules WHERE client_id = 'e0000000-0000-0000-0000-0000000036c1' AND module_code = 'lunch_location' AND statut = 'actif') THEN
    RAISE EXCEPTION 'ECHEC : A paie encore une location'; END IF;
  IF (SELECT quantite FROM abonnements_modules WHERE client_id = 'e0000000-0000-0000-0000-0000000036c2' AND module_code = 'lunch_location' AND statut = 'actif') <> 1 THEN
    RAISE EXCEPTION 'ECHEC : B ne paie pas sa machine'; END IF;
END $$;

-- Une machine en service doit être chez quelqu'un
DO $$ BEGIN
  BEGIN
    INSERT INTO parc_lunch (numero_serie, statut) VALUES ('LM-004', 'en_service');
    RAISE EXCEPTION 'ECHEC : machine en service sans immeuble';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;

-- Anon : aucun accès au parc
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN
    PERFORM 1 FROM parc_lunch;
    RAISE EXCEPTION 'ECHEC : anon lit le parc';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

\echo 'OK : parc_lunch_test'
ROLLBACK;
