// Endpoint /health : ping infrastructure pour que les clients sachent si
// la centrale est joignable AVANT d'engager une transaction (achat lunch,
// reservation espace, etc.). Pas d'authentification : la reponse ne
// revele rien de sensible (juste "central up/down" + latence).
//
// L'idee est qu'un client (CoHabitat, kiosque LunchMachine) poll cet
// endpoint toutes les ~60 s + au boot + sur l'evenement window 'online',
// et grise les boutons d'action quand la reponse n'est pas ok. Ca evite
// qu'un usager se retrouve avec un plat livre sans debit, ou une
// reservation creee localement sans contrepartie centrale.

import type { CentralCaller } from '../lib/central.ts';

export interface HealthOkResponse {
  ok: true;
  latency_ms: number;
  ts: string;
}

export interface HealthErrorResponse {
  ok: false;
  error: string;
  latency_ms?: number;
  detail?: unknown;
}

export async function handleHealth(
  caller: CentralCaller,
  serviceRole: string,
): Promise<{ status: number; body: HealthOkResponse | HealthErrorResponse }> {
  if (!serviceRole) {
    return { status: 503, body: { ok: false, error: 'SERVICE_ROLE_MISSING' } };
  }
  const res = await caller.ping(serviceRole);
  if (!res.ok) {
    return {
      status: 503,
      body: {
        ok: false,
        error: 'CENTRAL_UNREACHABLE',
        latency_ms: res.latency_ms,
        detail: { status: res.status, message: res.error ?? null },
      },
    };
  }
  return {
    status: 200,
    body: {
      ok: true,
      latency_ms: res.latency_ms,
      ts: new Date().toISOString(),
    },
  };
}
