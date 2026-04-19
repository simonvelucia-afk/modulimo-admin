-- 004_lunch_purchase_rpc_and_menus.sql
-- A deployer sur la base CENTRALE (bpxscgrbxjscicpnheep) qui porte la
-- configuration machine (lunch_machines, lunch_zones, lunch_slots).
--
-- NOTE IMPORTANTE :
--   La RPC lunch_purchase et lunch_transactions ont ete DEPLACEES cote
--   CoHabitat (base immeuble) parce que les soldes (profiles.virtual_balance,
--   dependents.virtual_balance) y vivent et qu'il faut un debit atomique.
--   Voir : CoHabitat/sql/001_lunch_coherence.sql.
--
-- Cette migration ne conserve desormais que la table lunch_menus qui reste
-- legitimement sur la base centrale (elle refere a des lunch_slots centraux
-- et est partagee entre kiosques).


-- =========================================================================
-- Table lunch_menus (menus pre-etablis, partages entre kiosques)
-- id est TEXT pour conserver les ids client-generes (m_<timestamp>) et
-- permettre au kiosque de fonctionner offline puis de se synchroniser.
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

ALTER TABLE lunch_menus ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lunch_menus_select_all ON lunch_menus;
CREATE POLICY lunch_menus_select_all ON lunch_menus
  FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS lunch_menus_write_auth ON lunch_menus;
CREATE POLICY lunch_menus_write_auth ON lunch_menus
  FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);

-- Ecriture anon : le kiosque utilise l'anon key pour sauvegarder les menus
-- edites depuis son interface admin. Si tu veux renforcer, il faut que
-- l'admin du kiosque soit authentifie via Supabase avant d'editer.
DROP POLICY IF EXISTS lunch_menus_write_anon ON lunch_menus;
CREATE POLICY lunch_menus_write_anon ON lunch_menus
  FOR ALL TO anon USING (TRUE) WITH CHECK (TRUE);
