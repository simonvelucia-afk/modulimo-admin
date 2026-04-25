-- =====================================================================
-- 016_finance_central_ensure_client.sql
-- Auto-provisionnement des rows clients pour les residents qui ont un
-- JWT valide d'un building actif mais pas encore de row clients. Ferme
-- la derniere boucle de la migration solde central : avant cette RPC, un
-- nouveau resident (ajoute apres le snapshot initial) etait flag
-- "Non-sync" dans l'admin et le kiosque rejetait ses achats avec
-- INSUFFICIENT_FUNDS (central avait 0). Avec cette RPC, finance-bridge
-- cree la row clients automatiquement au premier appel.
--
-- Securite : SECURITY DEFINER + service_role only. La RPC verifie que
-- le building cible est 'active' meme si finance-bridge le verifie deja
-- en amont — defense en profondeur contre un appel direct service_role
-- qui contournerait l'Edge Function.
--
-- Idempotence : INSERT...ON CONFLICT DO NOTHING (utilise l'index unique
-- partiel idx_clients_cohabitat_per_building cree dans sql/007). Un
-- 2eme appel sur le meme couple (cohabitat_user_id, building_id)
-- retourne le client_id existant.
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION ensure_client(
  p_cohabitat_user_id uuid,
  p_building_id       uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client_id uuid;
BEGIN
  IF p_cohabitat_user_id IS NULL OR p_building_id IS NULL THEN
    RAISE EXCEPTION 'missing_params'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM building_registry
     WHERE id = p_building_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'building_not_active'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Find first (frequent path post-provision : on evite l'INSERT inutile).
  SELECT id INTO v_client_id
    FROM clients
   WHERE cohabitat_user_id = p_cohabitat_user_id
     AND building_id       = p_building_id;
  IF FOUND THEN
    RETURN v_client_id;
  END IF;

  -- Create. Le ON CONFLICT cible l'index unique partiel pose en sql/007 :
  -- idx_clients_cohabitat_per_building (building_id, cohabitat_user_id)
  -- WHERE cohabitat_user_id IS NOT NULL AND building_id IS NOT NULL.
  -- En cas de race (deux appels concurrents pour le meme resident),
  -- le 2e tombe sur DO NOTHING + RETURNING vide -> on relit la row
  -- gagnante.
  INSERT INTO clients (cohabitat_user_id, building_id)
  VALUES (p_cohabitat_user_id, p_building_id)
  ON CONFLICT (building_id, cohabitat_user_id)
    WHERE cohabitat_user_id IS NOT NULL AND building_id IS NOT NULL
    DO NOTHING
  RETURNING id INTO v_client_id;

  IF v_client_id IS NULL THEN
    SELECT id INTO v_client_id
      FROM clients
     WHERE cohabitat_user_id = p_cohabitat_user_id
       AND building_id       = p_building_id;
  END IF;

  RETURN v_client_id;
END;
$$;

REVOKE ALL ON FUNCTION ensure_client(uuid, uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION ensure_client(uuid, uuid) TO service_role;

COMMENT ON FUNCTION ensure_client(uuid, uuid) IS
  'Find-or-create d''une row clients pour un (cohabitat_user_id, building_id).
  Appele par finance-bridge apres validation JWT pour eliminer le besoin de
  provisioning manuel. Service_role only.';

COMMIT;

NOTIFY pgrst, 'reload schema';
