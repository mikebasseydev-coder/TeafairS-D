// Spec A §6.11 — issue the shop-owner OTP. The code is generated here, stored
// only as a bcrypt hash by issue_otp, and texted to the phone on the owner's
// profile (never a number from the request).
//
// A replayed key returns the original challenge, whose code this request does
// not know, so a replay never sends an SMS. If the SMS fails, the agent
// requests a fresh code with a new key.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/core/gateway.ts";
import type { SmsSender } from "../_shared/core/sms.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { maskPhone } from "./code.ts";

export type OtpIssueDeps = UserGatewayDeps & {
  sendSms: SmsSender;
  generateCode: () => string;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  subject_id: z.string().uuid(),
  purpose: z.enum(["PICKUP_CONFIRM", "POS_SETTLEMENT"]),
});

type Issued = { challenge_id: string; expires_at: string; destination_phone: string; replayed: boolean };

const message = (code: string) =>
  `Your Teafair code is ${code}. Give it to the agent only once you have your goods. It expires in 5 minutes.`;

export function createOtpIssueHandler(deps: OtpIssueDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const code = deps.generateCode();
    const issued = await rpc<Issued>("issue_otp", {
      p_idempotency_key: body.idempotency_key,
      p_subject_id: body.subject_id,
      p_purpose: body.purpose,
      p_code: code,
    });

    if (!issued.replayed) {
      try {
        await deps.sendSms(issued.destination_phone, message(code));
      } catch (e) {
        console.error("OTP SMS failed", e);
        throw new GatewayError(502, "SMS_DELIVERY_FAILED", "The code could not be sent. Request a new one.");
      }
    }

    return {
      challenge_id: issued.challenge_id,
      expires_at: issued.expires_at,
      destination: maskPhone(issued.destination_phone),
      sms_sent: !issued.replayed,
    };
  }, deps);
}
