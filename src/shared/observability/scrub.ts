// Follows supabase/functions/_shared/core/scrub.ts (Ruling 46, Spec B §4.4).
// Values under a sensitive key are dropped whatever they hold; every other
// string is pattern-scrubbed. Every `p_` parameter is dropped: a queued
// payload never reaches a log.

export const FILTERED = "[Filtered]";

const SENSITIVE_KEY =
  /^(p_.*|pin|otp|code|.*proof.*|.*_code|delivery_pin|.*token.*|.*secret.*|password|passwd|authorization|cookie|set-cookie|.*phone.*|msisdn|.*email.*|.*address.*|ip|.*_ip|ip_.*|bvn|nin|.*hash.*|.*signature.*|apikey|api_key|x-api-key|.*path.*|.*url|payload|access_code)$/i;

const SAFE_KEY = /^(error_code|db\.sqlstate|http\.status_code|status_code)$/i;

const PATTERNS: [RegExp, string][] = [
  [/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, "[jwt]"],
  [/\bBearer\s+\S+/gi, "Bearer [Filtered]"],
  [/\b(sk|pk)_(test|live)_[A-Za-z0-9]+/g, "[paystack-key]"],
  [/\bsb_(secret|publishable)_[A-Za-z0-9_-]+/g, "[supabase-key]"],
  [/https?:\/\/[^\s"']*[?&](token|sig|signature|X-Amz-[A-Za-z]+)=[^\s"']*/gi, "[signed-url]"],
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]"],
  [/\+?234[789][01]\d{8}\b/g, "[phone]"],
  [/\b0[789][01]\d{8}\b/g, "[phone]"],
  [/\+[1-9]\d{7,14}\b/g, "[phone]"],
  [/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "[ip]"],
  [/\b(pin|code|otp|passcode)(\D{0,12}?)\d{4,8}\b/gi, "$1$2[Filtered]"],
];

export function scrubString(value: string): string {
  let out = value;
  for (const [pattern, replacement] of PATTERNS) out = out.replace(pattern, replacement);
  return out;
}

export function isSensitiveKey(key: string): boolean {
  return !SAFE_KEY.test(key) && SENSITIVE_KEY.test(key);
}

export function scrubValue(value: unknown, depth = 0): unknown {
  if (depth > 12) return FILTERED;
  if (typeof value === "string") return scrubString(value);
  if (Array.isArray(value)) return value.map((v) => scrubValue(v, depth + 1));
  if (value instanceof Error) return { name: value.name, message: scrubString(value.message) };
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = isSensitiveKey(k) ? FILTERED : scrubValue(v, depth + 1);
    return out;
  }
  return value;
}
