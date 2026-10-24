import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createSignedDownloadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createOrderDisputeEvidenceHandler } from "./handler.ts";

// user-flavoured: the service key is used for Storage signing only
const storage = storageConfigFromEnv();

Deno.serve(createOrderDisputeEvidenceHandler({
  ...liveUserGatewayDeps(),
  signDownload: (bucket, path) => createSignedDownloadUrl(storage, bucket, path),
}));
