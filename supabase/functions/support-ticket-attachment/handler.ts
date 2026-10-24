// Addendum A5 §4.3 — a buyer asks for one photo upload slot. The response is
// the attachment id and a 10-minute signed upload URL; the storage path stays
// server-side and nothing is logged.
import { z } from "../_shared/core/deps.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { mapNotFound } from "../_shared/support/not-found.ts";
import { ATTACHMENT_BUCKET, attachmentFields } from "../_shared/storage/attachment.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  public_reference: z.string().trim().toUpperCase().regex(/^TK-[0-9A-HJKMNP-TV-Z]{6}$/),
  secret: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  ...attachmentFields,
});

export type SupportTicketAttachmentDeps = PublicGatewayDeps & {
  signUpload: (bucket: string, path: string) => Promise<string>;
};

export function createSupportTicketAttachmentHandler(
  deps: SupportTicketAttachmentDeps,
): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc }) => {
    let slot: { attachment_id: string; storage_path: string };
    try {
      slot = await rpc("request_ticket_attachment", {
        p_idempotency_key: body.idempotency_key,
        p_public_reference: body.public_reference,
        p_secret: body.secret,
        p_mime_type: body.mime_type,
        p_size_bytes: body.size_bytes,
      });
    } catch (e) {
      throw mapNotFound(e, "We couldn't find that conversation.");
    }
    return {
      attachment_id: slot.attachment_id,
      upload_url: await deps.signUpload(ATTACHMENT_BUCKET, slot.storage_path),
    };
  }, deps);
}
