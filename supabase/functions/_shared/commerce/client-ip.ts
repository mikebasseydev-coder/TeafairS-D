// The caller's address as the edge sees it; used for Turnstile and consent/throttle records.
export function clientIp(req: Request): string | null {
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? null;
}
