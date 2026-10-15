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
  partner: crypto.randomUUID(),
  terminal: crypto.randomUUID(),
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

// a fake Paystack (Verify + Initialize) and a fake Turnstile, reached from the
// edge runtime via host.docker.internal:54399
const paystackLedger = new Map<string, Record<string, unknown>>();
const initialized: Array<Record<string, unknown>> = [];
const fakePaystack = Deno.serve({ hostname: "0.0.0.0", port: 54399, onListen() {} }, async (req) => {
  const path = new URL(req.url).pathname;
  if (path === "/turnstile/v0/siteverify") {
    const form = await req.formData();
    return Response.json({ success: form.get("response") === "pass" });
  }
  if (path === "/transaction/initialize") {
    const body = await req.json() as Record<string, unknown>;
    initialized.push(body);
    const ref = String(body.reference);
    return Response.json({ status: true, data: { authorization_url: `https://checkout.paystack.test/${ref}`, access_code: `ac_${ref}`, reference: ref } });
  }
  const reference = decodeURIComponent(path.split("/").pop()!);
  const data = paystackLedger.get(reference);
  return data
    ? Response.json({ status: true, message: "Verification successful", data })
    : Response.json({ status: false, message: "Transaction reference not found" }, { status: 400 });
});

let users: Record<"tm" | "dsm" | "dsa" | "owner" | "agent", { id: string; email: string }>;

Deno.test({
  name: "fixtures",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    users = { tm: await createUser(1), dsm: await createUser(2), dsa: await createUser(3), owner: await createUser(4), agent: await createUser(5) };
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
    await must(admin.from("tenant_users").insert([
      { tenant_id: ids.tenant, profile_id: users.agent.id, role: "FINTECH_AGENT", territory_id: ids.territory, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("territories").update({ tm_id: users.tm.id }).eq("id", ids.territory));
    await must(admin.from("fintech_partners").insert({
      id: ids.partner, tenant_id: ids.tenant, business_name: `IT Moniepoint ${run}`, pos_network: "MONIEPOINT",
      commission_bps: 150, contact_phone: `+${phone(5)}`, paystack_subaccount_code: "ACCT_it01",
      status: "ACTIVE", approved_by: users.tm.id, approved_at: new Date().toISOString(),
    }));
    await must(admin.from("fintech_terminals").insert({
      id: ids.terminal, tenant_id: ids.tenant, partner_id: ids.partner, agent_id: users.agent.id,
      terminal_id: `IT-${run}`, territory_id: ids.territory,
    }));
    await must(admin.from("central_products").insert([
      { tenant_id: ids.tenant, sku_code: "MILO-400", product_name: "Milo 400g", brand: "Milo", category: "Beverages", unit_price: 2500, wholesale_price: 2000 },
      { tenant_id: ids.tenant, sku_code: "MAGGI-12", product_name: "Maggi 12 cubes", brand: "Maggi", category: "Seasoning", unit_price: 1200, wholesale_price: 1000 },
    ]));
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

const CODE = `IT-${run.toUpperCase()}`;
const WEB = "http://localhost:3000";

Deno.test({
  name: "upsert_agent_code: a TM issues a 10% code through PostgREST",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const jwt = await signIn(users.tm.email);
    const tm = createClient(API, ANON, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const result = await must(tm.rpc("upsert_agent_code", {
      p_idempotency_key: crypto.randomUUID(), p_code: CODE, p_agent_id: users.agent.id, p_terminal_id: ids.terminal,
      p_discount_type: "PERCENT", p_discount_value: 10, p_max_redemptions: null, p_expires_at: null, p_is_active: true,
    })) as { code: string };
    assertEquals(result.code, CODE);
  },
});

Deno.test({
  name: "storefront-catalogue: products for the code, cacheable, no agent id",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await fetch(`${FN}/storefront-catalogue?code=${CODE.toLowerCase()}`, { headers: { Origin: WEB } });
    const text = await res.text();
    assertEquals(res.status, 200, text);
    // the local Kong gateway runs its own CORS plugin on /functions/v1 and answers "*";
    // the function's own allowlist is covered by the unit tests
    assert([WEB, "*"].includes(res.headers.get("access-control-allow-origin") ?? ""));
    assertEquals(res.headers.get("cache-control"), "public, max-age=60, s-maxage=300");
    assertEquals(JSON.parse(text).products.length, 2);
    assert(!text.includes(users.agent.id), "the agent's id never reaches the storefront");
  },
});

const checkout = (body: Record<string, unknown>) =>
  fetch(`${FN}/web-checkout`, { method: "POST", headers: { Origin: WEB, "content-type": "application/json" }, body: JSON.stringify(body) });

const webOrder = (over: Record<string, unknown> = {}) => ({
  idempotency_key: crypto.randomUUID(),
  code: CODE,
  items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
  customer: { name: "Ada Obi", phone: `+${phone(7)}`, delivery_address: "5 Opebi Road, Ikeja" },
  utm: { source: "whatsapp" },
  payment_route: "PAYSTACK_WEB",
  turnstile_token: "pass",
  ...over,
});

Deno.test({
  name: "web-checkout: a failed bot check is 403",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await checkout(webOrder({ turnstile_token: "fail" }));
    assertEquals([res.status, (await res.json()).error.code], [403, "BOT_CHECK_FAILED"]);
  },
});

Deno.test({
  name: "web-checkout: Paystack route initialises with the split and records an INITIATED payment",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const body = webOrder();
    const res = await checkout(body);
    const placed = await res.json();
    assertEquals(res.status, 200, JSON.stringify(placed));
    assert(/^TF-[0-9A-HJKMNP-TV-Z]{6}$/.test(placed.public_reference));
    assertEquals(placed.authorization_url, `https://checkout.paystack.test/${placed.paystack_reference}`);

    const init = initialized.find((i) => i.reference === placed.paystack_reference)!;
    assertEquals([init.amount, init.subaccount, init.transaction_charge], [558000, "ACCT_it01", 558000 - 8370]);

    const [payment] = (await must(admin.from("payments").select("payment_status, amount").eq("paystack_reference", placed.paystack_reference))) ?? [];
    assertEquals([payment.payment_status, Number(payment.amount)], ["INITIATED", 5580]);

    // a retry with the same key gets the same order and URL back
    const again = await (await checkout(body)).json();
    assertEquals([again.order_id, again.authorization_url], [placed.order_id, placed.authorization_url]);
  },
});

Deno.test({
  name: "web-checkout: pay-at-agent route returns a public reference and no payment",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await checkout(webOrder({ payment_route: "POS_AGENT" }));
    const placed = await res.json();
    assertEquals(res.status, 200, JSON.stringify(placed));
    assertEquals(placed.authorization_url, null);
    const [order] = (await must(admin.from("orders").select("attributed_terminal_id, teafair_agent_id, payment_route").eq("id", placed.order_id))) ?? [];
    assertEquals([order.attributed_terminal_id, order.teafair_agent_id, order.payment_route], [ids.terminal, users.tm.id, "POS_AGENT"]);
    const payments = await must(admin.from("payments").select("id").eq("order_id", placed.order_id));
    assertEquals(payments?.length, 0);
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
