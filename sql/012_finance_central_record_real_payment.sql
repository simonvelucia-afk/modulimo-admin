-- =====================================================================
-- 012_finance_central_record_real_payment.sql
-- RPC record_real_payment : enregistrement d'un paiement reel par un
-- admin Modulimo, qui credite le solde virtuel du resident en meme
-- temps qu'il cree la ligne d'audit "paiement reel".
--
-- Appele par modulimo-admin (cote serveur, avec service_role) apres
-- qu'un admin a recu cash/virement/cheque d'un resident et veut le
-- transformer en credit virtuel utilisable dans CoHabitat.
--
-- Idempotent via idempotency_key comme adjust_balance et lunch_purchase.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Table real_payments (audit centralise)
-- ---------------------------------------------------------------------
-- Chaque row represente UN paiement reel recu. Liee 1:1 a une ligne
-- transactions (le credit virtuel correspondant). Un paiement partiel
-- se fait en plusieurs rows (pas d'update sur cette table).
CREATE TABLE IF NOT EXISTS real_payments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id   uuid NOT NULL REFERENCES transactions(id),
  client_id        uuid NOT NULL REFERENCES clients(id),
  building_id      uuid NOT NULL REFERENCES building_registry(id),
  amount_real      numeric(12,2) NOT NULL CHECK (amount_real > 0),
  amount_virtual   numeric(12,2) NOT NULL CHECK (amount_virtual > 0),
  payment_method   text NOT NULL CHECK (payment_method IN (
    'cash','transfer','cheque','credit_card','debit_card','other'
  )),
  reference        text,        -- no de cheque, conf virement, etc.
  notes            text,
  recorded_by      uuid NOT NULL REFERENCES auth.users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transaction_id)        -- 1 real_payment par transaction
);

CREATE INDEX IF NOT EXISTS idx_real_payments_client_created
  ON real_payments(client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_real_payments_building_created
  ON real_payments(building_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_real_payments_recorder
  ON real_payments(recorded_by, created_at DESC);

ALTER TABLE real_payments ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON real_payments TO service_role;

-- Append-only comme transactions : pas d'edition ni suppression. Une
-- correction se fait par une nouvelle ligne de signe oppose.
CREATE OR REPLACE FUNCTION real_payments_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'real_payments is append-only (op=%)', TG_OP
    USING ERRCODE = 'read_only_sql_transaction';
END;
$$;

DROP TRIGGER IF EXISTS trg_real_payments_no_update ON real_payments;
CREATE TRIGGER trg_real_payments_no_update
  BEFORE UPDATE OR DELETE ON real_payments
  FOR EACH ROW EXECUTE FUNCTION real_payments_immutable();

-- ---------------------------------------------------------------------
-- 2. RPC record_real_payment
-- ---------------------------------------------------------------------
-- Logique :
--   1. adjust_balance(+amount_virtual, type=admin_credit, idem_key)
--      - en replay, retourne la meme transaction + real_payment lies
--      - en nouvelle ecriture, produit une tx neuve
--   2. Si replay, recupere la real_payment existante via transaction_id.
--      Sinon, insere une nouvelle ligne real_payments.
--   3. Retourne transaction_id, real_payment_id, nouveau solde, flag
--      replay.
--
-- Le rigoureux UNIQUE (transaction_id) garantit 1-1 : on ne peut pas
-- avoir deux real_payments pour une meme tx. Si la logique de replay
-- fonctionne, on ne tentera jamais l'INSERT en replay donc pas de
-- conflit UNIQUE.
CREATE OR REPLACE FUNCTION record_real_payment(
  p_client_id        uuid,
  p_building_id      uuid,
  p_amount_real      numeric,
  p_amount_virtual   numeric,
  p_payment_method   text,
  p_reference        text DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_recorded_by      uuid DEFAULT NULL,
  p_idempotency_key  text DEFAULT NULL
) RETURNS TABLE(
  transaction_id    uuid,
  real_payment_id   uuid,
  virtual_balance   numeric,
  idempotent_replay boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tx_id    uuid;
  v_bal      numeric;
  v_replay   boolean;
  v_rp_id    uuid;
BEGIN
  IF p_amount_real IS NULL OR p_amount_real <= 0 THEN
    RAISE EXCEPTION 'invalid_amount_real' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_amount_virtual IS NULL OR p_amount_virtual <= 0 THEN
    RAISE EXCEPTION 'invalid_amount_virtual' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_recorded_by IS NULL THEN
    RAISE EXCEPTION 'missing_recorded_by' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'missing_idempotency_key' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- 1. adjust_balance (credit +amount_virtual)
  SELECT t.transaction_id, t.virtual_balance, t.idempotent_replay
    INTO v_tx_id, v_bal, v_replay
    FROM adjust_balance(
      p_client_id       => p_client_id,
      p_building_id     => p_building_id,
      p_amount          => p_amount_virtual,
      p_type            => 'admin_credit',
      p_reference_type  => 'real_payment',
      p_description     => COALESCE('Paiement ' || p_payment_method, 'Paiement reel'),
      p_idempotency_key => p_idempotency_key,
      p_created_by      => p_recorded_by
    ) t;

  -- 2. Real_payment : replay => lookup, sinon insert
  IF v_replay THEN
    SELECT rp.id INTO v_rp_id
      FROM real_payments rp
     WHERE rp.transaction_id = v_tx_id;
    -- v_rp_id peut etre NULL si l'admin a appele adjust_balance avec
    -- cette meme idem_key mais type autre que real_payment. Dans ce
    -- cas on refuse : l'idem_key ne doit pas etre reutilisee cross-RPC.
    IF v_rp_id IS NULL THEN
      RAISE EXCEPTION 'idempotency_key_not_for_real_payment'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
  ELSE
    INSERT INTO real_payments AS rp (
      transaction_id, client_id, building_id,
      amount_real, amount_virtual, payment_method,
      reference, notes, recorded_by
    ) VALUES (
      v_tx_id, p_client_id, p_building_id,
      p_amount_real, p_amount_virtual, p_payment_method,
      p_reference, p_notes, p_recorded_by
    ) RETURNING rp.id INTO v_rp_id;
  END IF;

  transaction_id    := v_tx_id;
  real_payment_id   := v_rp_id;
  virtual_balance   := v_bal;
  idempotent_replay := v_replay;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION record_real_payment(
  uuid, uuid, numeric, numeric, text, text, text, uuid, text
) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION record_real_payment(
  uuid, uuid, numeric, numeric, text, text, text, uuid, text
) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
