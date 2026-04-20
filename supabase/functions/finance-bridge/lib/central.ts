// Appels vers les RPC PostgREST centrales. Separe du handler pour que les
// tests puissent injecter un caller fake sans avoir a mocker fetch global.

export interface CentralCaller {
  callRpc<T = unknown>(
    rpcName: string,
    params: Record<string, unknown>,
    centralJwt: string,
  ): Promise<CentralRpcResult<T>>;
}

export type CentralRpcResult<T> =
  | { ok: true; data: T }
  | { ok: false; status: number; error: string; body?: unknown };

// Implementation production : POST /rest/v1/rpc/<name> avec le JWT central
// mine par mintCentralJwt. PostgREST valide la signature HS256 grace au
// SUPABASE_JWT_SECRET partage, puis applique RLS selon les claims.
export function makePostgrestCaller(centralUrl: string, anonKey: string): CentralCaller {
  return {
    async callRpc<T>(
      rpcName: string,
      params: Record<string, unknown>,
      centralJwt: string,
    ): Promise<CentralRpcResult<T>> {
      const url = new URL(`/rest/v1/rpc/${rpcName}`, centralUrl);
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          apikey: anonKey,
          Authorization: `Bearer ${centralJwt}`,
          'Content-Type': 'application/json',
          // Retourne le body JSON meme en cas d'erreur Postgres.
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
