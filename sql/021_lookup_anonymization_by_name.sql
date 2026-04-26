-- 021_lookup_anonymization_by_name.sql
-- Garde-fou : avant de creer un nouveau client, l'admin peut verifier
-- si un certificat d'anonymisation existe pour ce nom (typiquement
-- "ancien locataire revient apres anonymisation").
--
-- Usage Loi 25 art. 4 (minimisation) : utilisation legitime de la
-- preuve d'anonymisation pour prevenir les ambiguites administratives,
-- pas pour fishing. La RPC retourne des matches exacts seulement
-- (ILIKE p_name complet, pas LIKE '%query%').

BEGIN;

CREATE OR REPLACE FUNCTION lookup_anonymization_by_name(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_normalized TEXT;
BEGIN
  IF p_name IS NULL OR length(trim(p_name)) < 3 THEN
    -- Refuse les requetes trop vagues (eviter fishing).
    RETURN jsonb_build_object('ok', true, 'matches', '[]'::jsonb);
  END IF;

  v_normalized := lower(trim(p_name));

  RETURN jsonb_build_object(
    'ok', true,
    'matches', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'certificate_id',  ac.id,
        'client_id',       ac.client_id,
        'subject_name',    ac.subject_name,
        'subject_unit',    ac.subject_unit,
        'building_name',   ac.building_name,
        'anonymized_at',   ac.anonymized_at,
        'admin_email',     ac.admin_email
      ) ORDER BY ac.anonymized_at DESC)
      FROM anonymization_certificates ac
      WHERE lower(trim(ac.subject_name)) = v_normalized
    ), '[]'::jsonb)
  );
END;
$fn$;

REVOKE ALL ON FUNCTION lookup_anonymization_by_name(TEXT)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION lookup_anonymization_by_name(TEXT) TO service_role;

COMMENT ON FUNCTION lookup_anonymization_by_name(TEXT) IS
  'Loi 25 garde-fou : retourne les certificats d''anonymisation
  matchant exactement un nom donne. Usage par les admins pour eviter
  de re-creer un compte pour une personne deja anonymisee. Match
  exact (lower+trim), pas de fuzzy/fishing.';

NOTIFY pgrst, 'reload schema';

COMMIT;
