import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createOtpVerifyHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

Deno.serve(observe("otp-verify", createOtpVerifyHandler(liveUserGatewayDeps())));
