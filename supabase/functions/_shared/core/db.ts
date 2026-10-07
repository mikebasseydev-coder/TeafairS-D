// Spec A §3.1 step 6 / §3.2. A user RPC runs with the caller's own JWT, so
// the database derives actor and tenant itself; the service-role client exists
// only for system-flavoured functions (§3.4).
import { createClient, type SupabaseClient } from "./deps.ts";
import { requireEnv } from "./env.ts";
import { mapPostgresError } from "./errors.ts";

export type Rpc = <T = unknown>(fn: string, args: Record<string, unknown>) => Promise<T>;

const noSession = { persistSession: false, autoRefreshToken: false };

export function rpcFrom(client: SupabaseClient): Rpc {
  return async <T>(fn: string, args: Record<string, unknown>) => {
    const { data, error } = await client.rpc(fn, args);
    if (error) throw mapPostgresError(error);
    return data as T;
  };
}

export function userRpc(authorization: string): Rpc {
  return rpcFrom(createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authorization } },
    auth: noSession,
  }));
}

export function serviceRpc(): Rpc {
  return rpcFrom(createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: noSession,
  }));
}
