# Modulimo Central — appliance autonome

Déploie la centrale comme un logiciel installé : clients, contrats,
licences, forfaits, réseaux entre immeubles, facturation, machines
Lunch et les six fonctions serveur, sur une machine que vous possédez.

Même forme que l'appliance CoHabitat : un fichier `.env`, un outil en
ligne de commande, un seul port ouvert.

---

## Ce que contient la pile

| Service | Rôle | Exposé ? |
|---|---|---|
| `db` | PostgreSQL 16 — données de la centrale | non |
| `auth` | GoTrue — comptes administrateurs | non |
| `rest` | PostgREST — l'API de l'interface d'admin | non |
| `fn-*` (×6) | Fonctions serveur Deno | non |
| `maintenance` | Purge Loi 25 quotidienne | non |
| `web` | Caddy — interface + routage | **oui** |

Les six fonctions : `finance-bridge` (soldes et débits inter-immeubles),
`finance-sync`, `loi25-process` (export et anonymisation),
`send-email`, `submit-candidature`, `submit-lead-pointe-est`.

## Installation

```bash
cd deploy
cp .env.example .env
$EDITOR .env                    # SITE_URL, SITE_HOST, ports

./scripts/fetch-vendor.sh       # sur une machine connectée
./modulimo init
./modulimo up
./modulimo admin vous@modulimo.lan   # premier compte administrateur
```

Les inscriptions sont fermées (`DISABLE_SIGNUP=true`) : les comptes
administrateurs se créent uniquement par `./modulimo admin`, qui affiche
un mot de passe temporaire.

Si CoHabitat tourne sur la même machine, garder les ports par défaut
(8080/8443 ici, 80/443 pour CoHabitat).

## Réseau fermé : ce qui change

- **Les fonctions ne téléchargent plus rien.** Sur Supabase, elles
  résolvent leurs imports (`jose`, `supabase-js`, `std/http`) au
  démarrage. Ici, `deno cache` s'exécute à la construction de l'image,
  sur une machine connectée : l'image transportée est complète. Un import
  cassé se voit au `build`, pas en production.
- **Pas de `pg_cron`.** L'image Postgres standard ne l'a pas. La
  migration 023 ne planifie donc plus rien si l'extension est absente ;
  c'est le service `maintenance` qui appelle `purge_expired_candidatures()`
  une fois par jour. `./modulimo purge` la déclenche à la demande.
- **Les courriels restent optionnels.** `send-email` passe par Resend,
  le seul service externe. Sans `RESEND_KEY`, la fonction refuse
  proprement et tout le reste continue de fonctionner.
- **Pas de Vault ni de `pg_net`.** Ils n'apparaissent que dans des
  commentaires des migrations ; rien ne les utilise réellement.

## Immeubles autorisés

`finance-bridge` n'accepte que les immeubles inscrits au registre :

```bash
./modulimo building list
./modulimo building add <uuid> "Pointe-Est" https://cohabitat.pointe-est.lan \
    https://cohabitat.pointe-est.lan/auth/v1/.well-known/jwks.json
```

**Limite importante pour les instances autonomes.** `finance-bridge`
vérifie les jetons des résidents via les **JWKS** de leur instance. Une
instance CoHabitat auto-hébergée signe ses jetons en HS256 et n'expose
pas de JWKS : le lien financier centrale ↔ instance autonome ne
fonctionne donc pas encore. Ce n'est pas bloquant pour un réseau fermé —
les transactions entre immeubles autonomes passent par la fédération
pair-à-pair de CoHabitat, qui ne demande rien à la centrale. Pour
brancher aussi la centrale, la voie propre est de réutiliser l'identité
Ed25519 de la fédération plutôt que les JWKS ; c'est le prochain
chantier, il n'est pas fait.

Les immeubles **hébergés** sur Supabase, eux, continuent de fonctionner
normalement avec ce registre.

## Sauvegarde

```bash
./modulimo backup /mnt/sauvegardes
```

Deux fichiers : le dump et une archive des secrets. **Les deux sont
nécessaires** — sans `JWT_SECRET`, plus aucune session n'est vérifiable.
Conserver l'archive des secrets ailleurs que le dump.

## Mises à jour

```bash
git pull
./modulimo migrate
./modulimo up
```

Chaque fichier SQL est appliqué une seule fois et suivi par empreinte ;
un fichier modifié après coup arrête la migration au lieu de rejouer un
script qui ne l'est pas.

## Diagnostic

| Symptôme | Piste |
|---|---|
| `./modulimo up` puis 502 sur l'admin | `docker compose logs rest db-migrate` |
| Une fonction répond 503 | vérifier ses variables dans `.env` (`RESEND_KEY` pour `send-email`) |
| `finance-bridge` renvoie `UNKNOWN_BUILDING` | l'immeuble n'est pas dans `building_registry` (`./modulimo building add`) |
| `finance-bridge` renvoie `INVALID_SIGNATURE` | JWKS injoignable — voir la limite ci-dessus pour les instances autonomes |
| Le `build` des fonctions échoue | il a besoin d'Internet : construire l'image sur une machine connectée, puis transporter |
