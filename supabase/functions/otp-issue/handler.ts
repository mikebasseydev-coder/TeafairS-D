// Spec A §6.11 — issue the shop-owner OTP. issue_otp draws the code, stores
// only its bcrypt hash and hands the code to this gateway once (audit H2: the
// gateway proof keeps an agent from calling it through PostgREST with a code
// of their own). The code goes to the phone (WhatsApp first, SMS fallback) on
// the owner's profile (never a number from the request).
//
// A replayed key returns the original challenge, whose code this request does
// not know, so a replay never sends a message. If delivery fails on every
// channel, the agent requests a fresh code with a new key.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { type MessageSender, otpTemplate } from "../_shared/messaging/router.ts";
import { maskPhone } from "./code.ts";

export type OtpIssueDeps = UserGatewayDeps & {
  sendMessage: MessageSender;
  /** Must equal the Vault secret `gateway_secret`. */
  gatewaySecret: string;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  subject_id: z.string().uuid(),
  purpose: z.enum(["PICKUP_CONFIRM", "POS_SETTLEMENT"]),
});

type Issued = {
  challenge_id: string;
  expires_at: string;
  destination_phone: string;
  replayed: boolean;
  /** Present on the first call only; never stored, never returned to the agent. */
  code?: string;
};

const message = (code: string) =>
  `Your Teafair code is ${code}. Give it to the agent only once you have your goods. It expires in 5 minutes.`;

export function createOtpIssueHandler(deps: OtpIssueDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ caller, body, rpc }) => {
    const issued = await rpc<Issued>("issue_otp", {
      p_idempotency_key: body.idempotency_key,
      p_subject_id: body.subject_id,
      p_purpose: body.purpose,
      p_gateway_proof: deps.gatewaySecret,
    });

    let channel: "WHATSAPP" | "SMS" | null = null;
    const code = issued.code;
    if (!issued.replayed && code) {
      try {
        ({ channel } = await deps.sendMessage(issued.destination_phone, {
          purpose: "OTP",
          template: otpTemplate(code),
          smsText: message(code),
          relatedId: issued.challenge_id,
          // R18: issue_otp checked the caller's live membership of this tenant
          tenantId: caller.activeTenantId ?? undefined,
        }));
      } catch {
        // no error object is logged: it could echo the destination or the code
        throw new GatewayError(502, "MESSAGE_DELIVERY_FAILED", "The code could not be sent. Request a new one.");
      }
    }

    return {
      challenge_id: issued.challenge_id,
      expires_at: issued.expires_at,
      destination: maskPhone(issued.destination_phone),
      // "sent on any channel", kept under its old name for compatibility
      sms_sent: channel !== null,
      channel,
    };
  }, deps);
}
