# modulimo-admin

## Déploiement

Deux façons de déployer, à partir du même code :

- **Hébergé** — interface sur GitHub Pages, base et fonctions sur Supabase.
- **Appliance autonome** — tout tourne sur une machine que vous possédez,
  en réseau fermé. Voir **[`deploy/README.md`](deploy/README.md)**.

Aucune URL ni clé n'est écrite dans `index.html` : la configuration vit
dans **`config.js`**, que l'appliance remplace par sa version générée.

Sur une base neuve, appliquer `sql/*.sql` dans l'ordre des numéros
(`000_base_tables.sql` en premier : il contient le socle métier —
clients, contrats, licences, forfaits, réseaux, machines Lunch — que les
migrations suivantes présupposent).

La Machine Lunch ne se gère plus ici : elle est installée dans un immeuble et vit
dans sa base CoHabitat (machines, cases, menus, achats — migration 037 de
CoHabitat, onglet Admin → Paramètres). Les tables `lunch_*` de la centrale ne
gardent que l'historique des anciens achats, toujours inclus dans l'export des
données d'un client.

## Sécurité de la centrale

La clé anon de la centrale est publique (dans `config.js`). Elle ne doit
rien pouvoir lire ni modifier, hormis la signature d'un contrat par lien
à jeton et le registre des immeubles (`sql/030_fermer_acces_public.sql`,
test `sql/tests/acces_public_test.sql`).

Tout compte connecté est traité en administrateur : **les inscriptions
doivent rester fermées** sur le projet Supabase de la centrale
(Authentication → Sign In / Providers → « Allow new users to sign up »
désactivé). Les comptes se créent à la main, depuis le tableau de bord
Supabase.

Ne pas ajouter de politique à la main dans l'interface Supabase : passer
par une migration de `sql/`, pour qu'elle se relise et se teste.
