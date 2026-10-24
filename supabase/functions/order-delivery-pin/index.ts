import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { generateDeliveryPin } from "../_shared/fulfilment/code.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { createOrderDeliveryPinHandler } from "./handler.ts";

// Must equal the Vault secret `gateway_secret` (see .env.example)
const gatewaySecret = requireEnv("GATEWAY_SECRET");

Deno.serve(createOrderDeliveryPinHandler({
  ...liveUserGatewayDeps(),
  sendMessage: messageRouterFromEnv(),
  generatePin: generateDeliveryPin,
  gatewaySecret,
}));
