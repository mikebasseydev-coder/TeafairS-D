// R46 (service-role key standard). The only reader of Supabase API keys.
//
// Supabase injects the new keys into Edge Functions as JSON dictionaries keyed
// by the key's name: SUPABASE_SECRET_KEYS ({"default": "sb_secret_…", …}) and
// SUPABASE_PUBLISHABLE_KEYS. The legacy JWT keys (SUPABASE_SERVICE_ROLE_KEY,
// SUPABASE_ANON_KEY) are deprecated by the end of 2026 and stop working once
// they are disabled in the dashboard; until then they are the fallback (the
// local stack may inject only them).
//
// Every secret key carries the same service_role (BYPASSRLS) privilege. A name
// is a label for rotation and revocation, not a scope: choosing
// TEAFAIR_SECRET_KEY_NAME=gateway lets that key be revoked alone, it does not
// narrow what the key can do. Narrowing lives in the database (grants and the
// identity checks inside each RPC).
//
// Never log or return a key. Never expose one under a client prefix
// (EXPO_PUBLIC_, NEXT_PUBLIC_, VITE_): `_tests/secret-scoping.test.ts` fails on it.

export type EnvGet = (name: string) => string | undefined;

const denoEnv: EnvGet = (name) => Deno.env.get(name);

function named(dictionary: string, keyName: string, prefix: string, env: EnvGet): string | null {
  const raw = env(dictionary);
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`${dictionary} is not valid JSON`);
  }
  const value = (parsed as Record<string, unknown> | null)?.[keyName];
  // The dictionary is present, so the new keys are in use: fail closed rather
  // than fall back to a legacy key that may already be disabled.
  if (typeof value !== "string" || value === "") throw new Error(`${dictionary} has no key named "${keyName}"`);
  if (!value.startsWith(prefix)) throw new Error(`${dictionary}["${keyName}"] is not a ${prefix}… key`);
  return value;
}

function legacy(name: string, env: EnvGet): string {
  const value = env(name);
  if (!value) throw new Error(`missing environment variable ${name}`);
  return value;
}

/** The server-only secret key (sb_secret_…), else the legacy service_role JWT. */
export function secretKey(env: EnvGet = denoEnv): string {
  const keyName = env("TEAFAIR_SECRET_KEY_NAME") || "default";
  return named("SUPABASE_SECRET_KEYS", keyName, "sb_secret_", env) ?? legacy("SUPABASE_SERVICE_ROLE_KEY", env);
}

/** The publishable key (sb_publishable_…), else the legacy anon JWT. */
export function publishableKey(env: EnvGet = denoEnv): string {
  const keyName = env("TEAFAIR_PUBLISHABLE_KEY_NAME") || "default";
  return named("SUPABASE_PUBLISHABLE_KEYS", keyName, "sb_publishable_", env) ?? legacy("SUPABASE_ANON_KEY", env);
}

/** A new-format key (not a JWT): it travels on `apikey` only, never as a Bearer token. */
export function isOpaqueKey(key: string): boolean {
  return key.startsWith("sb_secret_") || key.startsWith("sb_publishable_");
}

/** Headers for a raw REST call made with the secret key. */
export function secretKeyHeaders(key: string): Record<string, string> {
  return isOpaqueKey(key) ? { apikey: key } : { apikey: key, authorization: `Bearer ${key}` };
}
