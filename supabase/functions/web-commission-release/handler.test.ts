import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import type {
  FetchSubaccountId,
  ListSettlements,
  ListSettlementTransactions,
} from "../_shared/payments/paystack-settlements.ts";
import { createCommissionReleaseHandler } from "./handler.ts";

const SECRET = "cron_secret";

type Row = { subaccount_code: string; oldest_at: string; payment_references: string[] };
const ROWS: Row[] = [
  { subaccount_code: "ACCT_a", oldest_at: "2026-10-10T12:00:00Z", payment_references: ["ref_1", "ref_2"] },
];

function setup(opts: {
  rows?: Row[];
  fetchSubaccountId?: FetchSubaccountId;
  listSettlementTransactions?: ListSettlementTransactions;
  release?: (args: Record<string, unknown>) => Promise<unknown>;
} = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const settlementCalls: Array<{ subaccountId: string; from: Date }> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (fn === "list_unsettled_subaccounts") return Promise.resolve((opts.rows ?? ROWS) as T);
    if (fn === "expire_unsettled_commissions") return Promise.resolve(3 as T);
    if (opts.release) return opts.release(args) as Promise<T>;
    return Promise.resolve({ outcome: "settled" } as T);
  };
  const fetchSubaccountId: FetchSubaccountId = opts.fetchSubaccountId ?? ((code) => Promise.resolve(`id_${code}`));
  const listSettlements: ListSettlements = (q) => {
    settlementCalls.push(q);
    return Promise.resolve([
      { id: "s1", settledAt: "2026-10-12T00:00:00Z" },
      { id: "s2", settledAt: "2026-10-13T00:00:00Z" },
    ]);
  };
  const listSettlementTransactions: ListSettlementTransactions = opts.listSettlementTransactions ?? ((id) =>
    Promise.resolve(
      id === "s1"
        ? [{ reference: "ref_1", shareMinor: 500 }, { reference: "other", shareMinor: 9 }]
        : [{ reference: "ref_2", shareMinor: 700 }],
    ));
  const handler = createCommissionReleaseHandler({
    cronSecret: SECRET,
    rpc,
    fetchSubaccountId,
    listSettlements,
    listSettlementTransactions,
  });
  return { handler, rpcCalls, settlementCalls };
}

const post = (handler: (r: Request) => Promise<Response>, secret = SECRET) =>
  handler(new Request("http://x", { method: "POST", headers: { "x-cron-secret": secret } }));

Deno.test("wrong secret is 401", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, "nope");
  assertEquals(res.status, 401);
  assertEquals(rpcCalls.length, 0);
});

Deno.test("GET is 405", async () => {
  const { handler } = setup();
  const res = await handler(new Request("http://x", { method: "GET", headers: { "x-cron-secret": SECRET } }));
  assertEquals(res.status, 405);
});

Deno.test("matches settlement transactions to SPLIT references", async () => {
  const { handler, rpcCalls, settlementCalls } = setup();
  const res = await post(handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { subaccounts: 1, outcomes: { settled: 2 }, expired: 3, errors: 0 });
  const releases = rpcCalls.filter(([fn]) => fn === "release_commission");
  assertEquals(releases, [
    ["release_commission", { p_settlement_id: "s1", p_settled_at: "2026-10-12T00:00:00Z", p_reference: "ref_1", p_subaccount_share_minor: 500 }],
    ["release_commission", { p_settlement_id: "s2", p_settled_at: "2026-10-13T00:00:00Z", p_reference: "ref_2", p_subaccount_share_minor: 700 }],
  ]);
  assertEquals(settlementCalls[0].subaccountId, "id_ACCT_a");
  assertEquals(settlementCalls[0].from.toISOString(), "2026-10-09T12:00:00.000Z");
});

Deno.test("a subaccount's error does not stop the others", async () => {
  const rows = [
    { subaccount_code: "ACCT_bad", oldest_at: "2026-10-10T00:00:00Z", payment_references: ["ref_1"] },
    { subaccount_code: "ACCT_ok", oldest_at: "2026-10-10T00:00:00Z", payment_references: ["ref_2"] },
  ];
  const { handler, rpcCalls } = setup({
    rows,
    fetchSubaccountId: (code) => code === "ACCT_bad" ? Promise.reject(new Error("boom")) : Promise.resolve("id_ok"),
  });
  const res = await post(handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { subaccounts: 2, outcomes: { settled: 1 }, expired: 3, errors: 1 });
  assertEquals(rpcCalls.filter(([fn]) => fn === "release_commission").length, 1);
});

Deno.test("a failing release does not stop the subaccount's other transactions", async () => {
  const { handler, rpcCalls } = setup({
    release: (args) => args.p_reference === "ref_1" ? Promise.reject(new Error("TF002")) : Promise.resolve({ outcome: "mismatch" }),
  });
  const res = await post(handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { subaccounts: 1, outcomes: { mismatch: 1 }, expired: 3, errors: 1 });
  assertEquals(rpcCalls.filter(([fn]) => fn === "release_commission").length, 2);
});

Deno.test("expiry runs once after release", async () => {
  const { handler, rpcCalls } = setup();
  await post(handler);
  assertEquals(rpcCalls.at(-1)![0], "expire_unsettled_commissions");
  assertEquals(rpcCalls.filter(([fn]) => fn === "expire_unsettled_commissions").length, 1);
});
