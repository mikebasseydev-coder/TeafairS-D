// Addendum A3 §4 — read a conversation. (public_reference, secret) is the
// capability; any miss is the same 404.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

const schema = z.object({
  public_reference: z.string().trim().toUpperCase().regex(/^TK-[0-9A-HJKMNP-TV-Z]{6}$/),
  secret: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
});

export function createSupportTicketReadHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc }) => {
    const ticket = await rpc<unknown>("read_support_ticket", {
      p_public_reference: body.public_reference,
      p_secret: body.secret,
    });
    if (ticket === null || ticket === undefined) {
      throw new GatewayError(404, "NOT_FOUND", "We couldn't find that conversation.");
    }
    return ticket;
  }, deps);
}
