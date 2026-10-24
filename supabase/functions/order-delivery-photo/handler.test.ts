import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createOrderDeliveryPhotoHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const ORDER = "d0000000-0000-0000-0000-000000000001";
const PATH = "tenant/order/file.png";

Deno.test("photo gateway returns only an upload URL", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const buckets: string[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve({ attachment_id: "a1", storage_path: PATH } as T);
  };
  const handler = createOrderDeliveryPhotoHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    signUpload: (bucket) => {
      buckets.push(bucket);
      return Promise.resolve("https://s/upload?token=t");
    },
  });
  const send = (b: unknown) =>
    handler(new Request("http://x", { method: "POST", body: JSON.stringify(b), headers: { Authorization: "Bearer tok" } }));
  const body = { idempotency_key: KEY, order_id: ORDER, mime_type: "image/png", size_bytes: 10 };
  const text = await (await send(body)).text();
  assertEquals(JSON.parse(text), { attachment_id: "a1", upload_url: "https://s/upload?token=t" });
  assertEquals(text.includes(PATH), false);
  assertEquals(buckets, ["delivery-proofs"]);
  assertEquals(calls, [["request_delivery_photo", { p_idempotency_key: KEY, p_order_id: ORDER, p_mime_type: "image/png", p_size_bytes: 10 }]]);

  const bad = await send({ ...body, mime_type: "image/gif" });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  assertEquals(calls.length, 1);
});
