-- =====================================================================
-- 014_finance_central_transfer_to_dep.sql
-- RPC transfer_to_dependent_central : equivalent atomique cote central de
-- la RPC locale CoHabitat transfer_to_dependent. Le parent debite son
-- solde principal et le dependant en recoit le credit, en une seule
-- transaction PG. Si le credit echoue, le debit roll-back automatiquement
-- (pas de fenetre ou le parent a perdu sans que le dep recoive).
--
-- Appele par finance-bridge/transfer-to-dep depuis l'UI CoHabitat quand
-- finance_central_enabled=true. Avant ca, le transfert ne touchait que
-- profiles.virtual_balance / dependents.virtual_balance localement et la
-- centrale n'en voyait jamais trace.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Etendre le whitelist de transactions.type
-- ---------------------------------------------------------------------
-- Le CHECK est inline dans le CREATE TABLE de sql/007, le nom auto-genere
-- par PG est 'transactions_type_check'. Si la version locale a un nom
-- different (rare), on cherche dynamiquement dans pg_constraint avant de
-- drop pour eviter l'echec silencieux du DROP IF EXISTS.
DO $$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT conname INTO v_constraint_name
    FROM pg_constraint
   WHERE conrelid = 'public.transactions'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%type%IN%';
  IF v_constraint_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.transactions DROP CONSTRAINT ' || quote_ident(v_constraint_name);
  END IF;
END $$;

ALTER TABLE transactions ADD CONSTRAINT transactions_type_check
  CHECK (type IN (
    'admin_credit',
    'space_reservation',
    'space_cancel_refund',
    'trip_booking',
    'trip_cancel_refund',
    'trip_cancel_charge',
    'trip_driver_earning',
    'trip_driver_charge',
    'lunch_purchase',
    'demo',
    -- Transfert atomique parent -> dependant (Phase 3D)
    'transfer_to_dependent',   -- ligne ledger cote parent (debit)
    'transfer_from_parent'     -- ligne ledger cote dependant (credit)
  ));

-- ---------------------------------------------------------------------
-- 2. RPC transfer_to_dependent_central
-- ---------------------------------------------------------------------
-- Logique :
--   1. adjust_balance(parent, -amount, type='transfer_to_dependent')
--      Idempotency-key derivee : <p_idempotency_key>:out
--   2. adjust_balance(dep,    +amount, type='transfer_from_parent')
--      Idempotency-key derivee : <p_idempotency_key>:in
--
-- Les deux appels partagent la meme transaction PG : si le 2e plante
-- (insufficient_funds est impossible cote credit, mais p.ex. dep_external_id
-- vide ou format invalide), le ROLLBACK annule le 1er, on n'a pas de trou.
--
-- Idempotence : si le client retry avec la meme p_idempotency_key, les deux
-- adjust_balance internes detectent leur cle individuelle et retournent
-- l'etat existant -> on retourne le meme triplet (parent_tx, dep_tx, soldes).
CREATE OR REPLACE FUNCTION transfer_to_dependent_central(
  p_client_id        uuid,
  p_building_id      uuid,
  p_dep_external_id  text,
  p_amount           numeric,
  p_idempotency_key  text,
  p_description      text DEFAULT NULL,
  p_created_by       uuid DEFAULT NULL
) RETURNS TABLE(
  parent_transaction_id  uuid,
  dep_transaction_id     uuid,
  parent_balance_after   numeric,
  dep_balance_after      numeric,
  dep_id                 uuid,
  idempotent_replay      boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent_tx     uuid;
  v_parent_bal    numeric;
  v_parent_replay boolean;
  v_dep_tx        uuid;
  v_dep_bal       numeric;
  v_dep_id        uuid;
  v_dep_replay    boolean;
BEGIN
  IF p_dep_external_id IS NULL OR p_dep_external_id = '' THEN
    RAISE EXCEPTION 'missing_dep_external_id'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_idempotency_key IS NULL OR p_idempotency_key = '' THEN
    RAISE EXCEPTION 'missing_idempotency_key'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- 1. Debit parent
  SELECT t.transaction_id, t.virtual_balance, t.idempotent_replay
    INTO v_parent_tx, v_parent_bal, v_parent_replay
    FROM adjust_balance(
      p_client_id       => p_client_id,
      p_building_id     => p_building_id,
      p_amount          => -p_amount,
      p_type            => 'transfer_to_dependent',
      p_reference_type  => 'transfer_to_dep',
      p_description     => p_description,
      p_idempotency_key => p_idempotency_key || ':out',
      p_created_by      => p_created_by
    ) t;

  -- 2. Credit dependant
  SELECT t.transaction_id, t.virtual_balance, t.dependent_id, t.idempotent_replay
    INTO v_dep_tx, v_dep_bal, v_dep_id, v_dep_replay
    FROM adjust_balance(
      p_client_id       => p_client_id,
      p_building_id     => p_building_id,
      p_dep_external_id => p_dep_external_id,
      p_amount          => p_amount,
      p_type            => 'transfer_from_parent',
      p_reference_type  => 'transfer_to_dep',
      p_description     => p_description,
      p_idempotency_key => p_idempotency_key || ':in',
      p_created_by      => p_created_by
    ) t;

  parent_transaction_id := v_parent_tx;
  dep_transaction_id    := v_dep_tx;
  parent_balance_after  := v_parent_bal;
  dep_balance_after     := v_dep_bal;
  dep_id                := v_dep_id;
  -- Replay = vrai ssi les deux jambes sont des replays (sinon c'est une
  -- premiere ecriture mixte, considere comme nouvelle transaction).
  idempotent_replay     := v_parent_replay AND v_dep_replay;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION transfer_to_dependent_central(uuid, uuid, text, numeric, text, text, uuid)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION transfer_to_dependent_central(uuid, uuid, text, numeric, text, text, uuid)
  TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
