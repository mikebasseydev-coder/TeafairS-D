// Addendum A6 §4.4, §5 step 7 — the shop owner confirms a Monvelo delivery.
// "start" has the database draw the owner's code (start_monvelo_delivery; only
// this gateway holds the proof) and sends it to the owner's verified phone over
// WhatsApp only; "confirm" spends the code the deliverer types in as the owner
// reads it out (ruling R20: the caller must be a deliverer of the order). The
// code is never returned and never logged. A wrong, expired or locked code
// comes back from the RPC as data, so the attempt counter commits, and becomes
// a 422 here.
//
// A replayed start carries no code (the database never stored it), so it sends
// nothing; request a fresh code with a new key if delivery failed.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { type MessageSender, otpTemplate } from "../_shared/messaging/router.ts";
import { maskPhone } from "../otp-issue/code.ts";

export type MonveloConfirmDeliveryDeps = UserGatewayDeps & {
  sendMessage: MessageSender;
  /** Must equal the Vault secret `gateway_secret`. */
  gatewaySecret: string;
};

const schema = z.discriminatedUnion("action", [
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("start"),
    financing_id: z.string().uuid(),
  }),
  z.object({
    idempotency_key: idempotencyKey,
    action: z.literal("confirm"),
    challenge_id: z.string().uuid(),
    code: z.string().regex(/^\d{6}$/),
  }),
]);

type Started = {
  challenge_id: string;
  expires_at: string;
  destination_phone: string;
  replayed?: boolean;
  /** First call only; never stored, never returned to the deliverer. */
  code?: string;
};

type Confirmed =
  | { confirmed: true; due_at: string }
  | { confirmed: false; reason: "INVALID" | "EXPIRED" | "LOCKED" };

const REFUSALS: Record<string, [string, string]> = {
  INVALID: ["DELIVERY_CODE_INVALID", "That delivery code is not right."],
  EXPIRED: ["DELIVERY_CODE_EXPIRED", "That delivery code has expired. Ask for a new one."],
  LOCKED: ["DELIVERY_CODE_LOCKED", "Too many wrong codes. Ask for a new code later."],
};

export function createMonveloConfirmDeliveryHandler(
  deps: MonveloConfirmDeliveryDeps,
): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ caller, body, rpc }) => {
    if (body.action === "confirm") {
      const r = await rpc<Confirmed>("confirm_monvelo_delivery", {
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

    const started = await rpc<Started>("start_monvelo_delivery", {
      p_idempotency_key: body.idempotency_key,
      p_gateway_proof: deps.gatewaySecret,
      p_financing_id: body.financing_id,
    });
    if (!started.replayed && started.code) {
      try {
        await deps.sendMessage(started.destination_phone, {
          purpose: "MONVELO_DELIVERY",
          template: otpTemplate(started.code),
          // never sent: whatsappOnly. Deliberately free of the code.
          smsText: "Teafair WhatsApp delivery code.",
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
