// Spec A §4.4 — Custom Access Token Hook. Supabase Auth calls this, signed
// with Standard Webhooks, every time it mints an access token. The claim rules
// live in public.access_token_claims (pgTAP-tested); this is the HTTP shell.
// Claims PROPOSE; every RPC re-checks tenant_users live.
import { z } from "../_shared/core/deps.ts";
import { json } from "../_shared/core/http.ts";

export type AuthHookDeps = {
  verifyHook: (payload: string, headers: Record<string, string>) => unknown;
  claimsFor: (userId: string) => Promise<Record<string, unknown>>;
};

const hookEvent = z.object({
  user_id: z.string().uuid(),
  claims: z.record(z.unknown()),
}).passthrough();

const hookError = (status: number, message: string) => json(status, { error: { http_code: status, message } });

export function createAuthHookHandler(deps: AuthHookDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    const payload = await req.text();

    let signed: unknown;
    try {
      signed = deps.verifyHook(payload, Object.fromEntries(req.headers));
    } catch {
      return hookError(401, "invalid hook signature");
    }

    const event = hookEvent.safeParse(signed);
    if (!event.success) return hookError(400, "unexpected hook payload");

    try {
      const tenant = await deps.claimsFor(event.data.user_id);
      const appMetadata = { ...((event.data.claims.app_metadata as Record<string, unknown>) ?? {}), ...tenant };
      return json(200, { claims: { ...event.data.claims, app_metadata: appMetadata } });
    } catch (e) {
      console.error("access_token_claims failed", e);
      return hookError(500, "could not load tenant claims");
    }
  };
}
