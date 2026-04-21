-- =====================================================================
-- 009_finance_central_phase2.sql
-- Phase 2 : RPC mutants (adjust_balance primitive + lunch_purchase).
--
-- Pose les invariants qui rendent les mouvements de solde sur. Chaque
-- mutation est :
--   * atomique (lock SELECT FOR UPDATE + insert transactions dans la
--     meme transaction PostgreSQL),
--   * idempotente (idempotency_key unique ; un retour a la meme cle
--     ne re-debite pas, il replay l'etat precedent),
--   * fail-closed sur solde insuffisant (raise insufficient_funds),
--   * append-only (les transactions ne peuvent jamais etre modifiees,
--     trigger pose en Phase 1 toujours actif).
--
-- Tout est appelable uniquement par service_role. La frontiere de
-- confiance reste l'Edge Function finance-bridge (Phase 0), qui valide
-- le JWT entrant et passe les claims resolus en parametres explicites.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Table lunch_transactions (audit centrale des achats kiosk)
-- ---------------------------------------------------------------------
-- Mirror de la table CoHabitat locale, mais scopee par building_id et
-- liee via transaction_id au ledger. Permet la vue "achats recents par
-- machine" sans scanner transactions pour filtrer type='lunch_purchase'.
CREATE TABLE IF NOT EXISTS lunch_transactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  uuid NOT NULL REFERENCES transactions(id),
  client_id       uuid NOT NULL REFERENCES clients(id),
  building_id     uuid NOT NULL REFERENCES building_registry(id),
  dependent_balance_id uuid REFERENCES dependent_balances(id),
  machine_id      text NOT NULL,
  slot_id         text,
  buyer_name      text,
  price           numeric(10,2) NOT NULL CHECK (price >= 0),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lunch_tx_client_created
  ON lunch_transactions(client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_lunch_tx_machine_created
  ON lunch_transactions(machine_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_lunch_tx_building_created
  ON lunch_transactions(building_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_lunch_tx_transaction
  ON lunch_transactions(transaction_id);

ALTER TABLE lunch_transactions ENABLE ROW LEVEL SECURITY;

-- Aucune policy pour authenticated/anon : pas d'acces direct. Tout
-- passe par les RPC (service_role bypass RLS car SECURITY DEFINER).

-- service_role a besoin d'acces directs pour les operations admin et
-- pour que les RPC SECURITY DEFINER lancees depuis service_role ne
-- rencontrent pas de permission denied lors des SELECT internes.
-- Standard Supabase : service_role a des GRANTs larges, la securite
-- vient de qui detient la cle (uniquement l'Edge Function).
GRANT SELECT, INSERT ON lunch_transactions TO service_role;
GRANT SELECT, INSERT, UPDATE ON balances TO service_role;
GRANT SELECT, INSERT, UPDATE ON dependent_balances TO service_role;
GRANT SELECT, INSERT ON transactions TO service_role;

-- ---------------------------------------------------------------------
-- 2. RPC adjust_balance (primitive mutation)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION adjust_balance(
  p_client_id         uuid,
  p_building_id       uuid,
  p_amount            numeric,
  p_type              text,
  p_dep_external_id   text DEFAULT NULL,
  p_reference_id      uuid DEFAULT NULL,
  p_reference_type    text DEFAULT NULL,
  p_description       text DEFAULT NULL,
  p_idempotency_key   text DEFAULT NULL,
  p_created_by        uuid DEFAULT NULL,
  p_is_demo           boolean DEFAULT false
) RETURNS TABLE(
  transaction_id    uuid,
  virtual_balance   numeric,
  dependent_id      uuid,
  idempotent_replay boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_existing_id      uuid;
  v_existing_bal     numeric;
  v_existing_client  uuid;
  v_existing_bldg    uuid;
  v_existing_dep     uuid;
  v_current          numeric;
  v_new              numeric;
  v_dep_id           uuid;
  v_tx_id            uuid;
BEGIN
  IF p_client_id IS NULL OR p_building_id IS NULL THEN
    RAISE EXCEPTION 'missing_params'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_amount IS NULL OR p_amount = 0 THEN
    RAISE EXCEPTION 'zero_amount'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotency : si la cle a deja ete utilisee, retourne l'etat
  -- precedent. Defense : la cle doit appartenir au meme (client, building)
  -- pour prevenir qu'un JWT compromis ne lise le ledger d'un autre.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT t.id, t.balance_after, t.client_id, t.building_id, t.dependent_id
      INTO v_existing_id, v_existing_bal, v_existing_client, v_existing_bldg, v_existing_dep
      FROM transactions t
     WHERE t.idempotency_key = p_idempotency_key;
    IF FOUND THEN
      IF v_existing_client <> p_client_id OR v_existing_bldg <> p_building_id THEN
        -- Cle vue sous un autre (client, building) : on refuse plutot
        -- que de leak la balance_after d'un autre tenant.
        RAISE EXCEPTION 'idempotency_key_collision'
          USING ERRCODE = 'unique_violation';
      END IF;
      RETURN QUERY SELECT v_existing_id, v_existing_bal, v_existing_dep, true;
      RETURN;
    END IF;
  END IF;

  -- Verrouillage + lecture du solde courant. On cree la ligne si elle
  -- n'existe pas pour ne pas imposer un provisioning prealable.
  IF p_dep_external_id IS NULL THEN
    -- Solde principal
    INSERT INTO balances (client_id, building_id, virtual_balance)
    VALUES (p_client_id, p_building_id, 0.00)
    ON CONFLICT (client_id) DO NOTHING;

    SELECT b.virtual_balance INTO v_current
      FROM balances b
     WHERE b.client_id = p_client_id AND b.building_id = p_building_id
     FOR UPDATE;

    v_dep_id := NULL;
  ELSE
    -- Solde d'un dependant
    SELECT d.id, d.virtual_balance INTO v_dep_id, v_current
      FROM dependent_balances d
     WHERE d.client_id = p_client_id
       AND d.building_id = p_building_id
       AND d.external_dep_id = p_dep_external_id
     FOR UPDATE;

    IF NOT FOUND THEN
      INSERT INTO dependent_balances (client_id, building_id, external_dep_id, virtual_balance)
      VALUES (p_client_id, p_building_id, p_dep_external_id, 0.00)
      RETURNING id INTO v_dep_id;
      v_current := 0.00;
    END IF;
  END IF;

  v_new := v_current + p_amount;

  -- Fail-closed : on refuse tout mouvement qui ferait passer le solde
  -- en negatif. Le type ne donne PAS d'exception : un 'admin_credit'
  -- avec montant negatif doit quand meme couvrir le solde (c'est une
  -- operation admin de correction qui ne doit pas creer de dette).
  IF v_new < 0 THEN
    RAISE EXCEPTION 'insufficient_funds : requested %, available %',
      p_amount, v_current
      USING ERRCODE = 'check_violation';
  END IF;

  -- Applique le nouveau solde
  IF p_dep_external_id IS NULL THEN
    UPDATE balances SET virtual_balance = v_new
     WHERE client_id = p_client_id AND building_id = p_building_id;
  ELSE
    UPDATE dependent_balances SET virtual_balance = v_new
     WHERE id = v_dep_id;
  END IF;

  -- Ecrit la ligne ledger. Le trigger append-only de Phase 1 empeche
  -- toute mutation ulterieure ; les corrections passent par une ligne
  -- compensatoire (adjust_balance avec le montant inverse).
  INSERT INTO transactions (
    client_id, building_id, dependent_id, amount, balance_after,
    type, reference_id, reference_type, description,
    idempotency_key, created_by, is_demo
  ) VALUES (
    p_client_id, p_building_id, v_dep_id, p_amount, v_new,
    p_type, p_reference_id, p_reference_type, p_description,
    p_idempotency_key, p_created_by, p_is_demo
  ) RETURNING id INTO v_tx_id;

  RETURN QUERY SELECT v_tx_id, v_new, v_dep_id, false;
END;
$$;

REVOKE ALL ON FUNCTION adjust_balance(uuid, uuid, numeric, text, text, uuid, text, text, text, uuid, boolean) FROM public;
REVOKE ALL ON FUNCTION adjust_balance(uuid, uuid, numeric, text, text, uuid, text, text, text, uuid, boolean) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION adjust_balance(uuid, uuid, numeric, text, text, uuid, text, text, text, uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------
-- 3. RPC lunch_purchase (wrapper metier pour le kiosk)
-- ---------------------------------------------------------------------
-- Fait un debit atomique + ecrit la ligne d'audit lunch_transactions.
-- La colonne transaction_id est UNIQUE, donc si un idempotent_replay
-- se produit on retourne la meme ligne audit qu'au premier appel.
CREATE OR REPLACE FUNCTION lunch_purchase(
  p_client_id         uuid,
  p_building_id       uuid,
  p_machine_id        text,
  p_amount            numeric,
  p_idempotency_key   text,
  p_dep_external_id   text DEFAULT NULL,
  p_slot_id           text DEFAULT NULL,
  p_buyer_name        text DEFAULT NULL
) RETURNS TABLE(
  transaction_id    uuid,
  lunch_audit_id    uuid,
  virtual_balance   numeric,
  idempotent_replay boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tx_id      uuid;
  v_bal        numeric;
  v_dep_id     uuid;
  v_replay     boolean;
  v_audit_id   uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount : lunch_purchase requires positive amount'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_machine_id IS NULL OR p_machine_id = '' THEN
    RAISE EXCEPTION 'missing_machine_id'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Debit atomique via la primitive
  SELECT t.transaction_id, t.virtual_balance, t.dependent_id, t.idempotent_replay
    INTO v_tx_id, v_bal, v_dep_id, v_replay
    FROM adjust_balance(
      p_client_id       => p_client_id,
      p_building_id     => p_building_id,
      p_amount          => -p_amount,
      p_type            => 'lunch_purchase',
      p_dep_external_id => p_dep_external_id,
      p_reference_type  => 'lunch_transaction',
      p_description     => 'Lunch machine ' || p_machine_id
                           || CASE WHEN p_buyer_name IS NOT NULL AND p_buyer_name <> ''
                                   THEN ' : ' || p_buyer_name ELSE '' END,
      p_idempotency_key => p_idempotency_key
    ) t;

  -- Audit : si replay, on retrouve la ligne existante liee par
  -- transaction_id (UNIQUE). Sinon on insere. Le INSERT peut faillir
  -- si (par race) deux appels concurrents arrivent avec la meme cle
  -- idempotent — mais adjust_balance serialize deja via le SELECT FOR
  -- UPDATE, donc impossible en pratique.
  IF v_replay THEN
    SELECT lt.id INTO v_audit_id
      FROM lunch_transactions lt
     WHERE lt.transaction_id = v_tx_id;
  ELSE
    INSERT INTO lunch_transactions AS lt (
      transaction_id, client_id, building_id, dependent_balance_id,
      machine_id, slot_id, buyer_name, price
    ) VALUES (
      v_tx_id, p_client_id, p_building_id, v_dep_id,
      p_machine_id, p_slot_id, p_buyer_name, p_amount
    ) RETURNING lt.id INTO v_audit_id;

    -- Lie le ledger a l'audit (champ reference_id) pour la tracabilite
    -- complete. On utilise un UPDATE direct, exceptionnel car
    -- transactions est append-only : on le permet juste pour remplir
    -- une FK de corroboration, pas pour changer la semantique. On
    -- bypasse le trigger en desactivant temporairement.
    --
    -- Alternative cleanup : ne PAS remplir reference_id pour lunch,
    -- l'audit lunch_transactions est deja la source de verite via
    -- transaction_id. C'est ce qu'on fait : plus simple, pas de
    -- contournement du trigger.
  END IF;

  RETURN QUERY SELECT v_tx_id, v_audit_id, v_bal, v_replay;
END;
$$;

REVOKE ALL ON FUNCTION lunch_purchase(uuid, uuid, text, numeric, text, text, text, text) FROM public;
REVOKE ALL ON FUNCTION lunch_purchase(uuid, uuid, text, numeric, text, text, text, text) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION lunch_purchase(uuid, uuid, text, numeric, text, text, text, text) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
