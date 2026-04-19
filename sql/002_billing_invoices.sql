-- =====================================================================
-- Migration : facturation + paiements manuels (sans Stripe)
-- Central DB Modulimo (bpxscgrbxjscicpnheep)
-- =====================================================================
-- Apporte : factures détaillées par résident (frais mensuel + usage),
-- enregistrement manuel des paiements (cash/virement/chèque), mode de
-- collecte (proprio ou Modulimo) hérité du plan proprio, % commission
-- unique dans app_config, demande d'upgrade Local→Réseau par le résident.
-- =====================================================================

BEGIN;

-- 1. Colonnes tarification
ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS price_monthly numeric(10,2) DEFAULT 0;

ALTER TABLE contracts
  ADD COLUMN IF NOT EXISTS monthly_amount             numeric(10,2),
  ADD COLUMN IF NOT EXISTS billing_mode               text DEFAULT 'owner_collects'
    CHECK (billing_mode IN ('owner_collects','modulimo_collects')),
  ADD COLUMN IF NOT EXISTS upgrade_requested_to_plan  text,
  ADD COLUMN IF NOT EXISTS upgrade_requested_at       timestamptz;

-- 2. Seed du taux de commission unique (si absent)
INSERT INTO app_config (key, value)
  SELECT 'modulimo_commission_pct', '5'
  WHERE NOT EXISTS (SELECT 1 FROM app_config WHERE key = 'modulimo_commission_pct');

-- 3. Factures
CREATE TABLE IF NOT EXISTS invoices (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id         uuid NOT NULL REFERENCES contracts(id) ON DELETE CASCADE,
  client_id           uuid NOT NULL REFERENCES clients(id),
  owner_client_id     uuid REFERENCES clients(id),
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  issued_at           timestamptz DEFAULT now(),
  due_at              date,
  monthly_fee         numeric(10,2) NOT NULL DEFAULT 0,
  services_subtotal   numeric(10,2) NOT NULL DEFAULT 0,
  total_amount        numeric(10,2) NOT NULL DEFAULT 0,
  commission_pct      numeric(5,2)  NOT NULL DEFAULT 0,
  commission_amount   numeric(10,2) NOT NULL DEFAULT 0,
  net_to_owner        numeric(10,2) NOT NULL DEFAULT 0,
  billing_mode        text NOT NULL DEFAULT 'owner_collects'
                      CHECK (billing_mode IN ('owner_collects','modulimo_collects')),
  status              text NOT NULL DEFAULT 'issued'
                      CHECK (status IN ('draft','issued','paid','overdue','cancelled')),
  paid_at             timestamptz,
  paid_method         text,
  paid_by             text,
  notes               text,
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),
  UNIQUE (contract_id, period_start, period_end)
);

