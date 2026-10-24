import { hookVerifierFromEnv } from "../_shared/auth/hook.ts";
import { serviceRpc } from "../_shared/core/db.ts";
import { createAuthHookHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// system-flavoured (§3.4): no user JWT exists yet, so the claims are read
// with the service-role key — the only non-webhook place it appears.
const verifyHook = hookVerifierFromEnv("AUTH_HOOK_SECRET");
const rpc = serviceRpc();

Deno.serve(observe("auth-verify-claims", createAuthHookHandler({
  verifyHook,
  claimsFor: (userId) => rpc<Record<string, unknown>>("access_token_claims", { p_user_id: userId }),
})));
