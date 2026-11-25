// Resend transport (POST /emails). Neither the API key nor the recipient is
// ever put in an error message.
export type ResendConfig = { apiKey: string; from: string; apiUrl?: string };

/**
 * Resend's sandbox sender. It delivers only to the address that owns the
 * Resend account, so it is a safe fallback until a domain is verified.
 */
export const DEFAULT_FROM = "Teafair <onboarding@resend.dev>";

/** The configured sender, or the sandbox sender when it is unset or blank. */
export function senderFrom(configured: string | undefined | null): string {
  const v = configured?.trim();
  return v ? v : DEFAULT_FROM;
}

export type Email = { to: string; subject: string; html: string; text: string; idempotencyKey?: string };

export type EmailSender = (email: Email) => Promise<void>;

export class EmailDeliveryError extends Error {
  constructor(readonly status: number) {
    super(`Resend refused the email: HTTP ${status}`);
    this.name = "EmailDeliveryError";
  }
}

export function resendSender(cfg: ResendConfig, fetchFn: typeof fetch = fetch): EmailSender {
  const base = (cfg.apiUrl ?? "https://api.resend.com").replace(/\/$/, "");
  return async (email) => {
    const res = await fetchFn(`${base}/emails`, {
      method: "POST",
      signal: AbortSignal.timeout(10000),
      headers: {
        Authorization: `Bearer ${cfg.apiKey}`,
        "Content-Type": "application/json",
        // a retried hook call never sends the same email twice
        ...(email.idempotencyKey ? { "Idempotency-Key": email.idempotencyKey } : {}),
      },
      body: JSON.stringify({ from: cfg.from, to: [email.to], subject: email.subject, html: email.html, text: email.text }),
    });
    await res.body?.cancel();
    if (!res.ok) throw new EmailDeliveryError(res.status);
  };
}
