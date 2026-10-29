import { assertEquals } from "jsr:@std/assert@1";
import { paystackRefundLister } from "./paystack-refunds.ts";

function fake(items: unknown[], seen: string[]): typeof fetch {
  return (input) => {
    seen.push(String(input));
    return Promise.resolve(new Response(JSON.stringify({ status: true, data: items, meta: { pageCount: 1 } })));
  };
}
const item = {
  id: 747680, amount: 10000, currency: "NGN", status: "processed", transaction: 1234,
  transaction_reference: "TFW-1", customer: { email: "buyer@example.com" },
};

Deno.test("lists refunds for a reference", async () => {
  const seen: string[] = [];
  const list = paystackRefundLister({ secretKey: "k", fetchFn: fake([item], seen) });
  const out = await list({ reference: "TFW-1" });
  assertEquals(seen, ["https://api.paystack.co/refund?reference=TFW-1&perPage=100&page=1"]);
  assertEquals(out.length, 1);
  assertEquals(
    { id: out[0].id, amountMinor: out[0].amountMinor, status: out[0].status, transactionReference: out[0].transactionReference, currency: out[0].currency },
    { id: "747680", amountMinor: 10000, status: "processed", transactionReference: "TFW-1", currency: "NGN" },
  );
});

Deno.test("missing transaction_reference is null", async () => {
  const { transaction_reference: _t, ...rest } = item;
  const list = paystackRefundLister({ secretKey: "k", fetchFn: fake([rest], []) });
  assertEquals((await list({}))[0].transactionReference, null);
});

Deno.test("date filters are passed through", async () => {
  const seen: string[] = [];
  await paystackRefundLister({ secretKey: "k", fetchFn: fake([], seen) })({ from: "2026-10-01", to: "2026-10-02" });
  assertEquals(seen[0], "https://api.paystack.co/refund?from=2026-10-01&to=2026-10-02&perPage=100&page=1");
});
