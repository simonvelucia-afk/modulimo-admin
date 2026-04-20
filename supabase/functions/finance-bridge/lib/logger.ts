// Log structure minimal. Volontairement sans dependance : on ecrit du JSON
// sur stdout et Supabase Logs le collecte.

type Level = 'debug' | 'info' | 'warn' | 'error';

export function log(level: Level, msg: string, fields: Record<string, unknown> = {}) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg,
    ...fields,
  });
  if (level === 'error' || level === 'warn') console.error(line);
  else console.log(line);
}

export function requestId(): string {
  return crypto.randomUUID();
}
