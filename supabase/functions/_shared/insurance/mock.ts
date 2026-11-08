// The MOCK insurer (A8 §7.4), for local runs and tests. It accepts every
// declaration, except that a financing_reference ending in REJ is rejected
// and one ending in RTY asks to retry.
//
// Its webhook is signed: x-insurer-signature is hex HMAC-SHA256, keyed with
// MONVELO_MOCK_INSURER_SECRET, over "<x-insurer-timestamp>.<raw body>", and
// the timestamp (Unix seconds) must be within 5 minutes of now. Signing the
// timestamp with the body means an old event cannot be replayed under a
// fresh timestamp.
import type { InsurerAdapter, InsurerEvent, SendResult } from "./adapter.ts";

const WINDOW_SECONDS = 300;
const enc = new TextEncoder();

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}

// constant time over the longer input, as _shared/core/cron.ts
function sameText(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export function signMockWebhook(secret: string, timestamp: string, rawBody: string): Promise<string> {
  return hmacHex(secret, `${timestamp}.${rawBody}`);
}

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

export function createMockAdapter(opts: { secret: string; now?: () => number }): InsurerAdapter {
  const now = opts.now ?? Date.now;
  return {
    send(kind, payload, idempotencyKey): Promise<SendResult> {
      const ref = String(payload.financing_reference ?? payload.claim_reference ?? "");
      if (ref.endsWith("REJ")) {
        return Promise.resolve({ outcome: "REJECTED", insurerReference: null, error: "mock insurer: declined" });
      }
      if (ref.endsWith("RTY")) return Promise.resolve({ outcome: "RETRY", error: "mock insurer: try again" });
      return Promise.resolve({ outcome: "ACCEPTED", insurerReference: `MOCK-${kind}-${idempotencyKey}` });
    },

    async verifyWebhook(req, rawBody) {
      if (!opts.secret) return false;
      const sig = req.headers.get("x-insurer-signature") ?? "";
      const ts = req.headers.get("x-insurer-timestamp") ?? "";
      if (!sig || !/^\d{1,12}$/.test(ts)) return false;
      if (Math.abs(Math.floor(now() / 1000) - Number(ts)) > WINDOW_SECONDS) return false;
      return sameText(sig.toLowerCase(), await signMockWebhook(opts.secret, ts, rawBody));
    },

    parseEvent(rawBody): InsurerEvent {
      const o = JSON.parse(rawBody) as Record<string, unknown>;
      const e: InsurerEvent = { eventId: String(o.event_id ?? ""), type: String(o.type ?? "") };
      const map: Array<[keyof InsurerEvent, string]> = [
        ["claimReference", "claim_reference"],
        ["declarationId", "declaration_id"],
        ["settledAmount", "settled_amount"],
        ["payoutReference", "payout_reference"],
        ["insurerReference", "insurer_reference"],
        ["error", "error"],
      ];
      for (const [k, wire] of map) {
        const v = str(o[wire]);
        if (v !== undefined) (e as Record<string, string>)[k] = v;
      }
      return e;
    },
  };
}
