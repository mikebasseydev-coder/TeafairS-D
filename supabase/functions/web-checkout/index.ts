import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { turnstileVerifier } from "../_shared/commerce/turnstile.ts";
import { paystackInitializer } from "../_shared/fintech-liquidity/paystack.ts";
import { createWebCheckoutHandler } from "./handler.ts";

// public-flavoured (A1 §5): anonymous callers, gated by Turnstile; RPCs are service_role only
Deno.serve(createWebCheckoutHandler({
  rpc: serviceRpc(),
  allowedOrigins: allowedOriginsFromEnv(),
  verifyTurnstile: turnstileVerifier({
    secretKey: requireEnv("TURNSTILE_SECRET_KEY"),
    url: Deno.env.get("TURNSTILE_VERIFY_URL") || undefined,
  }),
  initializeTransaction: paystackInitializer({
    secretKey: requireEnv("PAYSTACK_SECRET_KEY"),
    baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined,
  }),
  newReference: () => `TFW-${crypto.randomUUID()}`,
  callbackUrl: requireEnv("WEB_CHECKOUT_CALLBACK_URL"),
}));
