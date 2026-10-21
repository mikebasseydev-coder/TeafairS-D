import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createSupportTicketReadHandler } from "./handler.ts";

// public-flavoured (A1 §5): the ticket secret is the capability; the RPC is granted to service_role only
Deno.serve(createSupportTicketReadHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() }));
