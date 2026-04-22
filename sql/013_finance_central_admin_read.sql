-- =====================================================================
-- 013_finance_central_admin_read.sql
-- Permet a modulimo-admin (UI behind auth) de lire les tables finance
-- pour afficher l'onglet Soldes. Meme pattern permissif que la PR Phase 3A
-- l'a fait pour invoices/invoice_line_items/network_settlements :
-- "authenticated a acces complet, la securite vient de qui peut se
-- connecter au projet modulimo-admin".
--
-- Note : les RPC finance mutantes (adjust_balance, lunch_purchase,
-- record_real_payment, reconcile_*) restent service_role-only. Seule
-- la LECTURE est ouverte aux authenticated.
-- =====================================================================

BEGIN;

-- balances
DROP POLICY IF EXISTS bal_select_authenticated ON balances;
CREATE POLICY bal_select_authenticated ON balances
  FOR SELECT TO authenticated USING (TRUE);

-- dependent_balances
DROP POLICY IF EXISTS depbal_select_authenticated ON dependent_balances;
CREATE POLICY depbal_select_authenticated ON dependent_balances
  FOR SELECT TO authenticated USING (TRUE);

-- transactions (lecture seule, append-only deja garanti par trigger)
DROP POLICY IF EXISTS tx_select_authenticated ON transactions;
CREATE POLICY tx_select_authenticated ON transactions
  FOR SELECT TO authenticated USING (TRUE);

-- real_payments
DROP POLICY IF EXISTS rp_select_authenticated ON real_payments;
CREATE POLICY rp_select_authenticated ON real_payments
  FOR SELECT TO authenticated USING (TRUE);

-- divergence_log : utile pour la page "Diagnostic" future
DROP POLICY IF EXISTS div_select_authenticated ON divergence_log;
CREATE POLICY div_select_authenticated ON divergence_log
  FOR SELECT TO authenticated USING (TRUE);

-- sync_cursor : idem
DROP POLICY IF EXISTS sc_select_authenticated ON sync_cursor;
CREATE POLICY sc_select_authenticated ON sync_cursor
  FOR SELECT TO authenticated USING (TRUE);

COMMIT;

NOTIFY pgrst, 'reload schema';
