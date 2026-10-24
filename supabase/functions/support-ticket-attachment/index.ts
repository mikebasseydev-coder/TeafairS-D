import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createSignedUploadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createSupportTicketAttachmentHandler } from "./handler.ts";

// public-flavoured (A1 §5): the ticket secret is the capability. The service
// key is used here for Storage signing only; the RPC is granted to service_role.
const storage = storageConfigFromEnv();

Deno.serve(createSupportTicketAttachmentHandler({
  rpc: serviceRpc(),
  allowedOrigins: allowedOriginsFromEnv(),
  signUpload: (bucket, path) => createSignedUploadUrl(storage, bucket, path),
}));
