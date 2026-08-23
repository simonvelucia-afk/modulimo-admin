# Fonctions serveur de la centrale — Deno.
#
# Les dependances (jose, supabase-js, std/http) sont mises en cache AU
# MOMENT DE LA CONSTRUCTION de l'image, sur une machine connectee. En
# reseau ferme, plus rien n'est telecharge au demarrage : c'est ce qui
# rend ces fonctions utilisables hors ligne, contrairement a un
# deploiement Supabase classique qui resout ses imports a chaud.
FROM denoland/deno:alpine-2.1.4

WORKDIR /app
COPY supabase/functions/ /app/

# Une passe de cache par fonction : un import cassé se voit ici, a la
# construction, et non en production.
RUN for f in /app/*/index.ts; do echo "cache $f"; deno cache "$f"; done

USER deno
EXPOSE 8000

CMD ["run", "--allow-net", "--allow-env", "--allow-read", "/app/finance-bridge/index.ts"]
