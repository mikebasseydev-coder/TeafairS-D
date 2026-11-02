import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { MessageDeliveryError, type OutboundMessage } from "../_shared/messaging/router.ts";
import { createMonveloConfirmRepaymentHandler } from "./handler.ts";

const KEY = "b0000000-0000-0000-0000-000000000001";
const FINANCING = "f0000000-0000-0000-0000-000000000001";
const AGENT = "a0000000-0000-0000-0000-000000000001";
const REPAYMENT = "d0000000-0000-0000-0000-000000000001";
const CHALLENGE = "c0000000-0000-0000-0000-000000000001";

function setup(
  opts: { replayed?: boolean; sendFails?: boolean; confirm?: Record<string, unknown>; activeTenant?: string } = {},
) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const sent: Array<[string, OutboundMessage]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "confirm_monvelo_repayment") {
      return Promise.resolve((opts.confirm ?? { confirmed: true, outstanding: 28000, status: "DELIVERED" }) as T);
    }
    return Promise.resolve({
      repayment_id: REPAYMENT,
      challenge_id: CHALLENGE,
      expires_at: "2026-10-31T12:10:00+00:00",
      destination_phone: "+2348031112222",
      replayed: opts.replayed ?? false,
      ...(opts.replayed ? {} : { code: "042917" }),
    } as T);
  };
  const handler = createMonveloConfirmRepaymentHandler({
    // an agent member: no active tenant
    verifyToken: () =>
      Promise.resolve({
        sub: "u21",
        role: "authenticated",
        app_metadata: opts.activeTenant ? { active_tenant_id: opts.activeTenant } : {},
      }),
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

const record = { idempotency_key: KEY, action: "record", financing_id: FINANCING, agent_id: AGENT, amount: 20000.5 };
const confirm = { idempotency_key: KEY, action: "confirm", challenge_id: CHALLENGE, code: "042917" };

Deno.test("record sends exactly one WhatsApp-only message with the code, and the reply has none", async () => {
  const { handler, rpcCalls, sent } = setup();
  const res = await call(handler, record);
  assertEquals(res.status, 200);
  const text = JSON.stringify(await res.clone().json());
  assertEquals(text.includes("042917"), false);
  assertEquals(text.includes("8031112222"), false);
  assertEquals(await res.json(), {
    repayment_id: REPAYMENT,
    challenge_id: CHALLENGE,
    expires_at: "2026-10-31T12:10:00+00:00",
    destination: "+234******2222",
  });
  assertEquals(rpcCalls, [["record_monvelo_repayment", {
    p_idempotency_key: KEY,
    p_gateway_proof: "gw-secret",
    p_financing_id: FINANCING,
    p_agent_id: AGENT,
    p_amount: 20000.5,
  }]]);
  assertEquals(sent.length, 1);
  assertEquals(sent[0][0], "+2348031112222");
  assertEquals(sent[0][1].purpose, "MONVELO_REPAYMENT");
  assertEquals(sent[0][1].whatsappOnly, true);
  assertEquals(sent[0][1].template, { name: "teafair_otp", language: "en", params: ["042917"], kind: "authentication" });
  assertEquals(sent[0][1].smsText.includes("042917"), false);
  assertEquals(sent[0][1].relatedId, CHALLENGE);
  // an agent member has no tenant: the log is platform-level
  assertEquals(sent[0][1].tenantId, undefined);
});

Deno.test("an agent member whose JWT names a tenant still logs no tenant", async () => {
  const { handler, sent } = setup({ activeTenant: "e0000000-0000-0000-0000-000000000009" });
  const res = await call(handler, record);
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  assertEquals(sent[0][1].tenantId, undefined);
});

Deno.test("a replayed record sends nothing", async () => {
  const { handler, sent } = setup({ replayed: true });
  const res = await call(handler, record);
  assertEquals(res.status, 200);
  assertEquals(sent, []);
});

Deno.test("a router failure is 502 MESSAGE_DELIVERY_FAILED", async () => {
  const { handler } = setup({ sendFails: true });
  const res = await call(handler, record);
  const { error } = await res.json();
  assertEquals([res.status, error.code], [502, "MESSAGE_DELIVERY_FAILED"]);
  // R54: the copy says what really happens to the unsent code
  assertEquals(error.message,
    "The code could not be sent. This repayment stays pending, holding its amount, until its code lapses in 10 minutes; then record it again.");
});

Deno.test("confirm returns the outstanding and the status", async () => {
  const { handler, rpcCalls, sent } = setup();
  const res = await call(handler, confirm);
  assertEquals([res.status, await res.json()], [200, { confirmed: true, outstanding: 28000, status: "DELIVERED" }]);
  assertEquals(rpcCalls, [["confirm_monvelo_repayment", { p_idempotency_key: KEY, p_challenge_id: CHALLENGE, p_code: "042917" }]]);
  assertEquals(sent, []);
});

for (const reason of ["INVALID", "EXPIRED", "LOCKED"]) {
  Deno.test(`confirm maps ${reason} to 422 REPAYMENT_CODE_${reason}`, async () => {
    const { handler } = setup({ confirm: { confirmed: false, reason } });
    const res = await call(handler, { ...confirm, code: "000000" });
    assertEquals([res.status, (await res.json()).error.code], [422, `REPAYMENT_CODE_${reason}`]);
  });
}

Deno.test("a malformed code or id is rejected before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const bad = await call(handler, { ...confirm, code: "12ab" });
  const badFin = await call(handler, { ...record, financing_id: "not-a-uuid" });
  const badAgent = await call(handler, { ...record, agent_id: "not-a-uuid" });
  assertEquals([bad.status, badFin.status, badAgent.status, rpcCalls.length], [400, 400, 400, 0]);
});

for (const [label, amount] of [
  ["zero", 0],
  ["negative", -5],
  ["three decimals", 100.005],
  ["a string", "20000"],
  ["missing", undefined],
  ["above numeric(15,2)", 1e13],
] as Array<[string, unknown]>) {
  Deno.test(`an amount that is ${label} is 400 before any RPC`, async () => {
    const { handler, rpcCalls } = setup();
    const res = await call(handler, { ...record, amount });
    assertEquals([res.status, rpcCalls.length], [400, 0]);
  });
}

Deno.test("two-decimal amounts pass, including ones binary floats round", async () => {
  for (const amount of [0.29, 1.1, 4800, 28000.01]) {
    const { handler, rpcCalls } = setup();
    const res = await call(handler, { ...record, amount });
    assertEquals([res.status, rpcCalls[0][1].p_amount], [200, amount]);
  }
});

Deno.test("an unknown action is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await call(handler, { ...confirm, action: "start" });
  assertEquals([res.status, rpcCalls.length], [400, 0]);
});

Deno.test("a client-supplied tenant never reaches the RPC", async () => {
  const { handler, rpcCalls } = setup();
  await call(handler, { ...record, tenant_id: "evil", tenantId: "evil" });
  assertEquals(Object.keys(rpcCalls[0][1]).some((k) => k.includes("tenant")), false);
});
