import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { paystackVerifier } from "../_shared/fintech-liquidity/paystack.ts";
import { createProcessPaymentHandler } from "./handler.ts";

// system-flavoured (§3.4): authenticated by Paystack's signature, runs as service_role
const secretKey = requireEnv("PAYSTACK_SECRET_KEY");

Deno.serve(createProcessPaymentHandler({
  secretKey,
  verifyTransaction: paystackVerifier({ secretKey, baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined }),
  rpc: serviceRpc(),
  now: () => new Date(),
}));
