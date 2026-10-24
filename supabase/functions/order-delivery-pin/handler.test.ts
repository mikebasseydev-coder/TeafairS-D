import { assertEquals } from "jsr:@std/assert@1";
import { createOrderDeliveryPinHandler } from "./handler.ts";
import { KEY, ORDER, PHONE, PIN, post, REF, SECRET, sendSetup } from "../_shared/fulfilment/_fixtures.ts";

const first = { order_id: ORDER, public_reference: REF, buyer_phone: PHONE };

Deno.test("resend uses DELIVERY_CODE_RESEND and never returns the PIN or phone", async () => {
  const { base, calls, sends } = sendSetup({ reply: first });
  const res = await post(createOrderDeliveryPinHandler(base), { idempotency_key: KEY, order_id: ORDER });
  const text = await res.text();
  assertEquals(JSON.parse(text), { order_id: ORDER, status: "IN_TRANSIT", delivery_code_sent: true, channel: "WHATSAPP" });
  assertEquals(text.includes(PIN) || text.includes(PHONE), false);
  assertEquals(calls[0], ["resend_delivery_pin", { p_idempotency_key: KEY, p_order_id: ORDER, p_pin: PIN, p_gateway_proof: SECRET }]);
  assertEquals(sends[0][1].purpose, "DELIVERY_CODE_RESEND");
  assertEquals(calls[1][0], "mark_delivery_pin_sent");
});

Deno.test("resend replay sends nothing; send failure skips mark-sent", async () => {
  const a = sendSetup({ reply: { order_id: ORDER, public_reference: REF } });
  const r = await post(createOrderDeliveryPinHandler(a.base), { idempotency_key: KEY, order_id: ORDER });
  assertEquals((await r.json()).delivery_code_sent, false);
  assertEquals(a.sends.length, 0);
  const b = sendSetup({ reply: first, fail: true });
  const r2 = await post(createOrderDeliveryPinHandler(b.base), { idempotency_key: KEY, order_id: ORDER });
  assertEquals(await r2.json(), { order_id: ORDER, status: "IN_TRANSIT", delivery_code_sent: false, channel: null });
  assertEquals(b.calls.map((c) => c[0]), ["resend_delivery_pin"]);
});
