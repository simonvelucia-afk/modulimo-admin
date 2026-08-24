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

`finance-bridge` n'accepte que les immeubles inscrits au registre, et
seulement eux. Deux façons pour un immeuble de prouver l'identité de ses
résidents, selon la façon dont il est déployé :

| Mode | Pour qui | Ce que la centrale détient |
|---|---|---|
| `jwks` | immeuble hébergé sur Supabase | rien — elle interroge les JWKS du projet |
| `ed25519` | instance auto-hébergée, jointe par VPN | la **clé publique** de l'instance |

**Immeuble hébergé** — inchangé :

```bash
./modulimo building add <uuid> "Pointe-Est" https://xxx.supabase.co \
    https://xxx.supabase.co/auth/v1/.well-known/jwks.json
```

**Instance auto-hébergée** — le VPN doit être monté, puis :

```bash
./modulimo building enroll https://cohabitat.pointe-est.lan "Pointe-Est"
```

La centrale lit `/federation/v1/identity` sur l'instance et enregistre sa
clé publique Ed25519. Côté instance, il reste à mettre `CENTRAL_ENABLED=true`
et `CENTRAL_URL` dans son `.env`, puis `./cohabitat init && ./cohabitat up`.

### Pourquoi deux modes

Une instance auto-hébergée signe les jetons de ses résidents en **HS256**,
avec un secret local, et n'expose aucun JWKS : la centrale ne peut pas les
vérifier. Lui confier ce secret serait pire — il permettrait de fabriquer
le jeton de n'importe quel résident.

L'instance vérifie donc le jeton **chez elle**, puis présente une
assertion courte (60 s) signée avec la clé privée de sa fédération. La
centrale n'en détient que la clé publique : elle vérifie, elle n'usurpe
pas. L'assertion prend la forme attendue par `finance-bridge`
(`iss` = `jwt_issuer`, `aud` = `authenticated`, `sub` = l'identifiant du
résident), ce qui laisse sa logique de résolution inchangée.

Concrètement, l'interface du résident n'appelle plus la centrale
directement : elle passe par la passerelle de fédération de son
immeuble, qui signe pour elle. Le secret local ne quitte jamais le
bâtiment.

### Le VPN dans une flotte mixte

Une centrale sert en général les deux à la fois : des immeubles hébergés,
joints par Internet, et des instances installées chez le client, jointes
par VPN. Chaque instance auto-hébergée est donc un tunnel de plus à
maintenir — et le lien porte de l'argent, pas seulement de la lecture.

Ce que cela implique en pratique :

- **Le tunnel est bidirectionnel.** L'instance appelle `finance-bridge`
  pour les soldes et les débits ; la centrale appelle l'instance pour
  `finance-sync` et pour `enroll`. Les règles de pare-feu doivent laisser
  passer les deux sens.
- **Une coupure n'est pas une panne.** L'instance continue de servir ses
  résidents ; seuls les écrans qui dépendent de la centrale (solde
  central, Machine Lunch, facturation) se dégradent, et la sonde
  `/health` affiche la bannière hors-ligne. Les opérations financières
  déjà engagées sont rejouées avec la même clé d'idempotence.
- **Les adresses doivent être stables.** `jwt_issuer` est enregistré au
  moment de l'`enroll` : changer l'URL VPN d'une instance invalide son
  entrée au registre. Prévoir des adresses fixes dans le plan
  d'adressage du VPN plutôt que du DHCP.
- **Une instance compromise reste bornée.** Sa clé ne signe que pour ses
  propres résidents, et `./modulimo building` permet de la passer en
  `suspended` sans toucher aux autres.

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
| `finance-bridge` renvoie `INVALID_SIGNATURE` | mode `jwks` : JWKS injoignable. Mode `ed25519` : clé publique périmée — refaire `./modulimo building enroll` |
| `finance-bridge` renvoie `UNKNOWN_ISSUER` | l'URL VPN de l'instance a changé depuis son enregistrement |
| Le `build` des fonctions échoue | il a besoin d'Internet : construire l'image sur une machine connectée, puis transporter |
