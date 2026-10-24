import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createOrderDisputeEvidenceHandler } from "./handler.ts";

const ORDER = "d0000000-0000-0000-0000-000000000001";
const PHOTO = "orders/o/photo.jpg";
const A1 = "tickets/t/a1.png";
const A2 = "tickets/t/a2.png";

const bundle = {
  order: { public_reference: "TF-AAAAAA" },
  fulfilment: { pin_verified: true, delivery_photo: { bucket: "delivery-proofs", storage_path: PHOTO } },
  tickets: [{
    public_reference: "TK-AAAAA1",
    within_damage_window: true,
    messages: [{
      body: "crushed",
      attachments: [
        { attachment_id: "a1", mime_type: "image/png", size_bytes: 7, bucket: "support-attachments", storage_path: A1 },
        { attachment_id: "a2", mime_type: "image/png", size_bytes: 8, bucket: "support-attachments", storage_path: A2 },
      ],
    }, { body: "no photos" }],
  }],
};

Deno.test("evidence gateway signs every storage path and returns none", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const signed: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve(structuredClone(bundle) as T);
  };
  const handler = createOrderDisputeEvidenceHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    signDownload: (bucket, path) => {
      signed.push([bucket, path]);
      if (path === A2) return Promise.reject(new Error("storage down"));
      return Promise.resolve(`https://s/sign?p=${signed.length}`);
    },
  });
  const res = await handler(new Request("http://x", {
    method: "POST",
    body: JSON.stringify({ order_id: ORDER }),
    headers: { Authorization: "Bearer tok" },
  }));
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(calls, [["get_order_dispute_evidence", { p_order_id: ORDER }]]);
  assertEquals(signed, [["delivery-proofs", PHOTO], ["support-attachments", A1], ["support-attachments", A2]]);
  for (const leaked of [PHOTO, A1, A2, "storage_path", "support-attachments", "delivery-proofs"]) {
    assertEquals(text.includes(leaked), false, leaked);
  }
  const out = JSON.parse(text);
  assertEquals(out.fulfilment.pin_verified, true);
  assertEquals(out.fulfilment.delivery_photo, { url: "https://s/sign?p=1" });
  assertEquals(out.tickets[0].within_damage_window, true);
  assertEquals(out.tickets[0].messages[0].attachments, [
    { attachment_id: "a1", mime_type: "image/png", size_bytes: 7, url: "https://s/sign?p=2" },
    { attachment_id: "a2", mime_type: "image/png", size_bytes: 8, url: null },
  ]);
  assertEquals(out.tickets[0].messages[1], { body: "no photos" });

  const bad = await handler(new Request("http://x", {
    method: "POST",
    body: JSON.stringify({ order_id: "nope" }),
    headers: { Authorization: "Bearer tok" },
  }));
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  assertEquals(calls.length, 1);
});
