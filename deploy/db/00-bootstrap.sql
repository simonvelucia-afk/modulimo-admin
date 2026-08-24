-- 00-bootstrap.sql — socle Postgres de l'appliance Modulimo Central.
--
-- Reproduit ce qu'un projet Supabase heberge fournit d'office et dont
-- le schema applicatif depend : les roles utilises par PostgREST, le
-- schema `auth` et les fonctions auth.uid()/auth.role()/auth.jwt() sur
-- lesquelles reposent les politiques RLS de la centrale.
--
-- Joue en premier, avant GoTrue. GoTrue creera ensuite ses propres
-- tables (auth.users, auth.sessions, ...) dans ce schema.
-- Idempotent : rejouable a chaque demarrage sans effet de bord.

-- ============================================================
-- 1) Roles
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  -- Role de connexion de PostgREST : il ne peut rien par lui-meme et
  -- bascule (SET ROLE) vers anon/authenticated/service_role selon le
  -- claim `role` du jeton presente.
  -- Mots de passe poses par migrate.sh a partir du .env, jamais ecrits
  -- dans un fichier SQL.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin LOGIN NOINHERIT CREATEROLE;
  END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;

-- ============================================================
-- 2) Schemas
-- ============================================================
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_auth_admin;
CREATE SCHEMA IF NOT EXISTS extensions;

GRANT USAGE ON SCHEMA public     TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA auth       TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;

-- ============================================================
-- 3) Extensions
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp"  WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto     WITH SCHEMA extensions;

-- Le schema applicatif appelle uuid_generate_v4() et gen_random_uuid()
-- sans qualification : on garde `extensions` dans le search_path des
-- roles PostgREST plutot que d'installer les extensions dans public.
ALTER ROLE authenticator        SET search_path = public, extensions;
ALTER ROLE supabase_auth_admin  SET search_path = auth, public, extensions;
DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET search_path = public, extensions', current_database());
END $$;

-- ============================================================
-- 4) Fonctions auth.* attendues par les politiques RLS
-- ============================================================
-- request.jwt.claims est pose par PostgREST a partir du jeton verifie.
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', TRUE), '')::JSONB,
    '{}'::JSONB
  );
$$;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(auth.jwt() ->> 'sub', '')::UUID;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(auth.jwt() ->> 'role', current_setting('role', TRUE));
$$;

CREATE OR REPLACE FUNCTION auth.email()
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
  SELECT auth.jwt() ->> 'email';
$$;

GRANT EXECUTE ON FUNCTION auth.jwt(), auth.uid(), auth.role(), auth.email()
  TO anon, authenticated, service_role;
