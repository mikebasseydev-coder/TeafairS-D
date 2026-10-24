// What leaves the runtime for Sentry. A5's rule holds here too: no PIN, OTP,
// verification code, token, full phone number, IP, Storage path or signed URL
// in anything we send. Values under a sensitive key are dropped whatever they
// hold; every other string is pattern-scrubbed. Pure functions, tested alone.

const FILTERED = "[Filtered]";

// Keys whose values are never sent (matched against the whole key, any case;
// RPC parameters carry a p_ prefix).
const SENSITIVE_KEY =
  /^(p_)?(pin|otp|code|.*proof.*|.*_code|delivery_pin|.*token.*|.*secret.*|password|passwd|authorization|cookie|set-cookie|.*phone.*|msisdn|.*email.*|.*address.*|ip|.*_ip|ip_.*|bvn|nin|.*hash.*|.*signature.*|apikey|api_key|x-api-key|.*path.*|.*url)$/i;

// Keys that look sensitive to the pattern above but carry our own safe codes.
const SAFE_KEY = /^(error_code|db\.sqlstate|http\.status_code|status_code)$/i;

const PATTERNS: [RegExp, string][] = [
  [/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, "[jwt]"],
  [/\bBearer\s+\S+/gi, "Bearer [Filtered]"],
  [/\b(sk|pk)_(test|live)_[A-Za-z0-9]+/g, "[paystack-key]"],
  [/https?:\/\/[^\s"']*[?&](token|sig|signature|X-Amz-[A-Za-z]+)=[^\s"']*/gi, "[signed-url]"],
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]"],
  [/\+?234[789][01]\d{8}\b/g, "[phone]"],
  [/\b0[789][01]\d{8}\b/g, "[phone]"],
  [/\+[1-9]\d{7,14}\b/g, "[phone]"],
  [/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "[ip]"],
  [/\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b/gi, "[ip]"],
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

/** Deep copy with sensitive keys filtered and every string scrubbed. */
export function scrubValue(value: unknown, depth = 0): unknown {
  if (depth > 12) return FILTERED;
  if (typeof value === "string") return scrubString(value);
  if (Array.isArray(value)) return value.map((v) => scrubValue(v, depth + 1));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = isSensitiveKey(k) ? FILTERED : scrubValue(v, depth + 1);
    }
    return out;
  }
  return value;
}

function stripQuery(url: string): string {
  const i = url.search(/[?#]/);
  return i === -1 ? url : url.slice(0, i);
}

type AnyEvent = Record<string, unknown> & {
  request?: Record<string, unknown>;
  user?: Record<string, unknown>;
  exception?: { values?: Array<Record<string, unknown>> };
};

/**
 * Scrubs an error or transaction event in place of a copy. The request keeps
 * only its method and path; the user keeps only an id; everything else is
 * scrubbed by key and by pattern.
 */
export function scrubEvent<E extends object>(event: E): E {
  const e = { ...event } as unknown as AnyEvent;
  if (e.request) {
    const r = e.request;
    e.request = {
      ...(typeof r.method === "string" ? { method: r.method } : {}),
      ...(typeof r.url === "string" ? { url: scrubString(stripQuery(r.url)) } : {}),
    };
  }
  if (e.user) e.user = typeof e.user.id === "string" ? { id: e.user.id } : undefined;
  for (const key of ["message", "transaction", "server_name"] as const) {
    if (typeof e[key] === "string") e[key] = scrubString(stripQueryIfUrl(e[key] as string));
  }
  for (const key of ["extra", "contexts", "tags", "breadcrumbs", "spans", "logentry", "measurements"] as const) {
    if (e[key] !== undefined) e[key] = scrubValue(e[key]);
  }
  if (e.exception?.values) {
    e.exception = {
      ...e.exception,
      values: e.exception.values.map((x) => ({
        ...x,
        value: typeof x.value === "string" ? scrubString(x.value) : x.value,
        // stack frames keep file and line only; local variables never leave
        stacktrace: scrubFrames(x.stacktrace),
      })),
    };
  }
  return e as unknown as E;
}

function stripQueryIfUrl(s: string): string {
  return /^https?:\/\//.test(s) ? stripQuery(s) : s;
}

function scrubFrames(stacktrace: unknown): unknown {
  if (!stacktrace || typeof stacktrace !== "object") return stacktrace;
  const st = stacktrace as { frames?: Array<Record<string, unknown>> };
  if (!st.frames) return stacktrace;
  return {
    ...st,
    frames: st.frames.map(({ vars: _vars, ...frame }) => frame),
  };
}

export function scrubBreadcrumb<B extends object>(crumb: B): B {
  const b = { ...crumb } as unknown as Record<string, unknown>;
  if (typeof b.message === "string") b.message = scrubString(b.message);
  if (b.data !== undefined) b.data = scrubValue(b.data);
  return b as unknown as B;
}
