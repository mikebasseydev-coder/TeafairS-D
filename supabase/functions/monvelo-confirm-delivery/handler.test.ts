import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import type { MonveloCodePurpose } from "../_shared/monvelo/code-email.ts";
import { createMonveloConfirmDeliveryHandler } from "./handler.ts";

const KEY = "b0000000-0000-0000-0000-000000000001";
const FINANCING = "f0000000-0000-0000-0000-000000000001";
const CHALLENGE = "c0000000-0000-0000-0000-000000000001";
const TENANT = "e0000000-0000-0000-0000-000000000001";
const DUE = "2026-12-01T23:00:00+00:00";

function setup(opts: { replayed?: boolean; sendFails?: boolean; confirm?: Record<string, unknown> } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const sent: Array<[string, MonveloCodePurpose, string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "confirm_monvelo_delivery") {
      return Promise.resolve((opts.confirm ?? { confirmed: true, due_at: DUE }) as T);
    }
    return Promise.resolve({
      challenge_id: CHALLENGE,
      expires_at: "2026-10-31T12:10:00+00:00",
      destination_email: "owner.one@example.com",
      replayed: opts.replayed ?? false,
      ...(opts.replayed ? {} : { code: "042917" }),
    } as T);
  };
  const handler = createMonveloConfirmDeliveryHandler({
    verifyToken: () => Promise.resolve({ sub: "u3", role: "authenticated", app_metadata: { active_tenant_id: TENANT } }),
    rpcFor: () => rpc,
    gatewaySecret: "gw-secret",
    sendCode: (to, purpose, code, challengeId) => {
      if (opts.sendFails) return Promise.reject(new Error("down"));
      sent.push([to, purpose, code, challengeId]);
      return Promise.resolve();
    },
  });
  return { handler, rpcCalls, sent };
}

const call = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer tok" } }));

const start = { idempotency_key: KEY, action: "start", financing_id: FINANCING };
const confirm = { idempotency_key: KEY, action: "confirm", challenge_id: CHALLENGE, code: "042917" };

Deno.test("start emails exactly one code to the owner, and the reply has none", async () => {
  const { handler, rpcCalls, sent } = setup();
  const res = await call(handler, start);
  assertEquals(res.status, 200);
  const text = JSON.stringify(await res.clone().json());
  assertEquals(text.includes("042917"), false);
  assertEquals(text.includes("owner.one"), false);
  assertEquals(await res.json(), {
    challenge_id: CHALLENGE,
    expires_at: "2026-10-31T12:10:00+00:00",
    destination: "o***@e***.com",
  });
  assertEquals(rpcCalls, [["start_monvelo_delivery",
    { p_idempotency_key: KEY, p_gateway_proof: "gw-secret", p_financing_id: FINANCING }]]);
  assertEquals(sent.length, 1);
  // A6 §23.6: one email to the owner's verified address, with the code
  assertEquals(sent[0], ["owner.one@example.com", "DELIVERY", "042917", CHALLENGE]);
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

Deno.test("confirm returns the due date", async () => {
  const { handler, rpcCalls, sent } = setup();
  const res = await call(handler, confirm);
  assertEquals([res.status, await res.json()], [200, { confirmed: true, due_at: DUE }]);
  assertEquals(rpcCalls, [["confirm_monvelo_delivery", { p_idempotency_key: KEY, p_challenge_id: CHALLENGE, p_code: "042917" }]]);
  assertEquals(sent, []);
});

for (const reason of ["INVALID", "EXPIRED", "LOCKED"]) {
  Deno.test(`confirm maps ${reason} to 422 DELIVERY_CODE_${reason}`, async () => {
    const { handler } = setup({ confirm: { confirmed: false, reason } });
    const res = await call(handler, { ...confirm, code: "000000" });
    assertEquals([res.status, (await res.json()).error.code], [422, `DELIVERY_CODE_${reason}`]);
  });
}

Deno.test("a malformed code or financing id is rejected before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const bad = await call(handler, { ...confirm, code: "12ab" });
  const badId = await call(handler, { ...start, financing_id: "not-a-uuid" });
  assertEquals([bad.status, badId.status, rpcCalls.length], [400, 400, 0]);
});

Deno.test("a client-supplied tenant never reaches the RPC", async () => {
  const { handler, rpcCalls } = setup();
  await call(handler, { ...start, tenant_id: "evil", tenantId: "evil" });
  assertEquals(Object.keys(rpcCalls[0][1]).some((k) => k.includes("tenant")), false);
});
