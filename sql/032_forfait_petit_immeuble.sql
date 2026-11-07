-- ============================================================
-- 032 — Un seul forfait au lancement : « Petit immeuble », 12 logements
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central, après 028.
-- Idempotent : peut être rejoué.
--
-- Pour débuter, CoHabitat ne vise que les petits immeubles de
-- 12 logements et moins. La page de vente de CoHabitat et
-- modulimo.com/cohabitat lisent la table plans en direct : seul le
-- forfait « Petit immeuble » y reste affiché.
--
-- Rien n'est supprimé : « Immeuble » (owner_immeuble) et « Réseau
-- d'immeubles » (owner_reseau) sont seulement désactivés, avec leurs
-- fonctions, et se réactivent dans l'onglet Forfaits le moment venu.
-- Prix : 43 $ / mois, celui saisi en production.
-- ============================================================

BEGIN;

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

COMMIT;

-- Vérification : ce que la page de vente affichera (une seule ligne).
SELECT code, name, price_monthly, max_units, featured, sort_order
  FROM plans WHERE active ORDER BY sort_order;
