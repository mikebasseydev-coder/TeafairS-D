import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createSignedDownloadUrl, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createSupportTicketReadHandler } from "./handler.ts";

// public-flavoured (A1 §5): the ticket secret is the capability; the RPC is granted to service_role only
const storage = storageConfigFromEnv(); // service key: Storage signing only

Deno.serve(createSupportTicketReadHandler({
  rpc: serviceRpc(),
  allowedOrigins: allowedOriginsFromEnv(),
  signDownload: (bucket, path) => createSignedDownloadUrl(storage, bucket, path),
}));
