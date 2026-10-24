// Addendum A3 §4 — a buyer follow-up message. Closed-ticket and throttle
// refusals are P0001 and keep the default 422 with the database copy.
import { z } from "../_shared/core/deps.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { attachmentIds } from "../_shared/storage/attachment.ts";
import { mapNotFound } from "../_shared/support/not-found.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  public_reference: z.string().trim().toUpperCase().regex(/^TK-[0-9A-HJKMNP-TV-Z]{6}$/),
  secret: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  message: z.string().trim().min(1).max(2000),
  attachment_ids: attachmentIds.optional(),
});

export function createSupportTicketMessageHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc }) => {
    try {
      return await rpc("add_ticket_message", {
        p_idempotency_key: body.idempotency_key,
        p_public_reference: body.public_reference,
        p_secret: body.secret,
        p_message: body.message,
        p_attachment_ids: body.attachment_ids ?? [],
      });
    } catch (e) {
      throw mapNotFound(e, "We couldn't find that conversation.");
    }
  }, deps);
}
