-- politiques_manuelles_test.sql — vérifie la migration 031 : sans
-- connexion, on ne modifie plus un contrat ni un solde réseau, on ne lit
-- plus la configuration ; CoHabitat lit toujours le statut d'un contrat ;
-- l'administration garde la main. Transaction annulée.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/politiques_manuelles_test.sql

BEGIN;

INSERT INTO clients (id, name) VALUES ('e0000000-0000-0000-0000-0000000001c1', 'Immeuble test');
INSERT INTO contracts (id, client_id, type, status)
VALUES ('e0000000-0000-0000-0000-0000000001d1', 'e0000000-0000-0000-0000-0000000001c1', 'owner', 'suspended');
INSERT INTO app_config (key, value) VALUES ('test_cle', 'valeur');

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND policyname IN
       ('contracts_all', 'nb_anon_update', 'ls_all', 'ls_read', 'config_read',
        'public write transactions', 'public read transactions')) THEN
    RAISE EXCEPTION 'ECHEC : une politique ouverte subsiste';
  END IF;
END $$;

SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
DO $$
BEGIN
  -- CoHabitat lit toujours le statut du contrat.
  IF (SELECT status FROM contracts WHERE id = 'e0000000-0000-0000-0000-0000000001d1') IS DISTINCT FROM 'suspended' THEN
    RAISE EXCEPTION 'ECHEC : CoHabitat ne lit plus le statut du contrat';
  END IF;
  -- Mais ne le réactive plus.
  BEGIN
    UPDATE contracts SET status = 'active';
    RAISE EXCEPTION 'ECHEC : anon réactive un contrat';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM contracts;
    RAISE EXCEPTION 'ECHEC : anon supprime les contrats';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE network_balances SET balance = 1000000;
    RAISE EXCEPTION 'ECHEC : anon modifie un solde réseau';
  EXCEPTION WHEN insufficient_privilege OR undefined_column THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM app_config;
    RAISE EXCEPTION 'ECHEC : anon lit la configuration';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"e0000000-0000-0000-0000-0000000001ad"}', TRUE);
DO $$
BEGIN
  UPDATE contracts SET status = 'active' WHERE id = 'e0000000-0000-0000-0000-0000000001d1';
  IF (SELECT status FROM contracts WHERE id = 'e0000000-0000-0000-0000-0000000001d1') <> 'active' THEN
    RAISE EXCEPTION 'ECHEC : l''administration ne modifie plus un contrat';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app_config WHERE key = 'test_cle') THEN
    RAISE EXCEPTION 'ECHEC : l''administration ne lit plus la configuration';
  END IF;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'politiques_manuelles_test : OK'; END $$;

ROLLBACK;
