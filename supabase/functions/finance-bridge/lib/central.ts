// Appels vers les RPC PostgREST centrales. Separe du handler pour que les
// tests puissent injecter un caller fake sans avoir a mocker fetch global.
//
// Modele d'auth apres migration vers les nouvelles Supabase API keys :
// on envoie UNIQUEMENT un header `apikey` avec une valeur de type
// sb_secret_... (ou legacy JWT tant qu'il reste valide). Pas de header
// Authorization Bearer — PostgREST mappe automatiquement l'apikey au bon
// role (service_role pour un secret, anon pour un publishable).

export interface CentralCaller {
  callRpc<T = unknown>(
    rpcName: string,
    params: Record<string, unknown>,
    apiKey: string,
  ): Promise<CentralRpcResult<T>>;
}

export type CentralRpcResult<T> =
  | { ok: true; data: T }
  | { ok: false; status: number; error: string; body?: unknown };

export function makePostgrestCaller(centralUrl: string): CentralCaller {
  return {
    async callRpc<T>(
      rpcName: string,
      params: Record<string, unknown>,
      apiKey: string,
    ): Promise<CentralRpcResult<T>> {
      const url = new URL(`/rest/v1/rpc/${rpcName}`, centralUrl);
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          apikey: apiKey,
          'Content-Type': 'application/json',
          Prefer: 'return=representation',
        },
        body: JSON.stringify(params),
      });
      let body: unknown;
      const text = await res.text();
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = text;
      }
      if (!res.ok) {
        return { ok: false, status: res.status, error: 'RPC_FAILED', body };
      }
      return { ok: true, data: body as T };
    },
  };
}

