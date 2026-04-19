-- =====================================================================
-- Migration : tokens de signature pour contrats
-- Central DB Modulimo (bpxscgrbxjscicpnheep)
-- =====================================================================
-- Permet à un client (résident ou propriétaire) de signer son contrat
-- via un lien email tokenisé, sans avoir accès à modulimo-admin ni à
-- une session authentifiée dans cohabitat.
--
-- Appliquer sur le projet Central (bpxscgrbxjscicpnheep) :
--   psql "postgresql://postgres.bpxscgrbxjscicpnheep:[PWD]@...:5432/postgres" \
--        -f sql/001_signature_tokens.sql
-- =====================================================================

BEGIN;

-- 1. Colonnes token sur contracts
ALTER TABLE contracts
  ADD COLUMN IF NOT EXISTS signature_token            text UNIQUE,
  ADD COLUMN IF NOT EXISTS signature_token_expires_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_contracts_signature_token
  ON contracts(signature_token)
  WHERE signature_token IS NOT NULL;

-- 2. RPC lecture : renvoie le contrat + les infos client/immeuble à partir du token
--    SECURITY DEFINER → contourne RLS, exposé à anon pour la page publique sign.html
CREATE OR REPLACE FUNCTION public.get_contract_by_token(p_token text)
RETURNS TABLE(
  id               uuid,
  type             text,
  plan             text,
  status           text,
  starts_at        date,
  ends_at          date,
  signed_at        timestamptz,
  signed_by_name   text,
  client_name      text,
  client_email     text,
  owner_name       text,
  token_expired    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id, c.type, c.plan, c.status, c.starts_at, c.ends_at,
    c.signed_at, c.signed_by_name,
    COALESCE(cli.contact_name, cli.name) AS client_name,
    cli.contact_email                    AS client_email,
    own.name                             AS owner_name,
    (c.signature_token_expires_at IS NOT NULL
       AND c.signature_token_expires_at < now())      AS token_expired
  FROM contracts c
  LEFT JOIN clients cli ON cli.id = c.client_id
  LEFT JOIN clients own ON own.id = c.owner_client_id
  WHERE c.signature_token = p_token;
END;
$$;

REVOKE ALL ON FUNCTION public.get_contract_by_token(text) FROM public;
GRANT EXECUTE ON FUNCTION public.get_contract_by_token(text) TO anon, authenticated;

-- 3. RPC signature : enregistre la signature et invalide le token (one-shot)
--    Retourne l'id du contrat signé ; lève une erreur si token invalide/expiré/déjà utilisé
CREATE OR REPLACE FUNCTION public.sign_contract_with_token(
  p_token           text,
  p_signed_by_name  text,
  p_signature_data  text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_token IS NULL OR length(p_token) < 20 THEN
    RAISE EXCEPTION 'Token invalide';
  END IF;
  IF p_signed_by_name IS NULL OR length(trim(p_signed_by_name)) < 2 THEN
    RAISE EXCEPTION 'Nom de signataire requis';
  END IF;
  IF p_signature_data IS NULL OR length(p_signature_data) < 100 THEN
    RAISE EXCEPTION 'Signature requise';
  END IF;

  UPDATE contracts
     SET signed_at                  = now(),
         signed_by_name             = p_signed_by_name,
         signature_data             = p_signature_data,
         signature_token            = NULL,
         signature_token_expires_at = NULL
   WHERE signature_token = p_token
     AND signed_at IS NULL
     AND (signature_token_expires_at IS NULL OR signature_token_expires_at > now())
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Lien invalide, expiré ou déjà utilisé';
  END IF;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.sign_contract_with_token(text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.sign_contract_with_token(text, text, text) TO anon, authenticated;

COMMIT;

-- =====================================================================
-- Rollback (à conserver pour référence)
-- =====================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.sign_contract_with_token(text, text, text);
-- DROP FUNCTION IF EXISTS public.get_contract_by_token(text);
-- DROP INDEX  IF EXISTS public.idx_contracts_signature_token;
-- ALTER TABLE contracts
--   DROP COLUMN IF EXISTS signature_token_expires_at,
--   DROP COLUMN IF EXISTS signature_token;
-- COMMIT;
