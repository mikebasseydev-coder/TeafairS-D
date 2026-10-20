// Spec D1 §7 — cron-invoked sweep (unconfirmed payments) and refund pass.
// Always 200 with counts once listing succeeds; per-item errors are counted.
import { z } from "../_shared/core/deps.ts";
import type { Rpc } from "../_shared/core/db.ts";
import { cronAuthorized } from "../_shared/core/cron.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import { parseJsonBody } from "../_shared/core/validate.ts";
import type { VerifyTransaction } from "../_shared/fintech-liquidity/paystack.ts";
import type { ListRefunds } from "../_shared/fintech-liquidity/paystack-refunds.ts";
import { applyRefunds, settleVerified } from "../_shared/fintech-liquidity/settle.ts";

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
        const outcomes = await applyRefunds(deps.rpc, "sweep", refunds);
        return json(200, { mode, seen: refunds.length, outcomes, errors: 0 });
      }

      const pending = await deps.rpc<Array<{ paystack_reference: string; created_at: string }>>(
        "list_unconfirmed_payments",
        { p_limit: 50 },
      );
      const outcomes: Record<string, number> = {};
      let errors = 0;
      for (const { paystack_reference: reference } of pending) {
        try {
          const tx = await deps.verifyTransaction(reference);
          const result = await settleVerified(deps.rpc, "sweep", tx);
          outcomes[result.outcome] = (outcomes[result.outcome] ?? 0) + 1;
        } catch {
          errors++;
          console.error("reconcile-funds: sweep failed for", reference);
        }
      }
      return json(200, { mode, seen: pending.length, outcomes, errors });
    } catch (e) {
      return errorResponse(e);
    }
  };
}
