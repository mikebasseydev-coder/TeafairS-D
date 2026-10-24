import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createCheckoutPhoneVerifyConfirmHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// public-flavoured (A1 §5): anonymous callers; the RPC is service_role only
Deno.serve(observe("checkout-phone-verify-confirm", createCheckoutPhoneVerifyConfirmHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() })));
