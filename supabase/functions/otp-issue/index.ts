import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { createOtpIssueHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// Must equal the Vault secret `gateway_secret` (see .env.example)
const gatewaySecret = requireEnv("GATEWAY_SECRET");

Deno.serve(observe("otp-issue", createOtpIssueHandler({
  ...liveUserGatewayDeps(),
  sendMessage: messageRouterFromEnv(),
  gatewaySecret,
})));
