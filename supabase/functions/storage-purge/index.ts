import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { removeObjects, storageConfigFromEnv } from "../_shared/storage/signed.ts";
import { createStoragePurgeHandler } from "./handler.ts";

// system-flavoured (§3.4): invoked by pg_cron via pg_net with x-cron-secret
const cronSecret = requireEnv("CRON_SECRET");
const storage = storageConfigFromEnv();

Deno.serve(createStoragePurgeHandler({
  cronSecret,
  rpc: serviceRpc(),
  remove: (bucket, paths) => removeObjects(storage, bucket, paths),
}));
