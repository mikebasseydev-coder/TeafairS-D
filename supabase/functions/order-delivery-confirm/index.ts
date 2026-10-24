import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createOrderDeliveryConfirmHandler } from "./handler.ts";

Deno.serve(createOrderDeliveryConfirmHandler(liveUserGatewayDeps()));
