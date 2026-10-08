// End-to-end against `supabase start` + `supabase functions serve`.
// Run: see supabase/CLAUDE.md → "Edge Functions". Needs API_URL, ANON_KEY,
// SERVICE_ROLE_KEY (from `supabase status -o env`) and PAYSTACK_SECRET_KEY.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "../_shared/core/deps.ts";

const API = Deno.env.get("API_URL")!;
const ANON = Deno.env.get("ANON_KEY")!;
const SERVICE = Deno.env.get("SERVICE_ROLE_KEY")!;
const PAYSTACK_SECRET = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const FN = `${API}/functions/v1`;

const admin = createClient(API, SERVICE, { auth: { persistSession: false } });
const run = crypto.randomUUID().slice(0, 8);
const ids = {
  tenant: crypto.randomUUID(),
  zone: crypto.randomUUID(),
  territory: crypto.randomUUID(),
  tm: crypto.randomUUID(),
  dsm: crypto.randomUUID(),
  dsa: crypto.randomUUID(),
  owner: crypto.randomUUID(),
  order: crypto.randomUUID(),
};
const phone = (n: number) => `234${String(Date.now()).slice(-7)}${n}`;

async function must<R extends { data: unknown; error: unknown }>(p: PromiseLike<R>): Promise<R["data"]> {
  const { data, error } = await p;
  if (error) throw error;
  return data;
}

async function createUser(n: number): Promise<{ id: string; email: string }> {
  const email = `it-${run}-${n}@teafair.test`;
  const { user } = await must(admin.auth.admin.createUser({
    email, password: "integration-pass-1", email_confirm: true,
    user_metadata: { phone: phone(n), full_name: `IT ${n}` },
  }));
  return { id: user!.id, email };
}

async function signIn(email: string): Promise<string> {
  const client = createClient(API, ANON, { auth: { persistSession: false } });
  const { session } = await must(client.auth.signInWithPassword({ email, password: "integration-pass-1" }));
  return session!.access_token;
}

const claimsOf = (jwt: string) =>
  JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));

async function sign(body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(PAYSTACK_SECRET), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  return Array.from(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))),
    (b) => b.toString(16).padStart(2, "0")).join("");
}

// a fake Paystack Verify API, reached from the edge runtime via host.docker.internal:54399
const paystackLedger = new Map<string, Record<string, unknown>>();
const fakePaystack = Deno.serve({ hostname: "0.0.0.0", port: 54399, onListen() {} }, (req) => {
  const reference = decodeURIComponent(new URL(req.url).pathname.split("/").pop()!);
  const data = paystackLedger.get(reference);
  return data
    ? Response.json({ status: true, message: "Verification successful", data })
    : Response.json({ status: false, message: "Transaction reference not found" }, { status: 400 });
});

let users: Record<"tm" | "dsm" | "dsa" | "owner", { id: string; email: string }>;

