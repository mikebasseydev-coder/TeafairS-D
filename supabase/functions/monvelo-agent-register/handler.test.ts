import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { createMonveloAgentRegisterHandler } from "./handler.ts";

const KEY = "c0000000-0000-4000-8000-000000000001"; // strict v4: version 4, variant 8
const AGENT = "d0000000-0000-4000-8000-000000000002";
const SECRET = "gw-secret-value";
const NUMBER = "0123456789";
const PREFLIGHT = "monvelo_agent_register_preflight";

type PreflightMock = { replay: false } | { replay: true; response: Record<string, unknown> } | GatewayError;

function setup(opts: {
  reply?: Record<string, unknown>;
  resolveError?: Error;
  preflight?: PreflightMock;
  rpcError?: GatewayError;
} = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const resolveCalls: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === PREFLIGHT) {
      const p = opts.preflight ?? { replay: false };
      return p instanceof GatewayError ? Promise.reject(p) : Promise.resolve(p as T);
    }
    if (opts.rpcError) return Promise.reject(opts.rpcError);
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

const post = (handler: (r: Request) => Promise<Response>, body: unknown, authorization: string | null = "Bearer tok") =>
  handler(
    new Request("http://x/monvelo-agent-register", {
      method: "POST",
      headers: authorization ? { Authorization: authorization } : {},
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

// the client's request as the database hashes it: no holder name
const CLIENT_AGENT = {
  business_name: "Ada POS",
  pos_network: "MONIEPOINT",
  network_agent_id: "mp-123",
  contact_phone: "+2348031234567",
  latitude: 6.6,
  longitude: 3.35,
  address_text: "12 Allen Ave, Ikeja",
  settlement_account_number: NUMBER,
  settlement_bank_code: "058",
  network_kyc_reference: "KYC-1",
};

Deno.test("register: preflight first, then Paystack, then the RPC with the proof, the resolved name and a normalised phone", async () => {
  const { handler, rpcCalls, resolveCalls } = setup();
  const res = await post(handler, register({ settlement_account_name: "CLIENT CHOSEN NAME" }));
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(resolveCalls, [[NUMBER, "058"]]);
  assertEquals(rpcCalls, [
    [PREFLIGHT, { p_idempotency_key: KEY, p_operation: "register_monvelo_agent", p_request: CLIENT_AGENT }],
    ["register_monvelo_agent", {
      p_idempotency_key: KEY,
      p_gateway_proof: SECRET,
      p_agent: { ...CLIENT_AGENT, settlement_account_name: "ADA OBI STORES" },
    }],
  ]);
  assertEquals(JSON.stringify(rpcCalls).includes("CLIENT CHOSEN"), false);
  assertEquals(JSON.parse(text), { agent_id: AGENT, status: "PENDING", name_matches: true, settlement_account_last4: "6789" });
  assertEquals(text.includes(NUMBER) || text.includes("2348031234567"), false);
});

Deno.test("the preflight never carries the gateway proof or a holder name", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, register());
  await res.body?.cancel();
  const pre = JSON.stringify(rpcCalls.find(([fn]) => fn === PREFLIGHT));
  assertEquals([pre.includes(SECRET), pre.includes("settlement_account_name")], [false, false]);
});

Deno.test("a cached replay returns the stored 200 with no Paystack call and no second RPC", async () => {
  const { handler, rpcCalls, resolveCalls } = setup({
    preflight: { replay: true, response: { agent_id: AGENT, status: "PENDING", name_matches: true } },
  });
  const res = await post(handler, register());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { agent_id: AGENT, status: "PENDING", name_matches: true, settlement_account_last4: "6789" });
  assertEquals(resolveCalls.length, 0);
  assertEquals(rpcCalls.map(([fn]) => fn), [PREFLIGHT]);
});

Deno.test("a key reused for a different request is 409 IDEMPOTENCY_MISMATCH before Paystack", async () => {
  const { handler, rpcCalls, resolveCalls } = setup({
    preflight: new GatewayError(409, "IDEMPOTENCY_MISMATCH", "This request was already submitted with different details."),
  });
  const res = await post(handler, register());
  assertEquals([res.status, (await res.json()).error.code], [409, "IDEMPOTENCY_MISMATCH"]);
  assertEquals([resolveCalls.length, rpcCalls.length], [0, 1]);
});

Deno.test("a caller the preflight refuses (403) never reaches Paystack or the write RPC", async () => {
  const { handler, rpcCalls, resolveCalls } = setup({
    preflight: new GatewayError(403, "FORBIDDEN", "You do not have permission to do that."),
  });
  // even an account Paystack would refuse: 403, never the 422 that says "no such account"
  const res = await post(handler, register({ settlement_account_number: "0000000000" }));
  assertEquals([res.status, (await res.json()).error.code], [403, "FORBIDDEN"]);
  assertEquals([resolveCalls.length, rpcCalls.length], [0, 1]);
});

