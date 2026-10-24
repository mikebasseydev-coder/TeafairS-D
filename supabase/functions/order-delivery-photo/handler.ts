// Addendum A5 §5.3 — a delivery-proof photo upload slot. The RPC checks the
// caller may deliver the order; the reply carries only the id and signed URL.
import { z } from "../_shared/core/deps.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { attachmentFields } from "../_shared/storage/attachment.ts";

export const DELIVERY_PROOF_BUCKET = "delivery-proofs";

const schema = z.object({
  idempotency_key: idempotencyKey,
  order_id: z.string().uuid(),
  ...attachmentFields,
});

export type OrderDeliveryPhotoDeps = UserGatewayDeps & {
  signUpload: (bucket: string, path: string) => Promise<string>;
};

export function createOrderDeliveryPhotoHandler(deps: OrderDeliveryPhotoDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const slot = await rpc<{ attachment_id: string; storage_path: string }>("request_delivery_photo", {
      p_idempotency_key: body.idempotency_key,
      p_order_id: body.order_id,
      p_mime_type: body.mime_type,
      p_size_bytes: body.size_bytes,
    });
    return {
      attachment_id: slot.attachment_id,
      upload_url: await deps.signUpload(DELIVERY_PROOF_BUCKET, slot.storage_path),
    };
  }, deps);
}
