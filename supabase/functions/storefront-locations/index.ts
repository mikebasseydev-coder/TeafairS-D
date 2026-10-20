import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createStorefrontLocationsHandler } from "./handler.ts";

// public-flavoured (A1 §5): anonymous callers; the RPC is granted to service_role only
Deno.serve(createStorefrontLocationsHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() }));
