-- 027_finance_types_mobilite.sql
-- Accepter les types de transaction de la mobilite partagee.
--
-- CoHabitat a ouvert la reservation directe d'un vehicule : un residant
-- reserve une minivan ou un velomobile sur un creneau, le solde est
-- debite au temps d'utilisation, et une annulation faite plus de deux
-- heures avant le debut est remboursee. Deux types de ligne apparaissent
-- donc au grand livre : 'vehicle_reservation' (debit) et
-- 'vehicle_reservation_refund' (credit).
--
-- Sans cette migration, adjust_balance rejette l'insertion et CoHabitat
-- annule la reservation qu'il venait de creer : la fonction reste
-- inutilisable sur tout immeuble branche a la centrale. Le pendant local
-- est sql/031_mobilite_partagee.sql cote CoHabitat, et la liste blanche
-- de finance-bridge (handlers/debit.ts) est etendue dans le meme lot.
--
-- Au passage, un type manquant depuis plus longtemps : 'lunch_cancel_refund'.
-- finance-bridge l'accepte dans ALLOWED_REFUND_TYPES depuis la phase P3
-- du kiosque, mais il n'a jamais ete ajoute ici — le CHECK date de la
-- migration 014, anterieure. Un remboursement d'annulation lunch passe
-- donc le pont puis echoue sur la contrainte. Il rejoint la liste.

BEGIN;

-- ---------------------------------------------------------------------
-- Etendre le whitelist de transactions.type
-- ---------------------------------------------------------------------
-- Meme precaution qu'en 014 : le CHECK est inline dans le CREATE TABLE de
-- sql/007, son nom est auto-genere. On le retrouve dans pg_constraint
-- plutot que de parier sur 'transactions_type_check'.
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

-- La liste reprend celle de 014 sans rien en retirer : toute ligne qui
-- satisfaisait l'ancienne contrainte satisfait la nouvelle, l'ALTER ne
-- peut donc pas echouer sur les donnees en place.
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
    -- Transfert atomique parent -> dependant (Phase 3D, migration 014)
    'transfer_to_dependent',        -- ligne ledger cote parent (debit)
    'transfer_from_parent',         -- ligne ledger cote dependant (credit)
    -- Annulation d'une cueillette lunch deja pre-debitee (kiosque P3).
    -- Accepte par finance-bridge depuis longtemps, jamais ajoute ici.
    'lunch_cancel_refund',
    -- Mobilite partagee : reservation directe d'un vehicule
    'vehicle_reservation',          -- debit, au temps d'utilisation
    'vehicle_reservation_refund'    -- credit, annulation > 2 h avant
  ));

COMMIT;

NOTIFY pgrst, 'reload schema';
