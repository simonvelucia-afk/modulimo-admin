-- =====================================================================
-- 024_candidatures_building_management.sql
-- Permet a chaque CoHabitat (par immeuble) de lister et de decider
-- les candidatures qui le concernent, sans exposer la table publique
-- aux residents authentifies cote local.
--
-- Contexte :
--   * 023_candidatures.sql a ete pose avec une RLS "alpha" :
--     authenticated (= login modulimo-admin) peut tout voir / modifier.
--   * Mais les admins CoHabitat n'ont PAS de session contre le projet
--     central : leur auth vit dans le projet Supabase de l'immeuble.
--     Ils utilisent l'anon_key central pour atteindre les RPC publiques
--     (cf. CENTRAL_URL/CENTRAL_KEY dans CoHabitat/index.html).
--   * Modulimo central ne doit PAS approuver les locataires d'un
--     immeuble individuel : c'est l'admin du building qui le fait.
--
-- Ce que ce fichier ajoute :
--   * list_candidatures_for_building(uuid) : retourne les candidatures
--     non detruites pour un building donne (lecture). Expose a anon.
--   * decide_candidature_for_building(uuid, text, uuid)
--     : passe le statut a 'accepte' / 'refuse' / 'en_evaluation' pour
--     une candidature donnee, en exigeant que le building_id de la
--     candidature corresponde a celui passe en argument (= scoping
--     par instance CoHabitat). Expose a anon.
--
-- Modele de confiance :
--   * Chaque CoHabitat connait son propre building_id (system_settings).
--   * La cle anon centrale est publique cote front mais le scoping par
--     building_id empeche un immeuble d'agir sur les candidatures d'un
--     autre. C'est le meme niveau de confiance que les autres RPC anon
--     existantes du projet (create_resident_client, etc.).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Lecture : liste des candidatures d'un building
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_candidatures_for_building(
  p_building_id uuid
)
RETURNS TABLE (
  id              uuid,
  created_at      timestamptz,
  status          text,
  applicant_email text,
  applicant_name  text,
  target_rent     numeric,
  annual_income   numeric,
  score_total     integer,
  score_category  text,
  form_data       jsonb,
  reviewed_at     timestamptz,
  decision_at     timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    c.id, c.created_at, c.status,
    c.applicant_email, c.applicant_name, c.target_rent, c.annual_income,
    c.score_total, c.score_category, c.form_data,
    c.reviewed_at, c.decision_at
  FROM public.candidatures c
  WHERE c.building_id = p_building_id
    AND c.destroyed_at IS NULL
  ORDER BY c.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.list_candidatures_for_building(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.list_candidatures_for_building(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.list_candidatures_for_building(uuid) IS
  'Liste les candidatures (non detruites) pour un building donne. Appelee depuis l''onglet Demandes du CoHabitat de chaque immeuble.';

-- ---------------------------------------------------------------------
-- 2. Decision : approuver / refuser / passer en evaluation
-- ---------------------------------------------------------------------
-- Le scoping par building_id (parametre + check) empeche un CoHabitat
-- d'agir sur les candidatures d'un autre immeuble.
-- Le retention_until est pose automatiquement a +12 mois pour 'refuse'
-- (Loi 25 : conservation max apres refus).
CREATE OR REPLACE FUNCTION public.decide_candidature_for_building(
  p_candidature_id uuid,
  p_decision       text,
  p_building_id    uuid
)
RETURNS public.candidatures
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.candidatures;
BEGIN
  IF p_decision NOT IN ('accepte','refuse','en_evaluation') THEN
    RAISE EXCEPTION 'Decision invalide: % (attendu: accepte | refuse | en_evaluation)', p_decision
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE public.candidatures c
  SET
    status          = p_decision,
    reviewed_at     = now(),
    decision_at     = CASE WHEN p_decision IN ('accepte','refuse') THEN now() ELSE c.decision_at END,
    retention_until = CASE WHEN p_decision = 'refuse' THEN now() + interval '12 months' ELSE c.retention_until END
  WHERE c.id = p_candidature_id
    AND c.building_id = p_building_id
    AND c.destroyed_at IS NULL
  RETURNING c.* INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Candidature introuvable ou hors scope (id=%, building=%)', p_candidature_id, p_building_id
      USING ERRCODE = 'no_data_found';
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.decide_candidature_for_building(uuid, text, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.decide_candidature_for_building(uuid, text, uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.decide_candidature_for_building(uuid, text, uuid) IS
  'Met a jour le statut d''une candidature, scope par building_id. Appelee depuis l''onglet Demandes du CoHabitat de chaque immeuble.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Rollback (manuel si besoin)
-- ---------------------------------------------------------------------
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.decide_candidature_for_building(uuid, text, uuid);
-- DROP FUNCTION IF EXISTS public.list_candidatures_for_building(uuid);
-- COMMIT;
