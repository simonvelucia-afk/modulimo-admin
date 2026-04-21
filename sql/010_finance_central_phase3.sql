-- =====================================================================
-- 010_finance_central_phase3.sql
-- Fondation de la Phase 3 : backfill d'un immeuble + dual-write transitoire.
--
--   * building_registry gagne deux flags par-immeuble :
--       read_source        ('cohabitat' | 'central') — ou lisent les UI
--       dual_write_enabled (bool)       — si true, mutations ecrivent des
--                                         deux cotes pendant l'observation
--   * reconcile_building(p_building_id) compare la somme des transactions
--     au champ virtual_balance. Toute divergence = incident. Appele
--     quotidiennement (pg_cron ou scheduled Edge Function).
--   * divergence_log consigne chaque ecart detecte, avec le timestamp du
--     run, pour suivre dans le temps.
--
-- Ce SQL ne deplace AUCUNE donnee : le backfill lui-meme vit cote script
-- (scripts/backfill-building.ts) parce qu'il requiert deux DBs (CoHabitat
-- + central), ce qui n'est pas propre en pl/pgsql.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Feature flags par immeuble
-- ---------------------------------------------------------------------
ALTER TABLE building_registry
  ADD COLUMN IF NOT EXISTS read_source text NOT NULL DEFAULT 'cohabitat'
    CHECK (read_source IN ('cohabitat','central')),
  ADD COLUMN IF NOT EXISTS dual_write_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN building_registry.read_source IS
  'Source de verite pour les lectures cote UI : "cohabitat" (default) =
  lit profiles.virtual_balance de l''immeuble ; "central" = lit
  balances.virtual_balance de la centrale via finance-bridge.';

COMMENT ON COLUMN building_registry.dual_write_enabled IS
  'Si true, les RPC CoHabitat ecrivent aussi sur la centrale (via
  finance-bridge). Utilise pendant la fenetre d''observation entre le
  backfill et la bascule definitive.';

-- ---------------------------------------------------------------------
-- 2. divergence_log : historique des ecarts detectes
-- ---------------------------------------------------------------------
-- Une ligne par (reconciliation_run, client_id) divergent. ok=true si la
-- somme correspond. Les runs successifs permettent de voir si les
-- divergences sont transitoires (retry cours) ou permanentes (incident).
CREATE TABLE IF NOT EXISTS divergence_log (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at           timestamptz NOT NULL DEFAULT now(),
  building_id      uuid NOT NULL REFERENCES building_registry(id),
  client_id        uuid NOT NULL REFERENCES clients(id),
  kind             text NOT NULL CHECK (kind IN ('balance_vs_ledger','external_snapshot')),
  expected         numeric(12,2) NOT NULL,
  actual           numeric(12,2) NOT NULL,
  diff             numeric(12,2) NOT NULL,
  note             text
);

CREATE INDEX IF NOT EXISTS idx_divergence_log_run ON divergence_log(run_at DESC);
CREATE INDEX IF NOT EXISTS idx_divergence_log_building ON divergence_log(building_id, run_at DESC);

ALTER TABLE divergence_log ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON divergence_log TO service_role;

