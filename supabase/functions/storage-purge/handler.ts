// Addendum A5 R12 — cron-invoked drain of storage_purge_queue. Always 200 with
// counts; a bucket whose Storage call fails stays queued for the next run.
// Paths are never logged.
import type { Rpc } from "../_shared/core/db.ts";
import { cronAuthorized } from "../_shared/core/cron.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";

export type StoragePurgeDeps = {
  cronSecret: string;
  rpc: Rpc;
  remove: (bucket: string, paths: string[]) => Promise<void>;
  maxBatches?: number;
};

type Row = { id: string; bucket: string; path: string };

export function createStoragePurgeHandler(deps: StoragePurgeDeps): (req: Request) => Promise<Response> {
  const maxBatches = deps.maxBatches ?? 10;
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      if (!cronAuthorized(req, deps.cronSecret)) throw new GatewayError(401, "UNAUTHORIZED", "Unauthorized.");
      await req.body?.cancel();

      let batches = 0, purged = 0, errors = 0;
      while (batches < maxBatches) {
        const rows = await deps.rpc<Row[]>("storage_purge_batch", { p_limit: 100 });
        if (!rows || rows.length === 0) break;
        batches++;
        const byBucket = new Map<string, Row[]>();
        for (const r of rows) byBucket.set(r.bucket, [...(byBucket.get(r.bucket) ?? []), r]);
        let progressed = false;
        for (const [bucket, group] of byBucket) {
          try {
            await deps.remove(bucket, group.map((r) => r.path));
            await deps.rpc("storage_purge_done", { p_ids: group.map((r) => r.id) });
            purged += group.length;
            progressed = true;
          } catch (e) {
            errors++;
            console.error("storage-purge: bucket failed:", bucket, e instanceof Error ? e.name : "error");
          }
        }
        // nothing could be removed: stop rather than re-read the same rows
        if (!progressed) break;
      }
      return json(200, { batches, purged, errors });
    } catch (e) {
      return errorResponse(e);
    }
  };
}
