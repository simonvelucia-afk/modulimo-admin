# finance-bridge — passerelle finance Modulimo (Phase 0)

Edge Function qui valide un JWT signé par l'Auth Supabase d'un immeuble
CoHabitat, résout le `cohabitat_user_id` en `client_id` + `building_id` via
la base centrale, et ré-émet un JWT court-terme pour appeler les RPC
financières centrales.

Voir la spec complète de la Phase 0 dans le ticket de migration (solde
central). Ce README couvre uniquement le déploiement et le test.

## Statut

- **Phase 0** : `/get-balance` stub retourne `virtual_balance: 0.00`.
  L'objectif est de prouver le chemin d'auth bout-en-bout.
- **Phase 1+** : branche les RPC centrales réelles (`get_balance`,
  `list_transactions`, etc.).

## Pré-requis côté base centrale

La migration `building_registry` + `clients.building_id` doit être
déployée avant que cette fonction serve du trafic réel (Phase 0 step 1).

Chaque immeuble inscrit doit exposer un JWKS ES256/RS256 — Supabase Auth
doit être configuré avec une clé asymétrique (sinon on ne peut pas
valider la signature sans détenir leur secret, ce qui casserait
l'isolation).

## Structure

```
finance-bridge/
├── index.ts               Handler HTTP + routing des endpoints
├── lib/
│   ├── types.ts           Types partagés (pas de dépendance)
│   ├── resolve.ts         JWT -> claims centrales (pure, adapters injectés)
│   ├── jwt.ts             Mint du JWT central (HS256)
│   ├── registry.ts        Adapters prod (PostgREST + JWKS distant)
│   └── logger.ts          Log JSON structuré
├── handlers/
│   └── get_balance.ts     Endpoint pilote
├── tests/
│   ├── fixtures.ts        Keypairs ES256 in-memory + adapters fakes
│   ├── cross_tenant_test.ts   Tests de fuite inter-immeuble (CI gate)
│   ├── resolve_test.ts    Edge cases du parser JWT
│   └── jwt_test.ts        Mint + verify roundtrip
└── deno.jsonc             Tasks + fmt + lint
```

## Déploiement

```sh
supabase functions deploy finance-bridge --project-ref bpxscgrbxjscicpnheep
```

Variables d'environnement (toutes sauf `SUPABASE_JWT_SECRET` sont
pré-injectées par Supabase) :

| Variable | Role |
|---|---|
| `SUPABASE_URL` | URL du projet central |
| `SUPABASE_ANON_KEY` | Lecture `building_registry` |
| `SUPABASE_SERVICE_ROLE_KEY` | Lecture `clients` (bypass RLS) |
| `SUPABASE_JWT_SECRET` | Signe le JWT central émis vers PostgREST |

`SUPABASE_JWT_SECRET` est le secret HS256 du projet central ; il ne
quitte jamais cette fonction.

## Appel côté client

```js
const { data, error } = await sb.functions.invoke('finance-bridge/get-balance', {
  body: { dependent_id: null },
});
```

Réponse (Phase 0) :
```json
{
  "client_id": "...",
  "building_id": "...",
  "dependent_id": null,
  "virtual_balance": 0.00,
  "source": "central"
}
```

## Tests locaux

```sh
cd supabase/functions/finance-bridge
deno task test
```

Les tests n'ont **aucune** dépendance réseau : les JWKS, les JWT et la
base centrale sont tous simulés en mémoire.

### Tests critiques en CI

`tests/cross_tenant_test.ts` doit rester vert à tout prix — c'est le
garde-fou qui empêche une régression de laisser l'immeuble A lire les
données de l'immeuble B. Scénarios couverts :

1. JWT de A avec `iss` réécrit vers B → `INVALID_SIGNATURE`
2. JWT forgé avec la mauvaise clé privée → `INVALID_SIGNATURE`
3. JWT valide mais body réclame `client_id` d'un autre → `CLIENT_ID_MISMATCH`
4. `iss` inconnu du registry → `UNKNOWN_ISSUER`
5. Immeuble suspendu → `BUILDING_INACTIVE`
6. `cohabitat_user_id` sans `clients` → `CLIENT_NOT_FOUND`
7. JWT expiré → rejet par `jose`
8. Audience incorrecte → rejet par `jose`
9. Même `cohabitat_user_id` existe dans deux immeubles → lookup par
   `(cohabitat_user_id, building_id)` composé, pas par user seul

## Ajout d'un nouvel immeuble au registre

Opération manuelle, effectuée par un admin Modulimo (pas de RPC publique) :

```sql
INSERT INTO building_registry (name, supabase_url, jwt_issuer, jwks_url, status)
VALUES (
  'Pointe Est',
  'https://uwyhrdjlwetcbtskijrs.supabase.co',
  'https://uwyhrdjlwetcbtskijrs.supabase.co/auth/v1',
  'https://uwyhrdjlwetcbtskijrs.supabase.co/auth/v1/.well-known/jwks.json',
  'active'
);
```

Puis backfiller `clients.building_id` pour les résidents de cet immeuble.

## Prochaine étape

Phase 1 : écrire la migration SQL `building_registry` + `clients.building_id`
+ les RPC `get_balance` et `list_transactions`, puis brancher
`handlers/get_balance.ts` dessus.
