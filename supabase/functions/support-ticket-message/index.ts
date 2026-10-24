import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createSupportTicketMessageHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// public-flavoured (A1 §5): the ticket secret is the capability; the RPC is granted to service_role only
Deno.serve(observe("support-ticket-message", createSupportTicketMessageHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() })));