Deno.test({
  name: "fixtures",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    users = { tm: await createUser(1), dsm: await createUser(2), dsa: await createUser(3), owner: await createUser(4) };
    await must(admin.from("tenants").insert({ id: ids.tenant, name: `IT ${run}`, code: `IT_${run.toUpperCase().replace(/[^A-Z0-9]/g, "")}`.slice(0, 16) }));
    await must(admin.from("zones").insert({ id: ids.zone, tenant_id: ids.tenant, zone_name: "Lagos" }));
    await must(admin.from("territories").insert({ id: ids.territory, tenant_id: ids.tenant, zone_id: ids.zone, territory_name: "Ikeja" }));
    await must(admin.from("tenant_users").insert([
      { id: ids.tm, tenant_id: ids.tenant, profile_id: users.tm.id, role: "TM", territory_id: ids.territory, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("tenant_users").insert([
      { id: ids.dsm, tenant_id: ids.tenant, profile_id: users.dsm.id, role: "DSM", territory_id: ids.territory, reports_to_id: ids.tm, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("tenant_users").insert([
      { id: ids.dsa, tenant_id: ids.tenant, profile_id: users.dsa.id, role: "DSA", territory_id: ids.territory, reports_to_id: ids.dsm, status: "ACTIVE", is_primary: true },
      { id: ids.owner, tenant_id: ids.tenant, profile_id: users.owner.id, role: "RETAIL_SHOP_OWNER", status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("orders").insert({ id: ids.order, tenant_id: ids.tenant, channel: "FIELD_DSA", teafair_agent_id: users.dsa.id, total_amount: 2500 }));
  },
});

Deno.test({
  name: "auth-verify-claims: a signed-in DSA's token carries the tenant claims",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const app = claimsOf(await signIn(users.dsa.email)).app_metadata;
    assertEquals([app.active_tenant_id, app.tenant_role], [ids.tenant, "DSA"]);
    assertEquals(app.tenant_ids, [ids.tenant]);
  },
});

Deno.test({
  name: "otp-issue: no JWT is 401",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await fetch(`${FN}/otp-issue`, { method: "POST", body: "{}" });
    assertEquals(res.status, 401);
    await res.body?.cancel();
  },
});

Deno.test({
  name: "otp-issue → otp-verify: issue, then a wrong code counts",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const jwt = await signIn(users.dsa.email);
    const post = (fn: string, body: unknown) =>
      fetch(`${FN}/${fn}`, { method: "POST", headers: { Authorization: `Bearer ${jwt}` }, body: JSON.stringify(body) });

    const issued = await post("otp-issue", {
      idempotency_key: crypto.randomUUID(), subject_id: users.owner.id, purpose: "POS_SETTLEMENT",
      tenant_id: crypto.randomUUID(), // must be ignored
    });
    const issuedBody = await issued.json();
    assertEquals(issued.status, 200, JSON.stringify(issuedBody));
    assertEquals(issuedBody.sms_sent, true);

    // the probability that "000000" is the real code is one in a million
    const wrong = await post("otp-verify", { idempotency_key: crypto.randomUUID(), challenge_id: issuedBody.challenge_id, code: "000000" });
    const wrongBody = await wrong.json();
    assertEquals([wrong.status, wrongBody.error.code, wrongBody.error.details.attempts_left], [422, "OTP_INVALID", 4]);
  },
});

Deno.test({
  name: "process-payment: bad signature 401, stale 200 + audit, fresh settles once",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const reference = `it_${run}`;
    await must(admin.from("payments").insert({
      tenant_id: ids.tenant, order_id: ids.order, teafair_agent_id: users.dsa.id,
      amount: 2500, payment_status: "INITIATED", paystack_reference: reference,
    }));
    const deliver = async (payload: unknown, signature?: string) => {
      const body = JSON.stringify(payload);
      const res = await fetch(`${FN}/process-payment`, {
        method: "POST", body, headers: { "x-paystack-signature": signature ?? await sign(body) },
      });
      return { status: res.status, body: await res.json() };
    };

    const forged = await deliver({ event: "charge.success", data: { reference } }, "00");
    assertEquals(forged.status, 401);

    const stale = await deliver({ event: "charge.success", data: { reference, paid_at: new Date(Date.now() - 3_600_000).toISOString() } });
    assertEquals([stale.status, stale.body.outcome], [200, "stale"]);
    const audit = await must(admin.from("audit_logs").select("operation").eq("operation", "WEBHOOK_STALE").eq("tenant_id", ids.tenant));
    assertEquals(audit?.length, 1);

    paystackLedger.set(reference, { status: "success", reference, amount: 250000, currency: "NGN", paid_at: new Date().toISOString() });
    const payload = { event: "charge.success", data: { reference, amount: 1, paid_at: new Date().toISOString() } };
    const first = await deliver(payload);
    assertEquals([first.status, first.body.outcome], [200, "updated"], JSON.stringify(first.body));
    const again = await deliver(payload);
    assertEquals(again.body.outcome, "updated");

    const [payment] = (await must(admin.from("payments").select("payment_status").eq("paystack_reference", reference))) ?? [];
    assertEquals(payment.payment_status, "SUCCESS");
    const settled = await must(admin.from("audit_logs").select("id").eq("operation", "settle_paystack_payment").eq("tenant_id", ids.tenant));
    assert(settled?.length === 1, "a redelivery settles nothing twice");
  },
});

Deno.test({
  name: "teardown",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    await fakePaystack.shutdown();
  },
});
