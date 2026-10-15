// Addendum A1 §5.1 — the public gateway flavour. A web buyer has no JWT, so
// the RPCs these gateways call are granted to service_role only and decide
// the tenant themselves from the agent code. CORS limits browsers to
// WEB_ALLOWED_ORIGINS; a request with no Origin (server-side rendering) is
// served, because CORS is not an access control.
import type { Rpc } from "./db.ts";
import type { z } from "./deps.ts";
import { errorResponse, GatewayError } from "./errors.ts";
import { json } from "./http.ts";
import { parseJsonBody, stripTenantKeys } from "./validate.ts";

export type PublicGatewayDeps = { rpc: Rpc; allowedOrigins: string[] };

export type PublicContext<B> = { body: B; rpc: Rpc; req: Request };

export type PublicRoute<S extends z.ZodTypeAny> = {
  method: "GET" | "POST";
  schema: S;
  cacheControl?: string;
};

export function allowedOriginsFromEnv(): string[] {
  return (Deno.env.get("WEB_ALLOWED_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(Boolean);
}

function corsHeaders(origin: string): Record<string, string> {
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type, authorization, apikey, x-client-info",
    "access-control-max-age": "86400",
  };
}

// Responses differ by Origin, so every one says so, or a CDN could serve a
// copy without (or with the wrong) CORS headers to another caller.
const BASE_HEADERS: Record<string, string> = { vary: "Origin" };

function withHeaders(res: Response, headers: Record<string, string>): Response {
  for (const [k, v] of Object.entries(headers)) res.headers.set(k, v);
  return res;
}

function parseQuery<S extends z.ZodTypeAny>(req: Request, schema: S): z.infer<S> {
  const query = Object.fromEntries(new URL(req.url).searchParams);
  const result = schema.safeParse(stripTenantKeys(query));
  if (!result.success) {
    throw new GatewayError(400, "VALIDATION_FAILED", "Request is invalid.", result.error.flatten());
  }
  return result.data;
}

export function publicGateway<S extends z.ZodTypeAny>(
  route: PublicRoute<S>,
  handle: (ctx: PublicContext<z.infer<S>>) => Promise<unknown>,
  deps: PublicGatewayDeps,
): (req: Request) => Promise<Response> {
  return async (req) => {
    const origin = req.headers.get("origin");
    const allowed = origin !== null && deps.allowedOrigins.includes(origin);
    const cors = allowed ? corsHeaders(origin) : {};

    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: allowed ? 204 : 403,
        headers: { ...BASE_HEADERS, ...cors, "cache-control": "no-store" },
      });
    }
    try {
      if (origin !== null && !allowed) {
        throw new GatewayError(403, "ORIGIN_NOT_ALLOWED", "This site may not call this endpoint.");
      }
      if (req.method !== route.method) {
        throw new GatewayError(405, "METHOD_NOT_ALLOWED", `Use ${route.method}.`);
      }
      const body = route.method === "GET" ? parseQuery(req, route.schema) : await parseJsonBody(req, route.schema);
      const result = await handle({ body, rpc: deps.rpc, req });
      return withHeaders(json(200, result), {
        ...BASE_HEADERS,
        ...cors,
        "cache-control": route.cacheControl ?? "no-store",
      });
    } catch (e) {
      return withHeaders(errorResponse(e), { ...BASE_HEADERS, ...cors, "cache-control": "no-store" });
    }
  };
}
