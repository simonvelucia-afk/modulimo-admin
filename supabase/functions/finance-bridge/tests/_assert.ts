// Assertions minimales, sans dependance, pour garder le test suite
// executable meme dans un env ou jsr/deno.land/std ne sont pas accessibles.
// Les signatures imitent @std/assert pour faciliter une migration future.

export function assertEquals<T>(actual: T, expected: T, msg?: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed${msg ? ` (${msg})` : ''}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}

export async function assertRejects(
  fn: () => Promise<unknown>,
  msg?: string,
): Promise<void> {
  let threw = false;
  try {
    await fn();
  } catch {
    threw = true;
  }
  if (!threw) {
    throw new Error(`assertRejects failed : la promesse devait throw${msg ? ` (${msg})` : ''}`);
  }
}
