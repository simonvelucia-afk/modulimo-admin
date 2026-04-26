-- 020_anonymize_client_central_with_certificate.sql
-- Phase G Loi 25 : refonte de anonymize_client_central pour :
--   1. Pre-check : refuse si bail actif (contrats status='active')
--   2. Capture les PII (nom, unite/logement, building) AVANT effacement
--   3. INSERT dans anonymization_certificates (preuve probante)
--   4. Hash SHA-256 du certificat
--   5. Retourne le certificate_id et les details du certif
--
-- Idempotence preservee : si deja anonymise, retourne le certificat
-- existant (ou NULL si la version ancienne avait anonymise sans certif).

BEGIN;

CREATE OR REPLACE FUNCTION anonymize_client_central(
  p_client_id UUID,
  p_admin_id  UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_existing_anon TIMESTAMPTZ;
  v_existing_cert_id UUID;
  v_short_id      TEXT;
  v_anon_label    TEXT;
  v_contracts_count INT;

  -- Snapshot PII pre-effacement
  v_subject_name  TEXT;
  v_subject_unit  TEXT;
  v_building_name TEXT;

  -- Audit admin
  v_admin_email   TEXT;

  -- Pre-check bail
  v_active_contract_count INT;

  -- Hash + certificat
  v_anon_at       TIMESTAMPTZ;
  v_hash          TEXT;
  v_cert_id       UUID;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id requis' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- 1. Idempotence : si deja anonymise, retourne le certificat existant.
  SELECT anonymized_at INTO v_existing_anon FROM clients WHERE id = p_client_id;
  IF v_existing_anon IS NOT NULL THEN
    SELECT id INTO v_existing_cert_id
      FROM anonymization_certificates
     WHERE client_id = p_client_id
     ORDER BY anonymized_at DESC
     LIMIT 1;
    RETURN jsonb_build_object(
      'ok', true,
      'already_anonymized', true,
      'anonymized_at', v_existing_anon,
      'certificate_id', v_existing_cert_id
    );
  END IF;

  -- 2. Pre-check : refuse si bail actif. Loi 25 + pratique :
  -- l'anonymisation doit etre coherente avec la fin du bail. Un
  -- contrat actif signifie que les donnees sont encore utiles a la
  -- finalite operationnelle. L'admin doit attendre la fin de bail
  -- (ou utiliser un override SQL direct si vraiment necessaire).
  SELECT COUNT(*) INTO v_active_contract_count
    FROM contracts
   WHERE (client_id = p_client_id OR owner_client_id = p_client_id)
     AND status = 'active';

  IF v_active_contract_count > 0 THEN
    RAISE EXCEPTION 'Anonymisation refusee : % contrat(s) actif(s) sur ce client. Resilier le bail avant.', v_active_contract_count
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. Capture les PII (snapshot pre-effacement). On lit aussi le nom
  -- du building pour denormaliser dans le certificat (le building peut
  -- etre supprime du registry plus tard).
  SELECT c.name, c.admin_building, br.name
    INTO v_subject_name, v_subject_unit, v_building_name
    FROM clients c
    LEFT JOIN building_registry br ON br.id = c.building_id
   WHERE c.id = p_client_id;

  -- 4. Resoudre l'email admin pour audit denormalise.
  IF p_admin_id IS NOT NULL THEN
    SELECT email INTO v_admin_email FROM auth.users WHERE id = p_admin_id;
  END IF;

  -- 5. Calcul du hash + INSERT du certificat dans la meme transaction.
  v_anon_at := now();
  v_hash := compute_anon_certificate_hash(
    v_subject_name, v_subject_unit, v_building_name, v_anon_at, v_admin_email
  );

  INSERT INTO anonymization_certificates (
    client_id, subject_name, subject_unit, building_name,
    anonymized_at, anonymized_by, admin_email, content_sha256
  ) VALUES (
    p_client_id, v_subject_name, v_subject_unit, v_building_name,
    v_anon_at, p_admin_id, v_admin_email, v_hash
  ) RETURNING id INTO v_cert_id;

  -- 6. Anonymise effectivement la row clients.
  v_short_id   := substring(p_client_id::text from 1 for 8);
  v_anon_label := 'Resident anonyme #' || v_short_id;

  UPDATE clients SET
    name              = v_anon_label,
    contact_name      = NULL,
    contact_email     = NULL,
    cohabitat_email   = NULL,
    cohabitat_user_id = NULL,
    address           = NULL,
    city              = NULL,
    notes             = NULL,
    admin_building    = NULL,
    anonymized_at     = v_anon_at,
    anonymized_by     = p_admin_id,
    updated_at        = v_anon_at
  WHERE id = p_client_id;

  -- 7. Anonymise les noms de signataires sur les contrats (analytics
  -- preservees : plan, dates, montants, status).
  UPDATE contracts SET
    signed_by_name = v_anon_label
  WHERE (client_id = p_client_id OR owner_client_id = p_client_id)
    AND signed_by_name IS NOT NULL;
  GET DIAGNOSTICS v_contracts_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',                  true,
    'already_anonymized',  false,
    'anonymized_at',       v_anon_at,
    'anonymized_by',       p_admin_id,
    'admin_email',         v_admin_email,
    'anon_label',          v_anon_label,
    'contracts_updated',   v_contracts_count,
    'certificate_id',      v_cert_id,
    'certificate', jsonb_build_object(
      'id',             v_cert_id,
      'subject_name',   v_subject_name,
      'subject_unit',   v_subject_unit,
      'building_name',  v_building_name,
      'anonymized_at',  v_anon_at,
      'admin_email',    v_admin_email,
      'content_sha256', v_hash,
      'retention_until', v_anon_at + interval '6 years'
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION anonymize_client_central(UUID, UUID)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION anonymize_client_central(UUID, UUID) TO service_role;


-- RPC pour re-telecharger un certificat existant (admin only).
CREATE OR REPLACE FUNCTION get_anonymization_certificate(p_client_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_cert RECORD;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id requis' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_cert
    FROM anonymization_certificates
   WHERE client_id = p_client_id
   ORDER BY anonymized_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NO_CERTIFICATE');
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'id',              v_cert.id,
    'client_id',       v_cert.client_id,
    'subject_name',    v_cert.subject_name,
    'subject_unit',    v_cert.subject_unit,
    'building_name',   v_cert.building_name,
    'anonymized_at',   v_cert.anonymized_at,
    'admin_email',     v_cert.admin_email,
    'content_sha256',  v_cert.content_sha256,
    'retention_until', v_cert.retention_until,
    'reason',          v_cert.reason
  );
END;
$fn$;

REVOKE ALL ON FUNCTION get_anonymization_certificate(UUID)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION get_anonymization_certificate(UUID) TO service_role;

COMMENT ON FUNCTION get_anonymization_certificate(UUID) IS
  'Loi 25 : retourne le certificat d''anonymisation existant pour un
  client. Appele par l''Edge Function loi25-process pour la re-impression
  du certificat (cas : admin a perdu l''onglet original).';

NOTIFY pgrst, 'reload schema';

COMMIT;
