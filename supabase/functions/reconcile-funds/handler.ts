// Spec D1 §7 — cron-invoked sweep (unconfirmed payments) and refund pass.
// Always 200 with counts once listing succeeds; a failing item (a payment, or a
// refund inside applyRefunds) is logged, counted in `errors`, and the batch continues.
import { z } from "../_shared/core/deps.ts";
import type { Rpc } from "../_shared/core/db.ts";
import { cronAuthorized } from "../_shared/core/cron.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import { parseJsonBody } from "../_shared/core/validate.ts";
import type { VerifyTransaction } from "../_shared/payments/paystack.ts";
import type { ListRefunds } from "../_shared/payments/paystack-refunds.ts";
import { applyRefunds, settleVerified } from "../_shared/payments/settle.ts";

export type ReconcileFundsDeps = {
  cronSecret: string;
  rpc: Rpc;
  verifyTransaction: VerifyTransaction;
  listRefunds: ListRefunds;
  now: () => Date;
};

const body = z.object({ mode: z.enum(["sweep", "refunds"]) });
const DAY_MS = 86_400_000;
const day = (d: Date) => d.toISOString().slice(0, 10);

export function createReconcileFundsHandler(deps: ReconcileFundsDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      if (!cronAuthorized(req, deps.cronSecret)) throw new GatewayError(401, "UNAUTHORIZED", "Unauthorized.");
      const { mode } = await parseJsonBody(req, body);

      if (mode === "refunds") {
        const now = deps.now();
        const refunds = await deps.listRefunds({
          from: day(new Date(now.getTime() - 3 * DAY_MS)),
          to: day(new Date(now.getTime() + DAY_MS)),
        });
        const { error: errors = 0, ...outcomes } = await applyRefunds(deps.rpc, "sweep", refunds);
        if ((outcomes.unreadable ?? 0) > 0) {
          // only the count: a refund payload can carry customer details
          console.warn("reconcile-funds: refunds without a transaction reference:", outcomes.unreadable);
        }
        return json(200, { mode, seen: refunds.length, outcomes, errors });
      }

      // claiming stamps last_swept_at on every row first, so a row that
      // errors below still moves to the back of the next sweep
      const pending = await deps.rpc<Array<{ paystack_reference: string; created_at: string }>>(
        "claim_unconfirmed_payments",
        { p_limit: 50 },
      );
      const outcomes: Record<string, number> = {};
      let errors = 0;
      for (const { paystack_reference: reference } of pending) {
        try {
          const tx = await deps.verifyTransaction(reference);
          if (tx.reference !== reference) {
            // the webhook makes the same check: never settle another payment
            errors++;
            console.error("reconcile-funds: Verify returned another reference for", reference);
            continue;
          }
          const result = await settleVerified(deps.rpc, "sweep", tx);
          outcomes[result.outcome] = (outcomes[result.outcome] ?? 0) + 1;
        } catch (e) {
          errors++;
          console.error("reconcile-funds: sweep failed for", reference, e instanceof Error ? e.name : "error");
        }
      }
      return json(200, { mode, seen: pending.length, outcomes, errors });
    } catch (e) {
      return errorResponse(e);
    }
  };
}
