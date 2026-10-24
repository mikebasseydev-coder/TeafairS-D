import { assertEquals } from "jsr:@std/assert@1";
import { createOrderDispatchHandler } from "./handler.ts";
import { KEY, ORDER, PHONE, PIN, post, REF, SECRET, sendSetup, TENANT } from "../_shared/fulfilment/_fixtures.ts";

const first = { order_id: ORDER, status: "IN_TRANSIT", public_reference: REF, buyer_phone: PHONE };
const replay = { order_id: ORDER, status: "IN_TRANSIT", public_reference: REF };

Deno.test("dispatch sends the PIN through the router and never returns it or the phone", async () => {
  const { base, calls, sends } = sendSetup({ reply: first });
  const res = await post(createOrderDispatchHandler(base), { idempotency_key: KEY, order_id: ORDER, tracking_reference: "T1" });
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(JSON.parse(text), { order_id: ORDER, status: "IN_TRANSIT", delivery_code_sent: true, channel: "WHATSAPP" });
  assertEquals(text.includes(PIN) || text.includes(PHONE) || text.includes(SECRET), false);
  assertEquals(calls[0], ["mark_order_dispatched", {
    p_idempotency_key: KEY,
    p_order_id: ORDER,
    p_tracking_reference: "T1",
    p_pin: PIN,
    p_gateway_proof: SECRET,
  }]);
  assertEquals(sends.length, 1);
  assertEquals(sends[0][0], PHONE);
  assertEquals(sends[0][1].purpose, "DELIVERY_CODE");
  assertEquals(sends[0][1].relatedId, ORDER);
  assertEquals(sends[0][1].tenantId, TENANT); // R18: the log row is visible to the tenant's ZSMs
  assertEquals(sends[0][1].template.params, [REF, PIN]);
  assertEquals(sends[0][1].smsText, `Your Teafair order ${REF} is on its way. Give this delivery code to the rider: ${PIN}.`);
  assertEquals(calls[1][0], "mark_delivery_pin_sent");
  assertEquals(calls[1][1].p_channel, "WHATSAPP");
  assertEquals(calls[1][1].p_gateway_proof, SECRET);
  assertEquals(calls[1][1].p_order_id, ORDER);
});

Deno.test("replay sends nothing", async () => {
  const { base, calls, sends } = sendSetup({ reply: replay });
  const res = await post(createOrderDispatchHandler(base), { idempotency_key: KEY, order_id: ORDER });
  assertEquals(await res.json(), { order_id: ORDER, status: "IN_TRANSIT", delivery_code_sent: false, channel: null });
  assertEquals(sends.length, 0);
  assertEquals(calls.map((c) => c[0]), ["mark_order_dispatched"]);
  assertEquals(calls[0][1].p_tracking_reference, null);
});

Deno.test("send failure keeps IN_TRANSIT and reports delivery_code_sent false", async () => {
  const { base, calls } = sendSetup({ reply: first, fail: true });
  const res = await post(createOrderDispatchHandler(base), { idempotency_key: KEY, order_id: ORDER });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { order_id: ORDER, status: "IN_TRANSIT", delivery_code_sent: false, channel: null });
  assertEquals(calls.map((c) => c[0]), ["mark_order_dispatched"]);
});

Deno.test("PIN, phone and secret never appear in console output", async () => {
  const seen: string[] = [];
  const orig = { log: console.log, error: console.error, warn: console.warn, info: console.info };
  for (const k of Object.keys(orig) as Array<keyof typeof orig>) {
    console[k] = (...a: unknown[]) => void seen.push(a.map(String).join(" "));
  }
  try {
    for (const fail of [false, true]) {
      const { base } = sendSetup({ reply: first, fail });
      await (await post(createOrderDispatchHandler(base), { idempotency_key: KEY, order_id: ORDER })).text();
    }
  } finally {
    Object.assign(console, orig);
  }
  const all = seen.join("\n");
  for (const s of [PIN, PHONE, SECRET]) assertEquals(all.includes(s), false);
});

Deno.test("dispatch validates the body and needs a token", async () => {
  const { base, calls } = sendSetup({ reply: first });
  const h = createOrderDispatchHandler(base);
  const bad = await post(h, { idempotency_key: KEY, order_id: "nope" });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  const none = await h(new Request("http://x", { method: "POST", body: "{}" }));
  assertEquals(none.status, 401);
  await none.body?.cancel();
  assertEquals(calls.length, 0);
});
