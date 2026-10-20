// Spec A §3.6 — Paystack webhook. Four checks, in order, before any RPC:
// signature → replay window → Verify API → at-most-once (in the RPC).
// Non-2xx means "retry" to Paystack, so only real failures return one.
import { z } from "../_shared/core/deps.ts";
import type { Rpc } from "../_shared/core/db.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import type { VerifyTransaction } from "../_shared/fintech-liquidity/paystack.ts";
import { applyRefunds, settleVerified } from "../_shared/fintech-liquidity/settle.ts";
import type { ListRefunds } from "../_shared/fintech-liquidity/paystack-refunds.ts";
import { eventTime, withinReplayWindow } from "./replay-window.ts";
import { paystackSignatureValid } from "./signature.ts";

export type ProcessPaymentDeps = {
  secretKey: string;
  verifyTransaction: VerifyTransaction;
  listRefunds: ListRefunds;
  rpc: Rpc;
  now: () => Date;
};

const chargeEvent = z.object({
  event: z.literal("charge.success"),
  data: z.object({
    reference: z.string().min(1),
    paid_at: z.string().nullish(),
    created_at: z.string().nullish(),
  }).passthrough(),
});
const refundEvent = z.object({
  event: z.literal("refund.processed"),
  data: z.object({ transaction_reference: z.string().min(1) }).passthrough(),
});
const webhook = z.discriminatedUnion("event", [chargeEvent, refundEvent]);

const acknowledged = (outcome: string) => json(200, { received: true, outcome });

function parseWebhook(raw: string) {
  try {
    return webhook.safeParse(JSON.parse(raw));
  } catch {
    return null;
  }
}

export function createProcessPaymentHandler(deps: ProcessPaymentDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");

      // 1. signature over the raw bytes — parsing first would break it
      const raw = await req.text();
      if (!(await paystackSignatureValid(raw, req.headers.get("x-paystack-signature"), deps.secretKey))) {
        throw new GatewayError(401, "INVALID_SIGNATURE", "Invalid signature.");
      }

      const parsed = parseWebhook(raw);
      if (!parsed?.success) return acknowledged("ignored");

      // refund.processed carries no refund id and has no replay window: re-read
      // the refunds from Paystack by transaction reference; the RPC is idempotent.
      if (parsed.data.event === "refund.processed") {
        const reference = parsed.data.data.transaction_reference;
        const refunds = await deps.listRefunds({ reference });
        const counts = await applyRefunds(deps.rpc, "webhook", refunds, reference);
        return acknowledged(counts.refunded ? "refunded" : "none_processed");
      }
      const { event, data } = parsed.data;

      // 2. replay window; stale events are recorded and left for the sweep
      const at = eventTime(data);
      if (!withinReplayWindow(at, deps.now())) {
        await deps.rpc("record_stale_paystack_webhook", {
          p_event: event,
          p_reference: data.reference,
          p_event_time: at?.toISOString() ?? null,
        });
        return acknowledged("stale");
      }

      // 3. source confirmation — the webhook body's amount is never trusted
      const tx = await deps.verifyTransaction(data.reference);
      if (tx.reference !== data.reference) {
        throw new GatewayError(502, "PAYSTACK_MISMATCH", "Paystack verified a different reference.");
      }

      // 4. at most once, inside the RPC
      const result = await settleVerified(deps.rpc, event, tx);
      return acknowledged(result.outcome);
    } catch (e) {
      return errorResponse(e);
    }
  };
}
