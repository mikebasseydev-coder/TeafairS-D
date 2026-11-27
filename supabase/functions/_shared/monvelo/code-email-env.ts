// Live wiring for the Monvelo code emails (A6 §23.6): Resend, with the sender
// MONVELO_EMAIL_FROM, else AUTH_EMAIL_FROM, else Resend's sandbox sender.
import { requireEnv } from "../core/env.ts";
import { resendSender, senderFrom } from "../messaging/resend.ts";
import { monveloCodeSender, type MonveloCodeSender } from "./code-email.ts";

export function monveloCodeSenderFromEnv(): MonveloCodeSender {
  return monveloCodeSender(resendSender({
    apiKey: requireEnv("RESEND_API_KEY"),
    from: senderFrom(Deno.env.get("MONVELO_EMAIL_FROM") || Deno.env.get("AUTH_EMAIL_FROM")),
    apiUrl: Deno.env.get("RESEND_API_URL") || undefined,
  }));
}
