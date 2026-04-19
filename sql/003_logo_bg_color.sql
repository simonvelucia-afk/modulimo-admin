-- 003_logo_bg_color.sql
-- Preference de couleur de fond du logo, par resident.
-- Valeurs autorisees : 'red','orange','yellow','green','blue','indigo','violet','pink'
-- NULL = pas de fond (transparent).
-- Override applicatif : le 8 mars (Journee internationale des femmes), le fond
-- est force a 'pink' cote client, peu importe la preference de l'utilisateur.

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS logo_bg_color TEXT
  CHECK (logo_bg_color IS NULL OR logo_bg_color IN
    ('red','orange','yellow','green','blue','indigo','violet','pink'));
