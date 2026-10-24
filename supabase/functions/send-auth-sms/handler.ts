// Auth audit M1 — Supabase Auth's Send SMS hook. Every code Supabase Auth
// sends by phone (sign-in) comes here, signed with Standard Webhooks, and goes
// out through the A5 message router on WhatsApp, with one notification_logs
// row per attempt (last four digits only, no tenant). User decision
// 2026-10-24: WhatsApp is the trusted channel and Nigerian SMS delivery is
// poor, so there is no SMS fallback unless AUTH_OTP_SMS_FALLBACK=true
// (KudiSMS). Twilio is never used.
//
// Only people Teafair has let in get a code (auth_sms_allowed: the account's
// own profile phone, and a platform role or an ACTIVE or INVITED membership).
// Phone changes are refused: profiles.phone_number would not follow them.
import { hookError, type HookVerifier } from "../_shared/auth/hook.ts";
import { normalizePhone } from "../_shared/commerce/phone.ts";
import { z } from "../_shared/core/deps.ts";
import { json } from "../_shared/core/http.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { reportError, tagRequest, tagUserId } from "../_shared/core/observability.ts";
import { type MessageSender, otpTemplate } from "../_shared/messaging/router.ts";

export type SendAuthSmsDeps = {
  verifyHook: HookVerifier;
  isAllowed: (userId: string, phone: string) => Promise<boolean>;
  sendMessage: MessageSender;
  /** Fall back to SMS (KudiSMS) when WhatsApp fails; off by default. */
  smsFallback: boolean;
};

const hookEvent = z.object({
  user: z.object({
    id: z.string().uuid(),
    phone: z.string().min(1),
    phone_change: z.string().optional().nullable(),
  }).passthrough(),
  sms: z.object({ otp: z.string().regex(/^[0-9]{4,10}$/) }).passthrough(),
}).passthrough();

const message = (code: string) =>
  `${code} is your Teafair sign-in code. Never share it, not even with Teafair staff.`;

export function createSendAuthSmsHandler(deps: SendAuthSmsDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    tagRequest({ gateway: "auth-hook" });
    const payload = await req.text();

    let signed: unknown;
    try {
      signed = deps.verifyHook(payload, Object.fromEntries(req.headers));
    } catch {
      return hookError(401, "invalid hook signature");
    }
    const event = hookEvent.safeParse(signed);
    if (!event.success) return hookError(400, "unexpected hook payload");

    const { user, sms } = event.data;
    tagUserId(user.id);
    if (user.phone_change) return hookError(403, "Changing the phone number is not available.");

    const phone = normalizePhone(user.phone);
    if (!phone) return hookError(400, "unsupported phone number");

    let allowed: boolean;
    try {
      allowed = await deps.isAllowed(user.id, phone);
    } catch (e) {
      reportError(e);
      return hookError(503, "Sign-in is unavailable. Try again shortly.");
    }
    if (!allowed) return hookError(403, "This number has no Teafair access.");

    try {
      await deps.sendMessage(phone, {
        purpose: "AUTH_OTP",
        template: otpTemplate(sms.otp),
        smsText: message(sms.otp),
        whatsappOnly: !deps.smsFallback,
      });
    } catch {
      // the router's error could echo the destination: report a fixed one
      reportError(new GatewayError(502, "MESSAGE_DELIVERY_FAILED", "auth code delivery failed on every channel"));
      return hookError(502, "The code could not be sent. Try again.");
    }
    return json(200, {});
  };
}
