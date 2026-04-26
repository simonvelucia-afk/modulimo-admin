-- 017_export_client_data_central.sql
-- Conformite Loi 25 (Quebec) — pendant cote central de la RPC
-- export_client_data deployee sur chaque CoHabitat. Retourne en JSONB
-- toutes les donnees centrales liees a un client (clients, contrats,
-- factures, lignes, soldes, transactions, paiements reels, lunch
-- audit, tokens signature, divergences).
--
-- Securite :
--   * SECURITY DEFINER + service_role only. La centrale n'a pas de
--     notion d'auth.uid() utilisable ici (les JWT centraux sont mintes
--     par les Edge Functions, pas par auth.users). On reserve donc
--     l'acces a service_role et l'orchestration passe par une Edge
--     Function (phase D) qui valide le caller (admin Modulimo).
--   * REVOKE explicite a tous les autres roles pour eviter l'oubli.
--
-- Usage cote Edge Function :
--   const { data } = await postgrest.rpc('export_client_data_central',
--     { p_client_id: '<uuid>' }, serviceRoleKey);

BEGIN;

CREATE OR REPLACE FUNCTION export_client_data_central(p_client_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_result JSONB;
BEGIN
  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'p_client_id requis' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT jsonb_build_object(
    'exported_at',           now(),
    'subject_client_id',     p_client_id,
    'schema_version',        '1.0'::text,

    -- Profil central (PII : name, contact_name, contact_email,
    -- cohabitat_user_id, cohabitat_email, etc.)
    'client',                (SELECT to_jsonb(c) FROM clients c WHERE c.id = p_client_id),

    -- Historique des contrats (plan changes, signatures)
    'contracts',             COALESCE((
      SELECT jsonb_agg(to_jsonb(ct))
      FROM contracts ct
      WHERE ct.client_id = p_client_id OR ct.owner_client_id = p_client_id
    ), '[]'::jsonb),

    -- Factures emises (1 par mois) avec leurs lignes detaillees.
    -- On ramene le tout dans un seul tableau ; chaque facture a une
    -- propriete 'lines' avec ses invoice_line_items.
    'invoices',              COALESCE((
      SELECT jsonb_agg(
        to_jsonb(i) || jsonb_build_object(
          'lines', COALESCE((
            SELECT jsonb_agg(to_jsonb(li))
            FROM invoice_line_items li
            WHERE li.invoice_id = i.id
          ), '[]'::jsonb)
        )
      )
      FROM invoices i
      WHERE i.client_id = p_client_id OR i.owner_client_id = p_client_id
    ), '[]'::jsonb),

    -- Solde actuel resident principal
    'balance',               (SELECT to_jsonb(b) FROM balances b WHERE b.client_id = p_client_id),

    -- Soldes des dependants rattaches a ce client
    'dependent_balances',    COALESCE((
      SELECT jsonb_agg(to_jsonb(db))
      FROM dependent_balances db
      WHERE db.client_id = p_client_id
    ), '[]'::jsonb),

    -- Ledger : tous les mouvements financiers
    'transactions',          COALESCE((
      SELECT jsonb_agg(to_jsonb(t))
      FROM transactions t
      WHERE t.client_id = p_client_id
    ), '[]'::jsonb),

    -- Paiements reels recus (cash, virement) attribues a ce client
    -- Note : real_payments centrale a une colonne client_id depuis sql/012.
    'real_payments',         COALESCE((
      SELECT jsonb_agg(to_jsonb(rp))
      FROM real_payments rp
      WHERE rp.client_id = p_client_id
    ), '[]'::jsonb),

    -- Audit lunch : achats faits sur les machines (la table existe
    -- cote central pour journalisation cross-immeuble)
    'lunch_transactions',    COALESCE((
      SELECT jsonb_agg(to_jsonb(lt))
      FROM lunch_transactions lt
      WHERE lt.client_id = p_client_id
    ), '[]'::jsonb),

    -- Tokens de signature emis pour ce client (contrats signes ou en
    -- attente). Skip silencieusement si la table n'existe pas.
    'signature_tokens',      COALESCE((
      SELECT jsonb_agg(to_jsonb(st))
      FROM signature_tokens st
      WHERE st.client_id = p_client_id
    ), '[]'::jsonb),

    -- Log des divergences soldes (si l'immeuble a synchronise des
    -- valeurs locales differentes des valeurs centrales pour ce client)
    'divergence_log',        COALESCE((
      SELECT jsonb_agg(to_jsonb(dl))
      FROM divergence_log dl
      WHERE dl.client_id = p_client_id
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION export_client_data_central(UUID) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION export_client_data_central(UUID) TO service_role;

COMMENT ON FUNCTION export_client_data_central(UUID) IS
  'Loi 25 / RGPD : retourne en JSONB toutes les donnees centrales liees
  a un client (profile central, contrats, factures + lignes, soldes,
  transactions, paiements, lunch audit, signature tokens, divergence log).
  Service_role only — orchestre par une Edge Function qui valide le
  caller (admin Modulimo) avant d''appeler cette RPC.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ROLLBACK :
--   DROP FUNCTION IF EXISTS export_client_data_central(UUID);
