-- ============================================================
-- 028 — Forfaits payés par le propriétaire
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central. Idempotent : peut
-- être rejoué ; chaque passage remet les forfaits dans l'état ci-dessous.
--
-- Le forfait est payé par le propriétaire de l'immeuble ; les locataires
-- n'ont pas d'abonnement et ne paient que ce qu'ils réservent. La page de
-- vente de CoHabitat et modulimo.com/cohabitat lisent cette table en
-- direct : elles affichent les forfaits actifs, dans l'ordre sort_order.
--
-- Les codes 'owner', 'local' et 'network' sont utilisés par les contrats
-- et la facturation : ils ne sont ni renommés ni supprimés.
--   owner           → reste le forfait des contrats propriétaire ;
--                     devient « Petit immeuble ».
--   owner_immeuble  → nouveau, affiché sur la page de vente. Un contrat
--   owner_reseau      propriétaire garde plan = 'owner' : pour un
--                     immeuble plus grand, saisir le montant convenu dans
--                     « monthly_amount » du contrat, qui prime sur le prix
--                     du forfait à la facturation.
--   local, network  → désactivés : retirés de la page de vente. Les
--                     contrats résidents existants ne changent pas
--                     (voir l'étape facultative en fin de fichier).
--
-- PRIX : propositions à valider. Modifier les montants ci-dessous avant
-- d'exécuter ; tout se règle ensuite aussi dans l'onglet Forfaits.
-- ============================================================

BEGIN;

-- 1. Les trois forfaits propriétaire --------------------------------

-- « Petit immeuble » : le forfait historique 'owner', mis à jour.
UPDATE plans
   SET name          = 'Petit immeuble',
       price_monthly = 49,
       max_units     = 20,
       sort_order    = 1,
       featured      = FALSE,
       active        = TRUE
 WHERE code = 'owner';

-- « Immeuble » et « Réseau d'immeubles » : créés s'ils n'existent pas,
-- avec les mêmes modules que le forfait propriétaire.
INSERT INTO plans (code, name, price_monthly, max_units, sort_order, featured, active, modules)
SELECT v.code, v.name, v.price, v.units, v.ordre, v.vedette, TRUE,
       COALESCE((SELECT modules FROM plans WHERE code = 'owner'), '{}'::jsonb)
  FROM (VALUES
         ('owner_immeuble', 'Immeuble',            149::numeric, 100, 2, TRUE),
         ('owner_reseau',   'Réseau d''immeubles', NULL::numeric, NULL::int, 3, FALSE)
       ) AS v(code, name, price, units, ordre, vedette)
ON CONFLICT (code) DO UPDATE
   SET name          = EXCLUDED.name,
       price_monthly = EXCLUDED.price_monthly,
       max_units     = EXCLUDED.max_units,
       sort_order    = EXCLUDED.sort_order,
       featured      = EXCLUDED.featured,
       active        = TRUE;

-- 2. Fonctions affichées sous chaque forfait ------------------------

DELETE FROM plan_features
 WHERE plan_id IN (SELECT id FROM plans WHERE code IN ('owner', 'owner_immeuble', 'owner_reseau'));

INSERT INTO plan_features (plan_id, label, included, sort_order)
SELECT p.id, f.label, TRUE, f.ordre
  FROM plans p
 CROSS JOIN (VALUES
   (1, 'Accès illimité pour les locataires, sans abonnement'),
   (2, 'Réservation d''espaces communs'),
   (3, 'Mobilité partagée : véhicules, vélomobiles, covoiturage'),
   (4, 'Serre et poulailler'),
   (5, 'Babillard, billets de service et Lab d''idées'),
   (6, 'Machine Lunch (kiosque)'),
   (7, 'Solde virtuel et transactions'),
   (8, 'Conformité Loi 25'),
   (9, 'Support par courriel')
 ) AS f(ordre, label)
 WHERE p.code IN ('owner', 'owner_immeuble', 'owner_reseau');

-- Le forfait réseau ajoute ce qui le distingue.
INSERT INTO plan_features (plan_id, label, included, sort_order)
SELECT id, f.label, TRUE, f.ordre
  FROM plans
 CROSS JOIN (VALUES
   (10, 'Plusieurs immeubles, réservations croisées'),
   (11, 'Hébergé ou autonome (réseau fermé)'),
   (12, 'Accompagnement au démarrage')
 ) AS f(ordre, label)
 WHERE code = 'owner_reseau';

-- 3. Forfaits résidents : retirés de la page de vente ---------------

UPDATE plans SET active = FALSE, featured = FALSE
 WHERE code IN ('local', 'network');

COMMIT;

-- Vérification : ce que la page de vente affichera.
SELECT code, name, price_monthly, max_units, featured, sort_order
  FROM plans WHERE active ORDER BY sort_order;

-- ------------------------------------------------------------
-- Étape facultative, NON exécutée : supprimer aussi le frais mensuel
-- des contrats résidents existants (les locataires ne paieraient plus
-- que leurs réservations). La facture d'un contrat prend le prix du
-- forfait quand le contrat n'a pas de montant propre. À décider avant
-- de décommenter :
--
-- UPDATE plans SET price_monthly = 0 WHERE code IN ('local', 'network');
-- ------------------------------------------------------------
