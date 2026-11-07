-- ============================================================
-- 036 — Parc des Machines Lunch louées par Modulimo
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central, après 034 et 035.
-- Idempotent : peut être rejoué ; le loyer déjà réglé n'est pas écrasé.
--
-- Modulimo loue ses Machines Lunch aux propriétaires. La centrale suit
-- son parc : chaque machine (numéro de série, modèle), l'immeuble où elle
-- est installée et son état. Tout le reste — cases, menus, ventes — vit
-- dans la base de l'immeuble (CoHabitat, migration 037), qui reconnaît la
-- machine à son numéro de série (CoHabitat, migration 038).
--
-- Loyer : module « Location Machine Lunch » du catalogue (034), au forfait
-- par machine, payé par le propriétaire et encaissé par Modulimo. Son prix
-- se modifie dans l'admin (page Parc Lunch). L'abonnement du propriétaire
-- suit le parc tout seul : quantité = nombre de ses machines en service ;
-- plus aucune en service, l'abonnement est terminé. La facture mensuelle
-- en fait une ligne (n machines × loyer).
-- ============================================================

BEGIN;

-- 1. Le module de location (loyer à régler dans l'admin) -------------

INSERT INTO modules (code, nom, description, payeur, encaisse_par, calcul, prix_mensuel, obligatoire, cle_licence, sort_order)
VALUES ('lunch_location', 'Location Machine Lunch', 'Loyer mensuel d''une Machine Lunch louée par Modulimo, par machine en service',
        'proprietaire', 'modulimo', 'forfait', 0, FALSE, NULL, 7)
ON CONFLICT (code) DO UPDATE
   SET nom          = EXCLUDED.nom,
       description  = EXCLUDED.description,
       payeur       = EXCLUDED.payeur,
       encaisse_par = EXCLUDED.encaisse_par,
       calcul       = EXCLUDED.calcul,
       cle_licence  = NULL,
       sort_order   = EXCLUDED.sort_order,
       updated_at   = NOW();
       -- prix_mensuel volontairement absent : le loyer réglé dans l'admin est gardé

-- 2. Le parc -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS parc_lunch (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero_serie  TEXT NOT NULL UNIQUE,
  modele        TEXT,
  client_id     UUID REFERENCES clients(id) ON DELETE SET NULL,   -- propriétaire de l'immeuble
  statut        TEXT NOT NULL DEFAULT 'en_stock'
                CHECK (statut IN ('en_stock', 'en_service', 'entretien', 'retiree')),
  installee_le  DATE,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- une machine en service est forcément installée chez quelqu'un
  CHECK (statut <> 'en_service' OR client_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_parc_lunch_client ON parc_lunch (client_id);

-- 3. L'abonnement du propriétaire suit le parc -------------------------

CREATE OR REPLACE FUNCTION sync_location_lunch(p_client UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_nb   INT;
  v_abo  abonnements_modules%ROWTYPE;
  v_prix NUMERIC(10,2);
BEGIN
  IF p_client IS NULL THEN RETURN; END IF;
  SELECT count(*) INTO v_nb FROM parc_lunch WHERE client_id = p_client AND statut = 'en_service';
  SELECT * INTO v_abo FROM abonnements_modules
   WHERE client_id = p_client AND module_code = 'lunch_location' AND statut <> 'termine'
   LIMIT 1;
  IF v_nb > 0 THEN
    IF v_abo.id IS NULL THEN
      SELECT prix_mensuel INTO v_prix FROM modules WHERE code = 'lunch_location';
      INSERT INTO abonnements_modules (client_id, module_code, quantite, prix_unitaire)
      VALUES (p_client, 'lunch_location', v_nb, COALESCE(v_prix, 0));
    ELSIF v_abo.quantite <> v_nb OR v_abo.statut <> 'actif' THEN
      UPDATE abonnements_modules SET quantite = v_nb, statut = 'actif', updated_at = NOW() WHERE id = v_abo.id;
    END IF;
  ELSIF v_abo.id IS NOT NULL THEN
    UPDATE abonnements_modules SET statut = 'termine', fin = CURRENT_DATE, updated_at = NOW() WHERE id = v_abo.id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION trg_parc_lunch_sync() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- ancien immeuble (modification, suppression), puis nouveau s'il a changé
  IF TG_OP <> 'INSERT' THEN PERFORM sync_location_lunch(OLD.client_id); END IF;
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.client_id IS DISTINCT FROM OLD.client_id) THEN
    PERFORM sync_location_lunch(NEW.client_id);
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_parc_lunch_sync ON parc_lunch;
CREATE TRIGGER trg_parc_lunch_sync
  AFTER INSERT OR UPDATE OR DELETE ON parc_lunch
  FOR EACH ROW EXECUTE FUNCTION trg_parc_lunch_sync();

-- 4. Une location ne touche pas aux modules de la licence ---------------
-- sync_licence_modules (034) recalcule toute la licence à chaque changement
-- d'abonnement : un propriétaire qui ne ferait que louer une machine
-- verrait ses modules fermés. La location n'ouvre ni ne ferme aucun module.

CREATE OR REPLACE FUNCTION sync_licence_modules() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client UUID := COALESCE(NEW.client_id, OLD.client_id);
  v_mods   JSONB;
BEGIN
  IF COALESCE(NEW.module_code, OLD.module_code) = 'lunch_location' THEN RETURN NULL; END IF;
  SELECT COALESCE(jsonb_object_agg(m.cle_licence, EXISTS (
           SELECT 1 FROM abonnements_modules a
            WHERE a.client_id = v_client AND a.module_code = m.code AND a.statut = 'actif')), '{}'::jsonb)
    INTO v_mods
    FROM modules m
   WHERE m.cle_licence IS NOT NULL;

  UPDATE licences
     SET modules = COALESCE(modules, '{}'::jsonb) || v_mods,
         updated_at = NOW()
   WHERE client_id = v_client;
  RETURN NULL;
END $$;

-- 5. Accès : réservé à l'administration ---------------------------------

ALTER TABLE parc_lunch ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON parc_lunch FROM anon;
DROP POLICY IF EXISTS parc_lunch_admin_all ON parc_lunch;
CREATE POLICY parc_lunch_admin_all ON parc_lunch FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);
REVOKE ALL ON FUNCTION sync_location_lunch(UUID) FROM PUBLIC, anon;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Vérification : le module de location (loyer à régler dans l'admin).
SELECT code, nom, calcul, prix_mensuel FROM modules WHERE code = 'lunch_location';
