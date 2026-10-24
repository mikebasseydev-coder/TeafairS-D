import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createStorefrontRefundPolicyHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// public-flavoured (A1 §5): anonymous callers; the RPC is granted to service_role only
Deno.serve(observe("storefront-refund-policy", createStorefrontRefundPolicyHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() })));
