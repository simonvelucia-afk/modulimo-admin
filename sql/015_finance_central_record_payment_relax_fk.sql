-- =====================================================================
-- 015_finance_central_record_payment_relax_fk.sql
-- Relaxe le FK real_payments.recorded_by -> auth.users(id) pour permettre
-- a la fois :
--   * l'admin modulimo-admin (auth.uid central) — comportement existant
--   * l'admin de l'immeuble depuis CoHabitat (auth.uid cote building)
-- L'identifiant reste un uuid : on garde la colonne en NOT NULL pour
-- audit, mais on perd l'integrite referentielle puisqu'il vit dans deux
-- bases distinctes. C'est acceptable pour un champ purement informatif —
-- l'autorisation effective vient de finance-bridge (verification admin
-- via le JWT cohabitat dans le handler /record-real-payment).
-- =====================================================================

BEGIN;

ALTER TABLE real_payments DROP CONSTRAINT IF EXISTS real_payments_recorded_by_fkey;

COMMENT ON COLUMN real_payments.recorded_by IS
  'auth.uid de l''utilisateur ayant enregistre le paiement. Peut etre un
  auth.users(id) central (admin modulimo-admin) ou un auth.users(id) du
  Supabase de l''immeuble (admin CoHabitat passant via finance-bridge).
  Pas de FK : l''integrite est garantie applicativement.';

COMMIT;

NOTIFY pgrst, 'reload schema';