Deno.test("no JWT is 401 before any RPC or Paystack call", async () => {
  const { handler, rpcCalls, resolveCalls } = setup();
  const res = await post(handler, register(), null);
  assertEquals(res.status, 401);
  await res.body?.cancel();
  assertEquals([resolveCalls.length, rpcCalls.length], [0, 0]);
});

Deno.test("the idempotency key must be a strict UUID v4: v1, v7, a bad variant, nil and junk are 400", async () => {
  for (const bad of [
    "6ba7b810-9dad-11d1-80b4-00c04fd430c8", // v1
    "01890a5d-ac96-774b-bcce-b302099a8057", // v7
    "c0000000-0000-4000-c000-000000000001", // version 4, variant c
    "00000000-0000-0000-0000-000000000000",
    "not-a-uuid",
  ]) {
    for (const body of [register({ idempotency_key: bad }), {
      idempotency_key: bad, action: "change_settlement", agent_id: AGENT,
      settlement_account_number: NUMBER, settlement_bank_code: "058",
    }]) {
      const { handler, rpcCalls, resolveCalls } = setup();
      const res = await post(handler, body);
      assertEquals([res.status, (await res.json()).error.code], [400, "VALIDATION_FAILED"], bad);
      assertEquals([resolveCalls.length, rpcCalls.length], [0, 0]);
    }
  }
});

Deno.test("a key sent only as a header is 400", async () => {
  const { handler, rpcCalls } = setup();
  const { idempotency_key: _, ...noKey } = register();
  const res = await handler(new Request("http://x/monvelo-agent-register", {
    method: "POST",
    headers: { Authorization: "Bearer tok", "x-idempotency-key": KEY },
    body: JSON.stringify(noKey),
  }));
  assertEquals(res.status, 400);
  await res.body?.cancel();
  assertEquals(rpcCalls.length, 0);
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

Deno.test("an unresolvable account is 422 and the write RPC is never called", async () => {
  const { handler, rpcCalls } = setup({
    resolveError: new GatewayError(422, "ACCOUNT_NOT_RESOLVED", "That bank account could not be verified."),
  });
  const res = await post(handler, register());
  const err = (await res.json()).error;
  assertEquals(
    [res.status, err.code, err.message, rpcCalls.map(([fn]) => fn)],
    [422, "ACCOUNT_NOT_RESOLVED", "That bank account could not be verified.", [PREFLIGHT]],
  );
});

Deno.test("change_settlement needs agent_id, preflights the account without a name, and returns only the last four", async () => {
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
  assertEquals(rpcCalls, [
    [PREFLIGHT, {
      p_idempotency_key: KEY,
      p_operation: "request_monvelo_settlement_change",
      p_request: { agent_id: AGENT, account: { settlement_account_number: NUMBER, settlement_bank_code: "058" } },
    }],
    ["request_monvelo_settlement_change", {
      p_idempotency_key: KEY,
      p_gateway_proof: SECRET,
      p_agent_id: AGENT,
      p_account: { settlement_account_number: NUMBER, settlement_bank_code: "058", settlement_account_name: "ADA OBI STORES" },
    }],
  ]);
  assertEquals(JSON.parse(text), { agent_id: AGENT, status: "PENDING_APPROVAL", settlement_account_last4: "6789" });
  assertEquals(text.includes(NUMBER), false);
});

Deno.test("change_settlement replays from the preflight with no Paystack call", async () => {
  const { handler, rpcCalls, resolveCalls } = setup({
    preflight: { replay: true, response: { agent_id: AGENT, status: "PENDING_APPROVAL", last4: "6789" } },
  });
  const res = await post(handler, {
    idempotency_key: KEY, action: "change_settlement", agent_id: AGENT,
    settlement_account_number: NUMBER, settlement_bank_code: "058",
  });
  assertEquals(await res.json(), { agent_id: AGENT, status: "PENDING_APPROVAL", settlement_account_last4: "6789" });
  assertEquals([resolveCalls.length, rpcCalls.map(([fn]) => fn)], [0, [PREFLIGHT]]);
});

Deno.test("a client tenant_id is ignored and a database refusal maps through (23505 is 409)", async () => {
  const { handler, rpcCalls } = setup({
    rpcError: new GatewayError(409, "CONFLICT", "this agent is already registered with Monvelo"),
  });
  const res = await post(handler, register({ tenant_id: crypto.randomUUID() }));
  assertEquals(res.status, 409);
  await res.body?.cancel();
  assertEquals(JSON.stringify(rpcCalls).includes("tenant_id"), false);
});
