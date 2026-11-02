import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { paystackInitializer } from "../_shared/payments/paystack.ts";
import { createMonveloFundHandler } from "./handler.ts";

// Must equal the Vault secret `gateway_secret` (see .env.example); R59
const gatewaySecret = requireEnv("GATEWAY_SECRET");

Deno.serve(observe("monvelo-fund", createMonveloFundHandler({
  ...liveUserGatewayDeps(),
  initializeTransaction: paystackInitializer({
    secretKey: requireEnv("PAYSTACK_SECRET_KEY"),
    baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined,
  }),
  gatewaySecret,
})));
