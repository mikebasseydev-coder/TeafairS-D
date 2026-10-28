import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import type { InitializeRequest, InitializeTransaction } from "../_shared/fintech-liquidity/paystack.ts";
import { createWebCheckoutHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const KEY = "c0000000-0000-0000-0000-000000000001";
const QUOTE = {
  total: 5580, currency: "NGN",
  split: { web_pos_partner_id: "p1", subaccount_code: "ACCT_grace01", commission_bps: 150, partner_share: 83.7 },
};
const TOKEN = "A".repeat(43);
const LGA = "d0000000-0000-0000-0000-000000000009";
const PLACED = { order_id: "o1", public_reference: "TF-7K3Q9X", total: 5580 };

type Opts = {
  human?: boolean | Error;
  quote?: unknown | Error;
  initFails?: boolean;
};

function setup(opts: Opts = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const inits: InitializeRequest[] = [];
  const turnstileCalls: Array<[string, string | null]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    const result = fn === "quote_web_order" ? (opts.quote ?? QUOTE) : PLACED;
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result as T);
  };
  const initializeTransaction: InitializeTransaction = (req) => {
    inits.push(req);
    if (opts.initFails) return Promise.reject(new Error("Paystack down"));
    return Promise.resolve({ reference: req.reference, accessCode: "ac_1", authorizationUrl: "https://checkout.paystack.com/ac_1" });
  };
  const handler = createWebCheckoutHandler({
    rpc,
    allowedOrigins: [ORIGIN],
    verifyTurnstile: (token, ip) => {
      turnstileCalls.push([token, ip]);
      const h = opts.human ?? true;
      return h instanceof Error ? Promise.reject(h) : Promise.resolve(h);
    },
    initializeTransaction,
    newReference: () => "TFW-FIXED",
    callbackUrl: "https://teafairweb.com/checkout/complete",
  });
  return { handler, rpcCalls, inits, turnstileCalls };
}

const order = (over: Record<string, unknown> = {}) => ({
  idempotency_key: KEY,
  code: "grace-01",
  lga_id: LGA,
  items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
  customer: { name: "Ada Obi", phone: "0803 123 4567", email: "Ada@Example.com", delivery_address: "5 Opebi Road, Ikeja" },
  utm: { source: "whatsapp", medium: "social" },
  payment_route: "PAYSTACK_WEB",
  turnstile_token: "tok",
  accept_refund_policy: true,
  policy_version_tag: "v2.0-food-cosmetics",
  phone_verification_token: TOKEN,
  ...over,
});

const post = (handler: (r: Request) => Promise<Response>, body: unknown, ip = "1.2.3.4") =>
  handler(new Request("http://x/web-checkout", {
    method: "POST",
    headers: { Origin: ORIGIN, "cf-connecting-ip": ip },
    body: JSON.stringify(body),
  }));

Deno.test("Paystack route: verify, quote, initialize with split, then place", async () => {
  const { handler, rpcCalls, inits, turnstileCalls } = setup();
  const res = await post(handler, order());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), PLACED);
  assertEquals(turnstileCalls, [["tok", "1.2.3.4"]]);
  assertEquals(rpcCalls.map(([fn]) => fn), ["quote_web_order", "place_web_order"]);
  assertEquals(inits[0], {
    reference: "TFW-FIXED", amountMinor: 558000, currency: "NGN", email: "ada@example.com",
    callbackUrl: "https://teafairweb.com/checkout/complete",
    metadata: { agent_code: "GRACE-01", payment_route: "PAYSTACK_WEB" },
    split: { subaccount: "ACCT_grace01", transactionChargeMinor: 549630 },
  });
  assertEquals(rpcCalls[1][1], {
    p_idempotency_key: KEY,
    p_code: "grace-01",
    p_lga_id: LGA,
    p_items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
    p_customer: { name: "Ada Obi", phone: "+2348031234567", email: "ada@example.com", delivery_address: "5 Opebi Road, Ikeja" },
    p_utm: { source: "whatsapp", medium: "social" },
    p_payment_route: "PAYSTACK_WEB",
    p_expected_total: 5580,
    p_accepted_refund_policy: true,
    p_policy_version_tag: "v2.0-food-cosmetics",
    p_client_ip: "1.2.3.4",
    p_phone_verification_token: TOKEN,
    p_checkout: { reference: "TFW-FIXED", access_code: "ac_1", authorization_url: "https://checkout.paystack.com/ac_1",
      split: { subaccount_code: "ACCT_grace01", commission_bps: 150, partner_share: 83.7 },
    },
  });
});

