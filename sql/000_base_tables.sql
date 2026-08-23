-- 000_base_tables.sql
-- Socle de la centrale Modulimo : les tables métier créées à la main
-- dans le projet Supabase historique et jamais versionnées.
--
-- Sans ce fichier, une installation neuve (appliance en réseau fermé,
-- ou nouveau projet Supabase) s'arrête dès la migration 001, qui
-- ajoute des colonnes à une table `contracts` inexistante — et
-- l'interface d'administration ne peut rien afficher.
--
-- Reconstruit à partir des requêtes réelles de index.html, des clés
-- étrangères des migrations 001 à 025 et des appels des Edge Functions.
-- Numéroté 000 pour s'appliquer en premier.
--
-- Entièrement idempotent : sur la base de production, où tout existe
-- déjà, ce fichier ne fait rien. Les colonnes ajoutées plus tard par
-- 001 (jetons de signature), 005 et 006 (réglages des machines) ne
-- sont volontairement pas reprises ici : leurs migrations les posent.

BEGIN;

-- ============================================================
-- 1) Administrateurs de la centrale
-- ============================================================
CREATE TABLE IF NOT EXISTS profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      TEXT,
  full_name  TEXT,
  role       TEXT NOT NULL DEFAULT 'admin' CHECK (role IN ('admin','viewer')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION handle_new_admin()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_admin_created ON auth.users;
CREATE TRIGGER on_auth_admin_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_admin();

-- ============================================================
-- 2) Réglages généraux
-- ============================================================
CREATE TABLE IF NOT EXISTS app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT,
  description TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 3) Clients — propriétaires d'immeuble et résidents