-- ---------------------------------------------------------------------
-- 3. reconcile_building : check interne (balance vs ledger)
-- ---------------------------------------------------------------------
-- Verifie l'invariant du ledger append-only : pour chaque client de
-- l'immeuble, balances.virtual_balance DOIT == SUM(transactions.amount).
-- Toute divergence = corruption de donnees (bug RPC, ecriture directe
-- en base qui contournerait le ledger, etc.).
CREATE OR REPLACE FUNCTION reconcile_building(
  p_building_id uuid,
  p_persist     boolean DEFAULT true
) RETURNS TABLE(
  client_id   uuid,
  balance     numeric,
  ledger_sum  numeric,
  diff        numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row RECORD;
BEGIN
  IF p_building_id IS NULL THEN
    RAISE EXCEPTION 'missing_building_id' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_row IN
    SELECT
      b.client_id,
      b.virtual_balance AS balance,
      COALESCE((
        SELECT SUM(t.amount)
          FROM transactions t
         WHERE t.client_id   = b.client_id
           AND t.building_id = b.building_id
           AND t.dependent_id IS NULL     -- reconcile ne mixe pas les deps
      ), 0)::numeric AS ledger_sum
    FROM balances b
   WHERE b.building_id = p_building_id
  LOOP
    client_id  := v_row.client_id;
    balance    := v_row.balance;
    ledger_sum := v_row.ledger_sum;
    diff       := v_row.balance - v_row.ledger_sum;

    IF p_persist AND diff <> 0 THEN
      INSERT INTO divergence_log (
        building_id, client_id, kind, expected, actual, diff, note
      ) VALUES (
        p_building_id, v_row.client_id, 'balance_vs_ledger',
        v_row.ledger_sum, v_row.balance, diff,
        'balances.virtual_balance differe de SUM(transactions.amount)'
      );
    END IF;

    -- Ne retourne que les lignes divergentes pour que l'appelant puisse
    -- "IF NOT FOUND THEN ok" sans parser toute la table.
    IF diff <> 0 THEN
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION reconcile_building(uuid, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION reconcile_building(uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------
-- 4. reconcile_vs_cohabitat : compare central a un snapshot CoHabitat
-- ---------------------------------------------------------------------
-- Pendant l'observation Phase 3, on prend une photo des soldes CoHabitat
-- et on la compare aux balances centrales. Le snapshot arrive sous forme
-- de JSON : [{"cohabitat_user_id":"...", "virtual_balance":"..."}]
-- (format stable, facile a produire avec un SELECT sur profiles).
CREATE OR REPLACE FUNCTION reconcile_vs_cohabitat(
  p_building_id uuid,
  p_snapshot    jsonb,
  p_persist     boolean DEFAULT true
) RETURNS TABLE(
  client_id       uuid,
  central_balance numeric,
  cohabitat_balance numeric,
  diff            numeric
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item jsonb;
  v_client_id uuid;
  v_coh_bal   numeric;
  v_cent_bal  numeric;
BEGIN
  IF p_building_id IS NULL OR p_snapshot IS NULL THEN
    RAISE EXCEPTION 'missing_params' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_snapshot) LOOP
    -- Resout cohabitat_user_id -> client_id dans le registre central
    SELECT c.id INTO v_client_id
      FROM clients c
     WHERE c.cohabitat_user_id = (v_item->>'cohabitat_user_id')::uuid
       AND c.building_id       = p_building_id;

    IF v_client_id IS NULL THEN
      -- Utilisateur CoHabitat sans row clients : a traiter a part
      -- (provisionnement non fait). On log mais on skip.
      CONTINUE;
    END IF;

    v_coh_bal := (v_item->>'virtual_balance')::numeric;

    SELECT COALESCE(b.virtual_balance, 0) INTO v_cent_bal
      FROM balances b
     WHERE b.client_id = v_client_id AND b.building_id = p_building_id;
    IF v_cent_bal IS NULL THEN v_cent_bal := 0; END IF;

    client_id         := v_client_id;
    central_balance   := v_cent_bal;
    cohabitat_balance := v_coh_bal;
    diff              := v_cent_bal - v_coh_bal;

    IF p_persist AND diff <> 0 THEN
      INSERT INTO divergence_log (
        building_id, client_id, kind, expected, actual, diff, note
      ) VALUES (
        p_building_id, v_client_id, 'external_snapshot',
        v_coh_bal, v_cent_bal, diff,
        'central differe du snapshot CoHabitat'
      );
    END IF;

    IF diff <> 0 THEN
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION reconcile_vs_cohabitat(uuid, jsonb, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION reconcile_vs_cohabitat(uuid, jsonb, boolean) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
