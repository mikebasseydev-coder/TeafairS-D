// Supabase Auth hooks (Custom Access Token, Send SMS, Send Email) call us
// signed with Standard Webhooks. Shared here: the verifier and the error shape
// Supabase Auth expects back.
import { Webhook } from "../core/deps.ts";
import { json } from "../core/http.ts";
import { requireEnv } from "../core/env.ts";

export type HookVerifier = (payload: string, headers: Record<string, string>) => unknown;

/**
 * The base64 key of a `v1,whsec_<base64>` hook secret, forgiving the ways a
 * pasted secret is commonly mangled: surrounding whitespace or CR/LF, and one
 * pair of surrounding single or double quotes.
 */
export function normalizeHookSecret(raw: string): string {
  let s = raw.trim();
  const q = s[0];
  if (s.length >= 2 && (q === '"' || q === "'") && s.at(-1) === q) s = s.slice(1, -1).trim();
  return s.replace(/^v1,/, "").replace(/^whsec_/, "");
}

/** Verifier for the `v1,whsec_<base64>` secret held in the named env variable. */
export function hookVerifierFromEnv(name: string): HookVerifier {
  const key = normalizeHookSecret(requireEnv(name));
  let webhook: Webhook;
  try {
    webhook = new Webhook(key);
  } catch {
    // never echo the value: name the variable and the expected shape only
    throw new Error(`${name} is not a valid hook secret (expected v1,whsec_<base64>)`);
  }
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
