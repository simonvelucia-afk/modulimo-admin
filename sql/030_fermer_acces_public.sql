-- 030_fermer_acces_public.sql
-- Fermer ce que la clé publique (anon) de la centrale pouvait faire.
--
-- La clé anon de la centrale est publique : elle est dans config.js de
-- cette interface, de CoHabitat et du kiosque. Tout ce qui lui est
-- ouvert l'est à n'importe qui sur Internet.
--
-- CE QUI ÉTAIT OUVERT
--
--   record_invoice_payment (002)  marquer une facture PAYÉE et réactiver
--                                 un contrat suspendu, sans connexion ni
--                                 vérification. L'identifiant de facture
--                                 s'obtenait par list_client_invoices.
--   list_client_invoices,         factures, lignes de facture et demande
--   get_invoice_detail,           de changement de forfait de n'importe
--   request_plan_upgrade (002)    quel résident, à partir de son
--                                 identifiant CoHabitat — que chaque
--                                 résident connaît pour lui-même et voit
--                                 pour ses voisins. Aucun appelant anon
--                                 légitime : CoHabitat les appelle sur la
--                                 base de l'immeuble, pas ici.
--   lunch_menus (004)             écriture complète par anon ;
--   lunch_machines (005)          modification par anon, et lecture de la
--                                 colonne pin (000) ;
--   lunch_machines/zones/slots    lecture par anon (000). Le kiosque ne
--                                 lit plus la centrale depuis qu'il vend
--                                 dans la base de l'immeuble.
--   invoices, invoice_line_items  RLS jamais activé dans une migration.
--
-- CE QUI RESTE OUVERT, VOULU
--
--   get_contract_by_token / sign_contract_with_token (001) : signature
--   d'un contrat par lien à jeton (sign.html) ; le jeton fait l'accès.
--   building_registry (007) : URL et émetteur des immeubles, publics.
--
-- L'interface d'administration (comptes connectés) garde tous ses accès.
-- Sa sécurité repose sur un point hors de ce fichier : les INSCRIPTIONS
-- doivent être FERMÉES sur le projet Supabase de la centrale
-- (Authentication → Sign In / Providers → « Allow new users to sign up »
-- désactivé). Sinon n'importe qui se crée un compte et lit tout.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ============================================================
-- 1) Factures : plus d'appel sans connexion
-- ============================================================
DO $fn$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.record_invoice_payment(uuid,text,text,text)',
    'public.list_client_invoices(uuid)',
    'public.get_invoice_detail(uuid,uuid)',
    'public.request_plan_upgrade(uuid,text)'
  ] LOOP
    IF to_regprocedure(f) IS NOT NULL THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
    END IF;
  END LOOP;
END $fn$;

-- ============================================================
-- 2) Tables de factures : RLS, lecture et écriture aux connectés
-- ============================================================
DO $inv$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['invoices', 'invoice_line_items'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('REVOKE ALL ON %I FROM anon', t);
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_admin_all', t);
      EXECUTE format('CREATE POLICY %I ON %I FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE)',
                     t || '_admin_all', t);
    END IF;
  END LOOP;
END $inv$;

-- ============================================================
-- 3) Tables Lunch de la centrale : plus rien pour anon
-- ============================================================
DO $lunch$
DECLARE
  t TEXT;
  p RECORD;
BEGIN
  FOREACH t IN ARRAY ARRAY['lunch_machines', 'lunch_zones', 'lunch_slots', 'lunch_menus'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
    -- Toute politique visant anon ou public, y compris ajoutée à la main.
    FOR p IN SELECT policyname FROM pg_policies
              WHERE schemaname = 'public' AND tablename = t
                AND roles && ARRAY['anon', 'public']::name[] LOOP
      EXECUTE format('DROP POLICY %I ON %I', p.policyname, t);
    END LOOP;
    EXECUTE format('REVOKE ALL ON %I FROM anon', t);
  END LOOP;
END $lunch$;

COMMIT;

NOTIFY pgrst, 'reload schema';
