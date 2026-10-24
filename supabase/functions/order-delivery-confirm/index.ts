import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createOrderDeliveryConfirmHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

Deno.serve(observe("order-delivery-confirm", createOrderDeliveryConfirmHandler(liveUserGatewayDeps())));
