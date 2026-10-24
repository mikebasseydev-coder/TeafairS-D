import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createSignedUploadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createSupportStaffAttachmentHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// user-flavoured: the service key is used for Storage signing only
const storage = storageConfigFromEnv();

Deno.serve(observe("support-staff-attachment", createSupportStaffAttachmentHandler({
  ...liveUserGatewayDeps(),
  signUpload: (bucket, path) => createSignedUploadUrl(storage, bucket, path),
})));
