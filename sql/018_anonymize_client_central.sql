-- 018_anonymize_client_central.sql
-- Conformite Loi 25 (Quebec) : anonymise les donnees personnelles
-- centrales d'un client tout en preservant les donnees analytiques
-- (transactions, factures, contrats avec montants/dates) pour les
-- statistiques, l'audit comptable et les obligations legales de
-- conservation comptable (6 ans Quebec).
--
-- Strategie :
--   * Champs PII directs => NULL ou identifiant generique stable
--     (ex: name = 'Resident anonyme #' || prefixe_id pour conserver
--     l'unicite dans les jointures admin sans reveler la personne).
--   * Champs analytiques => intacts (montants, dates, types).
--   * Cohabitat_user_id => NULL apres anonymisation (le resident a
--     deja ete anonymise cote CoHabitat, le lien n'a plus de sens).
--   * Idempotente : si deja anonymise (anonymized_at NOT NULL),
--     l'appel est un no-op (retourne le ts existant).
--
-- Tables affectees :
--   * clients (PII : name, contact_*, cohabitat_email, address,
--             notes, admin_building, cohabitat_user_id)
--   * contracts (signed_by_name uniquement, le reste est analytique)
--
-- Securite :
--   * SECURITY DEFINER + service_role only.
--   * Orchestration via Edge Function (phase D) qui valide le caller.

BEGIN;

-- 1. Ajout des colonnes d'audit anonymisation
ALTER TABLE clients
  ADD COLUMN IF NOT EXISTS anonymized_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS anonymized_by UUID;

CREATE INDEX IF NOT EXISTS idx_clients_anonymized
  ON clients(anonymized_at) WHERE anonymized_at IS NOT NULL;

COMMENT ON COLUMN clients.anonymized_at IS
  'Timestamp Loi 25 : date a laquelle les PII de ce client ont ete
  anonymisees. Permet de filtrer les vues admin (ne pas tenter de
  re-contacter un client anonymise) et fournir un audit trail.';

-- 2. La RPC d'anonymisation
CREATE OR REPLACE FUNCTION anonymize_client_central(
  p_client_id  UUID,
  p_admin_id   UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_existing_anon TIMESTAMPTZ;
  v_short_id      TEXT;
  v_anon_label    TEXT;
  v_contracts_count INT;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id requis' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotence : si deja anonymise, on retourne juste le timestamp.
  SELECT anonymized_at INTO v_existing_anon
    FROM clients WHERE id = p_client_id;

  IF v_existing_anon IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_anonymized', true,
      'anonymized_at', v_existing_anon
    );
  END IF;

  -- Identifiant generique stable pour les jointures et l'UI admin :
  -- 'Resident anonyme #abcd1234' (prefixe court de l'UUID).
  v_short_id   := substring(p_client_id::text from 1 for 8);
  v_anon_label := 'Resident anonyme #' || v_short_id;

  -- 3. Anonymise la row clients
  UPDATE clients SET
    name              = v_anon_label,
    contact_name      = NULL,
    contact_email     = NULL,
    cohabitat_email   = NULL,
    cohabitat_user_id = NULL,
    address           = NULL,
    city              = NULL,        -- granularite trop fine pour stats
    notes             = NULL,
    admin_building    = NULL,
    anonymized_at     = now(),
    anonymized_by     = p_admin_id,
    updated_at        = now()
  WHERE id = p_client_id;

  -- 4. Anonymise les noms de signataires sur les contrats. Les autres
  --    colonnes (plan, dates, montants, status) sont analytiques et
  --    restent intactes.
  UPDATE contracts SET
    signed_by_name = CASE
      WHEN signed_by_name IS NOT NULL THEN v_anon_label
      ELSE NULL
    END,
    updated_at = COALESCE(updated_at, now())
  WHERE client_id = p_client_id OR owner_client_id = p_client_id;
  GET DIAGNOSTICS v_contracts_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'already_anonymized', false,
    'anonymized_at', now(),
    'anonymized_by', p_admin_id,
    'anon_label', v_anon_label,
    'contracts_updated', v_contracts_count
  );
END;
$fn$;

REVOKE ALL ON FUNCTION anonymize_client_central(UUID, UUID)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION anonymize_client_central(UUID, UUID) TO service_role;

COMMENT ON FUNCTION anonymize_client_central(UUID, UUID) IS
  'Loi 25 / RGPD : anonymise les donnees personnelles centrales d''un
  client (PII -> NULL ou label generique stable) tout en preservant
  les donnees analytiques (transactions, factures, contrats avec
  montants/dates). Idempotente : un 2eme appel est un no-op.
  Service_role only — orchestre par une Edge Function qui valide le
  caller (admin Modulimo).';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ROLLBACK :
--   DROP FUNCTION IF EXISTS anonymize_client_central(UUID, UUID);
--   ALTER TABLE clients DROP COLUMN IF EXISTS anonymized_at;
--   ALTER TABLE clients DROP COLUMN IF EXISTS anonymized_by;
