// Spec A §3.1 steps 1–2: verify the JWT, reject anonymous callers, read the
// claims. The claims only PROPOSE a tenant; the RPC re-checks it live (§4.4).
import { createClient } from "./deps.ts";
import { requireEnv } from "./env.ts";
import { GatewayError } from "./errors.ts";

export type Caller = {
  userId: string;
  authorization: string;
  activeTenantId: string | null;
  tenantRole: string | null;
  platformRole: string | null;
};

export type TokenVerifier = (token: string) => Promise<Record<string, unknown> | null>;

const unauthenticated = () => new GatewayError(401, "UNAUTHENTICATED", "Sign in to continue.");
const text = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);

export async function authenticate(req: Request, verify: TokenVerifier): Promise<Caller> {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") ?? "");
  if (!match) throw unauthenticated();

  const claims = await verify(match[1]);
  if (
    !claims || typeof claims.sub !== "string" || claims.role !== "authenticated" ||
    claims.is_anonymous === true
  ) {
    throw unauthenticated();
  }

  const app = (claims.app_metadata ?? {}) as Record<string, unknown>;
  return {
    userId: claims.sub,
    authorization: `Bearer ${match[1]}`,
    activeTenantId: text(app.active_tenant_id),
    tenantRole: text(app.tenant_role),
    platformRole: text(app.platform_role),
  };
}

// getClaims verifies asymmetric tokens locally against the project's JWKS and
// falls back to the Auth server for symmetric ones.
export function supabaseTokenVerifier(): TokenVerifier {
  const client = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return async (token) => {
    const { data, error } = await client.auth.getClaims(token);
    if (error || !data) return null;
    return data.claims as Record<string, unknown>;
  };
}
