// Spec D1 §8.4 — a buyer's order status. The pair of references is the
// capability: the RPC returns null unless both match one order, and every
// miss is the same 404 so neither reference can be probed on its own.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

const schema = z.object({
  public_reference: z.string().trim().toUpperCase().regex(/^TF-[0-9A-HJKMNP-TV-Z]{6}$/),
  paystack_reference: z.string().trim().regex(/^TFW-[0-9a-f-]{36}$/i),
});

export function createWebOrderStatusHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc }) => {
    const status = await rpc<unknown>("web_order_status", {
      p_public_reference: body.public_reference,
      p_paystack_reference: body.paystack_reference,
    });
    if (status === null || status === undefined) throw new GatewayError(404, "NOT_FOUND", "We couldn't find that order.");
    return status;
  }, deps);
}
