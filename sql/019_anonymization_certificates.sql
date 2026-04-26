-- 019_anonymization_certificates.sql
-- Phase G Loi 25 : preuve probante d'anonymisation conservee 6 ans.
--
-- Pourquoi : si un ancien client conteste plus tard ("vous avez garde
-- mes donnees"), Modulimo doit pouvoir prouver ce qui a ete anonymise,
-- quand, et par qui. Sans cette table, la traceabilite repose
-- uniquement sur clients.anonymized_at qui ne capture pas les PII
-- d'avant l'effacement.
--
-- Strategie de minimisation (Loi 25 art. 21) :
--   * Conserver UNIQUEMENT le minimum legal : nom, logement, date,
--     admin signataire. Pas d'email, pas de notes superflues.
--   * Hash SHA-256 du contenu pour prouver l'integrite a posteriori.
--   * Append-only via RLS : aucune UPDATE/DELETE possible une fois
--     le certificat emis (sauf purge auto a 6 ans via SECURITY DEFINER).
--
-- Recevabilite legale (LRQ c. C-1.1, art. 5) :
--   * Hash SHA-256 = preuve d'integrite
--   * Timestamp Postgres now() (non-manipulable par les admins users)
--   * Admin signataire identifiable
--   * Code source auditable
--   Suffisant pour TAL et petites creances. Pour Cour superieure,
--   ajouter un timestamping RFC 3161 (FreeTSA) en couche additionnelle.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS anonymization_certificates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id       uuid NOT NULL REFERENCES clients(id),

  -- Snapshot minimal des PII au moment T (avant effacement) :
  subject_name    text NOT NULL,
  subject_unit    text,
  building_name   text,

  -- Preuve :
  anonymized_at   timestamptz NOT NULL DEFAULT now(),
  anonymized_by   uuid,                            -- auth.users.id de l'admin
  admin_email     text,                            -- denormalise (l'admin peut etre supprime)

  -- Integrite : hash des champs ci-dessus pour detecter alteration.
  content_sha256  text NOT NULL,

  -- Conservation : 6 ans aligne sur la prescription fiscale Quebec.
  retention_until timestamptz NOT NULL DEFAULT (now() + interval '6 years'),

  -- Si on doit ajouter un commentaire de contexte (ex : "demande email
  -- du resident le X"), c'est ici. Optionnel.
  reason          text
);

CREATE INDEX IF NOT EXISTS idx_anon_certs_client     ON anonymization_certificates(client_id);
CREATE INDEX IF NOT EXISTS idx_anon_certs_retention  ON anonymization_certificates(retention_until);

-- Append-only via RLS : on autorise INSERT (par les RPC SECURITY
-- DEFINER) et SELECT (par les admins), mais pas UPDATE/DELETE.
ALTER TABLE anonymization_certificates ENABLE ROW LEVEL SECURITY;

-- Aucune policy pour UPDATE ou DELETE => aucun role ne peut modifier
-- ou supprimer une fois insere (sauf service_role qui bypasse RLS,
-- mais ses appels sont restraints aux RPC SECURITY DEFINER).

-- SELECT : autorise pour les admins authentifies (compte sur le projet
-- central, ce qui est equivalent a admin Modulimo car les residents
-- n'ont pas de compte ici).
CREATE POLICY anon_certs_select_authenticated
  ON anonymization_certificates FOR SELECT TO authenticated
  USING (true);

-- INSERT : refuse pour tout role normal. Les certificats ne peuvent
-- etre crees que via les RPC SECURITY DEFINER (anonymize_client_central
-- modifiee dans 020) qui s'executent avec les droits owner de la
-- fonction et bypassent la RLS.
-- (Pas de policy INSERT => deny par defaut sauf service_role.)


-- Helper : calcule le hash SHA-256 d'un certificat. Sert a la fois a
-- l'INSERT (RPC anonymize) et a la verification a posteriori.
CREATE OR REPLACE FUNCTION compute_anon_certificate_hash(
  p_subject_name  text,
  p_subject_unit  text,
  p_building_name text,
  p_anonymized_at timestamptz,
  p_admin_email   text
) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT encode(digest(
    coalesce(p_subject_name, '') || '|' ||
    coalesce(p_subject_unit, '') || '|' ||
    coalesce(p_building_name, '') || '|' ||
    to_char(p_anonymized_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' ||
    coalesce(p_admin_email, ''),
    'sha256'), 'hex')
$fn$;

COMMENT ON TABLE anonymization_certificates IS
  'Loi 25 : preuve probante d''anonymisation. Append-only, conservee 6 ans
  (prescription fiscale Quebec). Le hash SHA-256 garantit l''integrite si
  conteste. Acces SELECT pour admins, aucune modification possible.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ROLLBACK (irreversible si rows existent — la table est append-only par design) :
--   DROP TABLE anonymization_certificates;
--   DROP FUNCTION compute_anon_certificate_hash(text, text, text, timestamptz, text);
