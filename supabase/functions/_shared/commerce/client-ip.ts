// The caller's address as the edge sees it; used for Turnstile and the
// consent/throttle records (A5 R19). The only place that reads it, so every
// public gateway agrees on the header.
//
// Headers are caller-controlled until the hosting edge is shown to set and
// overwrite them (pre-deploy staging check, supabase/CLAUDE.md). So the value
// is returned only when it parses as an IPv4 or IPv6 literal: anything else
// ("unknown", a hostname, junk) is null and never reaches an `inet` parameter.
// Turnstile and the per-phone throttle are the backstop for a spoofed address.

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
const IPV6_CHARS = /^[0-9A-Fa-f:.]+$/;

export function parseIpLiteral(value: string | null | undefined): string | null {
  const s = value?.trim();
  if (!s || s.length > 45) return null;
  if (IPV4.test(s)) return s;
  if (!s.includes(":") || !IPV6_CHARS.test(s)) return null;
  try {
    // The WHATWG URL parser implements the full IPv6 grammar (:: compression,
    // embedded IPv4); the character check above stops anything but an address.
    new URL(`http://[${s}]/`);
    return s;
  } catch {
    return null;
  }
}

export function clientIp(req: Request): string | null {
  const raw = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0] ?? null;
  return parseIpLiteral(raw);
}
