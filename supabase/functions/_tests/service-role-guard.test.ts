// R46, rule 2: the service-role (secret) key is reached only by reviewed
// functions, each of which authenticates its caller before its first RPC, and
// no Monvelo gateway uses it for Monvelo work. The database still decides:
// service_role holds no write on any Monvelo table (pgTAP 054, 061) and every
// Monvelo user RPC derives the actor from auth.uid().
//
// Run with --allow-read (the documented `deno test` command includes it).
import { assert, assertEquals } from "jsr:@std/assert@1";

const root = new URL("../", import.meta.url); // supabase/functions/
const read = (path: string) => Deno.readTextFileSync(new URL(path, root));

// How each function authenticates the caller before calling serviceRpc().
// Adding a function here is a security review: name the check.
const SERVICE_RPC: Record<string, string> = {
  "auth-verify-claims": "system: Standard Webhooks signature (AUTH_HOOK_SECRET)",
  "send-auth-sms": "system: Standard Webhooks signature (SEND_SMS_HOOK_SECRET)",
  "process-payment": "system: Paystack x-paystack-signature, then Verify",
  "reconcile-funds": "system: x-cron-secret (constant time)",
  "web-commission-release": "system: x-cron-secret (constant time)",
  "storage-purge": "system: x-cron-secret (constant time)",
  "email-outbox-send": "system: x-cron-secret (constant time)",
  "storefront-catalogue": "public: read-only, CORS-limited",
  "storefront-locations": "public: read-only, CORS-limited",
  "storefront-refund-policy": "public: read-only, CORS-limited",
  "web-checkout": "public: Turnstile + single-use phone verification token",
  "web-order-status": "public: (public_reference, paystack_reference) capability",
  "checkout-phone-verify-start": "public: Turnstile + per-phone/per-IP throttle",
  "checkout-phone-verify-confirm": "public: verification id + code, attempt counter",
  "support-ticket-open": "public: Turnstile",
  "support-ticket-read": "public: (public_reference, ticket secret) capability",
  "support-ticket-message": "public: (public_reference, ticket secret) capability",
  "support-ticket-attachment": "public: (public_reference, ticket secret) capability",
};

// User gateways that use the secret key for Storage signing and removal only
// (A5 R22); their RPCs run on the caller's JWT.
const STORAGE_SIGNING = new Set([
  "contact-report-upload",
  "order-delivery-photo",
  "order-dispute-evidence",
  "support-staff-attachment",
  "support-ticket-attachment",
  "support-ticket-read",
  "storage-purge",
]);

// The only Monvelo RPCs reachable with the secret key: the Paystack webhook
// and the reconcile sweep, after the signature or cron-secret check.
const SERVICE_MONVELO_RPCS = new Set(["settle_monvelo_funding", "apply_monvelo_refund"]);

function functionDirs(): string[] {
  return [...Deno.readDirSync(root)]
    .filter((e) => e.isDirectory && !e.name.startsWith("_"))
    .map((e) => e.name)
    .sort();
}

function sourceOf(dir: string): string {
  return [...Deno.readDirSync(new URL(`${dir}/`, root))]
    .filter((e) => e.isFile && e.name.endsWith(".ts") && !e.name.endsWith(".test.ts"))
    .map((e) => read(`${dir}/${e.name}`))
    .join("\n");
}

function walkTs(dir: URL, out: { path: string; text: string }[] = [], rel = ""): typeof out {
  for (const e of Deno.readDirSync(dir)) {
    const path = rel + e.name;
    if (e.isDirectory) walkTs(new URL(`${e.name}/`, dir), out, `${path}/`);
    else if (e.name.endsWith(".ts") && !e.name.endsWith(".test.ts")) {
      out.push({ path, text: Deno.readTextFileSync(new URL(e.name, dir)) });
    }
  }
  return out;
}

Deno.test("R46: every serviceRpc() caller is a reviewed system or public function", () => {
  const using = functionDirs().filter((d) => /\bserviceRpc\(\)/.test(sourceOf(d)));
  assertEquals(using, Object.keys(SERVICE_RPC).sort(), "review the caller check, then update SERVICE_RPC");
});

Deno.test("R46: Storage signing with the secret key is limited to the reviewed functions", () => {
  const using = functionDirs().filter((d) => /\bstorageConfigFromEnv\(\)/.test(sourceOf(d)));
  assertEquals(using, [...STORAGE_SIGNING].sort());
});

Deno.test("R46: no Monvelo gateway calls serviceRpc() or signs Storage with the secret key", () => {
  for (const d of functionDirs().filter((d) => d.startsWith("monvelo-"))) {
    const src = sourceOf(d);
    assert(!/\bserviceRpc\b/.test(src), `${d} must run its RPCs on the caller's JWT`);
    assert(!/\bstorageConfigFromEnv\b/.test(src), `${d} must not hold the secret key`);
  }
});

Deno.test("R46: the message router's secret-key client calls log_message_delivery only", () => {
  const calls = [...read("_shared/messaging/router.ts").matchAll(/\brpc\(\s*"([a-z_]+)"/g)].map((m) => m[1]);
  assertEquals([...new Set(calls)], ["log_message_delivery"]);
});

Deno.test("R46: Monvelo RPCs outside Monvelo gateways are only the webhook's two", () => {
  const found = new Set<string>();
  for (const f of walkTs(root)) {
    if (f.path.startsWith("monvelo-") || f.path.startsWith("_shared/monvelo/") || f.path.startsWith("_tests/")) continue;
    for (const m of f.text.matchAll(/"([a-z_]*monvelo[a-z_]*)"/g)) found.add(m[1]);
  }
  assertEquals([...found].sort(), [...SERVICE_MONVELO_RPCS].sort());
});

Deno.test("R46: only _shared/core/keys.ts reads a Supabase API key from the environment", () => {
  const names = /SUPABASE_(SERVICE_ROLE_KEY|SECRET_KEYS?|ANON_KEY|PUBLISHABLE_KEYS?)\b/;
  const readers = walkTs(root)
    .filter((f) => !f.path.startsWith("_tests/") && f.path !== "_shared/core/keys.ts" && names.test(f.text))
    .map((f) => f.path);
  assertEquals(readers, []);
});
