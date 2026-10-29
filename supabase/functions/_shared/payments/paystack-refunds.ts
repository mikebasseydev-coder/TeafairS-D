// List Refunds (Spec D1 §12, F4). The refund webhook carries no refund id, so
// the gateway re-reads from Paystack by transaction reference.
import { z } from "../core/deps.ts";
import { type PaystackOpts, paystackPages } from "./paystack-client.ts";

export type PaystackRefund = {
  id: string;
  transactionReference: string | null;
  amountMinor: number;
  currency: string;
  status: string;
  raw: Record<string, unknown>;
};
export type ListRefunds = (q: { reference?: string; from?: string; to?: string }) => Promise<PaystackRefund[]>;

const refundItem = z.object({
  id: z.union([z.number().int(), z.string().min(1)]),
  amount: z.number().int(),
  currency: z.string(),
  status: z.string(),
  transaction_reference: z.string().nullish(),
}).passthrough();

export function paystackRefundLister(opts: PaystackOpts): ListRefunds {
  return async (q) => {
    const items = await paystackPages(opts, "/refund", { reference: q.reference, from: q.from, to: q.to }, refundItem);
    return items.map((r) => ({
      id: String(r.id),
      transactionReference: r.transaction_reference ?? null,
      amountMinor: r.amount,
      currency: r.currency,
      status: r.status,
      raw: r,
    }));
  };
}
