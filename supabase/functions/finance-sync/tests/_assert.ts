export function assertEquals<T>(actual: T, expected: T, msg?: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(
      `assertEquals failed${msg ? ` (${msg})` : ''}\n  actual:   ${a}\n  expected: ${e}`,
    );
  }
}