CREATE INDEX IF NOT EXISTS idx_invoices_client     ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_owner      ON invoices(owner_client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_contract   ON invoices(contract_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status     ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_period_end ON invoices(period_end);

CREATE TABLE IF NOT EXISTS invoice_line_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id        uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  category          text NOT NULL DEFAULT 'other'
                    CHECK (category IN ('monthly_fee','space_reservation','trip','trip_charge','lunch','other')),
  description       text NOT NULL,
  quantity          numeric(10,2) NOT NULL DEFAULT 1,
  unit_amount       numeric(10,2) NOT NULL DEFAULT 0,
  total_amount      numeric(10,2) NOT NULL DEFAULT 0,
  transaction_ref   text,            -- id de la transaction tenant (optionnel)
  transaction_date  timestamptz,
  created_at        timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_invoice_lines_invoice ON invoice_line_items(invoice_id);

-- 4. RPC : enregistrer un paiement sur une facture (manuel, cash/etransfer/etc.)
--    Met la facture à 'paid', met à jour contracts.paid_until au period_end
--    et réactive un contrat suspendu le cas échéant.
CREATE OR REPLACE FUNCTION public.record_invoice_payment(
  p_invoice_id  uuid,
  p_method      text DEFAULT 'cash',
  p_paid_by     text DEFAULT NULL,
  p_notes       text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv RECORD;
BEGIN
  SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Facture introuvable'; END IF;
  IF v_inv.status = 'paid' THEN RAISE EXCEPTION 'Facture déjà payée'; END IF;

  UPDATE invoices
     SET status      = 'paid',
         paid_at     = now(),
         paid_method = COALESCE(p_method, 'cash'),
         paid_by     = p_paid_by,
         notes       = CASE WHEN p_notes IS NULL OR p_notes = '' THEN notes
                            ELSE COALESCE(notes || E'\n', '') || p_notes END,
         updated_at  = now()
   WHERE id = p_invoice_id;

  UPDATE contracts
     SET paid_until = GREATEST(COALESCE(paid_until, '1970-01-01'::date), v_inv.period_end),
         status     = CASE WHEN status = 'suspended' THEN 'active' ELSE status END
   WHERE id = v_inv.contract_id;

  RETURN p_invoice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_invoice_payment(uuid, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.record_invoice_payment(uuid, text, text, text) TO anon, authenticated;

-- 5. RPC : demande d'upgrade de forfait par le résident depuis CoHabitat
CREATE OR REPLACE FUNCTION public.request_plan_upgrade(
  p_cohabitat_user_id uuid,
  p_target_plan       text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id   uuid;
  v_contract_id uuid;
BEGIN
  IF p_target_plan NOT IN ('local','network') THEN
    RAISE EXCEPTION 'Plan invalide';
  END IF;

  SELECT id INTO v_client_id FROM clients
   WHERE cohabitat_user_id = p_cohabitat_user_id LIMIT 1;
  IF v_client_id IS NULL THEN RAISE EXCEPTION 'Client introuvable'; END IF;

  SELECT id INTO v_contract_id FROM contracts
   WHERE client_id = v_client_id
     AND type      = 'resident'
     AND status IN ('active','suspended')
   ORDER BY created_at DESC LIMIT 1;
  IF v_contract_id IS NULL THEN RAISE EXCEPTION 'Aucun contrat actif'; END IF;

  UPDATE contracts
     SET upgrade_requested_to_plan = p_target_plan,
         upgrade_requested_at      = now()
   WHERE id = v_contract_id;

  RETURN v_contract_id;
END;
$$;

REVOKE ALL ON FUNCTION public.request_plan_upgrade(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.request_plan_upgrade(uuid, text) TO anon, authenticated;

-- 6. RPC : lister les factures d'un résident (lecture sécurisée pour CoHabitat)
CREATE OR REPLACE FUNCTION public.list_client_invoices(p_cohabitat_user_id uuid)
RETURNS TABLE(
  id                uuid,
  period_start      date,
  period_end        date,
  issued_at         timestamptz,
  due_at            date,
  monthly_fee       numeric,
  services_subtotal numeric,
  total_amount      numeric,
  status            text,
  paid_at           timestamptz,
  paid_method       text,
  billing_mode      text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id uuid;
BEGIN
  SELECT id INTO v_client_id FROM clients
   WHERE cohabitat_user_id = p_cohabitat_user_id LIMIT 1;
  IF v_client_id IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT i.id, i.period_start, i.period_end, i.issued_at, i.due_at,
         i.monthly_fee, i.services_subtotal, i.total_amount,
         i.status, i.paid_at, i.paid_method, i.billing_mode
    FROM invoices i
   WHERE i.client_id = v_client_id
   ORDER BY i.period_end DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_client_invoices(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.list_client_invoices(uuid) TO anon, authenticated;

-- 7. RPC : détail d'une facture (lignes) pour CoHabitat
CREATE OR REPLACE FUNCTION public.get_invoice_detail(
  p_invoice_id        uuid,
  p_cohabitat_user_id uuid
) RETURNS TABLE(
  line_id           uuid,
  category          text,
  description       text,
  quantity          numeric,
  unit_amount       numeric,
  total_amount      numeric,
  transaction_date  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id uuid;
  v_owned_by  uuid;
BEGIN
  SELECT id INTO v_client_id FROM clients
   WHERE cohabitat_user_id = p_cohabitat_user_id LIMIT 1;
  IF v_client_id IS NULL THEN RETURN; END IF;

  SELECT client_id INTO v_owned_by FROM invoices WHERE id = p_invoice_id;
  IF v_owned_by IS NULL OR v_owned_by <> v_client_id THEN RETURN; END IF;

  RETURN QUERY
  SELECT l.id, l.category, l.description,
         l.quantity, l.unit_amount, l.total_amount,
         l.transaction_date
    FROM invoice_line_items l
   WHERE l.invoice_id = p_invoice_id
   ORDER BY l.transaction_date NULLS FIRST, l.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.get_invoice_detail(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.get_invoice_detail(uuid, uuid) TO anon, authenticated;

COMMIT;

-- =====================================================================
-- Rollback
-- =====================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.get_invoice_detail(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.list_client_invoices(uuid);
-- DROP FUNCTION IF EXISTS public.request_plan_upgrade(uuid, text);
-- DROP FUNCTION IF EXISTS public.record_invoice_payment(uuid, text, text, text);
-- DROP TABLE IF EXISTS invoice_line_items;
-- DROP TABLE IF EXISTS invoices;
-- DELETE FROM app_config WHERE key = 'modulimo_commission_pct';
-- ALTER TABLE contracts
--   DROP COLUMN IF EXISTS upgrade_requested_at,
--   DROP COLUMN IF EXISTS upgrade_requested_to_plan,
--   DROP COLUMN IF EXISTS billing_mode,
--   DROP COLUMN IF EXISTS monthly_amount;
-- ALTER TABLE plans DROP COLUMN IF EXISTS price_monthly;
-- COMMIT;
