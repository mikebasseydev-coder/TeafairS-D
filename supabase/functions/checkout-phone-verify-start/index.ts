import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { turnstileVerifier } from "../_shared/commerce/turnstile.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { generateOtpCode } from "../otp-issue/code.ts";
import { createCheckoutPhoneVerifyStartHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// public-flavoured (A1 §5): anonymous callers, gated by Turnstile; the RPC is service_role only
const rpc = serviceRpc();
Deno.serve(observe("checkout-phone-verify-start", createCheckoutPhoneVerifyStartHandler({
  rpc,
  allowedOrigins: allowedOriginsFromEnv(),
  verifyTurnstile: turnstileVerifier({
    secretKey: requireEnv("TURNSTILE_SECRET_KEY"),
    url: Deno.env.get("TURNSTILE_VERIFY_URL") || undefined,
  }),
  sendMessage: messageRouterFromEnv(rpc),
  generateCode: generateOtpCode,
})));
