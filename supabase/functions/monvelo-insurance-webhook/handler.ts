// Addendum A8 §7.3 — the insurers' webhook, a public function under Ruling 46.
//
//   POST /functions/v1/monvelo-insurance-webhook?insurer=<CODE>
//
// The insurer's adapter verifies the request (the MOCK adapter: HMAC-SHA256
// over "<timestamp>.<raw body>", 5-minute window) before any RPC but the
// adapter lookup; a failure, an unknown insurer and a MANUAL insurer (which
// never calls in) are all 401. The adapter maps its wire format to an
// InsurerEvent, which Zod validates (amounts are decimal strings, never
// floats). The database then records the event and applies it in one
// transaction (apply_monvelo_insurer_event), scoped to that insurer: a
// duplicate (insurer, event_id) changes nothing, and an event whose target
// cannot be found is refused whole, so the insurer's retry is not mistaken
// for a duplicate.
import type { Rpc } from "../_shared/core/db.ts";
import { z } from "../_shared/core/deps.ts";
import { errorResponse, GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import type { ApiProvider, InsurerAdapter, InsurerEvent } from "../_shared/insurance/adapter.ts";

export type MonveloInsuranceWebhookDeps = {
  rpc: Rpc;
  adapterFor: (apiProvider: ApiProvider) => InsurerAdapter;
};

const MAX_BODY = 64 * 1024;
const CODE = /^[A-Z0-9_]{2,32}$/;
const ref = z.string().min(1).max(128);

const Event = z.object({
  eventId: z.string().min(1).max(200),
  type: z.string().min(1).max(64),
  claimReference: z.string().regex(/^IC-[A-Z2-7]{8}$/).optional(),
  declarationId: z.string().uuid().optional(),
  settledAmount: z.string().regex(/^\d{1,13}\.\d{2}$/).optional(),
  payoutReference: ref.optional(),
  insurerReference: ref.optional(),
  error: z.string().max(2000).optional(),
}).strict().superRefine((e, ctx) => {
  const need = (ok: boolean, path: string) => {
    if (!ok) ctx.addIssue({ code: z.ZodIssueCode.custom, path: [path], message: `${path} is required for ${e.type}` });
  };
  if (e.type.startsWith("declaration.")) need(e.declarationId !== undefined, "declarationId");
  if (e.type.startsWith("claim.")) need(e.claimReference !== undefined, "claimReference");
  if (e.type === "claim.settled") {
    need(e.settledAmount !== undefined, "settledAmount");
    need(e.payoutReference !== undefined, "payoutReference");
  }
});

const WIRE: Array<[keyof InsurerEvent, string]> = [
  ["claimReference", "claim_reference"],
  ["declarationId", "declaration_id"],
  ["settledAmount", "settled_amount"],
  ["payoutReference", "payout_reference"],
  ["insurerReference", "insurer_reference"],
  ["error", "error"],
];

export function createMonveloInsuranceWebhookHandler(deps: MonveloInsuranceWebhookDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      const code = new URL(req.url).searchParams.get("insurer") ?? "";
      if (!CODE.test(code)) throw new GatewayError(400, "BAD_REQUEST", "Name the insurer.");
      const raw = await req.text();
      if (raw.length > MAX_BODY) throw new GatewayError(400, "BAD_REQUEST", "The event is too large.");

      const provider = await deps.rpc<string | null>("get_monvelo_insurer_provider", { p_code: code });
      let adapter: InsurerAdapter | null = null;
      try {
        if (provider) adapter = deps.adapterFor(provider as ApiProvider);
      } catch {
        adapter = null;
      }
      if (!adapter || !(await adapter.verifyWebhook(req, raw))) {
        throw new GatewayError(401, "UNAUTHORIZED", "Unauthorized.");
      }

      let parsed: InsurerEvent;
      try {
        parsed = adapter.parseEvent(raw);
      } catch {
        throw new GatewayError(400, "BAD_REQUEST", "The event is not valid JSON.");
      }
      const checked = Event.safeParse(parsed);
      if (!checked.success) throw new GatewayError(400, "BAD_REQUEST", "The event is malformed.");
      const e = checked.data;

      const event: Record<string, string> = {};
      for (const [k, wire] of WIRE) {
        const v = e[k as keyof typeof e];
        if (typeof v === "string") event[wire] = v;
      }
      const result = await deps.rpc<Record<string, unknown>>("apply_monvelo_insurer_event", {
        p_insurer_code: code, p_event_id: e.eventId, p_type: e.type, p_event: event,
      });
      return json(200, result ?? {});
    } catch (err) {
      return errorResponse(err);
    }
  };
}
