import { serviceRpc } from "../_shared/core/db.ts";
import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { paystackInitializer } from "../_shared/payments/paystack.ts";
import { createMonveloFundHandler, monveloCheckoutRecorder } from "./handler.ts";

Deno.serve(observe("monvelo-fund", createMonveloFundHandler({
  ...liveUserGatewayDeps(),
  initializeTransaction: paystackInitializer({
    secretKey: requireEnv("PAYSTACK_SECRET_KEY"),
    baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined,
  }),
  // R53: the only service-role call here; it stores the checkout after Initialize
  recordCheckout: monveloCheckoutRecorder(serviceRpc()),
})));
