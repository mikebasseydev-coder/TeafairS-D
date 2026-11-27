// Addendum A6 §23.6 (ruling 2026-11-27) — the shop owner's Monvelo codes go by
// email: the consent, policy-consent, delivery and repayment codes. The
// database draws each code and names the owner's verified sign-in address
// (destination_email); this module only words and sends the message. The copy
// is fixed text plus the code: nothing a user typed is rendered, and no shop,
// agent, amount or tenant is named. Neither the code nor the address is ever
// put in an error.
import type { EmailSender } from "../messaging/resend.ts";

export type MonveloCodePurpose = "CONSENT" | "POLICY_CONSENT" | "DELIVERY" | "REPAYMENT";

const COPY: Record<MonveloCodePurpose, { subject: string; line: string }> = {
  CONSENT: {
    subject: "Your Teafair Monvelo consent code",
    line: "Read this code to the Teafair field agent to agree that your shop may be offered Monvelo stock financing.",
  },
  POLICY_CONSENT: {
    subject: "Your Teafair Monvelo policy code",
    line: "Read this code to the Teafair field agent to submit your shop's insurance policy to Monvelo.",
  },
  DELIVERY: {
    subject: "Your Teafair Monvelo delivery code",
    line: "Read this code to the person delivering your financed stock, once you have checked the goods.",
  },
  REPAYMENT: {
    subject: "Your Teafair Monvelo repayment code",
    line: "Read this code to the agent only if you have just repaid them the amount they recorded.",
  },
};

const FOOTER = "The code expires in 10 minutes. Never share it with anyone who is not with you in person.";

/** The message for one code; exported for tests. */
export function monveloCodeEmail(to: string, purpose: MonveloCodePurpose, code: string, idempotencyKey: string) {
  if (!/^\d{6}$/.test(code)) throw new Error("a Monvelo code is six digits");
  const { subject, line } = COPY[purpose];
  return {
    to,
    subject,
    text: `${line}\n\nYour code: ${code}\n\n${FOOTER}\n`,
    html: `<p>${line}</p><p style="font-size:24px;letter-spacing:4px"><strong>${code}</strong></p><p>${FOOTER}</p>`,
    // a retried send of the same challenge never emails twice
    idempotencyKey,
  };
}

export type MonveloCodeSender = (to: string, purpose: MonveloCodePurpose, code: string, challengeId: string) => Promise<void>;

export function monveloCodeSender(send: EmailSender): MonveloCodeSender {
  return (to, purpose, code, challengeId) =>
    send(monveloCodeEmail(to, purpose, code, `monvelo-code:${challengeId}`));
}

/** "a***@e***.com": enough for the agent to tell the owner where to look. */
export function maskEmail(email: string): string {
  const at = email.lastIndexOf("@");
  if (at < 1) return "***";
  const local = email.slice(0, at);
  const domain = email.slice(at + 1);
  const dot = domain.lastIndexOf(".");
  const host = dot > 0 ? domain.slice(0, dot) : domain;
  const tld = dot > 0 ? domain.slice(dot) : "";
  return `${local[0]}***@${host ? host[0] : ""}***${tld}`;
}
