// Spec D1 §8.1 — cron-invoked commission release. Matches Paystack settlement
// transactions to our SPLIT payment references and calls release_commission, then
// expires commissions that never settled. Always 200 with counts once the two
// bracketing RPCs succeed; a failing subaccount or release is logged and counted.
import type { Rpc } from "../_shared/core/db.ts";
import { cronAuthorized } from "../_shared/core/cron.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import type {
  FetchSubaccountId,
  ListSettlements,
  ListSettlementTransactions,
} from "../_shared/payments/paystack-settlements.ts";

export type CommissionReleaseDeps = {
  cronSecret: string;
  rpc: Rpc;
  fetchSubaccountId: FetchSubaccountId;
  listSettlements: ListSettlements;
  listSettlementTransactions: ListSettlementTransactions;
};

type UnsettledRow = { subaccount_code: string; oldest_at: string; payment_references: string[] };
const DAY_MS = 86_400_000;
const errName = (e: unknown) => e instanceof Error ? e.name : "error";

export function createCommissionReleaseHandler(deps: CommissionReleaseDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      if (!cronAuthorized(req, deps.cronSecret)) throw new GatewayError(401, "UNAUTHORIZED", "Unauthorized.");

      const rows = await deps.rpc<UnsettledRow[]>("list_unsettled_subaccounts", {});
      const outcomes: Record<string, number> = {};
      let errors = 0;

      for (const row of rows) {
        try {
          const wanted = new Set(row.payment_references);
          const subaccountId = await deps.fetchSubaccountId(row.subaccount_code);
          const settlements = await deps.listSettlements({
            subaccountId,
            from: new Date(new Date(row.oldest_at).getTime() - DAY_MS),
          });
          for (const settlement of settlements) {
            const transactions = await deps.listSettlementTransactions(settlement.id);
            for (const tx of transactions) {
              if (!wanted.has(tx.reference)) continue;
              try {
                const result = await deps.rpc<{ outcome: string }>("release_commission", {
                  p_settlement_id: settlement.id,
                  p_settled_at: settlement.settledAt,
                  p_reference: tx.reference,
                  p_subaccount_share_minor: tx.shareMinor,
                });
                outcomes[result.outcome] = (outcomes[result.outcome] ?? 0) + 1;
              } catch (e) {
                errors++;
                console.error("release_commission failed", settlement.id, tx.reference, errName(e));
              }
            }
          }
        } catch (e) {
          errors++;
          console.error("commission-release: subaccount failed", row.subaccount_code, errName(e));
        }
      }

      const expired = await deps.rpc<number>("expire_unsettled_commissions", {});
      return json(200, { subaccounts: rows.length, outcomes, expired, errors });
    } catch (e) {
      return errorResponse(e);
    }
  };
}
