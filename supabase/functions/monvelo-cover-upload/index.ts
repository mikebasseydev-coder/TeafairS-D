import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { observe } from "../_shared/core/observability.ts";
import { createSignedUploadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createMonveloCoverUploadHandler } from "./handler.ts";

// user-flavoured: the RPC runs on the caller's JWT; the secret key signs the
// Storage upload only (A5 R22, as contact-report-upload)
const storage = storageConfigFromEnv();

Deno.serve(observe("monvelo-cover-upload", createMonveloCoverUploadHandler({
  ...liveUserGatewayDeps(),
  signUpload: (bucket, path) => createSignedUploadUrl(storage, bucket, path),
})));
