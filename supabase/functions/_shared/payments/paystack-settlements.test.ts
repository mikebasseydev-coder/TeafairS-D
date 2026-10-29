import { assertEquals } from "jsr:@std/assert@1";
import {
  paystackSettlementLister,
  paystackSettlementTransactionLister,
  paystackSubaccountFetcher,
} from "./paystack-settlements.ts";

function fake(body: unknown, seen: string[]): typeof fetch {
  return (input) => {
    seen.push(String(input));
    return Promise.resolve(new Response(JSON.stringify(body)));
  };
}

Deno.test("subaccount code resolves to id", async () => {
  const seen: string[] = [];
  const id = await paystackSubaccountFetcher({
    secretKey: "k",
    fetchFn: fake({ status: true, data: { id: 55, subaccount_code: "ACCT_grace01" } }, seen),
  })("ACCT_grace01");
  assertEquals(id, "55");
  assertEquals(seen, ["https://api.paystack.co/subaccount/ACCT_grace01"]);
});

Deno.test("settlements are filtered by subaccount id and success", async () => {
  const seen: string[] = [];
  const from = new Date("2026-10-01T00:00:00.000Z");
  const out = await paystackSettlementLister({
    secretKey: "k",
    fetchFn: fake({
      status: true,
      data: [{ id: 9001, status: "success", settlement_date: "2026-10-02T00:00:00.000Z", total_amount: 5 }],
      meta: { pageCount: 1 },
    }, seen),
  })({ subaccountId: "55", from });
  assertEquals(out, [{ id: "9001", settledAt: "2026-10-02T00:00:00.000Z" }]);
  const u = new URL(seen[0]);
  assertEquals(u.pathname, "/settlement");
  assertEquals(u.searchParams.get("subaccount"), "55");
  assertEquals(u.searchParams.get("status"), "success");
  assertEquals(u.searchParams.get("from"), from.toISOString());
});

Deno.test("settlement transaction share comes from fees_split.subaccount", async () => {
  const seen: string[] = [];
  const out = await paystackSettlementTransactionLister({
    secretKey: "k",
    fetchFn: fake({
      status: true,
      data: [{ reference: "TFW-1", fees_split: { paystack: 100, integration: 0, subaccount: 3750 }, customer: { email: "b@x.com" } }],
      meta: { pageCount: 1 },
    }, seen),
  })("9001");
  assertEquals(out, [{ reference: "TFW-1", shareMinor: 3750 }]);
  assertEquals(new URL(seen[0]).pathname, "/settlement/9001/transactions");
});

Deno.test("null fees_split gives shareMinor null", async () => {
  const out = await paystackSettlementTransactionLister({
    secretKey: "k",
    fetchFn: fake({ status: true, data: [{ reference: "TFW-2", fees_split: null }], meta: { pageCount: 1 } }, []),
  })("9001");
  assertEquals(out, [{ reference: "TFW-2", shareMinor: null }]);
});
