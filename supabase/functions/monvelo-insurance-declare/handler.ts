// Addendum A8 §7.2 — the cron-invoked drain of monvelo_insurance_declarations.
// It claims due rows, hands each to its insurer's adapter with the row id as
// the idempotency key (a reclaimed row is never declared twice), and records
// the answer: ACCEPTED, REJECTED or RETRY (back-off and the 24-hour limit are
// the database's), or MANUAL for an insurer an operator handles by hand. One
// row's failure never stops the batch, and a failure to send is a RETRY.
import type { Rpc } from "../_shared/core/db.ts";
import { cronAuthorized } from "../_shared/core/cron.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import type { ApiProvider, DeclarationKind, InsurerAdapter, SendResult } from "../_shared/insurance/adapter.ts";

export type MonveloInsuranceDeclareDeps = {
  cronSecret: string;
  rpc: Rpc;
  adapterFor: (apiProvider: ApiProvider) => InsurerAdapter;
  batchSize?: number;
};

type ClaimedRow = {
  id: string;
  kind: DeclarationKind;
  insurer_code: string;
  api_provider: ApiProvider;
  payload: Record<string, unknown>;
};

type Completion = { outcome: "ACCEPTED" | "REJECTED" | "RETRY" | "MANUAL"; reference: string | null; error: string | null };

function completionOf(r: SendResult): Completion {
  switch (r.outcome) {
    case "ACCEPTED":
      return { outcome: "ACCEPTED", reference: r.insurerReference, error: null };
    case "REJECTED":
      return { outcome: "REJECTED", reference: r.insurerReference, error: r.error };
    case "RETRY":
      return { outcome: "RETRY", reference: null, error: r.error };
    case "QUEUED_MANUAL":
      return { outcome: "MANUAL", reference: null, error: null };
  }
}

export function createMonveloInsuranceDeclareHandler(deps: MonveloInsuranceDeclareDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      if (!cronAuthorized(req, deps.cronSecret)) throw new GatewayError(401, "UNAUTHORIZED", "Unauthorized.");
      await req.body?.cancel();

      const rows = await deps.rpc<ClaimedRow[]>("claim_monvelo_declarations", { p_limit: deps.batchSize ?? 20 }) ?? [];
      const counts = { claimed: rows.length, accepted: 0, rejected: 0, retried: 0, manual: 0 };

      for (const row of rows) {
        let c: Completion;
        try {
          c = completionOf(await deps.adapterFor(row.api_provider).send(row.kind, row.payload, row.id));
        } catch (e) {
          // the payload never goes in a log; the row id, kind and insurer do
          const msg = e instanceof Error ? e.message : "unknown error";
          console.error(`monvelo-insurance-declare: row ${row.id} (${row.kind}, ${row.insurer_code}) not sent:`, msg);
          c = { outcome: "RETRY", reference: null, error: msg.slice(0, 500) };
        }
        try {
          await deps.rpc("complete_monvelo_declaration", {
            p_id: row.id, p_outcome: c.outcome, p_insurer_reference: c.reference, p_error: c.error,
          });
        } catch (e) {
          // the row stays SENDING and is reclaimed after 10 minutes
          console.error(`monvelo-insurance-declare: completing row ${row.id} failed:`, e instanceof Error ? e.message : e);
        }
        if (c.outcome === "ACCEPTED") counts.accepted++;
        else if (c.outcome === "REJECTED") counts.rejected++;
        else if (c.outcome === "RETRY") counts.retried++;
        else counts.manual++;
      }
      return json(200, counts);
    } catch (e) {
      return errorResponse(e);
    }
  };
}
