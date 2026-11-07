-- ============================================================
-- 033 — Modules optionnels, pour le propriétaire et le locataire
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central, après 032.
-- Idempotent : chaque passage remet les fonctions affichées dans
-- l'état ci-dessous.
--
-- Le propriétaire paie la base et les modules qu'il active, chacun à
-- son prix par chambre et par mois (catalogue : 034). Ses locataires
-- ont les modules activés et paient à l'usage. Le multi-site est le
-- seul module payé par le locataire, et il est facturé par Modulimo.
-- Les prix affichés ici reprennent ceux du catalogue de 034.
-- ============================================================

BEGIN;

-- « Petit immeuble » (propriétaire)
DELETE FROM plan_features
 WHERE plan_id IN (SELECT id FROM plans WHERE code IN ('owner', 'proprietaire'));

INSERT INTO plan_features (plan_id, label, included, sort_order)
SELECT p.id, f.label, TRUE, f.ordre
  FROM plans p
 CROSS JOIN (VALUES
   (1, 'Prix par chambre et par mois, module par module : 43 $ pour 12 chambres avec tous les modules'),
   (2, 'Base incluse (1,00 $) : espaces communs, babillard, gestion des locataires, solde virtuel, Loi 25, support'),
   (3, 'Mobilité partagée, en option (1,00 $) : véhicules, vélomobiles, covoiturage'),
   (4, 'Énergie et confort, en option (0,60 $) : état de l''immeuble, eau chaude, alertes'),
   (5, 'Serre, en option (0,50 $) : zones de culture louables au mois'),
   (6, 'Machine Lunch, en option (0,50 $) : kiosque et commandes'),
   (7, 'Vos locataires ont les modules activés et paient à l''usage')
 ) AS f(ordre, label)
 WHERE p.code IN ('owner', 'proprietaire');

-- « Locataire multi-site »
UPDATE plans SET name = 'Multi-site (locataire)' WHERE code IN ('network', 'resident_network');

DELETE FROM plan_features
 WHERE plan_id IN (SELECT id FROM plans WHERE code IN ('network', 'resident_network'));

INSERT INTO plan_features (plan_id, label, included, sort_order)
SELECT p.id, f.label, TRUE, f.ordre
  FROM plans p
 CROSS JOIN (VALUES
   (1, 'Réservations dans les autres immeubles du réseau'),
   (2, 'Facturé au locataire par Modulimo, pas par l''immeuble'),
   (3, 'Dans son immeuble, le locataire ne paie que ce qu''il utilise')
 ) AS f(ordre, label)
 WHERE p.code IN ('network', 'resident_network');

COMMIT;

-- Vérification : forfaits affichés et leurs fonctions.
SELECT p.name, f.sort_order, f.label
  FROM plans p JOIN plan_features f ON f.plan_id = p.id
 WHERE p.active
 ORDER BY p.sort_order, f.sort_order;
