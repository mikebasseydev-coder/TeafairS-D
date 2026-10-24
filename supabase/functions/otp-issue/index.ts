import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { messageRouterFromEnv } from "../_shared/messaging/router.ts";
import { generateOtpCode } from "./code.ts";
import { createOtpIssueHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

Deno.serve(observe("otp-issue", createOtpIssueHandler({
  ...liveUserGatewayDeps(),
  sendMessage: messageRouterFromEnv(),
  generateCode: generateOtpCode,
})));
