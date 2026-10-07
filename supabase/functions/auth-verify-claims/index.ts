import { Webhook } from "../_shared/core/deps.ts";
import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { createAuthHookHandler } from "./handler.ts";

// system-flavoured (§3.4): no user JWT exists yet, so the claims are read
// with the service-role key — the only non-webhook place it appears.
const webhook = new Webhook(requireEnv("AUTH_HOOK_SECRET").replace("v1,whsec_", ""));
const rpc = serviceRpc();

Deno.serve(createAuthHookHandler({
  verifyHook: (payload, headers) => webhook.verify(payload, headers),
  claimsFor: (userId) => rpc<Record<string, unknown>>("access_token_claims", { p_user_id: userId }),
}));
