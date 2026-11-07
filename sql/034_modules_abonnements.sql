-- ============================================================
-- 034 — Catalogue des modules et abonnements par module
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central, après 033.
-- Idempotent : peut être rejoué ; le catalogue est remis aux prix
-- ci-dessous, les abonnements existants ne sont pas touchés.
--
-- Le forfait n'est plus un montant unique : chaque module a son prix,
-- par chambre et par mois. Tous les modules pour 12 chambres font
-- 43,20 $, le « 43 $ » affiché sur la page de vente.
--
--   module      payé par      encaissé par  calcul       prix
--   base        propriétaire  Modulimo      par chambre  1,00 $  (inclus d'office)
--   mobilite    propriétaire  Modulimo      par chambre  1,00 $
--   energie     propriétaire  Modulimo      par chambre  0,60 $
--   serre       propriétaire  Modulimo      par chambre  0,50 $
--   lunch       propriétaire  Modulimo      par chambre  0,50 $
--   multisite   locataire     Modulimo      forfait     19,00 $
--
-- Le locataire a les modules que le propriétaire a activés pour
-- l'immeuble et paie à l'usage (réservations, kilomètres, repas) ; le
-- multi-site est le seul module qu'il paie lui-même, à Modulimo.
--
-- PAIEMENT ÉLECTRONIQUE : prévu, pas branché. Les colonnes
-- fournisseur_* restent vides et fournisseur = 'manuel' : la facture
-- mensuelle de l'admin fait une ligne par module. Quand un fournisseur
-- (Stripe) sera branché, chaque module recevra son identifiant de prix
-- et chaque abonnement l'identifiant de sa ligne d'abonnement ; le
-- retour du fournisseur (webhook) n'aura qu'à écrire dans
-- abonnements_modules : la licence suit d'elle-même (déclencheur
-- ci-dessous). Aucun compte n'est ouvert ici, donc aucun frais.
-- ============================================================

BEGIN;

-- 1. Catalogue ------------------------------------------------------

