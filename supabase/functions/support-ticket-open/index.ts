import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { turnstileVerifier } from "../_shared/commerce/turnstile.ts";
import { newTicketSecret } from "../_shared/support/secret.ts";
import { createSupportTicketOpenHandler } from "./handler.ts";

// public-flavoured (A1 §5): anonymous callers, gated by Turnstile; the RPC is service_role only
Deno.serve(createSupportTicketOpenHandler({
  rpc: serviceRpc(),
  allowedOrigins: allowedOriginsFromEnv(),
  verifyTurnstile: turnstileVerifier({
    secretKey: requireEnv("TURNSTILE_SECRET_KEY"),
    url: Deno.env.get("TURNSTILE_VERIFY_URL") || undefined,
  }),
  newSecret: newTicketSecret,
}));
