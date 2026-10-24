// Addendum A5 §5.2 — dispatch a paid web order and send the buyer its 4-digit
// delivery code. The PIN is generated here, hashed by the RPC and sent through
// the message router; neither it nor the buyer's phone is ever returned or logged.
// A replayed dispatch (no buyer_phone in the RPC reply) sends nothing and
// reports delivery_code_sent false; recovery is a resend (order-delivery-pin).
import { z } from "../_shared/core/deps.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import type { MessageSender } from "../_shared/messaging/router.ts";
import { sendDeliveryCode } from "../_shared/fulfilment/code.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  order_id: z.string().uuid(),
  tracking_reference: z.string().max(100).optional(),
});

export type OrderDispatchDeps = UserGatewayDeps & {
  sendMessage: MessageSender;
  generatePin: () => string;
  gatewaySecret: string;
};

type DispatchReply = { order_id: string; status: string; public_reference: string; buyer_phone?: string };

export function createOrderDispatchHandler(deps: OrderDispatchDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ caller, body, rpc }) => {
    const pin = deps.generatePin();
    const r = await rpc<DispatchReply>("mark_order_dispatched", {
      p_idempotency_key: body.idempotency_key,
      p_order_id: body.order_id,
      p_tracking_reference: body.tracking_reference ?? null,
      p_pin: pin,
      p_gateway_proof: deps.gatewaySecret,
    });
    const sent = await sendDeliveryCode({
      rpc,
      send: deps.sendMessage,
      purpose: "DELIVERY_CODE",
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
    return { order_id: r.order_id, status: r.status, ...sent };
  }, deps);
}
