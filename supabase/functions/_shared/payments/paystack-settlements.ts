// Subaccount lookup, List Settlements and settlement transactions
// (Spec D1 §12, F2/F3). Only the fields the release job uses are returned.
import { z } from "../core/deps.ts";
import { type PaystackOpts, paystackGet, paystackPages } from "./paystack-client.ts";

export type PaystackSettlement = { id: string; settledAt: string };
export type SettlementTransaction = { reference: string; shareMinor: number | null };
export type FetchSubaccountId = (code: string) => Promise<string>;
export type ListSettlements = (q: { subaccountId: string; from: Date }) => Promise<PaystackSettlement[]>;
export type ListSettlementTransactions = (settlementId: string) => Promise<SettlementTransaction[]>;

const id = z.union([z.number().int(), z.string().min(1)]);

const subaccountResponse = z.object({ status: z.literal(true), data: z.object({ id }) });

export function paystackSubaccountFetcher(opts: PaystackOpts): FetchSubaccountId {
  return async (code) => {
    const r = await paystackGet(opts, `/subaccount/${encodeURIComponent(code)}`, {}, subaccountResponse);
    return String(r.data.id);
  };
}

const settlementItem = z.object({ id, settlement_date: z.string() });

export function paystackSettlementLister(opts: PaystackOpts): ListSettlements {
  return async (q) => {
    const items = await paystackPages(
      opts,
      "/settlement",
      { subaccount: q.subaccountId, status: "success", from: q.from.toISOString() },
      settlementItem,
    );
    return items.map((s) => ({ id: String(s.id), settledAt: s.settlement_date }));
  };
}

const txItem = z.object({
  reference: z.string(),
  fees_split: z.object({ subaccount: z.number().int().nullish() }).passthrough().nullish(),
});

export function paystackSettlementTransactionLister(opts: PaystackOpts): ListSettlementTransactions {
  return async (settlementId) => {
    const items = await paystackPages(opts, `/settlement/${encodeURIComponent(settlementId)}/transactions`, {}, txItem);
    return items.map((t) => ({ reference: t.reference, shareMinor: t.fees_split?.subaccount ?? null }));
  };
}
