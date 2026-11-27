// Write path 1 (Spec B §7): an idempotency-keyed SECURITY DEFINER RPC through
// PostgREST, under the user's JWT. Only the §6.2 App RPCs are callable.
import type { Database } from "./database.types";
import { fromPostgrest, networkError, type Result } from "./errors";
import { APP_RPCS, type AppRpcName } from "./rpc-map";
import { supabase } from "./supabase";

type Fns = Database["public"]["Functions"];
export type RpcArgs<N extends AppRpcName> = Fns[N] extends { Args: infer A } ? A : never;
export type RpcReturn<N extends AppRpcName> = Fns[N] extends { Returns: infer R } ? R : never;

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED: ReadonlySet<string> = new Set(APP_RPCS);

export async function rpc<N extends AppRpcName>(name: N, args: RpcArgs<N>): Promise<Result<RpcReturn<N>>> {
  if (!ALLOWED.has(name)) throw new Error(`${name} is not an App RPC (Spec B §6.2)`);
  const a = (args ?? {}) as Record<string, unknown>;
  if ("p_tenant_id" in a) throw new Error("the client never sends a tenant id (Spec A §9)");
  if ("p_idempotency_key" in a && !(typeof a.p_idempotency_key === "string" && UUID_V4.test(a.p_idempotency_key)))
    throw new Error("p_idempotency_key must be a UUID v4 made at enqueue");
  try {
    // The generated overloads make `rpc`'s own generics too narrow for a mapped name.
    const { data, error, status } = await (supabase().rpc as (n: string, a: object) => PromiseLike<{ data: unknown; error: { code?: string; message?: string; details?: unknown } | null; status: number }>)(name, a);
    if (error) return { ok: false, error: fromPostgrest(error, status) };
    return { ok: true, data: data as RpcReturn<N> };
  } catch (e) {
    return { ok: false, error: networkError(e instanceof Error ? e.message : undefined) };
  }
}
