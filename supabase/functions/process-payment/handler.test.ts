import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import type { VerifiedTransaction, VerifyTransaction } from "../_shared/fintech-liquidity/paystack.ts";
import { createProcessPaymentHandler } from "./handler.ts";

const SECRET = "sk_test_secret";
const NOW = new Date("2026-10-07T12:00:00Z");

async function sign(body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
}

function setup(opts: { verify?: VerifyTransaction; rpcResult?: unknown } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const verifyCalls: string[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve((opts.rpcResult ?? { outcome: "updated" }) as T);
  };
  const verified: VerifiedTransaction = { status: "success", reference: "ref_1", amountMinor: 250000, currency: "NGN", raw: { id: 9 } };
  const verifyTransaction: VerifyTransaction = opts.verify ?? ((ref) => {
    verifyCalls.push(ref);
    return Promise.resolve(verified);
  });
  const handler = createProcessPaymentHandler({ secretKey: SECRET, verifyTransaction, rpc, now: () => NOW });
  return { handler, rpcCalls, verifyCalls };
}

async function deliver(handler: (r: Request) => Promise<Response>, payload: unknown, signature?: string) {
  const body = JSON.stringify(payload);
  return handler(new Request("http://x", {
    method: "POST",
    body,
    headers: { "x-paystack-signature": signature ?? await sign(body) },
  }));
}

const fresh = { event: "charge.success", data: { reference: "ref_1", amount: 1, currency: "XXX", paid_at: "2026-10-07T11:59:00Z" } };

Deno.test("a bad signature is 401 and touches nothing", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await deliver(handler, fresh, "00");
  assertEquals(res.status, 401);
  assertEquals([rpcCalls.length, verifyCalls.length], [0, 0]);
});

Deno.test("events other than charge.success are acknowledged and ignored", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await deliver(handler, { event: "transfer.success", data: { reference: "t" } });
  assertEquals([res.status, (await res.json()).outcome], [200, "ignored"]);
  assertEquals([rpcCalls.length, verifyCalls.length], [0, 0]);
});

Deno.test("a stale event is acknowledged, audited, and never verified or applied", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const stale = { ...fresh, data: { ...fresh.data, paid_at: "2026-10-07T11:50:00Z" } };
  const res = await deliver(handler, stale);
  assertEquals([res.status, (await res.json()).outcome], [200, "stale"]);
  assertEquals(verifyCalls, []);
  assertEquals(rpcCalls, [["record_stale_paystack_webhook",
    { p_event: "charge.success", p_reference: "ref_1", p_event_time: "2026-10-07T11:50:00.000Z" }]]);
});

Deno.test("a fresh event settles with the Verify API's values, not the webhook's", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await deliver(handler, fresh);
  assertEquals([res.status, (await res.json()).outcome], [200, "updated"]);
  assertEquals(verifyCalls, ["ref_1"]);
  assertEquals(rpcCalls, [["settle_paystack_payment", {
    p_event: "charge.success", p_reference: "ref_1", p_status: "success",
    p_amount_minor: 250000, p_currency: "NGN", p_verified: { id: 9 },
  }]]);
});

Deno.test("a Verify API outage is a 500, so Paystack retries", async () => {
  const { handler, rpcCalls } = setup({ verify: () => Promise.reject(new Error("timeout")) });
  const res = await deliver(handler, fresh);
  assertEquals(res.status, 500);
  assertEquals(rpcCalls.length, 0);
});

Deno.test("a Verify API answer for a different reference is refused", async () => {
  const { handler, rpcCalls } = setup({
    verify: () => Promise.resolve({ status: "success", reference: "other", amountMinor: 1, currency: "NGN", raw: {} }),
  });
  const res = await deliver(handler, fresh);
  assertEquals([res.status, (await res.json()).error.code], [502, "PAYSTACK_MISMATCH"]);
  assertEquals(rpcCalls.length, 0);
});

Deno.test("a signed body that is not JSON is acknowledged and ignored", async () => {
  const { handler, rpcCalls } = setup();
  const body = "not json";
  const res = await handler(new Request("http://x", { method: "POST", body, headers: { "x-paystack-signature": await sign(body) } }));
  assertEquals([res.status, rpcCalls.length], [200, 0]);
});