CREATE TABLE IF NOT EXISTS modules (
  code                    TEXT PRIMARY KEY,
  nom                     TEXT NOT NULL,
  description             TEXT,
  payeur                  TEXT NOT NULL CHECK (payeur IN ('proprietaire', 'locataire')),
  encaisse_par            TEXT NOT NULL CHECK (encaisse_par IN ('modulimo', 'immeuble')),
  calcul                  TEXT NOT NULL CHECK (calcul IN ('par_chambre', 'forfait')),
  prix_mensuel            NUMERIC(10,2) NOT NULL CHECK (prix_mensuel >= 0),
  obligatoire             BOOLEAN NOT NULL DEFAULT FALSE,
  -- Interrupteur de licences.modules que ce module ouvre (lu par
  -- CoHabitat) ; NULL pour un module sans interrupteur.
  cle_licence             TEXT,
  sort_order              INT NOT NULL DEFAULT 1,
  active                  BOOLEAN NOT NULL DEFAULT TRUE,
  -- Paiement électronique (vides tant que rien n'est branché)
  fournisseur_produit_id  TEXT,
  fournisseur_prix_id     TEXT,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO modules (code, nom, description, payeur, encaisse_par, calcul, prix_mensuel, obligatoire, cle_licence, sort_order)
VALUES
  ('base',      'Base',                  'Espaces communs, babillard, billets de service, gestion des locataires, solde virtuel, conformité Loi 25, support par courriel',
                'proprietaire', 'modulimo', 'par_chambre',  1.00, TRUE,  NULL,      1),
  ('mobilite',  'Mobilité partagée',     'Véhicules, vélomobiles, covoiturage',
                'proprietaire', 'modulimo', 'par_chambre',  1.00, FALSE, 'trips',   2),
  ('energie',   'Énergie et confort',    'État de l''immeuble, eau chaude, alertes',
                'proprietaire', 'modulimo', 'par_chambre',  0.60, FALSE, 'energie', 3),
  ('serre',     'Serre',                 'Zones de culture louables au mois',
                'proprietaire', 'modulimo', 'par_chambre',  0.50, FALSE, 'serre',   4),
  ('lunch',     'Machine Lunch',         'Kiosque et commandes',
                'proprietaire', 'modulimo', 'par_chambre',  0.50, FALSE, 'lunch',   5),
  ('multisite', 'Multi-site',            'Réserver dans les autres immeubles du réseau',
                'locataire',    'modulimo', 'forfait',     19.00, FALSE, NULL,      6)
ON CONFLICT (code) DO UPDATE
   SET nom          = EXCLUDED.nom,
       description  = EXCLUDED.description,
       payeur       = EXCLUDED.payeur,
       encaisse_par = EXCLUDED.encaisse_par,
       calcul       = EXCLUDED.calcul,
       prix_mensuel = EXCLUDED.prix_mensuel,
       obligatoire  = EXCLUDED.obligatoire,
       cle_licence  = EXCLUDED.cle_licence,
       sort_order   = EXCLUDED.sort_order,
       updated_at   = NOW();

-- 2. Abonnements ----------------------------------------------------
-- Une ligne par client et par module. quantite = nombre de chambres
-- (par_chambre) ou 1 (forfait). prix_unitaire est figé à la
-- souscription : changer le catalogue ne change pas un abonnement en
-- cours.

CREATE TABLE IF NOT EXISTS abonnements_modules (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id                   UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  contract_id                 UUID REFERENCES contracts(id) ON DELETE SET NULL,
  module_code                 TEXT NOT NULL REFERENCES modules(code),
  quantite                    INT NOT NULL DEFAULT 1 CHECK (quantite > 0),
  prix_unitaire               NUMERIC(10,2) NOT NULL CHECK (prix_unitaire >= 0),
  statut                      TEXT NOT NULL DEFAULT 'actif'
                              CHECK (statut IN ('actif', 'suspendu', 'termine')),
  debut                       DATE NOT NULL DEFAULT CURRENT_DATE,
  fin                         DATE,
  -- Paiement électronique (vides tant que fournisseur = 'manuel')
  fournisseur                 TEXT NOT NULL DEFAULT 'manuel',
  fournisseur_client_id       TEXT,
  fournisseur_abonnement_id   TEXT,
  fournisseur_ligne_id        TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Un seul abonnement en cours par client et par module.
CREATE UNIQUE INDEX IF NOT EXISTS abonnements_modules_un_en_cours
  ON abonnements_modules (client_id, module_code) WHERE statut <> 'termine';
CREATE INDEX IF NOT EXISTS idx_abonnements_modules_client ON abonnements_modules (client_id);

-- 3. La licence suit les abonnements --------------------------------
-- licences.modules (lu par CoHabitat) est recalculé à chaque
-- changement d'abonnement du client : un module ouvert si son
-- abonnement est actif, fermé sinon. Les licences d'un client sans
-- aucun abonnement ne sont jamais touchées.

CREATE OR REPLACE FUNCTION sync_licence_modules() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client UUID := COALESCE(NEW.client_id, OLD.client_id);
  v_mods   JSONB;
BEGIN
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

DROP TRIGGER IF EXISTS trg_sync_licence_modules ON abonnements_modules;
CREATE TRIGGER trg_sync_licence_modules
  AFTER INSERT OR UPDATE OR DELETE ON abonnements_modules
  FOR EACH ROW EXECUTE FUNCTION sync_licence_modules();

-- 4. Facture : une ligne par module ---------------------------------

ALTER TABLE invoice_line_items DROP CONSTRAINT IF EXISTS invoice_line_items_category_check;
ALTER TABLE invoice_line_items ADD CONSTRAINT invoice_line_items_category_check
  CHECK (category IN ('monthly_fee','module','space_reservation','trip','trip_charge','lunch','other'));

-- 5. Accès ----------------------------------------------------------
-- Le catalogue est public (page de vente, futur achat en ligne) ; les
-- abonnements ne se lisent et ne s'écrivent que connecté (admin).

ALTER TABLE modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE abonnements_modules ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON modules FROM anon;
GRANT SELECT ON modules TO anon;
DROP POLICY IF EXISTS modules_lecture_publique ON modules;
CREATE POLICY modules_lecture_publique ON modules FOR SELECT TO anon USING (active);
DROP POLICY IF EXISTS modules_admin_all ON modules;
CREATE POLICY modules_admin_all ON modules FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);

REVOKE ALL ON abonnements_modules FROM anon;
DROP POLICY IF EXISTS abonnements_modules_admin_all ON abonnements_modules;
CREATE POLICY abonnements_modules_admin_all ON abonnements_modules FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE);

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Vérification : le catalogue et le total pour 12 chambres.
SELECT code, nom, payeur, calcul, prix_mensuel,
       CASE WHEN calcul = 'par_chambre' THEN prix_mensuel * 12 END AS pour_12_chambres
  FROM modules ORDER BY sort_order;
