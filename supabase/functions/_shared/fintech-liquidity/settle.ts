// Shared by process-payment and reconcile-funds (Spec D1 §9, plan decisions 1-2).
import type { Rpc } from "../core/db.ts";
import type { PaystackRefund } from "./paystack-refunds.ts";
import type { VerifiedTransaction } from "./paystack.ts";

export async function settleVerified(rpc: Rpc, event: string, tx: VerifiedTransaction): Promise<{ outcome: string }> {
  const reversed = tx.status === "reversed";
  // settle_paystack_payment rejects 'reversed'; a reversed charge was first a paid one.
  const settled = await rpc<{ outcome: string }>("settle_paystack_payment", {
    p_event: event,
    p_reference: tx.reference,
    p_status: reversed ? "success" : tx.status,
    p_amount_minor: tx.amountMinor,
    p_currency: tx.currency,
    p_verified: tx.raw,
    p_transaction_id: tx.transactionId,
    p_split_subaccount: tx.split?.subaccountCode ?? null,
    p_split_share_minor: tx.split?.shareMinor ?? null,
  });
  if (!reversed) return settled;
  return await rpc<{ outcome: string }>("apply_paystack_refund", {
    p_source: event === "sweep" ? "sweep" : "webhook",
    p_refund_id: "reversal:" + tx.reference,
    p_transaction_reference: tx.reference,
    p_amount_minor: tx.amountMinor,
    p_currency: tx.currency,
    p_reason: "REVERSAL",
    p_verified: tx.raw,
  });
}

export async function applyRefunds(
  rpc: Rpc,
  source: "webhook" | "sweep",
  refunds: PaystackRefund[],
  reference?: string,
): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  const bump = (k: string) => counts[k] = (counts[k] ?? 0) + 1;
  for (const refund of refunds) {
    if (refund.status !== "processed") continue;
    const txRef = refund.transactionReference ?? reference;
    if (!txRef) {
      bump("unreadable");
      continue;
    }
    const r = await rpc<{ outcome: string }>("apply_paystack_refund", {
      p_source: source,
      p_refund_id: refund.id,
      p_transaction_reference: txRef,
      p_amount_minor: refund.amountMinor,
      p_currency: refund.currency,
      p_reason: "REFUND",
      p_verified: refund.raw,
    });
    bump(r.outcome);
  }
  return counts;
}
