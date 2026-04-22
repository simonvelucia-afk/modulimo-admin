-- =====================================================================
-- 011_finance_central_phase3b_sync.sql
-- Dual-write via sync periodique (Phase 3B).
--
-- Architecture : l'Edge Function finance-sync tourne toutes les 5 min
-- (cron) et, pour chaque immeuble avec dual_write_enabled=true, pull
-- les nouvelles transactions CoHabitat et les rejoue sur la centrale
-- via adjust_balance avec idempotency_key="backfill:<cohabitat_tx_id>"
-- (meme cle que le script manuel, evite les doubles si backfill et
-- sync se chevauchent).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. sync_cursor : progression par immeuble
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_cursor (
  building_id           uuid PRIMARY KEY REFERENCES building_registry(id) ON DELETE CASCADE,
  last_synced_at        timestamptz,
  last_synced_tx_id     uuid,
  last_run_at           timestamptz,
  last_run_applied      integer NOT NULL DEFAULT 0,
  last_run_replayed     integer NOT NULL DEFAULT 0,
  last_run_errors       integer NOT NULL DEFAULT 0,
  last_error_message    text
);

ALTER TABLE sync_cursor ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON sync_cursor TO service_role;

-- ---------------------------------------------------------------------
-- 2. list_buildings_to_sync : quels immeubles traiter
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_buildings_to_sync() RETURNS TABLE(
  building_id         uuid,
  supabase_url        text,
  last_synced_at      timestamptz,
  last_synced_tx_id   uuid
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    br.id,
    br.supabase_url,
    sc.last_synced_at,
    sc.last_synced_tx_id
  FROM building_registry br
  LEFT JOIN sync_cursor sc ON sc.building_id = br.id
  WHERE br.dual_write_enabled = true
    AND br.status = 'active'
  ORDER BY br.id;
$$;

REVOKE ALL ON FUNCTION list_buildings_to_sync() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION list_buildings_to_sync() TO service_role;

-- ---------------------------------------------------------------------
-- 3. record_sync_progress : update cursor + metriques du run
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_sync_progress(
  p_building_id         uuid,
  p_last_synced_at      timestamptz,
  p_last_synced_tx_id   uuid,
  p_applied             integer,
  p_replayed            integer,
  p_errors              integer,
  p_error_message       text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO sync_cursor (
    building_id, last_synced_at, last_synced_tx_id,
    last_run_at, last_run_applied, last_run_replayed, last_run_errors,
    last_error_message
  ) VALUES (
    p_building_id, p_last_synced_at, p_last_synced_tx_id,
    now(), p_applied, p_replayed, p_errors, p_error_message
  )
  ON CONFLICT (building_id) DO UPDATE SET
    last_synced_at     = COALESCE(EXCLUDED.last_synced_at, sync_cursor.last_synced_at),
    last_synced_tx_id  = COALESCE(EXCLUDED.last_synced_tx_id, sync_cursor.last_synced_tx_id),
    last_run_at        = EXCLUDED.last_run_at,
    last_run_applied   = EXCLUDED.last_run_applied,
    last_run_replayed  = EXCLUDED.last_run_replayed,
    last_run_errors    = EXCLUDED.last_run_errors,
    last_error_message = EXCLUDED.last_error_message;
END;
$$;

REVOKE ALL ON FUNCTION record_sync_progress(uuid, timestamptz, uuid, integer, integer, integer, text)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION record_sync_progress(uuid, timestamptz, uuid, integer, integer, integer, text)
  TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- Scheduling (a executer MANUELLEMENT dans le SQL Editor apres deploy
-- de l'Edge Function) :
--
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   CREATE EXTENSION IF NOT EXISTS pg_net;
--
--   SELECT cron.schedule(
--     'finance-sync-every-5min',
--     '*/5 * * * *',
--     $cron$
--       SELECT net.http_get(
--         url := 'https://bpxscgrbxjscicpnheep.supabase.co/functions/v1/finance-sync/run',
--         headers := jsonb_build_object(
--           'Authorization', 'Bearer ' || current_setting('app.service_role_key'),
--           'apikey',        current_setting('app.anon_key')
--         )
--       )
--     $cron$
--   );
--
--   -- Pour stopper :  SELECT cron.unschedule('finance-sync-every-5min');
-- =====================================================================
