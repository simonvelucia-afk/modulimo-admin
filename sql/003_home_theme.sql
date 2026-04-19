-- ============================================================================
-- 003 — Thème événementiel du site public (modulimo.com)
-- ============================================================================
-- Ajoute la clé `home_theme` dans `app_config` pour piloter la couleur du
-- logo et de l'en-tête du site public depuis la page Configuration de l'admin.
--
-- Valeurs possibles : 'none' | 'femme' | 'terre'
-- ============================================================================

INSERT INTO app_config (key, value)
  SELECT 'home_theme', 'none'
  WHERE NOT EXISTS (SELECT 1 FROM app_config WHERE key = 'home_theme');

-- Le site public lit cette valeur en anonyme ; on autorise le SELECT public.
-- (Si RLS est activé sur app_config, décommente la policy ci-dessous.)
-- ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS "app_config read home_theme" ON app_config;
-- CREATE POLICY "app_config read home_theme" ON app_config
--   FOR SELECT USING (key = 'home_theme');
