import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { generateOtpCode } from "./code.ts";
import { createOtpIssueHandler } from "./handler.ts";

Deno.serve(createOtpIssueHandler({
  ...liveUserGatewayDeps(),
  sendMessage: messageRouterFromEnv(),
  generateCode: generateOtpCode,
}));
