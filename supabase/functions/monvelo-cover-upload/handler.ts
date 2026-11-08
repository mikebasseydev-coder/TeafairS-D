// Addendum A8 §6.3 — a signed upload slot for a cover document: a shop's
// policy certificate (monvelo-shop-policies/<shop_id>/…) or evidence of a
// loss (monvelo-claim-evidence/<financing_id>/…). The database decides who
// may upload (can_upload_monvelo_cover, on the caller's own JWT); this
// gateway only checks the file's type and size and signs the path. The path
// goes back to the client, which names it in submit_policy or
// report_monvelo_loss; both check the folder again.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";

export const MAX_COVER_BYTES = 10_485_760;

const BUCKET = { SHOP_POLICY: "monvelo-shop-policies", CLAIM_EVIDENCE: "monvelo-claim-evidence" } as const;
const EXT = { "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png" } as const;

const schema = z.object({
  purpose: z.enum(["SHOP_POLICY", "CLAIM_EVIDENCE"]),
  subject_id: z.string().uuid(),
  content_type: z.enum(["application/pdf", "image/jpeg", "image/png"]),
  byte_length: z.number().int().min(1).max(MAX_COVER_BYTES),
});

export type MonveloCoverUploadDeps = UserGatewayDeps & {
  signUpload: (bucket: string, path: string) => Promise<string>;
};

export function createMonveloCoverUploadHandler(deps: MonveloCoverUploadDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const allowed = await rpc<boolean>("can_upload_monvelo_cover", {
      p_purpose: body.purpose,
      p_subject_id: body.subject_id,
    });
    if (allowed !== true) throw new GatewayError(403, "FORBIDDEN", "You cannot upload a document for this.");
    const bucket = BUCKET[body.purpose];
    const path = `${body.subject_id.toLowerCase()}/${crypto.randomUUID()}.${EXT[body.content_type]}`;
    return { bucket, path, upload_url: await deps.signUpload(bucket, path) };
  }, deps);
}
