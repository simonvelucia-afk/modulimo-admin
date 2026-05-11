-- =====================================================================
-- 023_candidatures.sql
-- Migration : systeme de candidatures locataires Modulimo.
--
-- Adaptations vs candidatures_kit/02_supabase_schema.sql :
--   * FK building_id -> public.building_registry(id) au lieu de
--     public.buildings(id) : la table 'buildings' n'existe pas dans
--     ce projet ; building_registry (cree en 007_finance_central_phase1)
--     est la table de reference des immeubles.
--   * RLS option alpha : pas de table user_roles dans ce projet.
--     On suit le pattern des migrations 013_finance_central_admin_read
--     et de la note dans 007 : "authenticated has full access, la
--     securite vient de qui peut se connecter au projet modulimo-admin".
--     Donc policies SELECT/UPDATE/DELETE pour authenticated USING (TRUE).
--   * cron.schedule actif : pg_cron 1.6.4 est installe (verifie via
--     pg_extension). Job 'purge-candidatures-loi25' a 03:00 chaque nuit.
--   * Aucune policy INSERT cote authenticated : les candidatures
--     entrent exclusivement par l'Edge Function submit-candidature
--     (qui utilise SUPABASE_SERVICE_ROLE_KEY et bypass RLS).
--
-- Conforme Loi 25 (RGPD-like Quebec) : minimisation, finalite, hash IP,
-- consentements explicites, destruction PII sur demande, purge 12 mois.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Table principale
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.candidatures (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- Reference a l'immeuble (optionnel)
  building_id     uuid REFERENCES public.building_registry(id) ON DELETE SET NULL,

  -- Statut du dossier
  status          text NOT NULL DEFAULT 'recu'
    CHECK (status IN ('recu','en_evaluation','accepte','refuse','retire','expire')),

  -- Donnees brutes du formulaire (JSON, pour flexibilite)
  form_data       jsonb NOT NULL,

  -- Champs denormalises pour recherche rapide (anonymisables)
  applicant_email text GENERATED ALWAYS AS (form_data->>'email') STORED,
  applicant_name  text GENERATED ALWAYS AS (
    coalesce(form_data->>'first_name','') || ' ' || coalesce(form_data->>'last_name','')
  ) STORED,
  target_rent     numeric GENERATED ALWAYS AS (
    nullif(form_data->>'target_rent','')::numeric
  ) STORED,
  annual_income   numeric GENERATED ALWAYS AS (
    coalesce(nullif(form_data->>'annual_income','')::numeric, 0) +
    coalesce(nullif(form_data->>'co_income','')::numeric, 0)
  ) STORED,

  -- Score calcule cote serveur (jamais expose au candidat)
  score_total       integer,
  score_category    text CHECK (score_category IN ('excellent','bon','a_evaluer','a_risque') OR score_category IS NULL),
  score_breakdown   jsonb,
  score_computed_at timestamptz,

  -- Notes admin
  admin_notes     text,
  reviewed_by     uuid REFERENCES auth.users(id),
  reviewed_at     timestamptz,
  decision_at     timestamptz,

  -- Loi 25 -- metadonnees
  consents        jsonb,
  retention_until timestamptz,
  destroyed_at    timestamptz,

  -- Metadonnees techniques (Loi 25 : pas d'IP brute)
  user_agent      text,
  locale          text,
  ip_hash         text
);

CREATE INDEX IF NOT EXISTS idx_candidatures_status   ON public.candidatures(status);
CREATE INDEX IF NOT EXISTS idx_candidatures_building ON public.candidatures(building_id);
CREATE INDEX IF NOT EXISTS idx_candidatures_created  ON public.candidatures(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_candidatures_email    ON public.candidatures(applicant_email);
CREATE INDEX IF NOT EXISTS idx_candidatures_retention
  ON public.candidatures(retention_until)
  WHERE destroyed_at IS NULL;

-- ---------------------------------------------------------------------
-- 2. Trigger updated_at (reuse de la convention 007/touch_updated_at)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_candidatures_updated ON public.candidatures;
CREATE TRIGGER trg_candidatures_updated
  BEFORE UPDATE ON public.candidatures
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------
-- 3. RLS -- option alpha (pattern existant : authenticated = admin)
-- ---------------------------------------------------------------------
ALTER TABLE public.candidatures ENABLE ROW LEVEL SECURITY;

-- INSERT : aucune policy. Toute insertion passe par l'Edge Function
-- submit-candidature (service_role, bypass RLS). Cela protege le score
-- (calcul serveur uniquement) et empeche l'API anon d'inserer.

-- SELECT pour tout utilisateur authentifie (login modulimo-admin)
DROP POLICY IF EXISTS candidatures_authenticated_select ON public.candidatures;
CREATE POLICY candidatures_authenticated_select ON public.candidatures
  FOR SELECT TO authenticated USING (TRUE);

-- UPDATE pour tout utilisateur authentifie (status, notes, decision)
DROP POLICY IF EXISTS candidatures_authenticated_update ON public.candidatures;
CREATE POLICY candidatures_authenticated_update ON public.candidatures
  FOR UPDATE TO authenticated USING (TRUE) WITH CHECK (TRUE);

-- DELETE pour tout utilisateur authentifie (rare ; on prefere
-- destroy_candidature_pii pour la conformite Loi 25)
DROP POLICY IF EXISTS candidatures_authenticated_delete ON public.candidatures;
CREATE POLICY candidatures_authenticated_delete ON public.candidatures
  FOR DELETE TO authenticated USING (TRUE);

GRANT SELECT, UPDATE, DELETE ON public.candidatures TO authenticated;

-- ---------------------------------------------------------------------
-- 4. Loi 25 -- destruction des PII sur demande
-- ---------------------------------------------------------------------
-- Conserve la ligne pour l'audit mais efface les donnees personnelles.
-- SECURITY DEFINER pour bypasser RLS au sein de la fonction, mais on
-- ne fait pas de check de role (modele authenticated = admin).
CREATE OR REPLACE FUNCTION public.destroy_candidature_pii(p_candidature_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Garde-fou minimal : doit etre appele par un utilisateur authentifie
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE public.candidatures
  SET
    form_data = jsonb_build_object(
      '_destroyed', true,
      'status_at_destruction', status,
      'score_category_at_destruction', score_category
    ),
    consents     = NULL,
    user_agent   = NULL,
    ip_hash      = NULL,
    destroyed_at = now()
  WHERE id = p_candidature_id;
END;
$$;

REVOKE ALL ON FUNCTION public.destroy_candidature_pii(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.destroy_candidature_pii(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. Loi 25 -- purge automatique > 12 mois (refusees / retirees / expirees)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_expired_candidatures()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count integer;
BEGIN
  WITH purged AS (
    UPDATE public.candidatures
    SET
      form_data    = jsonb_build_object(
        '_auto_purged', true,
        'status_at_destruction', status
      ),
      consents     = NULL,
      user_agent   = NULL,
      ip_hash      = NULL,
      destroyed_at = now()
    WHERE destroyed_at IS NULL
      AND retention_until < now()
      AND status IN ('refuse','retire','expire')
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM purged;

  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. Vue analytics (sans PII)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.candidatures_analytics AS
SELECT
  date_trunc('month', created_at)         AS month,
  building_id,
  status,
  score_category,
  count(*)                                AS total,
  avg(score_total)::numeric(5,2)          AS avg_score,
  avg(target_rent)::numeric(10,2)         AS avg_target_rent
FROM public.candidatures
WHERE destroyed_at IS NULL
GROUP BY 1, 2, 3, 4;

GRANT SELECT ON public.candidatures_analytics TO authenticated;

-- ---------------------------------------------------------------------
-- 7. Commentaires (auto-doc)
-- ---------------------------------------------------------------------
COMMENT ON TABLE public.candidatures IS
  'Candidatures de location Modulimo. Conforme Loi 25. Le score est calcule par l''Edge Function submit-candidature et n''est jamais expose au candidat.';
COMMENT ON COLUMN public.candidatures.score_total IS
  'Score sur 100. Outil d''aide a la decision uniquement -- la decision finale demeure humaine.';
COMMENT ON COLUMN public.candidatures.retention_until IS
  'Date limite de conservation des PII. Loi 25 : 12 mois max apres refus.';

COMMIT;

-- ---------------------------------------------------------------------
-- 8. pg_cron : purge nightly a 03:00
-- ---------------------------------------------------------------------
-- pg_cron 1.6.4 est installe (verifie via SELECT * FROM pg_extension).
-- Le schedule est cree hors du BEGIN/COMMIT car cron.schedule fait son
-- propre commit interne.
SELECT cron.schedule(
  'purge-candidatures-loi25',
  '0 3 * * *',
  $$SELECT public.purge_expired_candidatures()$$
);

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Rollback (pour reference -- a executer manuellement si besoin)
-- =====================================================================
-- BEGIN;
-- SELECT cron.unschedule('purge-candidatures-loi25');
-- DROP VIEW IF EXISTS public.candidatures_analytics;
-- DROP FUNCTION IF EXISTS public.purge_expired_candidatures();
-- DROP FUNCTION IF EXISTS public.destroy_candidature_pii(uuid);
-- DROP TRIGGER IF EXISTS trg_candidatures_updated ON public.candidatures;
-- DROP FUNCTION IF EXISTS public.set_updated_at();
-- DROP TABLE IF EXISTS public.candidatures;
-- COMMIT;