-- ============================================================
-- client_type distingue le propriétaire (qui signe le contrat de
-- l'immeuble) du résident, rattaché à lui par owner_client_id.
-- cohabitat_user_id fait le lien avec le compte du résident dans
-- l'instance CoHabitat de son immeuble.
CREATE TABLE IF NOT EXISTS clients (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT NOT NULL,
  client_type       TEXT NOT NULL DEFAULT 'local'
                    CHECK (client_type IN ('owner','local','network')),
  owner_client_id   UUID REFERENCES clients(id) ON DELETE SET NULL,
  contact_email     TEXT,
  contact_name      TEXT,
  cohabitat_user_id UUID,
  cohabitat_email   TEXT,
  cohabitat_modules JSONB NOT NULL DEFAULT '{"spaces":true,"trips":true,"lunch":false}'::JSONB,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  pending_approval  BOOLEAN NOT NULL DEFAULT FALSE,
  is_admin          BOOLEAN NOT NULL DEFAULT FALSE,
  admin_building    TEXT,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_clients_owner  ON clients(owner_client_id);
CREATE INDEX IF NOT EXISTS idx_clients_cohab  ON clients(cohabitat_user_id);

-- ============================================================
-- 4) Contrats
-- ============================================================
CREATE TABLE IF NOT EXISTS contracts (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id                 UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  owner_client_id           UUID REFERENCES clients(id) ON DELETE SET NULL,
  type                      TEXT NOT NULL CHECK (type IN ('owner','resident')),
  plan                      TEXT,
  status                    TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','active','suspended','terminated')),
  starts_at                 DATE,
  ends_at                   DATE,
  paid_until                DATE,
  monthly_amount            NUMERIC(10,2),
  billing_mode              TEXT,
  network_flat_fee          NUMERIC(10,2),
  network_commission_pct    NUMERIC(5,2),
  signed_at                 TIMESTAMPTZ,
  signed_by_name            TEXT,
  signature_data            TEXT,
  upgrade_requested_to_plan TEXT,
  upgrade_requested_at      TIMESTAMPTZ,
  notes                     TEXT,
  created_by                TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_contracts_client ON contracts(client_id);
CREATE INDEX IF NOT EXISTS idx_contracts_owner  ON contracts(owner_client_id);

-- ============================================================
-- 5) Licences — un immeuble, un domaine, une base
-- ============================================================
-- C'est par cette table que CoHabitat, au démarrage, sait à quel
-- client il appartient : la recherche se fait sur le domaine servi.
CREATE TABLE IF NOT EXISTS licences (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    UUID REFERENCES clients(id) ON DELETE CASCADE,
  domain       TEXT NOT NULL UNIQUE,
  supabase_url TEXT,
  anon_key     TEXT,
  plan         TEXT,
  max_units    INT DEFAULT 20,
  modules      JSONB NOT NULL DEFAULT '{"trips":true,"lunch":false}'::JSONB,
  active       BOOLEAN NOT NULL DEFAULT TRUE,
  expires_at   DATE,
  notes        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 6) Forfaits
-- ============================================================
CREATE TABLE IF NOT EXISTS plans (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code          TEXT NOT NULL UNIQUE,
  name          TEXT NOT NULL,
  price_monthly NUMERIC(10,2),
  max_units     INT,
  sort_order    INT NOT NULL DEFAULT 1,
  featured      BOOLEAN NOT NULL DEFAULT FALSE,
  active        BOOLEAN NOT NULL DEFAULT TRUE,
  modules       JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS plan_features (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id    UUID NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  label      TEXT NOT NULL,
  included   BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INT NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_plan_features_plan ON plan_features(plan_id);

-- ============================================================
-- 7) Réseaux entre immeubles
-- ============================================================
-- Modèle historique, médié par la centrale : chaque membre publie
-- l'URL et la clé anon de sa base pour que les autres puissent lire
-- ses ressources partagées. Les instances autonomes de CoHabitat
-- utilisent désormais la fédération pair-à-pair, mais la centrale
-- garde ce registre pour les immeubles hébergés.
CREATE TABLE IF NOT EXISTS networks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  description TEXT,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS network_members (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id   UUID NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
  client_id    UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  supabase_url TEXT,
  anon_key     TEXT,
  priority     INT NOT NULL DEFAULT 24,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (network_id, client_id)
);

CREATE TABLE IF NOT EXISTS shared_resources (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id       UUID NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
  source_client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  resource_type    TEXT NOT NULL CHECK (resource_type IN ('space','vehicle')),
  resource_name    TEXT NOT NULL,
  resource_id      UUID NOT NULL,
  priority_hours   INT NOT NULL DEFAULT 24,
  shared_from      DATE,
  shared_to        DATE,
  active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_shared_resources_net ON shared_resources(network_id);

CREATE TABLE IF NOT EXISTS network_balances (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id  UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  network_id UUID NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
  balance    NUMERIC(10,2) NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (client_id, network_id)
);

-- Une ligne par consommation croisée : le résident de A a utilisé une
-- ressource de B. amount_gross est le montant payé, fee_pct la part
-- retenue par Modulimo.
CREATE TABLE IF NOT EXISTS network_transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id       UUID REFERENCES networks(id) ON DELETE SET NULL,
  from_client_id   UUID REFERENCES clients(id) ON DELETE SET NULL,
  to_client_id     UUID REFERENCES clients(id) ON DELETE SET NULL,
  resident_user_id UUID,
  resource_type    TEXT,
  resource_id      UUID,
  resource_name    TEXT,
  amount_gross     NUMERIC(10,2) NOT NULL DEFAULT 0,
  fee_pct          NUMERIC(5,2)  NOT NULL DEFAULT 5,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_network_tx_net ON network_transactions(network_id, created_at DESC);

-- Réconciliation mensuelle affichée dans l'écran Réseaux.
CREATE OR REPLACE VIEW network_monthly_summary AS
  SELECT nt.network_id,
         DATE_TRUNC('month', nt.created_at)::DATE           AS period,
         cf.name                                            AS from_client,
         ct.name                                            AS to_client,
         COUNT(*)                                           AS nb_transactions,
         COALESCE(SUM(nt.amount_gross), 0)::NUMERIC(10,2)   AS total_gross,
         COALESCE(SUM(nt.amount_gross * nt.fee_pct / 100), 0)::NUMERIC(10,2) AS total_fees_modulimo,
         COALESCE(SUM(nt.amount_gross * (100 - nt.fee_pct) / 100), 0)::NUMERIC(10,2) AS total_net_to_owner
    FROM network_transactions nt
    LEFT JOIN clients cf ON cf.id = nt.from_client_id
    LEFT JOIN clients ct ON ct.id = nt.to_client_id
   GROUP BY nt.network_id, DATE_TRUNC('month', nt.created_at), cf.name, ct.name;

-- ============================================================
-- 8) Machines Lunch
-- ============================================================
-- id est fourni par l'exploitant (étiquette physique de la machine),
-- d'où un identifiant texte plutôt qu'un UUID.
CREATE TABLE IF NOT EXISTS lunch_machines (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  pin         TEXT,
  building_id UUID,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS lunch_zones (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id   TEXT NOT NULL REFERENCES lunch_machines(id) ON DELETE CASCADE,
  zone_key     TEXT NOT NULL,
  name         TEXT,
  setpoint     NUMERIC(5,1),
  setpoint_min NUMERIC(5,1),
  setpoint_max NUMERIC(5,1),
  actual       NUMERIC(5,1),
  slot_count   INT NOT NULL DEFAULT 0,
  UNIQUE (machine_id, zone_key)
);

CREATE TABLE IF NOT EXISTS lunch_slots (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id  TEXT NOT NULL REFERENCES lunch_machines(id) ON DELETE CASCADE,
  zone_key    TEXT,
  slot_num    INT NOT NULL,
  description TEXT,
  price       NUMERIC(8,2) NOT NULL DEFAULT 0,
  reserved    BOOLEAN NOT NULL DEFAULT FALSE,
  UNIQUE (machine_id, slot_num)
);

-- ============================================================
-- 9) RLS
-- ============================================================
-- La centrale n'est pas une application publique : tout passe par
-- l'interface d'administration, authentifiée, ou par les Edge
-- Functions en service_role (hors RLS). On active donc RLS partout et
-- on n'ouvre la lecture qu'aux comptes authentifiés.
DO $rls$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','app_config','clients','contracts','licences','plans',
                           'plan_features','networks','network_members','shared_resources',
                           'network_balances','network_transactions','lunch_machines',
                           'lunch_zones','lunch_slots']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = t AND policyname = t || '_admin_all') THEN
      EXECUTE format(
        'CREATE POLICY %I ON %I FOR ALL TO authenticated USING (TRUE) WITH CHECK (TRUE)',
        t || '_admin_all', t);
    END IF;
  END LOOP;
END
$rls$;

-- Le kiosque Lunch lit les machines, zones et cases avec la clé anon :
-- il n'a pas de session. Lecture seule, jamais d'écriture.
DO $anon$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['lunch_machines','lunch_zones','lunch_slots']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = t AND policyname = t || '_anon_read') THEN
      EXECUTE format('CREATE POLICY %I ON %I FOR SELECT TO anon USING (TRUE)', t || '_anon_read', t);
    END IF;
  END LOOP;
END
$anon$;

COMMIT;

NOTIFY pgrst, 'reload schema';
