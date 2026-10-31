import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { Rpc } from "../core/db.ts";
import type { PaystackRefund } from "./paystack-refunds.ts";
import type { VerifiedTransaction } from "./paystack.ts";
import { applyRefunds, isMonveloReference, settleVerified } from "./settle.ts";

function fakeRpc(results: Record<string, unknown> = {}) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve((results[fn] ?? { outcome: "updated" }) as T);
  };
  return { rpc, calls };
}

const tx: VerifiedTransaction = {
  status: "success", reference: "ref_1", amountMinor: 250000, currency: "NGN", transactionId: "9",
  split: { subaccountCode: "ACCT_x", shareMinor: 1000 }, raw: { id: 9 },
};

Deno.test("success passes the split through", async () => {
  const { rpc, calls } = fakeRpc();
  const r = await settleVerified(rpc, "charge.success", tx);
  assertEquals(r.outcome, "updated");
  assertEquals(calls, [["settle_paystack_payment", {
    p_event: "charge.success", p_reference: "ref_1", p_status: "success", p_amount_minor: 250000,
    p_currency: "NGN", p_verified: { id: 9 }, p_transaction_id: "9",
    p_split_subaccount: "ACCT_x", p_split_share_minor: 1000,
  }]]);
});

Deno.test("reversed applies only a reversal, never a settlement", async () => {
  const { rpc, calls } = fakeRpc({ apply_paystack_refund: { outcome: "refunded" } });
  const r = await settleVerified(rpc, "sweep", { ...tx, status: "reversed", split: null });
  assertEquals(r.outcome, "refunded");
  assertEquals(calls, [["apply_paystack_refund", {
    p_source: "sweep", p_refund_id: "reversal:ref_1", p_transaction_reference: "ref_1",
    p_amount_minor: 250000, p_currency: "NGN", p_reason: "REVERSAL", p_verified: { id: 9 },
  }]]);
});

Deno.test("a webhook reversal is applied with source webhook", async () => {
  const { rpc, calls } = fakeRpc({ apply_paystack_refund: { outcome: "refunded" } });
  await settleVerified(rpc, "charge.success", { ...tx, status: "reversed" });
  assertEquals(calls.map((c) => [c[0], c[1].p_source]), [["apply_paystack_refund", "webhook"]]);
});

Deno.test("applyRefunds continues past a failing refund", async () => {
  const calls: string[] = [];
  const rpc: Rpc = <T>(_fn: string, args: Record<string, unknown>) => {
    calls.push(String(args.p_refund_id));
    if (args.p_refund_id === "1") return Promise.reject(new Error("db down"));
    return Promise.resolve({ outcome: "refunded" } as T);
  };
  const mk = (id: string): PaystackRefund =>
    ({ id, transactionReference: "r" + id, amountMinor: 100, currency: "NGN", status: "processed", raw: { id } });
  const counts = await applyRefunds(rpc, "sweep", [mk("1"), mk("2")]);
  assertEquals(calls, ["1", "2"]);
  assertEquals(counts, { error: 1, refunded: 1 });
});

Deno.test("applyRefunds skips non-processed and unreadable", async () => {
  const { rpc, calls } = fakeRpc({ apply_paystack_refund: { outcome: "refunded" } });
  const mk = (id: string, status: string, ref: string | null): PaystackRefund =>
    ({ id, transactionReference: ref, amountMinor: 100, currency: "NGN", status, raw: { id } });
  const counts = await applyRefunds(rpc, "webhook", [mk("1", "processed", "r1"), mk("2", "pending", "r2"), mk("3", "processed", null)]);
  assertEquals(counts, { refunded: 1, unreadable: 1 });
  assertEquals(calls.length, 1);
  assertEquals(calls[0][1].p_refund_id, "1");
  assertEquals(calls[0][1].p_reason, "REFUND");
});

const mv: VerifiedTransaction = { ...tx, reference: "MV-ABCDEFGH-1", split: null };

Deno.test("an MV- reference settles through Monvelo and never the web RPC", async () => {
  const { rpc, calls } = fakeRpc({ settle_monvelo_funding: { outcome: "funded" } });
  const r = await settleVerified(rpc, "charge.success", mv);
  assertEquals(r.outcome, "funded");
  assertEquals(calls, [["settle_monvelo_funding", {
    p_event: "charge.success", p_reference: "MV-ABCDEFGH-1", p_status: "success", p_amount_minor: 250000,
    p_currency: "NGN", p_verified: { id: 9 }, p_transaction_id: "9",
  }]]);
});

Deno.test("an MV- reversal throws until Task 5 routes it", async () => {
  const { rpc, calls } = fakeRpc();
  await assertRejects(() => settleVerified(rpc, "sweep", { ...mv, status: "reversed" }), Error, "monvelo reversals are applied as refunds");
  assertEquals(calls, []);
});

Deno.test("isMonveloReference matches only the MV format", () => {
  assertEquals(
    ["MV-ABCDEFGH-1", "MV-A2B3C4D5-12", "MV-abcdefgh-1", "MV-ABCDEFG-1", "TFW-ABCDEFGH-1", "xMV-ABCDEFGH-1", "MV-ABCDEFGH-1x", "MV-ABCDEFG1-1"]
      .map(isMonveloReference),
    [true, true, false, false, false, false, false, false],
  );
});
