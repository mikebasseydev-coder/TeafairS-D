import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createSignedUploadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createOrderDeliveryPhotoHandler } from "./handler.ts";

// user-flavoured: the service key is used for Storage signing only
const storage = storageConfigFromEnv();

Deno.serve(createOrderDeliveryPhotoHandler({
  ...liveUserGatewayDeps(),
  signUpload: (bucket, path) => createSignedUploadUrl(storage, bucket, path),
}));
