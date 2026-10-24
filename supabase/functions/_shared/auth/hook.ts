// Supabase Auth hooks (Custom Access Token, Send SMS, Send Email) call us
// signed with Standard Webhooks. Shared here: the verifier and the error shape
// Supabase Auth expects back.
import { Webhook } from "../core/deps.ts";
import { json } from "../core/http.ts";
import { requireEnv } from "../core/env.ts";

export type HookVerifier = (payload: string, headers: Record<string, string>) => unknown;

/** Verifier for the `v1,whsec_<base64>` secret held in the named env variable. */
export function hookVerifierFromEnv(name: string): HookVerifier {
  const webhook = new Webhook(requireEnv(name).replace("v1,whsec_", ""));
  return (payload, headers) => webhook.verify(payload, headers);
}

/**
 * An error Supabase Auth relays to its caller as `http_code` + `message`.
 * It must travel as HTTP 200: Auth treats any other status as "Unexpected
 * status code returned from hook" (a bare 500) and drops the message.
 * `message` must never carry PII or a code.
 */
export const hookError = (httpCode: number, message: string) =>
  json(200, { error: { http_code: httpCode, message } });

/** The status Supabase Auth will act on: the error's http_code, else the HTTP status. */
export async function hookResultCode(res: Response): Promise<number> {
  const body = await res.clone().json().catch(() => null) as { error?: { http_code?: number } } | null;
  return body?.error?.http_code ?? res.status;
}
