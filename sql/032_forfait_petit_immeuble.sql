-- ============================================================
-- 032 — Forfaits au lancement : « Petit immeuble » (12 logements) + multi-site
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central, après 028.
-- Idempotent : peut être rejoué.
--
-- Pour débuter, CoHabitat ne vise que les petits immeubles de
-- 12 logements et moins. La page de vente de CoHabitat et
-- modulimo.com/cohabitat lisent la table plans en direct : y restent
-- affichés « Petit immeuble » et le forfait multi-site des locataires.
--
-- Rien n'est supprimé : « Immeuble » (owner_immeuble) et « Réseau
-- d'immeubles » (owner_reseau) sont seulement désactivés, avec leurs
-- fonctions, et se réactivent dans l'onglet Forfaits le moment venu.
-- Prix : 43 $ / mois, celui saisi en production.
--
-- Locataires : l'application est gratuite dans leur immeuble. Ils ne
-- paient un forfait que pour le multi-site (réserver dans d'autres
-- immeubles) :
--   local   (« Résident Local », 9 $)    → désactivé, prix ramené à 0 :
--                                         un contrat existant n'est plus
--                                         facturé.
--   network (« Résident Réseau », 19 $)  → reste affiché, renommé
--                                         « Locataire multi-site ».
-- ============================================================

BEGIN;

-- 0. Codes alignés sur ceux qu'écrit l'admin (repris de 028) --------
-- Les contrats portent plan = 'owner', 'local' ou 'network' et la
-- facture cherche le prix du forfait par ce code. Sans effet si les
-- codes sont déjà les bons.
UPDATE plans SET code = 'owner'
 WHERE code = 'proprietaire' AND NOT EXISTS (SELECT 1 FROM plans WHERE code = 'owner');
UPDATE plans SET code = 'local'
 WHERE code = 'resident_local' AND NOT EXISTS (SELECT 1 FROM plans WHERE code = 'local');
UPDATE plans SET code = 'network'
 WHERE code = 'resident_network' AND NOT EXISTS (SELECT 1 FROM plans WHERE code = 'network');

-- 1. Propriétaire : « Petit immeuble » seulement --------------------
UPDATE plans
   SET name          = 'Petit immeuble',
       price_monthly = 43,
       max_units     = 12,
       sort_order    = 1,
       featured      = TRUE,
       active        = TRUE
 WHERE code IN ('proprietaire', 'owner');

UPDATE plans
   SET active = FALSE, featured = FALSE
 WHERE code IN ('owner_immeuble', 'owner_reseau');

-- 2. Locataires : ne paient que le multi-site -----------------------
UPDATE plans
   SET active = FALSE, featured = FALSE, price_monthly = 0
 WHERE code IN ('resident_local', 'local');

UPDATE plans
   SET name       = 'Locataire multi-site',
       sort_order = 2,
       featured   = FALSE,
       active     = TRUE
 WHERE code IN ('resident_network', 'network');

COMMIT;

-- Vérification : ce que la page de vente affichera (deux lignes).
SELECT code, name, price_monthly, max_units, featured, sort_order
  FROM plans WHERE active ORDER BY sort_order;
