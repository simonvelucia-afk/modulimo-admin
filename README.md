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
