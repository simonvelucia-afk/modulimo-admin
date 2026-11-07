-- ============================================================
-- 035 — Colonnes de licences attendues par l'admin
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central. Idempotent : n'ajoute
-- que ce qui manque, ne modifie aucune donnée.
--
-- La table licences de Central a été créée hors de 000_base_tables.sql
-- et n'a pas toutes ses colonnes : enregistrer une licence dans l'admin
-- échouait (« Could not find the 'anon_key' column of 'licences' »), et
-- le déclencheur de 034 écrit licences.updated_at.
--
-- anon_key est la clé publique (publishable) de la base de l'immeuble :
-- publique par nature, elle sert à l'admin pour lire les services
-- consommés à facturer. Vide, l'admin se rabat sur la clé de Central.
-- ============================================================

BEGIN;

ALTER TABLE licences
  ADD COLUMN IF NOT EXISTS supabase_url TEXT,
  ADD COLUMN IF NOT EXISTS anon_key     TEXT,
  ADD COLUMN IF NOT EXISTS plan         TEXT,
  ADD COLUMN IF NOT EXISTS max_units    INT DEFAULT 20,
  ADD COLUMN IF NOT EXISTS modules      JSONB NOT NULL DEFAULT '{"trips":true,"lunch":false}'::JSONB,
  ADD COLUMN IF NOT EXISTS active       BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS expires_at   DATE,
  ADD COLUMN IF NOT EXISTS notes        TEXT,
  ADD COLUMN IF NOT EXISTS created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW();

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Vérification : colonnes de licences.
SELECT column_name, data_type
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'licences'
 ORDER BY ordinal_position;
