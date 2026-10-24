// Addendum A5 §5.3 — resend the delivery code: a fresh PIN replaces the old
// hash, then goes out through the router (purpose DELIVERY_CODE_RESEND). Only a
// ZSM resend clears locks; others are limited to 3 sent resends a day (RPC).
// A replay (no buyer_phone) sends nothing and reports delivery_code_sent false.
import { z } from "../_shared/core/deps.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import type { MessageSender } from "../_shared/messaging/router.ts";
import { sendDeliveryCode } from "../_shared/fulfilment/code.ts";

const schema = z.object({ idempotency_key: idempotencyKey, order_id: z.string().uuid() });

export type OrderDeliveryPinDeps = UserGatewayDeps & {
  sendMessage: MessageSender;
  generatePin: () => string;
  gatewaySecret: string;
};

type ResendReply = { order_id: string; public_reference: string; buyer_phone?: string };

export function createOrderDeliveryPinHandler(deps: OrderDeliveryPinDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ caller, body, rpc }) => {
    const pin = deps.generatePin();
    const r = await rpc<ResendReply>("resend_delivery_pin", {
      p_idempotency_key: body.idempotency_key,
      p_order_id: body.order_id,
      p_pin: pin,
      p_gateway_proof: deps.gatewaySecret,
    });
    const sent = await sendDeliveryCode({
      rpc,
      send: deps.sendMessage,
      purpose: "DELIVERY_CODE_RESEND",
      idempotencyKey: body.idempotency_key,
      orderId: r.order_id,
      reference: r.public_reference,
      phone: r.buyer_phone,
      pin,
      gatewayProof: deps.gatewaySecret,
      // R18: the RPC succeeded, so assert_tenant_role and the order lock proved
      // the active tenant is the order's; notification_logs gets it for ZSM RLS.
      tenantId: caller.activeTenantId,
    });
    return { order_id: r.order_id, status: "IN_TRANSIT", ...sent };
  }, deps);
}
