// Addendum A1 §5.3 step 1 — Cloudflare Turnstile siteverify. A failed check
// resolves false (403 to the buyer); a network failure throws, so the gateway
// answers a retryable 503 instead of blaming the buyer.
export type VerifyTurnstile = (token: string, remoteIp: string | null) => Promise<boolean>;

export function turnstileVerifier(opts: { secretKey: string; url?: string; fetchFn?: typeof fetch }): VerifyTurnstile {
  const fetchFn = opts.fetchFn ?? fetch;
  const url = opts.url ?? "https://challenges.cloudflare.com/turnstile/v0/siteverify";
  return async (token, remoteIp) => {
    const form = new FormData();
    form.set("secret", opts.secretKey);
    form.set("response", token);
    if (remoteIp) form.set("remoteip", remoteIp);
    const res = await fetchFn(url, { method: "POST", body: form });
    const payload = await res.json() as { success?: unknown };
    return res.ok && payload.success === true;
  };
}
