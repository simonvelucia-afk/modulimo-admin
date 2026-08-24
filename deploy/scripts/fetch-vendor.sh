#!/bin/sh
# fetch-vendor.sh — recupere les librairies tierces pour un deploiement
# sans acces Internet. A executer sur une machine CONNECTEE.
set -eu
DEST="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/vendor"
mkdir -p "$DEST"
echo "[vendor] destination : $DEST"
curl -fsSL "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2" -o "$DEST/supabase.js"
curl -fsSL "https://simonvelucia-afk.github.io/modulimo-home/images/favicon_Modulimo.png" -o "$DEST/favicon.png"
echo "[vendor] termine"
