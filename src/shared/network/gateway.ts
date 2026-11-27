// Write path 2 (Spec B §7): an Edge Function wherever a gateway exists, under
// the user's JWT. The body is validated with the gateway's own schema first.
import { FunctionsHttpError } from "@supabase/supabase-js";
import { fromGateway, networkError, type Result } from "./errors";
import { gatewaySchemas, type GatewayBody, type GatewayName } from "./gateways";
import { supabase } from "./supabase";

export async function gateway<G extends GatewayName, R = unknown>(name: G, body: GatewayBody<G>): Promise<Result<R>> {
  const parsed = gatewaySchemas[name].parse(body); // throws in the user's hands, never sent invalid
  if ("tenant_id" in (parsed as object)) throw new Error("the client never sends a tenant id (Spec A §9)");
  try {
    const { data, error } = await supabase().functions.invoke<R>(name, { body: parsed });
    if (!error) return { ok: true, data: data as R };
    if (error instanceof FunctionsHttpError) {
      const res = error.context as Response;
      let json: unknown = null;
      try {
        json = await res.json();
      } catch {
        json = null;
      }
      return { ok: false, error: fromGateway(res.status, json as Parameters<typeof fromGateway>[1]) };
    }
    return { ok: false, error: networkError(error.message) };
  } catch (e) {
    return { ok: false, error: networkError(e instanceof Error ? e.message : undefined) };
  }
}
