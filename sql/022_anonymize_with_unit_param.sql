-- 022_anonymize_with_unit_param.sql
-- Suite de la phase G : permet a l'admin de fournir explicitement le
-- numero d'unite/logement au moment de l'anonymisation. Necessaire car
-- pour les clients de type 'local'/'network' (locataires), l'unite
-- vit dans profiles.unit cote CoHabitat (pas accessible cote central).
-- L'admin saisit l'unite dans un prompt UI ; on la stocke dans le
-- certificat pour la preuve probante.

BEGIN;

-- DROP de l'ancienne signature pour pouvoir ajouter le 3eme param.
DROP FUNCTION IF EXISTS anonymize_client_central(UUID, UUID);

CREATE OR REPLACE FUNCTION anonymize_client_central(
  p_client_id    UUID,
  p_admin_id     UUID DEFAULT NULL,
  p_subject_unit TEXT DEFAULT NULL
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
  v_subject_name  TEXT;
  v_captured_unit TEXT;
  v_building_name TEXT;
  v_admin_email   TEXT;
  v_active_contract_count INT;
  v_anon_at       TIMESTAMPTZ;
  v_hash          TEXT;
  v_cert_id       UUID;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id requis' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotence
  SELECT anonymized_at INTO v_existing_anon FROM clients WHERE id = p_client_id;
  IF v_existing_anon IS NOT NULL THEN
    SELECT id INTO v_existing_cert_id
      FROM anonymization_certificates
     WHERE client_id = p_client_id
     ORDER BY anonymized_at DESC LIMIT 1;
    RETURN jsonb_build_object(
      'ok', true, 'already_anonymized', true,
      'anonymized_at', v_existing_anon,
      'certificate_id', v_existing_cert_id
    );
  END IF;

  -- Pre-check bail actif
  SELECT COUNT(*) INTO v_active_contract_count
    FROM contracts
   WHERE (client_id = p_client_id OR owner_client_id = p_client_id)
     AND status = 'active';

  IF v_active_contract_count > 0 THEN
    RAISE EXCEPTION 'Anonymisation refusee : % contrat(s) actif(s) sur ce client. Resilier le bail avant.', v_active_contract_count
      USING ERRCODE = 'check_violation';
  END IF;

  -- Capture PII. Pour subject_unit, on prefere :
  --   1. p_subject_unit (saisi par l'admin au prompt UI, le plus fiable)
  --   2. admin_building (rempli pour les owners-admins)
  -- Pas de fallback vers CoHabitat (cross-DB inaccessible cote central).
  SELECT c.name, c.admin_building, br.name
    INTO v_subject_name, v_captured_unit, v_building_name
    FROM clients c
    LEFT JOIN building_registry br ON br.id = c.building_id
   WHERE c.id = p_client_id;

  -- Surcharge avec p_subject_unit si fourni (priorite admin).
  IF p_subject_unit IS NOT NULL AND length(trim(p_subject_unit)) > 0 THEN
    v_captured_unit := trim(p_subject_unit);
  END IF;

  -- Resoudre l'email admin
  IF p_admin_id IS NOT NULL THEN
    SELECT email INTO v_admin_email FROM auth.users WHERE id = p_admin_id;
  END IF;

  -- Calcul hash + INSERT cert
  v_anon_at := now();
  v_hash := compute_anon_certificate_hash(
    v_subject_name, v_captured_unit, v_building_name, v_anon_at, v_admin_email
  );

  INSERT INTO anonymization_certificates (
    client_id, subject_name, subject_unit, building_name,
    anonymized_at, anonymized_by, admin_email, content_sha256
  ) VALUES (
    p_client_id, v_subject_name, v_captured_unit, v_building_name,
    v_anon_at, p_admin_id, v_admin_email, v_hash
  ) RETURNING id INTO v_cert_id;

  -- Anonymise clients
  v_short_id   := substring(p_client_id::text from 1 for 8);
  v_anon_label := 'Resident anonyme #' || v_short_id;

  UPDATE clients SET
    name = v_anon_label, contact_name = NULL, contact_email = NULL,
    cohabitat_email = NULL, cohabitat_user_id = NULL, address = NULL,
    city = NULL, notes = NULL, admin_building = NULL,
    anonymized_at = v_anon_at, anonymized_by = p_admin_id, updated_at = v_anon_at
  WHERE id = p_client_id;

  -- Anonymise signed_by_name sur contrats
  UPDATE contracts SET signed_by_name = v_anon_label
   WHERE (client_id = p_client_id OR owner_client_id = p_client_id)
     AND signed_by_name IS NOT NULL;
  GET DIAGNOSTICS v_contracts_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true, 'already_anonymized', false,
    'anonymized_at', v_anon_at, 'anonymized_by', p_admin_id,
    'admin_email', v_admin_email, 'anon_label', v_anon_label,
    'contracts_updated', v_contracts_count, 'certificate_id', v_cert_id,
    'certificate', jsonb_build_object(
      'id', v_cert_id, 'subject_name', v_subject_name,
      'subject_unit', v_captured_unit, 'building_name', v_building_name,
      'anonymized_at', v_anon_at, 'admin_email', v_admin_email,
      'content_sha256', v_hash,
      'retention_until', v_anon_at + interval '6 years'
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION anonymize_client_central(UUID, UUID, TEXT) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION anonymize_client_central(UUID, UUID, TEXT) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
