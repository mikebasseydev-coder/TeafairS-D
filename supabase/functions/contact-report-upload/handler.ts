// Addendum A6 §16.4 — the CSM asks for a slot to upload the signed hard copy of
// a contact report. The caller's own JWT reaches the RPC, which checks tenant,
// role and the ZSM approval live. The storage path stays server-side.
import { z } from "../_shared/core/deps.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { CONTACT_REPORT_BUCKET, hardCopyFields } from "../_shared/storage/contact-report.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  report_id: z.string().uuid(),
  ...hardCopyFields,
});

export type ContactReportUploadDeps = UserGatewayDeps & {
  signUpload: (bucket: string, path: string) => Promise<string>;
};

export function createContactReportUploadHandler(
  deps: ContactReportUploadDeps,
): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const slot = await rpc<{ hard_copy_id: string; storage_path: string }>("request_contact_report_hard_copy", {
      p_idempotency_key: body.idempotency_key,
      p_report_id: body.report_id,
      p_mime_type: body.mime_type,
      p_size_bytes: body.size_bytes,
    });
    return {
      hard_copy_id: slot.hard_copy_id,
      upload_url: await deps.signUpload(CONTACT_REPORT_BUCKET, slot.storage_path),
    };
  }, deps);
}
