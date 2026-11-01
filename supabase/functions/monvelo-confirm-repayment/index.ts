import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { createMonveloConfirmRepaymentHandler } from "./handler.ts";

// Must equal the Vault secret `gateway_secret` (see .env.example)
const gatewaySecret = requireEnv("GATEWAY_SECRET");

Deno.serve(observe("monvelo-confirm-repayment", createMonveloConfirmRepaymentHandler({
  ...liveUserGatewayDeps(),
  sendMessage: messageRouterFromEnv(),
  gatewaySecret,
})));
