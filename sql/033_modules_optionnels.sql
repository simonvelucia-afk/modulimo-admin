-- ============================================================
-- 033 — Modules optionnels, pour le propriétaire et le locataire
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central, après 032.
-- Idempotent : chaque passage remet les fonctions affichées dans
-- l'état ci-dessous.
--
-- Aucun module n'est imposé : le propriétaire active ceux qu'il veut
-- pour son immeuble, et chaque locataire n'utilise que ceux qui lui
-- servent. La liste affichée sous chaque forfait le dit en premier,
-- puis sépare les modules au choix de ce qui est toujours inclus.
-- Les prix ne changent pas.
-- ============================================================

BEGIN;

-- « Petit immeuble » (propriétaire)
DELETE FROM plan_features
 WHERE plan_id IN (SELECT id FROM plans WHERE code IN ('owner', 'proprietaire'));

INSERT INTO plan_features (plan_id, label, included, sort_order)
SELECT p.id, f.label, TRUE, f.ordre
  FROM plans p
 CROSS JOIN (VALUES
   (1,  'Modules au choix, activables un à un : pour l''immeuble comme pour chaque locataire'),
   (2,  'Module Réservation d''espaces communs'),
   (3,  'Module Mobilité partagée : auto-partage, vélomobiles, covoiturage'),
   (4,  'Module Serre et poulailler'),
   (5,  'Module Babillard, billets de service et Lab d''idées'),
   (6,  'Module Machine Lunch (kiosque)'),
   (7,  'Toujours inclus : gestion des locataires'),
   (8,  'Toujours inclus : solde virtuel et transactions'),
   (9,  'Toujours inclus : conformité Loi 25'),
   (10, 'Toujours inclus : support par courriel')
 ) AS f(ordre, label)
 WHERE p.code IN ('owner', 'proprietaire');

-- « Locataire multi-site »
DELETE FROM plan_features
 WHERE plan_id IN (SELECT id FROM plans WHERE code IN ('network', 'resident_network'));

INSERT INTO plan_features (plan_id, label, included, sort_order)
SELECT p.id, f.label, TRUE, f.ordre
  FROM plans p
 CROSS JOIN (VALUES
   (1, 'Gratuit dans votre propre immeuble : ce forfait ne sert qu''au multi-site'),
   (2, 'Réservations dans les autres immeubles du réseau'),
   (3, 'Modules au choix : vous n''utilisez que ceux qui vous servent')
 ) AS f(ordre, label)
 WHERE p.code IN ('network', 'resident_network');

COMMIT;

-- Vérification : forfaits affichés et leurs fonctions.
SELECT p.name, f.sort_order, f.label
  FROM plans p JOIN plan_features f ON f.plan_id = p.id
 WHERE p.active
 ORDER BY p.sort_order, f.sort_order;
