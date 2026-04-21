-- =====================================================================
-- 007_finance_central_phase1.sql
-- Migration : fondation du solde central Modulimo (Phase 1 du plan
-- "solde central"). Pose le schema sans deplacer encore les donnees
-- depuis les DBs CoHabitat des immeubles — ce sera la Phase 3 (dual-write
-- puis bascule). Ici on cree seulement :
--   * building_registry  : table de confiance consultee par l'Edge
--                          Function finance-bridge pour valider les JWT
--                          emis par l'Auth Supabase de chaque immeuble.
--   * clients.building_id: scoping explicite par immeuble (aujourd'hui
--                          derive implicitement des contracts).
--   * balances, dependent_balances : source de verite du solde virtuel,
--                          scope par (client_id, building_id).
--   * transactions       : ledger append-only, un seul schema pour tous
--                          les immeubles au lieu de N schemas CoHabitat.
--   * helpers JWT + RLS  : jwt_building_id(), jwt_client_id() lisent le
--                          claim injecte par l'Edge Function.
--   * RPC get_balance    : lecture sure (SECURITY DEFINER, scope sur les
--                          claims JWT, aucune confiance dans le body).
--
-- Central DB cible : bpxscgrbxjscicpnheep
-- Edge Function appelante : supabase/functions/finance-bridge
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Extensions
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------
-- 2. building_registry — source de verite des projets Supabase immeubles
-- ---------------------------------------------------------------------
-- Chaque row represente un immeuble branche sur la centrale. L'Edge
-- Function finance-bridge lit cette table par 'jwt_issuer' pour retrouver
-- le JWKS a utiliser pour valider les signatures entrantes. Un immeuble
-- peut etre 'suspended' (refus des appels finance sans le retirer du
-- registre) ou 'offboarded' (purge prevue, lecture historique seulement).
CREATE TABLE IF NOT EXISTS building_registry (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL,
  supabase_url    text NOT NULL UNIQUE,
  jwt_issuer      text NOT NULL UNIQUE,
  jwks_url        text NOT NULL,
  status          text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','suspended','offboarded')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_building_registry_issuer
  ON building_registry(jwt_issuer);

ALTER TABLE building_registry ENABLE ROW LEVEL SECURITY;

-- Les residents n'ont pas besoin de voir d'autres immeubles ; la lecture
-- via l'Edge Function passe par la cle anon + policy select_authenticated,
-- mais on scope a un seul row a la fois (jwt_issuer match). Sans claim
-- building_id, anon peut lister tous les registres — c'est acceptable :
-- l'info (url + issuer) est par nature publique (on la trouve dans le
-- DNS + les JWT emis).
DROP POLICY IF EXISTS br_select_all ON building_registry;
CREATE POLICY br_select_all ON building_registry
  FOR SELECT TO anon, authenticated USING (TRUE);

-- Ecriture : seul un admin authentifie via le dashboard Modulimo doit
-- inserer un immeuble. Tant qu'on n'a pas de table admin_users formelle,
-- on autorise l'ecriture uniquement via connexions service_role (qui
-- bypass RLS par design). Aucun role 'authenticated' ne doit pouvoir
-- ecrire ici.
DROP POLICY IF EXISTS br_no_write ON building_registry;
CREATE POLICY br_no_write ON building_registry
  FOR ALL TO authenticated USING (FALSE) WITH CHECK (FALSE);

-- ---------------------------------------------------------------------
-- 3. clients.building_id — scoping explicite
-- ---------------------------------------------------------------------
-- La colonne est nullable dans un premier temps : on ne peut pas
-- backfill automatiquement sans connaitre quel immeuble a provisionne
-- quel client. Un script de migration par immeuble remplira cette
-- colonne (et on basculera en NOT NULL quand tous les rows auront un
-- building_id).
ALTER TABLE clients
  ADD COLUMN IF NOT EXISTS building_id uuid REFERENCES building_registry(id);

CREATE INDEX IF NOT EXISTS idx_clients_building ON clients(building_id);

-- Un meme cohabitat_user_id peut exister dans plusieurs immeubles
-- (theoriquement : utilisateur qui change d'immeuble ou double compte).
-- On contraint l'unicite au sein d'un meme immeuble seulement.
CREATE UNIQUE INDEX IF NOT EXISTS idx_clients_cohabitat_per_building
  ON clients(building_id, cohabitat_user_id)
  WHERE cohabitat_user_id IS NOT NULL AND building_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4. Helpers JWT lus depuis les claims injectes par l'Edge Function
-- ---------------------------------------------------------------------
-- L'Edge Function mint un JWT HS256 avec {building_id, client_id,
-- cohabitat_user_id}. PostgREST valide la signature et expose les claims
-- via auth.jwt(). Ces helpers centralisent la lecture + le cast.
CREATE OR REPLACE FUNCTION jwt_building_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(auth.jwt() ->> 'building_id', '')::uuid
$$;

