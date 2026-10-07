import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { smsSenderFromEnv } from "../_shared/core/sms.ts";
import { generateOtpCode } from "./code.ts";
import { createOtpIssueHandler } from "./handler.ts";

Deno.serve(createOtpIssueHandler({
  ...liveUserGatewayDeps(),
  sendSms: smsSenderFromEnv(),
  generateCode: generateOtpCode,
}));
