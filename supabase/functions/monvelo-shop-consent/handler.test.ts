import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { MessageDeliveryError, type OutboundMessage } from "../_shared/messaging/router.ts";
import { createMonveloShopConsentHandler } from "./handler.ts";

const KEY = "b0000000-0000-0000-0000-000000000001";
const SHOP = "70000000-0000-0000-0000-000000000001";
const AREA = "60000000-0000-0000-0000-000000000001";
const CHALLENGE = "c0000000-0000-0000-0000-000000000001";
const TENANT = "e0000000-0000-0000-0000-000000000001";

function setup(opts: { replayed?: boolean; sendFails?: boolean; enrol?: Record<string, unknown> } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const sent: Array<[string, OutboundMessage]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "enrol_monvelo_shop") {
      return Promise.resolve((opts.enrol ?? { enrolled: true, shop_code: "SH-ABC234" }) as T);
    }
    return Promise.resolve({
      challenge_id: CHALLENGE,
      expires_at: "2026-10-28T12:10:00+00:00",
      destination_phone: "+2348031112222",
      replayed: opts.replayed ?? false,
      ...(opts.replayed ? {} : { code: "042917" }),
    } as T);
  };
  const handler = createMonveloShopConsentHandler({
    verifyToken: () => Promise.resolve({ sub: "u2", role: "authenticated", app_metadata: { active_tenant_id: TENANT } }),
    rpcFor: () => rpc,
    gatewaySecret: "gw-secret",
    sendMessage: (to, message) => {
      if (opts.sendFails) return Promise.reject(new MessageDeliveryError("down"));
      sent.push([to, message]);
      return Promise.resolve({ channel: "WHATSAPP", sent: true });
    },
  });
  return { handler, rpcCalls, sent };
}

const call = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer tok" } }));

const start = { idempotency_key: KEY, action: "start", shop_id: SHOP, area_id: AREA };

Deno.test("start sends exactly one WhatsApp-only message with the code, and the reply has none", async () => {
  const { handler, rpcCalls, sent } = setup();
  const res = await call(handler, start);
  assertEquals(res.status, 200);
  const text = JSON.stringify(await res.clone().json());
  assertEquals(text.includes("042917"), false);
  assertEquals(text.includes("8031112222"), false);
  assertEquals(await res.json(), {
    challenge_id: CHALLENGE,
    expires_at: "2026-10-28T12:10:00+00:00",
    destination: "+234******2222",
  });
  assertEquals(rpcCalls, [["start_monvelo_consent",
    { p_idempotency_key: KEY, p_gateway_proof: "gw-secret", p_shop_id: SHOP, p_area_id: AREA }]]);
  assertEquals(sent.length, 1);
  assertEquals(sent[0][0], "+2348031112222");
  assertEquals(sent[0][1].purpose, "MONVELO_CONSENT");
  assertEquals(sent[0][1].whatsappOnly, true);
  assertEquals(sent[0][1].template, { name: "teafair_otp", language: "en", params: ["042917"], kind: "authentication" });
  assertEquals(sent[0][1].smsText.includes("042917"), false);
  assertEquals(sent[0][1].relatedId, CHALLENGE);
  assertEquals(sent[0][1].tenantId, TENANT);
});

Deno.test("a replayed start sends nothing", async () => {
  const { handler, sent } = setup({ replayed: true });
  const res = await call(handler, start);
  assertEquals(res.status, 200);
  assertEquals(sent, []);
});

Deno.test("a router failure is 502 MESSAGE_DELIVERY_FAILED", async () => {
  const { handler } = setup({ sendFails: true });
  const res = await call(handler, start);
  assertEquals([res.status, (await res.json()).error.code], [502, "MESSAGE_DELIVERY_FAILED"]);
});

Deno.test("enrol returns the shop code", async () => {
  const { handler, rpcCalls } = setup();
  const res = await call(handler, { idempotency_key: KEY, action: "enrol", challenge_id: CHALLENGE, code: "042917" });
  assertEquals([res.status, await res.json()], [200, { enrolled: true, shop_code: "SH-ABC234" }]);
  assertEquals(rpcCalls, [["enrol_monvelo_shop", { p_idempotency_key: KEY, p_challenge_id: CHALLENGE, p_code: "042917" }]]);
});

for (const reason of ["INVALID", "EXPIRED", "LOCKED"]) {
  Deno.test(`enrol maps ${reason} to 422 CONSENT_CODE_${reason}`, async () => {
    const { handler } = setup({ enrol: { enrolled: false, reason } });
    const res = await call(handler, { idempotency_key: KEY, action: "enrol", challenge_id: CHALLENGE, code: "000000" });
    assertEquals([res.status, (await res.json()).error.code], [422, `CONSENT_CODE_${reason}`]);
  });
}

Deno.test("a malformed code is rejected before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await call(handler, { idempotency_key: KEY, action: "enrol", challenge_id: CHALLENGE, code: "12ab" });
  assertEquals([res.status, rpcCalls.length], [400, 0]);
});

Deno.test("a client-supplied tenant never reaches the RPC", async () => {
  const { handler, rpcCalls } = setup();
  await call(handler, { ...start, tenant_id: "evil", tenantId: "evil" });
  assertEquals(Object.keys(rpcCalls[0][1]).some((k) => k.includes("tenant")), false);
});
