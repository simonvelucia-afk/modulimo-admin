// Verification du role d'admin d'immeuble.
//
// Le role vit dans la base de l'immeuble (profiles.role), pas dans le
// jeton : on le lit via le PostgREST de l'immeuble avec le jeton meme de
// l'appelant. La RLS de l'immeuble autorise un utilisateur a lire son
// propre profil ; personne ne peut donc lire le role d'un autre ni le
// falsifier.
//
// Limite connue : une instance auto-hebergee (auth_mode 'ed25519')
// presente une assertion de federation, que le PostgREST de l'immeuble
// ne reconnait pas. Le role n'est alors pas lisible et la verification
// refuse — fermee par defaut.

export const ADMIN_ROLES = new Set(['admin', 'principal_admin']);

export type FetchAdminRole = (
  buildingUrl: string,
  cohabitatUserId: string,
  bearerJwt: string,
) => Promise<string | null>;

export const fetchAdminRole: FetchAdminRole = async (buildingUrl, cohabitatUserId, bearerJwt) => {
  const url = new URL('/rest/v1/profiles', buildingUrl);
  url.searchParams.set('select', 'role');
  url.searchParams.set('id', `eq.${cohabitatUserId}`);
  url.searchParams.set('limit', '1');
  // PostgREST cote building exige apikey. On reutilise le JWT du caller
  // comme apikey ET Bearer — ca evite d'avoir besoin de la cle anon
  // building dans finance-bridge. Le JWT user satisfait le PostgREST
  // gateway (verifie la signature) puis la RLS autorise SELECT du propre
  // profil.
  try {
    const res = await fetch(url, {
      headers: {
        apikey: bearerJwt,
        Authorization: `Bearer ${bearerJwt}`,
      },
    });
    if (!res.ok) return null;
    const rows = (await res.json()) as Array<{ role?: string }>;
    return rows[0]?.role ?? null;
  } catch {
    return null;
  }
};
