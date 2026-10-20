// Cron-invoked system functions (pg_cron -> pg_net) authenticate with a shared
// secret in the x-cron-secret header. D1 plan decision 7.
const enc = new TextEncoder();

// Constant-time: loops over the longer of the two byte arrays (a missing byte
// counts as 0) and folds the length difference into the accumulator, so there
// is no early exit on the first differing byte or on a length mismatch.
export function cronAuthorized(req: Request, secret: string): boolean {
  const given = req.headers.get("x-cron-secret") ?? "";
  if (given.length === 0 || secret.length === 0) return false;
  const a = enc.encode(given);
  const b = enc.encode(secret);
  let diff = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}
