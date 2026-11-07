-- modules_abonnements_test.sql — vérifie la migration 034 : la licence
-- suit les abonnements par module, un seul abonnement en cours par
-- module, le catalogue est public mais pas les abonnements.
-- Transaction annulée.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/modules_abonnements_test.sql

BEGIN;

INSERT INTO clients (id, name) VALUES ('e0000000-0000-0000-0000-0000000003c1', 'Immeuble test');
INSERT INTO licences (client_id, domain, modules)
VALUES ('e0000000-0000-0000-0000-0000000003c1', 'test-034.example', '{"trips":true,"lunch":true}');

-- Souscrire base + serre pour 12 chambres
INSERT INTO abonnements_modules (client_id, module_code, quantite, prix_unitaire) VALUES
  ('e0000000-0000-0000-0000-0000000003c1', 'base',  12, 1.00),
  ('e0000000-0000-0000-0000-0000000003c1', 'serre', 12, 0.50);

DO $$
DECLARE m JSONB;
BEGIN
  SELECT modules INTO m FROM licences WHERE domain = 'test-034.example';
  IF m->>'serre' <> 'true' THEN RAISE EXCEPTION 'ECHEC : serre souscrite mais fermée (%)', m; END IF;
  IF m->>'trips' <> 'false' OR m->>'lunch' <> 'false' OR m->>'energie' <> 'false' THEN
    RAISE EXCEPTION 'ECHEC : module non souscrit resté ouvert (%)', m;
  END IF;
END $$;

-- Terminer la serre : la licence la ferme
UPDATE abonnements_modules SET statut = 'termine', fin = CURRENT_DATE
 WHERE client_id = 'e0000000-0000-0000-0000-0000000003c1' AND module_code = 'serre';
DO $$
BEGIN
  IF (SELECT modules->>'serre' FROM licences WHERE domain = 'test-034.example') <> 'false' THEN
    RAISE EXCEPTION 'ECHEC : serre terminée mais encore ouverte';
  END IF;
END $$;

-- Un seul abonnement en cours par module ; on peut resouscrire après la fin
DO $$
BEGIN
  BEGIN
    INSERT INTO abonnements_modules (client_id, module_code, quantite, prix_unitaire)
    VALUES ('e0000000-0000-0000-0000-0000000003c1', 'base', 12, 1.00);
    RAISE EXCEPTION 'ECHEC : deux abonnements « base » en cours';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
INSERT INTO abonnements_modules (client_id, module_code, quantite, prix_unitaire)
VALUES ('e0000000-0000-0000-0000-0000000003c1', 'serre', 12, 0.50);

-- Ligne de facture « module » acceptée
INSERT INTO contracts (id, client_id, type, status)
VALUES ('e0000000-0000-0000-0000-0000000003d1', 'e0000000-0000-0000-0000-0000000003c1', 'owner', 'active');
INSERT INTO invoices (id, contract_id, client_id, period_start, period_end, total_amount)
VALUES ('e0000000-0000-0000-0000-0000000003f1', 'e0000000-0000-0000-0000-0000000003d1',
        'e0000000-0000-0000-0000-0000000003c1', '2026-10-01', '2026-10-31', 18);
INSERT INTO invoice_line_items (invoice_id, category, description, quantity, unit_amount, total_amount)
VALUES ('e0000000-0000-0000-0000-0000000003f1', 'module', 'Module Base', 12, 1.00, 12.00);

-- Anon : lit le catalogue, pas les abonnements
SET LOCAL ROLE anon;
DO $$
BEGIN
  IF (SELECT count(*) FROM modules) < 6 THEN RAISE EXCEPTION 'ECHEC : catalogue illisible pour anon'; END IF;
  BEGIN
    PERFORM 1 FROM abonnements_modules;
    RAISE EXCEPTION 'ECHEC : anon lit les abonnements';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE modules SET prix_mensuel = 0;
    RAISE EXCEPTION 'ECHEC : anon modifie le catalogue';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

\echo 'OK : modules_abonnements_test'
ROLLBACK;