CREATE OR REPLACE FUNCTION jwt_client_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(auth.jwt() ->> 'client_id', '')::uuid
$$;

-- ---------------------------------------------------------------------
-- 5. balances — solde principal par client (1:1)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS balances (
  client_id        uuid PRIMARY KEY REFERENCES clients(id) ON DELETE CASCADE,
  building_id      uuid NOT NULL REFERENCES building_registry(id),
  virtual_balance  numeric(12,2) NOT NULL DEFAULT 0.00,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_balances_building ON balances(building_id);

-- ---------------------------------------------------------------------
-- 6. dependent_balances — un solde par dependant
-- ---------------------------------------------------------------------
-- `external_dep_id` est l'id du dependant cote CoHabitat (opaque pour la
-- centrale : text pour ne pas contraindre le type a l'avance). Scopee
-- par (client_id, external_dep_id) : un meme dependant ne peut exister
-- qu'une fois par client.
CREATE TABLE IF NOT EXISTS dependent_balances (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id        uuid NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  building_id      uuid NOT NULL REFERENCES building_registry(id),
  external_dep_id  text NOT NULL,
  label            text,
  virtual_balance  numeric(12,2) NOT NULL DEFAULT 0.00,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, external_dep_id)
);

CREATE INDEX IF NOT EXISTS idx_dep_balances_client ON dependent_balances(client_id);
CREATE INDEX IF NOT EXISTS idx_dep_balances_building ON dependent_balances(building_id);

