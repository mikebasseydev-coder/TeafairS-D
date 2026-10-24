// Addendum A5 §5.3 — confirm delivery with the buyer's 4-digit code. The RPC
// returns a wrong code or a lock as data ({error: 'WRONG_PIN' | 'LOCKED'}) so
// the failed-attempt counters commit; this gateway turns that into a 422.
// The stored idempotent request excludes the PIN, so the client MUST use a
// fresh idempotency_key for every PIN entry: reusing a key replays the first
// answer whatever PIN is typed.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  order_id: z.string().uuid(),
  pin: z.string().regex(/^\d{4}$/),
  photo_attachment_id: z.string().uuid().optional(),
});

export function createOrderDeliveryConfirmHandler(deps: UserGatewayDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const r = await rpc<{ error?: string } & Record<string, unknown>>("mark_order_delivered", {
      p_idempotency_key: body.idempotency_key,
      p_order_id: body.order_id,
      p_pin: body.pin,
      p_photo_attachment_id: body.photo_attachment_id ?? null,
    });
    if (r.error === "WRONG_PIN") {
      throw new GatewayError(422, "WRONG_PIN", "That delivery code is not right.");
    }
    if (r.error === "LOCKED") {
      throw new GatewayError(
        422,
        "LOCKED",
        "Too many wrong codes. Ask the buyer to request a new code or try again later.",
      );
    }
    return r;
  }, deps);
}
