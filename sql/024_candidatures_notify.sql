-- =====================================================================
-- 024_candidatures_notify.sql
-- Bascule du systeme candidatures vers "notification courriel + stats".
--
-- Decisions du gestionnaire de l'immeuble :
--   * Modulimo central ne sert plus de panneau de gestion par dossier.
--     candidatures.html devient un tableau de stats agregees.
--   * Chaque nouvelle candidature est envoyee par courriel au
--     gestionnaire de l'immeuble (lookup via building_registry.
--     notification_email).
--   * Sans panneau de changement de statut, on ne peut plus s'appuyer
--     sur status='refuse' pour declencher la purge Loi 25. On purge
--     donc TOUTES les candidatures > 12 mois sauf 'accepte' (dossier
--     locataire actif a conserver).
-- =====================================================================

BEGIN;

-- 1. notification_email sur building_registry ------------------------
ALTER TABLE public.building_registry
  ADD COLUMN IF NOT EXISTS notification_email text;

COMMENT ON COLUMN public.building_registry.notification_email IS
  'Adresse courriel du gestionnaire qui recoit les nouvelles candidatures pour cet immeuble via Resend.';

-- 2. Configuration Pointe Est ----------------------------------------
UPDATE public.building_registry
SET notification_email = 'contribution@modulimo.com'
WHERE id = 'a41b3b31-1681-4cb1-b54c-69486d27e132';

-- 3. Nouvelle logique de purge Loi 25 --------------------------------
--    Toute candidature > retention_until est purgee, SAUF 'accepte'
--    (dossier locataire actif). Idempotent : pose la fonction a jour.
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
        'status_at_destruction', status,
        'score_category_at_destruction', score_category
      ),
      consents     = NULL,
      user_agent   = NULL,
      ip_hash      = NULL,
      destroyed_at = now()
    WHERE destroyed_at IS NULL
      AND retention_until < now()
      AND status <> 'accepte'
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM purged;
  RETURN v_count;
END;
$$;

COMMIT;

NOTIFY pgrst, 'reload schema';
