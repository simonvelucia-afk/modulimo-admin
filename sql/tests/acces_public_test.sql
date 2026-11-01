-- acces_public_test.sql — vérifie la migration 030 : la clé anon ne
-- marque plus une facture payée, ne lit plus les factures d'un résident,
-- ne touche plus aux tables Lunch de la centrale ; un compte connecté
-- (interface d'administration) garde la main. Transaction annulée.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/acces_public_test.sql

BEGIN;

INSERT INTO clients (id, name, cohabitat_user_id)
VALUES ('e0000000-0000-0000-0000-0000000000c1', 'Client test', 'e0000000-0000-0000-0000-0000000000aa');
INSERT INTO contracts (id, client_id, type, status)
VALUES ('e0000000-0000-0000-0000-0000000000d1', 'e0000000-0000-0000-0000-0000000000c1', 'resident', 'suspended');
INSERT INTO invoices (id, contract_id, client_id, period_start, period_end, total_amount)
VALUES ('e0000000-0000-0000-0000-0000000000f1', 'e0000000-0000-0000-0000-0000000000d1',
        'e0000000-0000-0000-0000-0000000000c1', '2026-10-01', '2026-10-31', 50);
INSERT INTO lunch_machines (id, name, pin) VALUES ('MTEST', 'Machine test', '1234');

-- ------------------------------------------------------------
-- Anon : rien
-- ------------------------------------------------------------
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
DO $$
BEGIN
  BEGIN
    PERFORM public.record_invoice_payment('e0000000-0000-0000-0000-0000000000f1', 'cash', NULL, NULL);
    RAISE EXCEPTION 'ECHEC : anon marque une facture payée';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.list_client_invoices('e0000000-0000-0000-0000-0000000000aa');
    RAISE EXCEPTION 'ECHEC : anon liste les factures d''un résident';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM invoices;
    RAISE EXCEPTION 'ECHEC : anon lit les factures';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM pin FROM lunch_machines;
    RAISE EXCEPTION 'ECHEC : anon lit le PIN d''une machine';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE lunch_machines SET name = 'pirate';
    RAISE EXCEPTION 'ECHEC : anon modifie une machine';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO lunch_menus (machine_id, name) VALUES ('MTEST', 'pirate');
    RAISE EXCEPTION 'ECHEC : anon écrit un menu';
  EXCEPTION WHEN insufficient_privilege OR not_null_violation OR undefined_column THEN NULL;
  END;
END $$;

-- ------------------------------------------------------------
-- Compte connecté (admin) : garde la main
-- ------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"e0000000-0000-0000-0000-0000000000ad"}', TRUE);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM invoices) THEN RAISE EXCEPTION 'ECHEC : l''admin ne lit plus les factures'; END IF;
  IF NOT EXISTS (SELECT 1 FROM lunch_machines) THEN RAISE EXCEPTION 'ECHEC : l''admin ne lit plus les machines'; END IF;
  PERFORM public.record_invoice_payment('e0000000-0000-0000-0000-0000000000f1', 'cash', 'test', NULL);
  IF (SELECT status FROM invoices WHERE id = 'e0000000-0000-0000-0000-0000000000f1') <> 'paid' THEN
    RAISE EXCEPTION 'ECHEC : l''admin n''enregistre plus un paiement';
  END IF;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'acces_public_test : OK'; END $$;

ROLLBACK;
