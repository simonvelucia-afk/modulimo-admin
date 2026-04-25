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
  // Ping leger pour le health-check : verifie que PostgREST + DB centrale
  // repondent. Utilise par /health pour que les clients sachent si la
  // centrale est joignable avant d'engager une transaction.
  ping(apiKey: string): Promise<CentralPingResult>;
}

export type CentralRpcResult<T> =
  | { ok: true; data: T }
  | { ok: false; status: number; error: string; body?: unknown };

export interface CentralPingResult {
  ok: boolean;
  status: number;
  latency_ms: number;
  error?: string;
}

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
    async ping(apiKey: string): Promise<CentralPingResult> {
      // Ping = HEAD sur building_registry avec limit=1. C'est la requete la
      // plus legere qui verifie en meme temps : PostgREST repond, l'apikey
      // est valide, la DB est joignable. Pas de body retourne, juste les
      // headers Content-Range. Timeout court pour ne pas bloquer le client.
      const url = new URL('/rest/v1/building_registry', centralUrl);
      url.searchParams.set('select', 'id');
      url.searchParams.set('limit', '1');
      const t0 = performance.now();
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 3000);
      try {
        const res = await fetch(url, {
          method: 'HEAD',
          headers: { apikey: apiKey },
          signal: ctrl.signal,
        });
        const latency_ms = Math.round(performance.now() - t0);
        return { ok: res.ok, status: res.status, latency_ms };
      } catch (err) {
        const latency_ms = Math.round(performance.now() - t0);
        const message = err instanceof Error ? err.message : String(err);
        return { ok: false, status: 0, latency_ms, error: message };
      } finally {
        clearTimeout(timer);
      }
    },
  };
}

