import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import type { VerifyTransaction } from "../_shared/fintech-liquidity/paystack.ts";
import type { ListRefunds } from "../_shared/fintech-liquidity/paystack-refunds.ts";
import { createReconcileFundsHandler } from "./handler.ts";

const SECRET = "cron_secret";
const NOW = new Date("2026-10-20T05:00:00Z");

function setup(opts: { verify?: VerifyTransaction } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const verifyCalls: string[] = [];
  const listCalls: Array<{ reference?: string; from?: string; to?: string }> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "claim_unconfirmed_payments") {
      return Promise.resolve([
        { paystack_reference: "ref_1", created_at: "2026-10-20T04:00:00Z" },
        { paystack_reference: "ref_2", created_at: "2026-10-20T04:01:00Z" },
      ] as T);
    }
    return Promise.resolve({ outcome: "updated" } as T);
  };
  const verifyTransaction: VerifyTransaction = opts.verify ?? ((ref) => {
    verifyCalls.push(ref);
    return Promise.resolve({ status: "success", reference: ref, amountMinor: 100, currency: "NGN", transactionId: "9", split: null, raw: {} });
  });
  const listRefunds: ListRefunds = (q) => {
    listCalls.push(q);
    return Promise.resolve([
      { id: "1", transactionReference: "ref_1", amountMinor: 5, currency: "NGN", status: "processed", raw: {} },
      { id: "2", transactionReference: "ref_2", amountMinor: 5, currency: "NGN", status: "pending", raw: {} },
    ]);
  };
  const handler = createReconcileFundsHandler({ cronSecret: SECRET, rpc, verifyTransaction, listRefunds, now: () => NOW });
  return { handler, rpcCalls, verifyCalls, listCalls };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown, secret = SECRET) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { "x-cron-secret": secret } }));

Deno.test("wrong secret is 401 and touches nothing", async () => {
  const { handler, rpcCalls, verifyCalls, listCalls } = setup();
  const res = await post(handler, { mode: "sweep" }, "nope");
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error.code, "UNAUTHORIZED");
  assertEquals([rpcCalls.length, verifyCalls.length, listCalls.length], [0, 0, 0]);
});

Deno.test("GET is 405", async () => {
  const { handler } = setup();
  const res = await handler(new Request("http://x", { method: "GET", headers: { "x-cron-secret": SECRET } }));
  assertEquals(res.status, 405);
});

Deno.test("sweep verifies and settles each payment", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await post(handler, { mode: "sweep" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { mode: "sweep", seen: 2, outcomes: { updated: 2 }, errors: 0 });
  assertEquals(rpcCalls[0], ["claim_unconfirmed_payments", { p_limit: 50 }]);
  assertEquals(verifyCalls, ["ref_1", "ref_2"]);
  const settles = rpcCalls.filter(([fn]) => fn === "settle_paystack_payment");
  assertEquals(settles.length, 2);
  assertEquals(settles.map(([, a]) => a.p_event), ["sweep", "sweep"]);
});

Deno.test("one payment's error does not stop the batch", async () => {
  const verified: string[] = [];
  const { handler, rpcCalls } = setup({
    verify: (ref) => {
      if (ref === "ref_1") return Promise.reject(new Error("boom"));
      verified.push(ref);
      return Promise.resolve({ status: "success", reference: ref, amountMinor: 100, currency: "NGN", transactionId: "9", split: null, raw: {} });
    },
  });
  const res = await post(handler, { mode: "sweep" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { mode: "sweep", seen: 2, outcomes: { updated: 1 }, errors: 1 });
  assertEquals(verified, ["ref_2"]);
  assertEquals(rpcCalls.filter(([fn]) => fn === "settle_paystack_payment").length, 1);
});

Deno.test("a Verify reply for another reference is an error and is not settled", async () => {
  const { handler, rpcCalls } = setup({
    verify: (ref) =>
      Promise.resolve({
        status: "success", reference: ref === "ref_1" ? "ref_other" : ref, amountMinor: 100, currency: "NGN",
        transactionId: "9", split: null, raw: {},
      }),
  });
  const res = await post(handler, { mode: "sweep" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { mode: "sweep", seen: 2, outcomes: { updated: 1 }, errors: 1 });
  const settles = rpcCalls.filter(([fn]) => fn === "settle_paystack_payment");
  assertEquals(settles.map(([, a]) => a.p_reference), ["ref_2"]);
});

Deno.test("refunds mode warns with the count of unreadable refunds, and nothing else", async () => {
  const warned: unknown[][] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => void warned.push(args);
  try {
    const handler = createReconcileFundsHandler({
      cronSecret: SECRET, now: () => NOW,
      rpc: <T>() => Promise.resolve({ outcome: "refunded" } as T),
      verifyTransaction: () => Promise.reject(new Error("unused")),
      listRefunds: () => Promise.resolve([
        { id: "1", transactionReference: null, amountMinor: 5, currency: "NGN", status: "processed",
          raw: { customer: { email: "buyer@example.com" } } },
        { id: "2", transactionReference: null, amountMinor: 5, currency: "NGN", status: "processed", raw: {} },
        { id: "3", transactionReference: "ref_3", amountMinor: 5, currency: "NGN", status: "processed", raw: {} },
      ]),
    });
    const res = await post(handler, { mode: "refunds" });
    assertEquals(await res.json(), { mode: "refunds", seen: 3, outcomes: { refunded: 1, unreadable: 2 }, errors: 0 });
  } finally {
    console.warn = original;
  }
  assertEquals(warned.length, 1);
  assertEquals(warned[0].includes(2), true);
  assertEquals(JSON.stringify(warned).includes("buyer@example.com"), false);
});

Deno.test("refunds mode does not warn when every refund is readable", async () => {
  const warned: unknown[][] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => void warned.push(args);
  try {
    const { handler } = setup();
    await (await post(handler, { mode: "refunds" })).json();
  } finally {
    console.warn = original;
  }
  assertEquals(warned.length, 0);
});

Deno.test("refunds mode lists the last 3 days", async () => {
  const { handler, listCalls, rpcCalls } = setup();
  const res = await post(handler, { mode: "refunds" });
  assertEquals(res.status, 200);
  assertEquals(listCalls, [{ from: "2026-10-17", to: "2026-10-21" }]);
  assertEquals(await res.json(), { mode: "refunds", seen: 2, outcomes: { updated: 1 }, errors: 0 });
  assertEquals(rpcCalls.filter(([fn]) => fn === "apply_paystack_refund").length, 1);
});

Deno.test("refunds mode counts a failing refund and continues", async () => {
  const rpc: Rpc = <T>(_fn: string, args: Record<string, unknown>) =>
    args.p_refund_id === "1" ? Promise.reject(new Error("db down")) : Promise.resolve({ outcome: "refunded" } as T);
  const handler = createReconcileFundsHandler({
    cronSecret: SECRET, rpc, now: () => NOW,
    verifyTransaction: () => Promise.reject(new Error("unused")),
    listRefunds: () => Promise.resolve([
      { id: "1", transactionReference: "ref_1", amountMinor: 5, currency: "NGN", status: "processed", raw: {} },
      { id: "3", transactionReference: "ref_3", amountMinor: 5, currency: "NGN", status: "processed", raw: {} },
    ]),
  });
  const res = await post(handler, { mode: "refunds" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { mode: "refunds", seen: 2, outcomes: { refunded: 1 }, errors: 1 });
});

Deno.test("unknown mode is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, { mode: "nuke" });
  assertEquals(res.status, 400);
  assertEquals(rpcCalls.length, 0);
});
