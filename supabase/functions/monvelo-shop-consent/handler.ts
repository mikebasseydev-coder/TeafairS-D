// Addendum A6 §4.1 — a street agent (ZSA/ASA) enrols a shop with the owner's
// consent. "start" has the database draw a code (start_monvelo_consent; only
// this gateway holds the proof) and sends it to the shop's phone over
// WhatsApp only; "enrol" spends the code. The code is never returned and never
// logged. A wrong, expired or locked code comes back from the RPC as data, so
// the attempt counter commits, and becomes a 422 here.
//
// Addendum A8 §6.3 adds the same two steps for the shop's own fire and
// burglary policy: "start_policy" (start_monvelo_policy_consent) and
// "submit_policy" (submit_monvelo_shop_policy, which spends the code and
// records the policy PENDING for an operator's review).
//
// A replayed start carries no code (the database never stored it), so it sends
// nothing; request a fresh code with a new key if delivery failed.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { type MessageSender, otpTemplate } from "../_shared/messaging/router.ts";
import { maskPhone } from "../otp-issue/code.ts";

export type MonveloShopConsentDeps = UserGatewayDeps & {
  sendMessage: MessageSender;
  /** Must equal the Vault secret `gateway_secret`. */
  gatewaySecret: string;
};

const schema = z.discriminatedUnion("action", [
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("start"),
    shop_id: z.string().uuid(),
    area_id: z.string().uuid(),
  }),
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("enrol"),
    challenge_id: z.string().uuid(),
    code: z.string().regex(/^\d{6}$/),
  }),
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("start_policy"),
    shop_id: z.string().uuid(),
    area_id: z.string().uuid(),
  }),
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("submit_policy"),
    challenge_id: z.string().uuid(),
    code: z.string().regex(/^\d{6}$/),
    insurer_name: z.string().trim().min(1).max(200),
    policy_number: z.string().trim().min(1).max(64),
    covers_fire_perils: z.boolean(),
    covers_burglary: z.boolean(),
    sum_insured: z.number().positive().max(9_999_999_999_999),
    lender_interest_endorsed: z.boolean(),
    starts_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    expires_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    document_path: z.string().min(1).max(300),
  }),
]);

type Submitted =
  | { submitted: true; policy_id: string; status: string }
  | { submitted: false; reason: "INVALID" | "EXPIRED" | "LOCKED" };

type Started = {
  challenge_id: string;
  expires_at: string;
  destination_phone: string;
  replayed?: boolean;
  /** First call only; never stored, never returned to the agent. */
  code?: string;
};

type Enrolled =
  | { enrolled: true; shop_code: string }
  | { enrolled: false; reason: "INVALID" | "EXPIRED" | "LOCKED" };

const REFUSALS: Record<string, [string, string]> = {
  INVALID: ["CONSENT_CODE_INVALID", "That consent code is not right."],
  EXPIRED: ["CONSENT_CODE_EXPIRED", "That consent code has expired. Ask for a new one."],
  LOCKED: ["CONSENT_CODE_LOCKED", "Too many wrong codes. Ask for a new code later."],
};

export function createMonveloShopConsentHandler(deps: MonveloShopConsentDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ caller, body, rpc }) => {
    if (body.action === "enrol") {
      const r = await rpc<Enrolled>("enrol_monvelo_shop", {
        p_idempotency_key: body.idempotency_key,
        p_challenge_id: body.challenge_id,
        p_code: body.code,
      });
      if (!r.enrolled) {
        const [code, message] = REFUSALS[r.reason] ?? REFUSALS.INVALID;
        throw new GatewayError(422, code, message);
      }
      return r;
    }

    if (body.action === "submit_policy") {
      const r = await rpc<Submitted>("submit_monvelo_shop_policy", {
        p_idempotency_key: body.idempotency_key,
        p_challenge_id: body.challenge_id,
        p_code: body.code,
        p_insurer_name: body.insurer_name,
        p_policy_number: body.policy_number,
        p_covers_fire_perils: body.covers_fire_perils,
        p_covers_burglary: body.covers_burglary,
        p_sum_insured: body.sum_insured,
        p_lender_interest_endorsed: body.lender_interest_endorsed,
        p_starts_on: body.starts_on,
        p_expires_on: body.expires_on,
        p_document_path: body.document_path,
      });
      if (!r.submitted) {
        const [code, message] = REFUSALS[r.reason] ?? REFUSALS.INVALID;
        throw new GatewayError(422, code, message);
      }
      return r;
    }

    const started = await rpc<Started>(body.action === "start_policy" ? "start_monvelo_policy_consent" : "start_monvelo_consent", {
      p_idempotency_key: body.idempotency_key,
      p_gateway_proof: deps.gatewaySecret,
      p_shop_id: body.shop_id,
      p_area_id: body.area_id,
    });
    if (!started.replayed && started.code) {
      try {
        await deps.sendMessage(started.destination_phone, {
          purpose: "MONVELO_CONSENT",
          template: otpTemplate(started.code),
          // never sent: whatsappOnly. Deliberately free of the code.
          smsText: "Teafair WhatsApp consent code.",
          relatedId: started.challenge_id,
          tenantId: caller.activeTenantId ?? undefined,
          whatsappOnly: true,
        });
      } catch {
        // no error object is logged: it could echo the destination or the code
        throw new GatewayError(502, "MESSAGE_DELIVERY_FAILED", "The code could not be sent. Request a new one.");
      }
    }
    return {
      challenge_id: started.challenge_id,
      expires_at: started.expires_at,
      destination: maskPhone(started.destination_phone),
    };
  }, deps);
}
