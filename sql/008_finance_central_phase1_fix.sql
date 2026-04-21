-- =====================================================================
-- 008_finance_central_phase1_fix.sql
-- Correctif Phase 1 : bascule get_balance sur le pattern service_role +
-- parametres explicites au lieu de lire auth.jwt().
--
-- Contexte : le smoke test de la Phase 1 a revele que PostgREST du projet
-- central refuse les JWT HS256 mintes par l'Edge Function (erreur
-- PGRST301 "No suitable key or wrong key type"). Le projet central a la
-- signature asymetrique activee, et PostgREST ne fait plus confiance aux
-- JWT signes avec le JWT Secret HS256.
--
-- Plutot que d'essayer de minter avec une cle asymetrique dont on n'a
-- pas acces en Edge Function, on adopte le pattern Supabase standard :
--   * L'Edge Function finance-bridge valide le JWT entrant (signe par
--     l'Auth Supabase de l'immeuble) et resout (client_id, building_id).
--   * Elle appelle ensuite get_balance avec SERVICE_ROLE_KEY, en passant
--     les claims resolus en parametres explicites.
--   * La RPC est SECURITY DEFINER et ne peut etre appelee QUE par
--     service_role (REVOKE + GRANT cible). Authenticated/anon sont
--     refuses direct au niveau du GRANT.
--
-- La frontiere de confiance reste l'Edge Function : c'est elle qui
-- garantit que p_client_id et p_building_id correspondent au JWT verifie.
-- La RPC ne re-valide pas ; elle filtre simplement par les params.
-- =====================================================================

BEGIN;

-- Ancienne signature (lisait jwt_client_id() / jwt_building_id())
DROP FUNCTION IF EXISTS get_balance(text);

CREATE OR REPLACE FUNCTION get_balance(
  p_client_id       uuid,
  p_building_id     uuid,
  p_external_dep_id text DEFAULT NULL
) RETURNS TABLE(
  virtual_balance numeric,
  source_kind     text,        -- 'main' | 'dependent' | 'missing'
  updated_at      timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_client_id IS NULL OR p_building_id IS NULL THEN
    RAISE EXCEPTION 'missing_params'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_external_dep_id IS NULL THEN
    RETURN QUERY
    SELECT b.virtual_balance, 'main'::text, b.updated_at
      FROM balances b
     WHERE b.client_id = p_client_id
       AND b.building_id = p_building_id;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 0.00::numeric, 'missing'::text, NULL::timestamptz;
    END IF;
  ELSE
    RETURN QUERY
    SELECT d.virtual_balance, 'dependent'::text, d.updated_at
      FROM dependent_balances d
     WHERE d.client_id = p_client_id
       AND d.building_id = p_building_id
       AND d.external_dep_id = p_external_dep_id;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 0.00::numeric, 'missing'::text, NULL::timestamptz;
    END IF;
  END IF;
END;
$$;

-- Refus explicite pour public/anon/authenticated : seule l'Edge Function
-- avec service_role a le droit d'appeler. Les residents n'atteignent
-- cette RPC que via /functions/v1/finance-bridge/get-balance.
REVOKE ALL ON FUNCTION get_balance(uuid, uuid, text) FROM public;
REVOKE ALL ON FUNCTION get_balance(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION get_balance(uuid, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION get_balance(uuid, uuid, text) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Rollback :
--   DROP FUNCTION get_balance(uuid, uuid, text);
--   Puis re-executer la Phase 1 pour restaurer la version avec JWT.
-- =====================================================================
