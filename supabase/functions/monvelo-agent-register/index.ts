import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { resolveAccount } from "../_shared/monvelo/paystack-resolve.ts";
import { createMonveloAgentRegisterHandler } from "./handler.ts";

const paystack = { secretKey: requireEnv("PAYSTACK_SECRET_KEY"), baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined };
// Must equal the Vault secret `gateway_secret` (see .env.example)
const gatewaySecret = requireEnv("GATEWAY_SECRET");

Deno.serve(observe("monvelo-agent-register", createMonveloAgentRegisterHandler({
  ...liveUserGatewayDeps(),
  resolve: (accountNumber, bankCode) => resolveAccount(paystack, accountNumber, bankCode),
  gatewaySecret,
})));
