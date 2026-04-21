#!/usr/bin/env bash
# Smoke test de la Phase 1 : appelle /finance-bridge/get-balance avec un
# JWT reel emis par l'Auth Supabase d'un immeuble, et verifie qu'on
# obtient une reponse structuree (peu importe la valeur du solde).
#
# Pre-requis :
#   1. Migration 007_finance_central_phase1.sql appliquee sur la centrale.
#   2. Au moins un immeuble inscrit dans building_registry (voir
#      scripts/register-building.sql.example).
#   3. Le resident a un row clients avec le bon cohabitat_user_id et
#      building_id (backfill manuel).
#   4. Edge Function deployee :
#        supabase functions deploy finance-bridge --project-ref <CENTRAL_REF>
#   5. Un JWT valide recupere depuis le projet immeuble :
#        - Se connecter dans CoHabitat
#        - Console DevTools :
#            (await sb.auth.getSession()).data.session.access_token
#
# Usage :
#   CENTRAL_URL=https://bpxscgrbxjscicpnheep.supabase.co \
#   CENTRAL_ANON_KEY=ey... \
#   BUILDING_JWT=ey... \
#   ./scripts/smoke-test-finance-bridge.sh

set -euo pipefail

: "${CENTRAL_URL:?CENTRAL_URL requis (ex: https://bpxscgrbxjscicpnheep.supabase.co)}"
: "${CENTRAL_ANON_KEY:?CENTRAL_ANON_KEY requis (cle anon du projet central)}"
: "${BUILDING_JWT:?BUILDING_JWT requis (access_token d'un resident authentifie)}"

URL="${CENTRAL_URL}/functions/v1/finance-bridge/get-balance"

echo ">>> POST ${URL}"
echo ">>> JWT len : ${#BUILDING_JWT}"
echo

response=$(mktemp)
status=$(curl -sS -o "${response}" -w '%{http_code}' \
  -X POST "${URL}" \
  -H "Authorization: Bearer ${BUILDING_JWT}" \
  -H "Content-Type: application/json" \
  -H "apikey: ${CENTRAL_ANON_KEY}" \
  --data '{"dependent_id": null}')

echo "=== HTTP ${status} ==="
if command -v jq >/dev/null 2>&1; then
  jq . < "${response}" || cat "${response}"
else
  cat "${response}"
fi
echo

case "${status}" in
  200) echo "OK : la phase 1 tourne de bout en bout." ;;
  401) echo "JWT rejete cote Edge Function. Verifier :"
       echo "  - JWKS de l'immeuble expose ? (curl .../jwks.json)"
       echo "  - JWT non expire ?"
       echo "  - Audience = 'authenticated' ?" ;;
  403) echo "Authenticated mais acces refuse. Verifier :"
       echo "  - L'immeuble est-il dans building_registry et 'active' ?"
       echo "  - Le cohabitat_user_id existe-t-il dans clients avec le bon building_id ?" ;;
  404) echo "Endpoint introuvable. Edge Function deployee ? (supabase functions list)" ;;
  502) echo "La RPC centrale a echoue. Verifier les logs PostgREST." ;;
  *)   echo "Code inattendu." ;;
esac

rm -f "${response}"
