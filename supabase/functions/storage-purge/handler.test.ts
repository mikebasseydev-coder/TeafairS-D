import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createStoragePurgeHandler } from "./handler.ts";

const SECRET = "cron_secret";
type Row = { id: string; bucket: string; path: string };

function setup(batches: Row[][], opts: { removeFails?: (bucket: string) => boolean } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const removed: Array<[string, string[]]> = [];
  const queue = [...batches];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "storage_purge_batch") return Promise.resolve((queue.shift() ?? []) as T);
    return Promise.resolve((args.p_ids as string[]).length as T);
  };
  const handler = createStoragePurgeHandler({
    cronSecret: SECRET,
    rpc,
    remove: (bucket, paths) => {
      if (opts.removeFails?.(bucket)) return Promise.reject(new Error("down"));
      removed.push([bucket, paths]);
      return Promise.resolve();
    },
    maxBatches: 3,
  });
  return { handler, rpcCalls, removed };
}

const call = (h: (r: Request) => Promise<Response>, secret: string | null = SECRET, method = "POST") =>
  h(new Request("http://x", { method, headers: secret ? { "x-cron-secret": secret } : {}, body: method === "POST" ? "{}" : undefined }));

Deno.test("a wrong or missing secret is 401 and does nothing", async () => {
  const { handler, rpcCalls } = setup([]);
  for (const s of ["nope", null]) {
    const res = await call(handler, s);
    assertEquals(res.status, 401);
    await res.body?.cancel();
  }
  assertEquals(rpcCalls.length, 0);
});

Deno.test("rows are grouped by bucket, removed, then marked done", async () => {
  const { handler, rpcCalls, removed } = setup([[
    { id: "1", bucket: "support-attachments", path: "a" },
    { id: "2", bucket: "delivery-proofs", path: "b" },
    { id: "3", bucket: "support-attachments", path: "c" },
  ]]);
  const res = await call(handler);
  assertEquals([res.status, await res.json()], [200, { batches: 1, purged: 3, errors: 0 }]);
  assertEquals(removed, [["support-attachments", ["a", "c"]], ["delivery-proofs", ["b"]]]);
  const done = rpcCalls.filter(([f]) => f === "storage_purge_done").map(([, a]) => a.p_ids);
  assertEquals(done, [["1", "3"], ["2"]]);
});

Deno.test("an empty batch stops the loop", async () => {
  const { handler, rpcCalls } = setup([]);
  const res = await call(handler);
  assertEquals(await res.json(), { batches: 0, purged: 0, errors: 0 });
  assertEquals(rpcCalls.length, 1);
});

Deno.test("the loop is bounded by maxBatches", async () => {
  const row = (i: number): Row[] => [{ id: String(i), bucket: "support-attachments", path: `p${i}` }];
  const { handler, rpcCalls } = setup([row(1), row(2), row(3), row(4)]);
  const res = await call(handler);
  assertEquals((await res.json()).batches, 3);
  assertEquals(rpcCalls.filter(([f]) => f === "storage_purge_batch").length, 3);
});

Deno.test("a failing bucket is counted, left in the queue, and never logs paths", async () => {
  const logged: unknown[][] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => void logged.push(a);
  try {
    const { handler, rpcCalls } = setup(
      [[{ id: "1", bucket: "bad", path: "secret/path.jpg" }, { id: "2", bucket: "ok", path: "q" }]],
      { removeFails: (b) => b === "bad" },
    );
    const res = await call(handler);
    assertEquals(await res.json(), { batches: 1, purged: 1, errors: 1 });
    assertEquals(rpcCalls.filter(([f]) => f === "storage_purge_done").map(([, a]) => a.p_ids), [["2"]]);
  } finally {
    console.error = orig;
  }
  assertEquals(JSON.stringify(logged).includes("secret/path.jpg"), false);
});

Deno.test("a bucket that failed is not retried in the same run", async () => {
  const bad = (id: string): Row => ({ id, bucket: "bad", path: `x${id}` });
  const ok = (id: string): Row => ({ id, bucket: "ok", path: `y${id}` });
  const attempts: string[] = [];
  const queue = [[bad("1"), ok("2")], [bad("1"), ok("3")]];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) =>
    Promise.resolve((fn === "storage_purge_batch" ? queue.shift() ?? [] : (args.p_ids as string[]).length) as T);
  const orig = console.error;
  console.error = () => {};
  try {
    const handler = createStoragePurgeHandler({
      cronSecret: SECRET,
      rpc,
      remove: (bucket) => {
        attempts.push(bucket);
        return bucket === "bad" ? Promise.reject(new Error("down")) : Promise.resolve();
      },
      maxBatches: 5,
    });
    const res = await call(handler);
    assertEquals(await res.json(), { batches: 2, purged: 2, errors: 1 });
  } finally {
    console.error = orig;
  }
  assertEquals(attempts, ["bad", "ok", "ok"]);
});
