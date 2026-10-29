import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { createMonveloAgentRegisterHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const AGENT = "d0000000-0000-0000-0000-000000000002";
const SECRET = "gw-secret-value";
const NUMBER = "0123456789";

function setup(opts: { reply?: Record<string, unknown>; resolveError?: Error } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const resolveCalls: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve((opts.reply ?? { agent_id: AGENT, status: "PENDING", name_matches: true }) as T);
  };
  const handler = createMonveloAgentRegisterHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    resolve: (n, b) => {
      resolveCalls.push([n, b]);
      return opts.resolveError ? Promise.reject(opts.resolveError) : Promise.resolve({ accountName: "ADA OBI STORES" });
    },
    gatewaySecret: SECRET,
  });
  return { handler, rpcCalls, resolveCalls };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(
    new Request("http://x/monvelo-agent-register", {
      method: "POST",
      headers: { Authorization: "Bearer tok" },
      body: JSON.stringify(body),
    }),
  );

const register = (over: Record<string, unknown> = {}) => ({
  idempotency_key: KEY,
  action: "register",
  business_name: "Ada POS",
  pos_network: "MONIEPOINT",
  network_agent_id: "mp-123",
  contact_phone: "0803 123 4567",
  latitude: 6.6,
  longitude: 3.35,
  address_text: "12 Allen Ave, Ikeja",
  settlement_account_number: NUMBER,
  settlement_bank_code: "058",
  network_kyc_reference: "KYC-1",
  ...over,
});

Deno.test("register resolves the account, then passes the proof, the resolved name and a normalised phone to the RPC", async () => {
  const { handler, rpcCalls, resolveCalls } = setup();
  const res = await post(handler, register({ settlement_account_name: "CLIENT CHOSEN NAME" }));
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(resolveCalls, [[NUMBER, "058"]]);
  assertEquals(rpcCalls, [["register_monvelo_agent", {
    p_idempotency_key: KEY,
    p_gateway_proof: SECRET,
    p_agent: {
      business_name: "Ada POS",
      pos_network: "MONIEPOINT",
      network_agent_id: "mp-123",
      contact_phone: "+2348031234567",
      latitude: 6.6,
      longitude: 3.35,
      address_text: "12 Allen Ave, Ikeja",
      settlement_account_number: NUMBER,
      settlement_bank_code: "058",
      settlement_account_name: "ADA OBI STORES",
      network_kyc_reference: "KYC-1",
    },
  }]]);
  assertEquals(JSON.stringify(rpcCalls).includes("CLIENT CHOSEN"), false);
  assertEquals(JSON.parse(text), { agent_id: AGENT, status: "PENDING", name_matches: true, settlement_account_last4: "6789" });
  assertEquals(text.includes(NUMBER) || text.includes("2348031234567"), false);
});

Deno.test("a bad account number is 400 before any Paystack call or RPC", async () => {
  for (const bad of ["12345", "01234567890", "012345678a", ""]) {
    const { handler, rpcCalls, resolveCalls } = setup();
    const res = await post(handler, register({ settlement_account_number: bad }));
    assertEquals([res.status, resolveCalls.length, rpcCalls.length], [400, 0, 0]);
    await res.body?.cancel();
  }
});

Deno.test("an unusable phone, network or coordinates is 400 before any Paystack call", async () => {
  for (const over of [{ contact_phone: "12345" }, { pos_network: "FIRSTMONIE" }, { latitude: 91 }, { longitude: -181 }]) {
    const { handler, rpcCalls, resolveCalls } = setup();
    const res = await post(handler, register(over));
    assertEquals([res.status, resolveCalls.length, rpcCalls.length], [400, 0, 0]);
    await res.body?.cancel();
  }
});

Deno.test("an unresolvable account is 422 and the RPC is never called", async () => {
  const { handler, rpcCalls } = setup({
    resolveError: new GatewayError(422, "ACCOUNT_NOT_RESOLVED", "That bank account could not be verified."),
  });
  const res = await post(handler, register());
  const err = (await res.json()).error;
  assertEquals(
    [res.status, err.code, err.message, rpcCalls.length],
    [422, "ACCOUNT_NOT_RESOLVED", "That bank account could not be verified.", 0],
  );
});

Deno.test("change_settlement needs agent_id, skips the agent fields, and returns only the last four", async () => {
  const { handler, rpcCalls, resolveCalls } = setup({ reply: { agent_id: AGENT, status: "PENDING_APPROVAL", last4: "6789" } });
  const missing = await post(handler, {
    idempotency_key: KEY,
    action: "change_settlement",
    settlement_account_number: NUMBER,
    settlement_bank_code: "058",
  });
  assertEquals(missing.status, 400);
  await missing.body?.cancel();

  const res = await post(handler, {
    idempotency_key: KEY,
    action: "change_settlement",
    agent_id: AGENT,
    settlement_account_number: NUMBER,
    settlement_bank_code: "058",
    settlement_account_name: "EVIL",
  });
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(resolveCalls, [[NUMBER, "058"]]);
  assertEquals(rpcCalls, [["request_monvelo_settlement_change", {
    p_idempotency_key: KEY,
    p_gateway_proof: SECRET,
    p_agent_id: AGENT,
    p_account: { settlement_account_number: NUMBER, settlement_bank_code: "058", settlement_account_name: "ADA OBI STORES" },
  }]]);
  assertEquals(JSON.parse(text), { agent_id: AGENT, status: "PENDING_APPROVAL", settlement_account_last4: "6789" });
  assertEquals(text.includes(NUMBER), false);
});

Deno.test("a client tenant_id is ignored and a database refusal maps through (23505 is 409)", async () => {
  const rpc: Rpc = () => Promise.reject(new GatewayError(409, "CONFLICT", "this agent is already registered with Monvelo"));
  const handler = createMonveloAgentRegisterHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    resolve: () => Promise.resolve({ accountName: "N" }),
    gatewaySecret: SECRET,
  });
  const res = await post(handler, register({ tenant_id: crypto.randomUUID() }));
  assertEquals(res.status, 409);
  await res.body?.cancel();
});
