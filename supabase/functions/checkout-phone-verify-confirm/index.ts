import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createCheckoutPhoneVerifyConfirmHandler } from "./handler.ts";

// public-flavoured (A1 §5): anonymous callers; the RPC is service_role only
Deno.serve(createCheckoutPhoneVerifyConfirmHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() }));
