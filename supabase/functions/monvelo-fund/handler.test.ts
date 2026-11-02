import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { type InitializeRequest, PaystackDuplicateReference } from "../_shared/payments/paystack.ts";
import { checkoutKey, createMonveloFundHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const FIN = "e0000000-0000-0000-0000-000000000003";
const AGENT = "d0000000-0000-0000-0000-000000000002";
const REF = "MV-ABCDEFGH-1";

const STARTED = { payment_id: "p1", reference: REF, amount_minor: 4500000, currency: "NGN", claim_expires_at: "2026-11-01T00:00:00Z" };

function setup(opts: {
  rpcError?: Error;
  paystackError?: Error;
  recordError?: Error;
  started?: Record<string, unknown>;
} = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const inits: InitializeRequest[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "record_monvelo_checkout") {
      return opts.recordError ? Promise.reject(opts.recordError) : Promise.resolve({ recorded: true } as T);
    }
    if (opts.rpcError) return Promise.reject(opts.rpcError);
    return Promise.resolve((opts.started ?? { ...STARTED, replayed: false }) as T);
  };
  const handler = createMonveloFundHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    initializeTransaction: (req) => {
      inits.push(req);
      if (opts.paystackError) return Promise.reject(opts.paystackError);
      return Promise.resolve({ reference: req.reference, accessCode: "ac_SECRET", authorizationUrl: "https://checkout.paystack.com/ac_SECRET" });
    },
    gatewaySecret: "gw-secret",
  });
  const recorded = () => rpcCalls.filter(([fn]) => fn === "record_monvelo_checkout").map(([, args]) => args);
  return { handler, rpcCalls, inits, recorded };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/monvelo-fund", { method: "POST", headers: { Authorization: "Bearer tok" }, body: JSON.stringify(body) }));

const body = (over: Record<string, unknown> = {}) => ({ idempotency_key: KEY, financing_id: FIN, agent_id: AGENT, ...over });

Deno.test("happy path: RPC first, then Paystack with bank_transfer, the synthetic email and Monvelo metadata", async () => {
  const { handler, rpcCalls, inits } = setup();
  const res = await post(handler, body());
  assertEquals(res.status, 200);
  assertEquals(rpcCalls[0], ["start_monvelo_funding", { p_idempotency_key: KEY, p_financing_id: FIN, p_agent_id: AGENT }]);
  assertEquals(inits, [{
    reference: REF,
    amountMinor: 4500000,
    currency: "NGN",
    email: "monvelo-mv-abcdefgh-1@pay.teafairweb.com",
    channels: ["bank_transfer"],
    metadata: { kind: "monvelo", financing_id: FIN },
  }]);
  assertEquals(await res.json(), {
    reference: REF, authorization_url: "https://checkout.paystack.com/ac_SECRET", access_code: "ac_SECRET",
  });
});

// R53: a retried key must not dead-end on Paystack's duplicate-reference refusal
Deno.test("the first call stores the checkout on the caller's JWT with the gateway proof (R59)", async () => {
  const { handler, recorded } = setup();
  assertEquals((await post(handler, body())).status, 200);
  assertEquals(recorded(), [{
    p_idempotency_key: await checkoutKey("p1"), p_gateway_proof: "gw-secret", p_payment_id: "p1",
    p_authorization_url: "https://checkout.paystack.com/ac_SECRET", p_access_code: "ac_SECRET",
  }]);
});

Deno.test("the checkout key is a stable uuid per payment", async () => {
  const a = await checkoutKey("11111111-1111-1111-1111-111111111111");
  assertEquals(a, await checkoutKey("11111111-1111-1111-1111-111111111111"));
  assertEquals(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(a), true);
  assertEquals(a === await checkoutKey("22222222-2222-2222-2222-222222222222"), false);
});

Deno.test("a replay returns the stored checkout and never calls Initialize", async () => {
  const { handler, inits, recorded } = setup({
    started: { ...STARTED, replayed: true, authorization_url: "https://checkout.paystack.com/ac_STORED", access_code: "ac_STORED" },
  });
  const res = await post(handler, body());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { reference: REF, authorization_url: "https://checkout.paystack.com/ac_STORED", access_code: "ac_STORED" });
  assertEquals(inits.length, 0);
  assertEquals(recorded().length, 0);
});

Deno.test("a replay with nothing stored initialises again and stores what Paystack returns", async () => {
  const { handler, inits, recorded } = setup({ started: { ...STARTED, replayed: true } });
  const res = await post(handler, body());
  assertEquals(res.status, 200);
  assertEquals(inits.length, 1);
  assertEquals(recorded().length, 1);
});

Deno.test("a replay with nothing stored that Paystack refuses as a duplicate is 409 MONVELO_CHECKOUT_LOST", async () => {
  const { handler, inits } = setup({ started: { ...STARTED, replayed: true }, paystackError: new PaystackDuplicateReference() });
  const res = await post(handler, body());
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error.code, "MONVELO_CHECKOUT_LOST");
  assertEquals(inits.length, 1);
});

Deno.test("a first call that Paystack refuses is still 502, duplicate or not", async () => {
  const { handler } = setup({ paystackError: new PaystackDuplicateReference() });
  assertEquals((await post(handler, body())).status, 502);
});

Deno.test("a failed store still returns the checkout, and logs nothing of it", async () => {
  const logged: unknown[][] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => logged.push(args);
  try {
    const { handler } = setup({ recordError: new Error("db down ac_SECRET") });
    const res = await post(handler, body());
    assertEquals(res.status, 200);
    assertEquals((await res.json()).access_code, "ac_SECRET");
  } finally {
    console.error = original;
  }
  assertEquals(JSON.stringify(logged).includes("ac_SECRET"), false);
});

Deno.test("the gateway takes no service-role client (R59)", async () => {
  const src = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  assertEquals(/serviceRpc|SERVICE_ROLE/.test(src), false);
  assertEquals(/GATEWAY_SECRET/.test(src), true);
});

Deno.test("an RPC refusal (42501) is 403 and Paystack is never called", async () => {
  const { handler, inits } = setup({ rpcError: new GatewayError(403, "FORBIDDEN", "not your agent") });
  const res = await post(handler, body());
  assertEquals(res.status, 403);
  assertEquals(inits.length, 0);
});

Deno.test("a Paystack failure is 502 PAYSTACK_UNAVAILABLE and leaks nothing", async () => {
  const { handler } = setup({ paystackError: new Error("Paystack initialize failed: sk_live_LEAK") });
  const res = await post(handler, body());
  const text = await res.text();
  assertEquals(res.status, 502);
  assertEquals(JSON.parse(text).error.code, "PAYSTACK_UNAVAILABLE");
  assertEquals(text.includes("sk_live_LEAK"), false);
});

Deno.test("a bad body is 400", async () => {
  const { handler, rpcCalls } = setup();
  assertEquals((await post(handler, body({ financing_id: "nope" }))).status, 400);
  assertEquals((await post(handler, { idempotency_key: KEY })).status, 400);
  assertEquals(rpcCalls.length, 0);
});
