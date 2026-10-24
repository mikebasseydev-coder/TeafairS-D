import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createWebOrderStatusHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// public-flavoured (A1 §5): anonymous callers; the RPC is granted to service_role only
Deno.serve(observe("web-order-status", createWebOrderStatusHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() })));
