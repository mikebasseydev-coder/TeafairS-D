// Addendum A5 §3.3 — start WhatsApp verification of a web buyer's number.
// Turnstile → normalise the phone → store the code's hash (RPC) → send the
// code over WhatsApp only (no SMS fallback: the point is proving the number
// is on WhatsApp). The code is never returned or logged.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { clientIp } from "../_shared/commerce/client-ip.ts";
import { normalizePhone } from "../_shared/core/phone.ts";
import type { VerifyTurnstile } from "../_shared/commerce/turnstile.ts";
import { type MessageSender, otpTemplate } from "../_shared/messaging/router.ts";

export type CheckoutPhoneVerifyStartDeps = PublicGatewayDeps & {
  verifyTurnstile: VerifyTurnstile;
  sendMessage: MessageSender;
  generateCode: () => string;
};

const schema = z.object({
  turnstile_token: z.string().min(1).max(2048),
  phone: z.string().trim().min(7).max(24),
});

type Started = { verification_id: string; expires_at: string };

export function createCheckoutPhoneVerifyStartHandler(
  deps: CheckoutPhoneVerifyStartDeps,
): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc, req }) => {
    const ip = clientIp(req);
    let human: boolean;
    try {
      human = await deps.verifyTurnstile(body.turnstile_token, ip);
    } catch (e) {
      console.error("Turnstile verification failed", e);
      throw new GatewayError(503, "RETRY", "The security check is unavailable. Please try again.");
    }
    if (!human) throw new GatewayError(403, "BOT_CHECK_FAILED", "Please complete the security check and try again.");

    const phone = normalizePhone(body.phone);
    if (!phone) throw new GatewayError(400, "VALIDATION_FAILED", "Enter a valid phone number.");

    const code = deps.generateCode();
    const started = await rpc<Started>("start_web_phone_verification", {
      p_phone: phone,
      p_code: code,
      p_client_ip: ip,
    });

    try {
      await deps.sendMessage(phone, {
        purpose: "PHONE_VERIFY",
        template: otpTemplate(code),
        // never sent: whatsappOnly. Deliberately free of the code.
        smsText: "Teafair WhatsApp verification.",
        relatedId: started.verification_id,
        whatsappOnly: true,
      });
    } catch {
      // no error object is logged: it could echo the destination or the code
      throw new GatewayError(
        503,
        "WHATSAPP_UNAVAILABLE",
        "We couldn't reach WhatsApp. Please try again in a few minutes.",
      );
    }
    return { verification_id: started.verification_id, expires_at: started.expires_at };
  }, deps);
}
