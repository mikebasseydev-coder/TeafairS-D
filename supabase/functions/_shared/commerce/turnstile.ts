// Addendum A1 §5.3 step 1 — Cloudflare Turnstile siteverify. A failed check
// resolves false (403 to the buyer). Anything that is the operator's or
// Cloudflare's fault (network, timeout, HTTP error, bad secret, internal
// error, unparseable body) throws, so the gateway answers a retryable 503
// instead of blaming the buyer. Error messages never include the secret.
export type VerifyTurnstile = (token: string, remoteIp: string | null) => Promise<boolean>;

const OPERATOR_CODES = ["internal-error", "invalid-input-secret", "missing-input-secret"];

export function turnstileVerifier(
  opts: { secretKey: string; url?: string; fetchFn?: typeof fetch; timeoutMs?: number },
): VerifyTurnstile {
  const fetchFn = opts.fetchFn ?? fetch;
  const url = opts.url ?? "https://challenges.cloudflare.com/turnstile/v0/siteverify";
  const timeoutMs = opts.timeoutMs ?? 8000;
  return async (token, remoteIp) => {
    const form = new FormData();
    form.set("secret", opts.secretKey);
    form.set("response", token);
    if (remoteIp) form.set("remoteip", remoteIp);
    const res = await fetchFn(url, { method: "POST", body: form, signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok) {
      // Cloudflare answers 400 for a bad secret; its error codes say why
      const failed = await res.json().catch(() => null) as { "error-codes"?: unknown } | null;
      const codes = Array.isArray(failed?.["error-codes"])
        ? failed["error-codes"].filter((c): c is string => typeof c === "string").join(", ").slice(0, 200)
        : "";
      throw new Error(`Turnstile siteverify failed: HTTP ${res.status}${codes ? ` (${codes})` : ""}`);
    }
    const payload: unknown = await res.json().catch(() => {
      throw new Error("Turnstile siteverify returned a non-JSON body");
    });
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
      throw new Error("Turnstile siteverify returned an unexpected body");
    }
    const body = payload as { success?: unknown; "error-codes"?: unknown };
    const codes = Array.isArray(body["error-codes"]) ? body["error-codes"].filter((c): c is string => typeof c === "string") : [];
    const operator = codes.find((c) => OPERATOR_CODES.includes(c));
    if (operator) throw new Error(`Turnstile siteverify error: ${operator}`);
    return body.success === true;
  };
}
