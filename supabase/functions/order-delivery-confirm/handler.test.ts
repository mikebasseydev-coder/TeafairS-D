import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createOrderDeliveryConfirmHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const ORDER = "d0000000-0000-0000-0000-000000000001";
const PHOTO = "e0000000-0000-0000-0000-000000000001";

function setup(reply: Record<string, unknown>) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve(reply as T);
  };
  const handler = createOrderDeliveryConfirmHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
  });
  const post = (b: unknown) =>
    handler(new Request("http://x", { method: "POST", body: JSON.stringify(b), headers: { Authorization: "Bearer tok" } }));
  return { post, calls };
}

Deno.test("confirm passes a delivery through", async () => {
  const reply = { order_id: ORDER, status: "DELIVERED", delivered_at: "t", damage_claim_deadline: "t2", delivered_via: "FIELD" };
  const { post, calls } = setup(reply);
  const res = await post({ idempotency_key: KEY, order_id: ORDER, pin: "0042", photo_attachment_id: PHOTO });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), reply);
  assertEquals(calls, [["mark_order_delivered", { p_idempotency_key: KEY, p_order_id: ORDER, p_pin: "0042", p_photo_attachment_id: PHOTO }]]);
});

Deno.test("confirm maps WRONG_PIN and LOCKED to 422 with the copy", async () => {
  const wrong = await setup({ order_id: ORDER, status: "IN_TRANSIT", error: "WRONG_PIN" }).post({
    idempotency_key: KEY,
    order_id: ORDER,
    pin: "1234",
  });
  assertEquals(wrong.status, 422);
  assertEquals((await wrong.json()).error.message, "That delivery code is not right.");
  const locked = await setup({ order_id: ORDER, status: "IN_TRANSIT", error: "LOCKED" }).post({
    idempotency_key: KEY,
    order_id: ORDER,
    pin: "1234",
  });
  assertEquals(locked.status, 422);
  assertEquals(
    (await locked.json()).error.message,
    "Too many wrong codes. Ask the buyer to request a new code or try again later.",
  );
});

Deno.test("confirm rejects a malformed PIN with no RPC, and sends a null photo by default", async () => {
  const { post, calls } = setup({ order_id: ORDER, status: "DELIVERED" });
  const bad = await post({ idempotency_key: KEY, order_id: ORDER, pin: "12a4" });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  assertEquals(calls.length, 0);
  await (await post({ idempotency_key: KEY, order_id: ORDER, pin: "1234" })).text();
  assertEquals(calls[0][1].p_photo_attachment_id, null);
});
