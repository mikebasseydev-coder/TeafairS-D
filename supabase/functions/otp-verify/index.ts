import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createOtpVerifyHandler } from "./handler.ts";

Deno.serve(createOtpVerifyHandler(liveUserGatewayDeps()));
