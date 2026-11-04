// Spec A §3.1 step 6 / §3.2. A user RPC runs with the caller's own JWT, so
// the database derives actor and tenant itself; the service-role client exists
// only for system-flavoured functions (§3.4).
import { createClient, type SupabaseClient } from "./deps.ts";
import { requireEnv } from "./env.ts";
import { mapPostgresError } from "./errors.ts";
import { publishableKey, secretKey } from "./keys.ts";
import { annotateSpan, traced } from "./observability.ts";

export type Rpc = <T = unknown>(fn: string, args: Record<string, unknown>) => Promise<T>;

const noSession = { persistSession: false, autoRefreshToken: false };

// Each call is a db.rpc span named after the function. Arguments never go on
// the span: they carry PINs, phones and proofs.
export function rpcFrom(client: SupabaseClient): Rpc {
  return <T>(fn: string, args: Record<string, unknown>) =>
    traced(`rpc ${fn}`, "db.rpc", { "db.system": "postgresql", "db.operation.name": fn }, async () => {
      const { data, error } = await client.rpc(fn, args);
      if (error) {
        if (error.code) annotateSpan({ "db.sqlstate": error.code });
        const mapped = mapPostgresError(error);
        mapped.sqlstate = error.code || undefined;
        mapped.rpcFunction = fn;
        throw mapped;
      }
      return data as T;
    });
}

export function userRpc(authorization: string): Rpc {
  return rpcFrom(createClient(requireEnv("SUPABASE_URL"), publishableKey(), {
    global: { headers: { Authorization: authorization } },
    auth: noSession,
  }));
}

// R46: only the functions listed in `_tests/service-role-guard.test.ts` may
// call this, each having authenticated its caller first (signature, cron
// secret, hook secret, Turnstile or a capability) — and the RPCs it reaches
// still decide for themselves.
export function serviceRpc(): Rpc {
  return rpcFrom(createClient(requireEnv("SUPABASE_URL"), secretKey(), {
    auth: noSession,
  }));
}
