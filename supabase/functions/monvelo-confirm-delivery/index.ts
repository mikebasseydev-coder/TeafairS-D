import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { createMonveloConfirmDeliveryHandler } from "./handler.ts";

// Must equal the Vault secret `gateway_secret` (see .env.example)
const gatewaySecret = requireEnv("GATEWAY_SECRET");

Deno.serve(observe("monvelo-confirm-delivery", createMonveloConfirmDeliveryHandler({
  ...liveUserGatewayDeps(),
  sendMessage: messageRouterFromEnv(),
  gatewaySecret,
})));
