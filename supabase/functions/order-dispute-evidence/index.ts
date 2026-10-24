import { liveUserGatewayDeps } from "../_shared/core/gateway.ts";
import { createSignedDownloadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createOrderDisputeEvidenceHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// user-flavoured: the service key is used for Storage signing only
const storage = storageConfigFromEnv();

Deno.serve(observe("order-dispute-evidence", createOrderDisputeEvidenceHandler({
  ...liveUserGatewayDeps(),
  signDownload: (bucket, path) => createSignedDownloadUrl(storage, bucket, path),
})));