-- ---------------------------------------------------------------------
-- 7. transactions — ledger append-only
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id         uuid NOT NULL REFERENCES clients(id),
  building_id       uuid NOT NULL REFERENCES building_registry(id),
  dependent_id      uuid REFERENCES dependent_balances(id),  -- null si solde principal
  amount            numeric(12,2) NOT NULL,
  balance_after     numeric(12,2) NOT NULL,
  type              text NOT NULL CHECK (type IN (
    'admin_credit',
    'space_reservation',
    'space_cancel_refund',
    'trip_booking',
    'trip_cancel_refund',
    'trip_cancel_charge',
    'trip_driver_earning',
    'trip_driver_charge',
    'lunch_purchase',
    'demo'
  )),
  reference_id      uuid,
  reference_type    text,
  description       text,
  idempotency_key   text UNIQUE,
  created_by        uuid,  -- auth.users.id si cree via admin, sinon null
  is_demo           boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tx_client_building
  ON transactions(client_id, building_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tx_building_created
  ON transactions(building_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tx_type ON transactions(type);
CREATE INDEX IF NOT EXISTS idx_tx_reference
  ON transactions(reference_type, reference_id)
  WHERE reference_id IS NOT NULL;

-- Append-only : pas d'UPDATE ni DELETE. Les corrections passent par une
-- nouvelle ligne compensatoire (pattern ledger standard).
CREATE OR REPLACE FUNCTION transactions_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'transactions is append-only (op=%)', TG_OP
    USING ERRCODE = 'read_only_sql_transaction';
END;
$$;

DROP TRIGGER IF EXISTS trg_transactions_no_update ON transactions;
CREATE TRIGGER trg_transactions_no_update
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION transactions_immutable();

DROP TRIGGER IF EXISTS trg_transactions_no_delete ON transactions;
CREATE TRIGGER trg_transactions_no_delete
  BEFORE DELETE ON transactions
  FOR EACH ROW EXECUTE FUNCTION transactions_immutable();

-- ---------------------------------------------------------------------
-- 8. RLS sur balances / dependent_balances / transactions
-- ---------------------------------------------------------------------
-- Les policies scopent au JWT injecte par l'Edge Function. Si le claim
-- est absent (requete directe sans passer par finance-bridge), le WHERE
-- est FALSE puisque jwt_client_id() retourne NULL.
ALTER TABLE balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE dependent_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bal_select_self ON balances;
CREATE POLICY bal_select_self ON balances
  FOR SELECT TO authenticated
  USING (client_id = jwt_client_id() AND building_id = jwt_building_id());

-- Aucune policy INSERT/UPDATE/DELETE pour authenticated : tout passe par
-- les RPC SECURITY DEFINER (a venir dans les phases suivantes).

DROP POLICY IF EXISTS depbal_select_self ON dependent_balances;
CREATE POLICY depbal_select_self ON dependent_balances
  FOR SELECT TO authenticated
  USING (client_id = jwt_client_id() AND building_id = jwt_building_id());

DROP POLICY IF EXISTS tx_select_self ON transactions;
CREATE POLICY tx_select_self ON transactions
  FOR SELECT TO authenticated
  USING (client_id = jwt_client_id() AND building_id = jwt_building_id());

-- ---------------------------------------------------------------------
-- 9. RPC get_balance — lecture sure
-- ---------------------------------------------------------------------
-- SECURITY DEFINER pour bypasser la RLS cote lecture interne, mais on
-- re-applique le filtre explicite sur jwt_client_id() + jwt_building_id()
-- : la confiance repose sur PostgREST qui a deja valide le JWT central.
--
-- Contrat de retour :
--   * si p_external_dep_id IS NULL => solde principal (balances)
--   * sinon => solde du dependant (dependent_balances)
--   * si aucune ligne n'existe encore => retourne 0.00 (clients non
--     encore provisionnes n'ont pas d'erreur, affichent 0)
CREATE OR REPLACE FUNCTION get_balance(
  p_external_dep_id text DEFAULT NULL
) RETURNS TABLE(
  virtual_balance numeric,
  source_kind     text,        -- 'main' | 'dependent' | 'missing'
  updated_at      timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client_id   uuid := jwt_client_id();
  v_building_id uuid := jwt_building_id();
BEGIN
  IF v_client_id IS NULL OR v_building_id IS NULL THEN
    RAISE EXCEPTION 'missing_jwt_claims'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_external_dep_id IS NULL THEN
    RETURN QUERY
    SELECT b.virtual_balance, 'main'::text, b.updated_at
      FROM balances b
     WHERE b.client_id = v_client_id
       AND b.building_id = v_building_id;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 0.00::numeric, 'missing'::text, NULL::timestamptz;
    END IF;
  ELSE
    RETURN QUERY
    SELECT d.virtual_balance, 'dependent'::text, d.updated_at
      FROM dependent_balances d
     WHERE d.client_id = v_client_id
       AND d.building_id = v_building_id
       AND d.external_dep_id = p_external_dep_id;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 0.00::numeric, 'missing'::text, NULL::timestamptz;
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION get_balance(text) FROM public;
GRANT EXECUTE ON FUNCTION get_balance(text) TO authenticated;

-- GRANTs cote tables : sans ces GRANT, meme avec RLS permissive, le role
-- authenticated ne peut rien lire (Supabase n'auto-grant pas pour les
-- tables creees via migration custom). On n'accorde QUE SELECT : tout
-- INSERT/UPDATE/DELETE doit passer par les RPC SECURITY DEFINER.
GRANT SELECT ON balances, dependent_balances, transactions TO authenticated;

-- ---------------------------------------------------------------------
-- 10. updated_at triggers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_br_updated_at ON building_registry;
CREATE TRIGGER trg_br_updated_at BEFORE UPDATE ON building_registry
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_balances_updated_at ON balances;
CREATE TRIGGER trg_balances_updated_at BEFORE UPDATE ON balances
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_depbal_updated_at ON dependent_balances;
CREATE TRIGGER trg_depbal_updated_at BEFORE UPDATE ON dependent_balances
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

COMMIT;

-- Forcer PostgREST a recharger son schema pour exposer get_balance.
NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Rollback (pour reference — a executer manuellement si besoin)
-- =====================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS get_balance(text);
-- DROP TRIGGER IF EXISTS trg_transactions_no_delete ON transactions;
-- DROP TRIGGER IF EXISTS trg_transactions_no_update ON transactions;
-- DROP FUNCTION IF EXISTS transactions_immutable();
-- DROP TABLE IF EXISTS transactions;
-- DROP TABLE IF EXISTS dependent_balances;
-- DROP TABLE IF EXISTS balances;
-- DROP FUNCTION IF EXISTS jwt_client_id();
-- DROP FUNCTION IF EXISTS jwt_building_id();
-- ALTER TABLE clients DROP COLUMN IF EXISTS building_id;
-- DROP TABLE IF EXISTS building_registry;
-- COMMIT;
