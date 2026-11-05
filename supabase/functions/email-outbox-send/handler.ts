// Addendum A7 §5.2 — the cron-invoked drain of email_outbox. It claims due
// rows, renders each one, sends it through Resend with the row id as the
// idempotency key (a reclaimed row is never delivered twice), and completes
// it: SENT, RETRY (back-off in the database), PERMANENT, or DEFER (no ticket
// URL configured: wait without spending an attempt). One row's failure
// never stops the batch. A recipient address is never logged.
import type { Rpc } from "../_shared/core/db.ts";
import { cronAuthorized } from "../_shared/core/cron.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import { EmailDeliveryError, type EmailSender } from "../_shared/messaging/resend.ts";
import { MissingConfigError, renderEmail } from "./templates.ts";

export type EmailOutboxSendDeps = {
  cronSecret: string;
  rpc: Rpc;
  sendEmail: EmailSender;
  ticketUrl?: string;
  batchSize?: number;
};

type ClaimedRow = { id: string; template: string; to_email: string; payload: Record<string, unknown> };
type Result = "SENT" | "RETRY" | "PERMANENT" | "DEFER";

// Resend will never accept these, so retrying wastes five attempts.
const PERMANENT_STATUSES = new Set([400, 403, 422]);

function classify(e: unknown): Result {
  if (e instanceof EmailDeliveryError && PERMANENT_STATUSES.has(e.status)) return "PERMANENT";
  return "RETRY";
}

export function createEmailOutboxSendHandler(deps: EmailOutboxSendDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      if (!cronAuthorized(req, deps.cronSecret)) throw new GatewayError(401, "UNAUTHORIZED", "Unauthorized.");
      await req.body?.cancel();

      const rows = await deps.rpc<ClaimedRow[]>("claim_email_outbox", { p_limit: deps.batchSize ?? 50 }) ?? [];
      const counts = { claimed: rows.length, sent: 0, retried: 0, failed: 0 };
      let configLogged = false;

      for (const row of rows) {
        let result: Result;
        try {
          const email = renderEmail(row, { ticketUrl: deps.ticketUrl });
          await deps.sendEmail({ to: row.to_email, ...email, idempotencyKey: row.id });
          result = "SENT";
        } catch (e) {
          if (e instanceof MissingConfigError) {
            if (!configLogged) console.error("email-outbox-send: WEB_SUPPORT_TICKET_URL is not set; buyer emails wait");
            configLogged = true;
            // a config gap must not spend the row's attempts
            result = "DEFER";
          } else {
            result = classify(e);
            // the error text never holds the address (resend.ts); the row id and template do
            console.error(`email-outbox-send: row ${row.id} (${row.template}) not sent:`,
              e instanceof Error ? e.message : "unknown error");
          }
        }
        try {
          await deps.rpc("complete_email_outbox", { p_id: row.id, p_result: result });
        } catch (e) {
          // the row stays SENDING and is reclaimed after 10 minutes
          console.error(`email-outbox-send: completing row ${row.id} failed:`, e instanceof Error ? e.message : e);
        }
        if (result === "SENT") counts.sent++;
        else if (result === "RETRY" || result === "DEFER") counts.retried++;
        else counts.failed++;
      }
      return json(200, counts);
    } catch (e) {
      return errorResponse(e);
    }
  };
}
