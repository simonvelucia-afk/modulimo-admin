-- 005_lunch_machines_settings.sql
-- A deployer sur modulimo-central (bpxscgrbxjscicpnheep).
--
-- Contexte : certains reglages de la machine (nombre de boites, couleurs de
-- temperature, vitesse auto du robot) vivaient en localStorage cote kiosque,
-- donc se perdaient d'un appareil/navigateur a l'autre. Cette migration les
-- persiste sur la ligne lunch_machines pour que le meme kiosque ait les
-- memes reglages partout.

ALTER TABLE lunch_machines
  ADD COLUMN IF NOT EXISTS box_max          INT    NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS box_count        INT    NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS gantry_auto_speed INT   NOT NULL DEFAULT 5
    CHECK (gantry_auto_speed BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS color_ranges     JSONB  NOT NULL DEFAULT
    '{"blue":{"min":-10,"max":10},"violet":{"min":11,"max":25},"orange":{"min":26,"max":55},"red":{"min":56,"max":100}}'::jsonb;

-- Autoriser l'UPDATE depuis le kiosque (cle anon) sur les colonnes de
-- reglage uniquement. Si tu veux un controle plus fin, remplace par une
-- policy WITH CHECK plus restrictive et/ou deplace ces ecritures dans une
-- RPC. Pour l'instant les autres colonnes (id, pin, active, ...) ne sont
-- pas modifiees par le kiosque.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_machines' AND policyname='lunch_machines_update_anon') THEN
    CREATE POLICY lunch_machines_update_anon ON lunch_machines
      FOR UPDATE TO anon USING (TRUE) WITH CHECK (TRUE);
  END IF;
END $$;
