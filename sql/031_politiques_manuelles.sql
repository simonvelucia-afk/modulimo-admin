-- 031_politiques_manuelles.sql
-- Retirer les politiques ouvertes ajoutées à la main sur la centrale.
--
-- Relevées le 2026-11-01 sur la base en ligne (pg_policies, rôles anon
-- ou public), hors de toute migration de ce dépôt :
--
--   contracts                  contracts_all (ALL, true) : n'importe qui,
--                              sans connexion, modifiait ou supprimait
--                              tout contrat — y compris réactiver le sien,
--                              suspendu pour non-paiement.
--   network_balances           nb_anon_update (UPDATE, true) : soldes
--                              entre immeubles modifiables par tous.
--                              Aucun appelant.
--   lunch_sessions             ls_all, ls_read, ls_insert, ls_delete :
--                              sessions du kiosque (ancien circuit par la
--                              centrale) lisibles et modifiables.
--   lunch_transactions_legacy_central
--                              lecture et écriture complètes : historique
--                              d'achats (noms) ouvert.
--   app_config                 config_read : configuration lisible sans
--                              connexion. Aucun appelant anon.
--
-- CE QUI RESTE, PARCE QUE COHABITAT S'EN SERT AVEC LA CLÉ ANON
--
--   contracts (lecture)        statut du contrat de l'immeuble et du
--                              résident. Lecture seule désormais.
--   licences, plans,           licence d'un domaine, forfaits affichés.
--   plan_features
--   network_members,           réseaux d'immeubles et ressources
--   shared_resources           partagées.
--   network_transactions       insertion : trace d'une réservation dans
--                              un autre immeuble. À faire passer par
--                              finance-bridge (vérification du jeton) —
--                              en attendant, l'insertion reste ouverte.
--   building_registry          public par nature.
--
-- Les comptes connectés (interface d'administration) gardent tous leurs
-- accès : la politique *_admin_all de 000 est recréée si elle manque.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ============================================================
-- 1) Politiques ouvertes : retirées
-- ============================================================
DO $drop$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('contracts',                         'contracts_all'),
      ('network_balances',                  'nb_anon_update'),
      ('lunch_sessions',                    'ls_all'),
      ('lunch_sessions',                    'ls_read'),
      ('lunch_sessions',                    'ls_insert'),
      ('lunch_sessions',                    'ls_delete'),
      ('lunch_transactions_legacy_central', 'public read transactions'),
      ('lunch_transactions_legacy_central', 'public write transactions'),
      ('app_config',                        'config_read')
    ) AS v(t, p)
  LOOP
    IF to_regclass('public.' || quote_ident(r.t)) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I', r.p, r.t);
    END IF;
  END LOOP;
END $drop$;

-- Plus aucun droit pour anon sur ce qui ne lui sert pas.
DO $revoke$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['network_balances', 'lunch_sessions',
                           'lunch_transactions_legacy_central', 'app_config'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON %I FROM anon', t);
    END IF;
  END LOOP;
END $revoke$;

-- ============================================================
-- 2) Contrats : lecture seule pour anon
-- ============================================================
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON contracts FROM anon;
DROP POLICY IF EXISTS contracts_lecture_anon ON contracts;
CREATE POLICY contracts_lecture_anon ON contracts
  FOR SELECT TO anon USING (TRUE);

-- ============================================================
-- 3) L'interface d'administration garde la main
-- ============================================================
DO $admin$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['contracts', 'network_balances', 'app_config',
                           'lunch_sessions', 'lunch_transactions_legacy_central'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                    AND tablename = t AND policyname = t || '_admin_all') THEN
      EXECUTE format('CREATE POLICY %I ON %I FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE)',
                     t || '_admin_all', t);
    END IF;
  END LOOP;
END $admin$;

COMMIT;

NOTIFY pgrst, 'reload schema';
