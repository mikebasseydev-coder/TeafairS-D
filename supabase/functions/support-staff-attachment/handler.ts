// Addendum A5 §4.3 — staff ask for a photo upload slot on a ticket. The
// caller's own JWT reaches the RPC, which checks tenant and role live.
import { z } from "../_shared/core/deps.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { ATTACHMENT_BUCKET, attachmentFields } from "../_shared/storage/attachment.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  ticket_id: z.string().uuid(),
  ...attachmentFields,
});

export type SupportStaffAttachmentDeps = UserGatewayDeps & {
  signUpload: (bucket: string, path: string) => Promise<string>;
};

export function createSupportStaffAttachmentHandler(
  deps: SupportStaffAttachmentDeps,
): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const slot = await rpc<{ attachment_id: string; storage_path: string }>("request_staff_ticket_attachment", {
      p_idempotency_key: body.idempotency_key,
      p_ticket_id: body.ticket_id,
      p_mime_type: body.mime_type,
      p_size_bytes: body.size_bytes,
    });
    return {
      attachment_id: slot.attachment_id,
      upload_url: await deps.signUpload(ATTACHMENT_BUCKET, slot.storage_path),
    };
  }, deps);
}
