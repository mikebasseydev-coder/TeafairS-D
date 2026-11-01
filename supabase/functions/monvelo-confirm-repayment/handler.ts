// Addendum A6 §4.4, §5 step 9 — a Monvelo repayment, confirmed by the shop owner.
// "record" has the funder's member record an amount; the database draws the
// owner's code (record_monvelo_repayment; only this gateway holds the proof)
// and this gateway sends it to the owner's verified phone over WhatsApp only.
// "confirm" spends the code the recorder types in as the owner reads it out
// (ruling R32: only the recorder confirms). The code is never returned and
// never logged. A wrong, expired or locked code comes back from the RPC as
// data, so the attempt counter and the repayment's EXPIRED move commit (R30),
// and becomes a 422 here.
//
// A replayed record carries no code (the database never stored it), so it
// sends nothing; if the message was lost, record again with a new key once the
// code has lapsed.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { type MessageSender, otpTemplate } from "../_shared/messaging/router.ts";
import { maskPhone } from "../otp-issue/code.ts";

export type MonveloConfirmRepaymentDeps = UserGatewayDeps & {
  sendMessage: MessageSender;
  /** Must equal the Vault secret `gateway_secret`. */
  gatewaySecret: string;
};

// naira with at most two decimals, within numeric(15,2); the database checks again
const amount = z.number().positive().max(9_999_999_999_999.99).refine(
  (n) => Math.abs(n * 100 - Math.round(n * 100)) < 1e-6,
  "at most 2 decimals",
);

const schema = z.discriminatedUnion("action", [
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("record"),
    financing_id: z.string().uuid(),
    agent_id: z.string().uuid(),
    amount,
  }),
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("confirm"),
    challenge_id: z.string().uuid(),
    code: z.string().regex(/^\d{6}$/),
  }),
]);

type Recorded = {
  repayment_id: string;
  challenge_id: string;
  expires_at: string;
  destination_phone: string;
  replayed?: boolean;
  /** First call only; never stored, never returned to the recorder. */
  code?: string;
};

type Confirmed =
  | { confirmed: true; outstanding: number | string; status: string }
  | { confirmed: false; reason: "INVALID" | "EXPIRED" | "LOCKED" };

const REFUSALS: Record<string, [string, string]> = {
  INVALID: ["REPAYMENT_CODE_INVALID", "That repayment code is not right."],
  EXPIRED: ["REPAYMENT_CODE_EXPIRED", "That repayment code has expired. Record the repayment again."],
  LOCKED: ["REPAYMENT_CODE_LOCKED", "Too many wrong codes. Record the repayment again later."],
};

export function createMonveloConfirmRepaymentHandler(
  deps: MonveloConfirmRepaymentDeps,
): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ caller, body, rpc }) => {
    if (body.action === "confirm") {
      const r = await rpc<Confirmed>("confirm_monvelo_repayment", {
        p_idempotency_key: body.idempotency_key,
        p_challenge_id: body.challenge_id,
        p_code: body.code,
      });
      if (!r.confirmed) {
        const [code, message] = REFUSALS[r.reason] ?? REFUSALS.INVALID;
        throw new GatewayError(422, code, message);
      }
      return r;
    }

    const recorded = await rpc<Recorded>("record_monvelo_repayment", {
      p_idempotency_key: body.idempotency_key,
      p_gateway_proof: deps.gatewaySecret,
      p_financing_id: body.financing_id,
      p_agent_id: body.agent_id,
      p_amount: body.amount,
    });
    if (!recorded.replayed && recorded.code) {
      try {
        await deps.sendMessage(recorded.destination_phone, {
          purpose: "MONVELO_REPAYMENT",
          template: otpTemplate(recorded.code),
          // never sent: whatsappOnly. Deliberately free of the code.
          smsText: "Teafair WhatsApp repayment code.",
          relatedId: recorded.challenge_id,
          // an agent member has no active tenant: the log is platform-level
          tenantId: caller.activeTenantId ?? undefined,
          whatsappOnly: true,
        });
      } catch {
        // no error object is logged: it could echo the destination or the code
        throw new GatewayError(502, "MESSAGE_DELIVERY_FAILED", "The code could not be sent. Record the repayment again.");
      }
    }
    return {
      repayment_id: recorded.repayment_id,
      challenge_id: recorded.challenge_id,
      expires_at: recorded.expires_at,
      destination: maskPhone(recorded.destination_phone),
    };
  }, deps);
}
