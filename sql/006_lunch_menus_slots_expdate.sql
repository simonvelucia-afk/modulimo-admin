-- 006_lunch_menus_slots_expdate.sql
-- A deployer sur modulimo-central (bpxscgrbxjscicpnheep).
--
-- Contexte : un menu peut avoir une date d'expiration (ex : sandwich avec
-- DLC). Quand le menu est charge dans une case de la machine, la case
-- herite de cette date. La page Status du kiosque affiche le nombre de
-- jours restants et encadre la case en rouge si la date est depassee.

ALTER TABLE lunch_menus
  ADD COLUMN IF NOT EXISTS exp_date DATE;

ALTER TABLE lunch_slots
  ADD COLUMN IF NOT EXISTS exp_date DATE;

-- Forcer PostgREST a relire le schema pour exposer immediatement la
-- nouvelle colonne via l'API REST.
NOTIFY pgrst, 'reload schema';
