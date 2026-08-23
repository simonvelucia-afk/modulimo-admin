#!/bin/sh
# migrate.sh — application ordonnee et idempotente du schema central.
#
#   migrate.sh bootstrap   roles, schema auth, extensions (avant GoTrue)
#   migrate.sh app         sql/*.sql (apres GoTrue)
#
# Chaque fichier applique est inscrit dans app_migrations avec l'empreinte
# de son contenu. Un fichier deja applique est saute ; un fichier modifie
# apres coup arrete la migration plutot que de rejouer un SQL qui n'est
# pas forcement rejouable.

set -eu

PHASE="${1:-app}"
PSQL="psql -v ON_ERROR_STOP=1 -q"

wait_for_db() {
  i=0
  until pg_isready -q; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { echo "[migrate] base injoignable"; exit 1; }
    sleep 1
  done
}

ensure_registry() {
  $PSQL -c "CREATE TABLE IF NOT EXISTS app_migrations (
              filename   TEXT PRIMARY KEY,
              checksum   TEXT NOT NULL,
              applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );"
}

apply_once() {
  file="$1"
  name="$(basename "$file")"
  sum="$(sha256sum "$file" | cut -d' ' -f1)"
  known="$($PSQL -tAc "SELECT checksum FROM app_migrations WHERE filename = '$name'")"

  if [ -n "$known" ]; then
    if [ "$known" != "$sum" ]; then
      echo "[migrate] ARRET : $name a change depuis son application."
      echo "[migrate] Creer une nouvelle migration plutot que de modifier celle-ci."
      exit 1
    fi
    echo "[migrate] = $name (deja applique)"
    return 0
  fi

  echo "[migrate] + $name"
  $PSQL -f "$file"
  $PSQL -c "INSERT INTO app_migrations (filename, checksum) VALUES ('$name', '$sum')"
}

wait_for_db

case "$PHASE" in
  bootstrap)
    ensure_registry
    $PSQL -f /db/00-bootstrap.sql
    $PSQL -c "ALTER ROLE authenticator       PASSWORD '${AUTHENTICATOR_PASSWORD}'"
    $PSQL -c "ALTER ROLE supabase_auth_admin PASSWORD '${AUTH_ADMIN_PASSWORD}'"
    echo "[migrate] socle en place"
    ;;

  app)
    ensure_registry
    for f in /app/sql/*.sql; do
      [ -f "$f" ] || continue
      apply_once "$f"
    done
    $PSQL -c "NOTIFY pgrst, 'reload schema'"
    echo "[migrate] schema central a jour"
    ;;

  purge)
    # Purge Loi 25 des candidatures expirees. Sur l'appliance, pg_cron
    # n'est pas installe : c'est le service `maintenance` qui appelle
    # cette phase une fois par jour.
    $PSQL -c "SELECT public.purge_expired_candidatures()" \
      && echo "[maintenance] purge candidatures effectuee" \
      || echo "[maintenance] purge indisponible (fonction absente ?)"
    ;;

  *)
    echo "usage: migrate.sh [bootstrap|app|purge]"
    exit 2
    ;;
esac
