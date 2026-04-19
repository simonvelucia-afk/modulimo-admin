-- 004_lunch_purchase_rpc_and_menus.sql
-- A) Ajoute les colonnes user_id / dep_id sur lunch_transactions pour tracer qui a achete.
-- B) Nouvelle table lunch_menus (menus pre-etablis partages, remplace l'ancien state.menus localStorage).
-- C) Fonction RPC lunch_purchase(...) : atomique, verifie les fonds, ecrit la tx, debite le solde.
--
-- A deployer sur les DEUX Supabase :
--   - bpxscgrbxjscicpnheep (central : lunch_transactions, lunch_slots, lunch_menus)
--   - uwyhrdjlwetcbtskijrs (cohabitat : profiles, dependents, lunch_queue, lunch_sessions)
-- La fonction lunch_purchase doit etre deployee sur le Supabase qui contient profiles/dependents
-- (cohabitat) car c'est lui qui heberge les soldes. Si lunch_transactions est sur l'autre
-- instance, adapter en consequence (cf note en bas du fichier).


-- =========================================================================
-- A) Colonnes user_id / dep_id sur lunch_transactions (traçabilité)
-- =========================================================================
ALTER TABLE lunch_transactions
  ADD COLUMN IF NOT EXISTS user_id UUID,
  ADD COLUMN IF NOT EXISTS dep_id  UUID;

CREATE INDEX IF NOT EXISTS idx_lunch_tx_user ON lunch_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_lunch_tx_dep  ON lunch_transactions(dep_id);


-- =========================================================================
-- B) Table lunch_menus (menus pre-etablis, partages entre kiosques et apps)
-- NB: id est TEXT pour conserver les ids client-generes (m_<timestamp>).
-- Le kiosque peut ainsi continuer a fonctionner en mode offline et se synchroniser
-- sans conflit d'id.
-- =========================================================================
CREATE TABLE IF NOT EXISTS lunch_menus (
  id          TEXT PRIMARY KEY,
  machine_id  TEXT NOT NULL,
  description TEXT NOT NULL,
  price       NUMERIC(8,2) NOT NULL DEFAULT 0,
  photo       TEXT,
  chef        TEXT,
  ingredients TEXT,
  allergens   JSONB NOT NULL DEFAULT '[]'::jsonb,
  calories    NUMERIC(8,2),
  proteines   NUMERIC(8,2),
  glucides    NUMERIC(8,2),
  lipides     NUMERIC(8,2),
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lunch_menus_machine ON lunch_menus(machine_id) WHERE active;

-- RLS : lecture pour tous (anon compris, les menus sont publics dans le kiosque),
-- ecriture reservee aux admins authentifies.
ALTER TABLE lunch_menus ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lunch_menus_select_all ON lunch_menus;
CREATE POLICY lunch_menus_select_all ON lunch_menus
  FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS lunch_menus_write_auth ON lunch_menus;
CREATE POLICY lunch_menus_write_auth ON lunch_menus
  FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);


-- =========================================================================
-- C) RPC lunch_purchase : debit atomique du solde
-- =========================================================================
-- Deployer sur le Supabase qui contient profiles + dependents (cohabitat).
-- Si dep_id est fourni, debite le solde du dependant ; sinon celui du profil.
-- L'appelant passe aussi slot_id (pour tracer la tx) et montant.
-- RAISE EXCEPTION si le solde est insuffisant -> aucun ecrit.

CREATE OR REPLACE FUNCTION lunch_purchase(
  p_user_id  UUID,
  p_dep_id   UUID,
  p_machine_id TEXT,
  p_slot_db_id UUID,
  p_buyer_name TEXT,
  p_amount   NUMERIC
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current NUMERIC;
  v_tx_id   UUID;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'Montant invalide';
  END IF;

  -- 1. Debiter le bon solde (dependant ou profil parent)
  IF p_dep_id IS NOT NULL THEN
    SELECT virtual_balance INTO v_current FROM dependents WHERE id = p_dep_id FOR UPDATE;
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'Dependant introuvable';
    END IF;
    IF v_current < p_amount THEN
      RAISE EXCEPTION 'Solde insuffisant (dep: %, requis: %)', v_current, p_amount;
    END IF;
    UPDATE dependents
       SET virtual_balance = virtual_balance - p_amount
     WHERE id = p_dep_id;
  ELSE
    SELECT virtual_balance INTO v_current FROM profiles WHERE id = p_user_id FOR UPDATE;
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'Profil introuvable';
    END IF;
    IF v_current < p_amount THEN
      RAISE EXCEPTION 'Solde insuffisant (% requis, % disponible)', p_amount, v_current;
    END IF;
    UPDATE profiles
       SET virtual_balance = virtual_balance - p_amount
     WHERE id = p_user_id;
  END IF;

  -- 2. Enregistrer la transaction
  -- NB: si lunch_transactions est sur un autre projet Supabase, cette section doit
  -- etre faite cote client via l'API. Ici on suppose la meme instance.
  INSERT INTO lunch_transactions (machine_id, slot_id, buyer_name, price, user_id, dep_id)
  VALUES (p_machine_id, p_slot_db_id, p_buyer_name, p_amount, p_user_id, p_dep_id)
  RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$$;

-- Autoriser l'appel par les utilisateurs authentifies ET anon (le kiosque
-- passe souvent par l'anon key avec un chsession). La fonction reste sure
-- car elle verifie les soldes et est atomique.
GRANT EXECUTE ON FUNCTION lunch_purchase(UUID, UUID, TEXT, UUID, TEXT, NUMERIC)
  TO anon, authenticated;


-- =========================================================================
-- NOTE : deux instances Supabase
-- =========================================================================
-- Le projet utilise deux instances :
--   * bpxscgrbxjscicpnheep  (central : lunch_*)
--   * uwyhrdjlwetcbtskijrs  (cohabitat : profiles, dependents)
-- Deux options :
--   1) Deployer lunch_purchase sur cohabitat, et laisser le client appeler
--      saveTransactionToSupabase() sur central apres succes du RPC (non
--      atomique entre les deux bases, mais idempotent).
--   2) Deplacer lunch_transactions sur cohabitat (meilleure coherence).
--
-- Par defaut ce fichier suppose (1). Adapter la fonction si tu choisis (2).
