import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { paystackVerifier } from "../_shared/payments/paystack.ts";
import { paystackRefundLister } from "../_shared/payments/paystack-refunds.ts";
import { createProcessPaymentHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// system-flavoured (§3.4): authenticated by Paystack's signature, runs as service_role
const secretKey = requireEnv("PAYSTACK_SECRET_KEY");

Deno.serve(observe("process-payment", createProcessPaymentHandler({
  secretKey,
  verifyTransaction: paystackVerifier({ secretKey, baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined }),
  listRefunds: paystackRefundLister({ secretKey, baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined }),
  rpc: serviceRpc(),
  now: () => new Date(),
})));
