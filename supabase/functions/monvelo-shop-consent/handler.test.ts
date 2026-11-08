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
  const auths: string[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "enrol_monvelo_shop") {
      return Promise.resolve((opts.enrol ?? { enrolled: true, shop_code: "SH-ABC234" }) as T);
    }
    if (fn === "submit_monvelo_shop_policy") {
      return Promise.resolve((opts.enrol ?? { submitted: true, policy_id: "p1", status: "PENDING" }) as T);
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
    rpcFor: (authorization) => {
      auths.push(authorization);
      return rpc;
    },
    gatewaySecret: "gw-secret",
    sendMessage: (to, message) => {
      if (opts.sendFails) return Promise.reject(new MessageDeliveryError("down"));
      sent.push([to, message]);
      return Promise.resolve({ channel: "WHATSAPP", sent: true });
    },
  });
  return { handler, rpcCalls, sent, auths };
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

// Addendum A8 §6.3: the owner's consent to share the shop's own policy
const policy = {
  idempotency_key: KEY, action: "submit_policy", challenge_id: CHALLENGE, code: "042917",
  insurer_name: "Leadway", policy_number: "SME-1", covers_fire_perils: true, covers_burglary: true,
  sum_insured: 1000000, lender_interest_endorsed: true, starts_on: "2026-11-01", expires_on: "2027-10-31",
  document_path: `${SHOP}/cert.pdf`,
};

Deno.test("start_policy draws the code with the caller's JWT and sends it WhatsApp-only", async () => {
  const { handler, rpcCalls, sent, auths } = setup();
  const res = await call(handler, { ...start, action: "start_policy" });
  assertEquals(res.status, 200);
  assertEquals(JSON.stringify(await res.json()).includes("042917"), false);
  assertEquals(auths, ["Bearer tok"]);
  assertEquals(rpcCalls, [["start_monvelo_policy_consent",
    { p_idempotency_key: KEY, p_gateway_proof: "gw-secret", p_shop_id: SHOP, p_area_id: AREA }]]);
  assertEquals(sent.length, 1);
  assertEquals(sent[0][1].whatsappOnly, true);
});

Deno.test("submit_policy spends the code and submits the policy", async () => {
  const { handler, rpcCalls } = setup();
  const res = await call(handler, policy);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { submitted: true, policy_id: "p1", status: "PENDING" });
  assertEquals(rpcCalls, [["submit_monvelo_shop_policy", {
    p_idempotency_key: KEY, p_challenge_id: CHALLENGE, p_code: "042917", p_insurer_name: "Leadway",
    p_policy_number: "SME-1", p_covers_fire_perils: true, p_covers_burglary: true, p_sum_insured: 1000000,
    p_lender_interest_endorsed: true, p_starts_on: "2026-11-01", p_expires_on: "2027-10-31",
    p_document_path: `${SHOP}/cert.pdf`,
  }]]);
});

Deno.test("a wrong policy consent code is a 422", async () => {
  const { handler } = setup({ enrol: { submitted: false, reason: "INVALID" } });
  const res = await call(handler, policy);
  assertEquals(res.status, 422);
  assertEquals((await res.json()).error.code, "CONSENT_CODE_INVALID");
});