Deno.test("POS route: no Paystack call, no checkout", async () => {
  const { handler, rpcCalls, inits } = setup();
  const res = await post(handler, order({ payment_route: "POS_AGENT" }));
  assertEquals(res.status, 200);
  assertEquals(inits.length, 0);
  assertEquals(rpcCalls[1][1].p_checkout, null);
  await res.body?.cancel();
});

Deno.test("no email: Paystack gets a per-order address", async () => {
  const { handler, inits } = setup();
  const o = order();
  delete (o.customer as Record<string, unknown>).email;
  const res = await post(handler, o);
  assertEquals(inits[0].email, "order-tfw-fixed@pay.teafairweb.com");
  await res.body?.cancel();
});

Deno.test("no split: Initialize carries no subaccount", async () => {
  const { handler, inits } = setup({ quote: { total: 1200, currency: "NGN", split: null } });
  const res = await post(handler, order());
  assertEquals([inits[0].amountMinor, inits[0].split], [120000, undefined]);
  await res.body?.cancel();
});

Deno.test("a failed bot check is 403 and calls nothing", async () => {
  const { handler, rpcCalls } = setup({ human: false });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length], [403, "BOT_CHECK_FAILED", 0]);
});

Deno.test("a Turnstile outage is 503 and writes nothing", async () => {
  const { handler, rpcCalls } = setup({ human: new TypeError("network down") });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length], [503, "RETRY", 0]);
});

Deno.test("an unusable phone is 400 before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order({ customer: { name: "Ada", phone: "12345", delivery_address: "5 Opebi Road" } }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("a Paystack failure writes no order", async () => {
  const { handler, rpcCalls } = setup({ initFails: true });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.code], [502, "PAYMENT_PROVIDER_UNAVAILABLE"]);
  assertEquals(rpcCalls.map(([fn]) => fn), ["quote_web_order"]);
});

Deno.test("a business error from the quote passes through as 422", async () => {
  const { handler } = setup({ quote: new GatewayError(422, "BUSINESS_RULE", "This link is no longer valid") });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.message], [422, "This link is no longer valid"]);
});

Deno.test("an unknown payment route is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order({ payment_route: "CASH" }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("codeless checkout initialises without a split", async () => {
  const { handler, rpcCalls, inits } = setup({ quote: { total: 1200, currency: "NGN", split: null } });
  const o = order();
  delete (o as Record<string, unknown>).code;
  const res = await post(handler, o);
  assertEquals(res.status, 200);
  assertEquals(inits[0].metadata.agent_code, null);
  assertEquals(inits[0].split, undefined);
  assertEquals(rpcCalls[0][1].p_code, null);
  assertEquals((rpcCalls[1][1].p_checkout as Record<string, unknown>).split, null);
  assertEquals(rpcCalls[1][1].p_lga_id, LGA);
  await res.body?.cancel();
});

Deno.test("lga_id is required", async () => {
  const { handler, rpcCalls } = setup();
  const o = order();
  delete (o as Record<string, unknown>).lga_id;
  const res = await post(handler, o);
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("codeless POS_AGENT is 400", async () => {
  const { handler, rpcCalls } = setup();
  const o = order({ payment_route: "POS_AGENT" });
  delete (o as Record<string, unknown>).code;
  const res = await post(handler, o);
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length], [400, "VALIDATION_FAILED", 0]);
});

Deno.test("the quote's split travels to place_web_order", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order());
  const checkout = rpcCalls[1][1].p_checkout as Record<string, unknown>;
  assertEquals(checkout.split, { subaccount_code: "ACCT_grace01", commission_bps: 150, partner_share: 83.7 });
  await res.body?.cancel();
});

Deno.test("missing accept_refund_policy is 400 with the consent copy", async () => {
  for (const over of [{ accept_refund_policy: undefined }, { accept_refund_policy: false }]) {
    const { handler, rpcCalls, turnstileCalls } = setup();
    const res = await post(handler, order(over));
    assertEquals([res.status, (await res.json()).error.message, rpcCalls.length, turnstileCalls.length], [
      400, "You must accept the refund policy to place an order.", 0, 0,
    ]);
  }
});

Deno.test("a verification token that is not 43 characters is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order({ phone_verification_token: "short" }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("a non-IP client address header is dropped to null, never a 500 (R19)", async () => {
  const { handler, rpcCalls, turnstileCalls } = setup();
  const res = await post(handler, order(), "unknown");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(turnstileCalls, [["tok", null]]);
  assertEquals(rpcCalls[1][1].p_client_ip, null);
});

Deno.test("an IPv6 client address reaches the consent record (R19)", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order(), "2001:db8::42");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(rpcCalls[1][1].p_client_ip, "2001:db8::42");
});
