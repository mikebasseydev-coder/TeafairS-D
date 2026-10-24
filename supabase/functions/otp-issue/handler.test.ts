import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { MessageDeliveryError, type OutboundMessage } from "../_shared/messaging/router.ts";
import { createOtpIssueHandler } from "./handler.ts";

const KEY = "b0000000-0000-0000-0000-000000000001";
const SUBJECT = "20000000-0000-0000-0000-000000000005";
const TENANT = "e0000000-0000-0000-0000-000000000001";

function setup(opts: { replayed?: boolean; smsFails?: boolean; channel?: "WHATSAPP" | "SMS" } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const sms: Array<[string, OutboundMessage]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve({
      challenge_id: "60000000-0000-0000-0000-000000000001",
      expires_at: "2026-10-07T12:05:00+00:00",
      destination_phone: "+2348000000005",
      replayed: opts.replayed ?? false,
      ...(opts.replayed ? {} : { code: "042917" }),
    } as T);
  };
  const handler = createOtpIssueHandler({
    verifyToken: () => Promise.resolve({ sub: "u3", role: "authenticated", app_metadata: { active_tenant_id: TENANT } }),
    rpcFor: () => rpc,
    gatewaySecret: "gw-secret",
    sendMessage: (to, message) => {
      if (opts.smsFails) return Promise.reject(new MessageDeliveryError("down"));
      sms.push([to, message]);
      return Promise.resolve({ channel: opts.channel ?? "SMS", sent: true });
    },
  });
  return { handler, rpcCalls, sms };
}

const call = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer tok" } }));

Deno.test("a fresh challenge sends the code the database drew to the owner's phone", async () => {
  const { handler, rpcCalls, sms } = setup();
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    challenge_id: "60000000-0000-0000-0000-000000000001",
    expires_at: "2026-10-07T12:05:00+00:00",
    destination: "+234******0005",
    sms_sent: true,
    channel: "SMS",
  });
  assertEquals(rpcCalls, [["issue_otp",
    { p_idempotency_key: KEY, p_subject_id: SUBJECT, p_purpose: "POS_SETTLEMENT", p_gateway_proof: "gw-secret" }]]);
  assertEquals(sms.length, 1);
  assertEquals(sms[0][0], "+2348000000005");
  assertEquals(sms[0][1].smsText.includes("042917"), true);
  assertEquals(sms[0][1].purpose, "OTP");
  assertEquals(sms[0][1].template, { name: "teafair_otp", language: "en", params: ["042917"], kind: "authentication" });
  assertEquals(sms[0][1].relatedId, "60000000-0000-0000-0000-000000000001");
  assertEquals(sms[0][1].tenantId, TENANT); // R18: the caller's active tenant goes to notification_logs
});

Deno.test("the code never reaches the agent's response", async () => {
  const { handler } = setup();
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals(JSON.stringify(await res.json()).includes("042917"), false);
});

Deno.test("a replay never texts a code the database does not hold", async () => {
  const { handler, sms } = setup({ replayed: true });
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals((await res.json()).sms_sent, false);
  assertEquals(sms, []);
});

Deno.test("reports the channel used", async () => {
  const { handler } = setup({ channel: "WHATSAPP" });
  const body = await (await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" })).json();
  assertEquals([body.channel, body.sms_sent], ["WHATSAPP", true]);
});

Deno.test("a replay reports no channel", async () => {
  const { handler } = setup({ replayed: true });
  const body = await (await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" })).json();
  assertEquals(body.channel, null);
});

Deno.test("a delivery failure is 502 MESSAGE_DELIVERY_FAILED", async () => {
  const { handler } = setup({ smsFails: true });
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals([res.status, (await res.json()).error.code], [502, "MESSAGE_DELIVERY_FAILED"]);
});

Deno.test("a client-supplied tenant never reaches the RPC", async () => {
  const { handler, rpcCalls } = setup();
  await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT", tenant_id: "evil", tenantId: "evil" });
  assertEquals(Object.keys(rpcCalls[0][1]).some((k) => k.includes("tenant")), false);
});

Deno.test("an unknown purpose is rejected before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "ANYTHING" });
  assertEquals([res.status, rpcCalls.length], [400, 0]);
});
