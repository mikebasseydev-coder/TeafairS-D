// End-to-end against `supabase start` + `supabase functions serve`.
// Run: see supabase/CLAUDE.md → "Edge Functions". Needs API_URL, ANON_KEY,
// SERVICE_ROLE_KEY (from `supabase status -o env`), PAYSTACK_SECRET_KEY and
// CRON_SECRET (from supabase/functions/.env). The functions must be served with
// WHATSAPP_API_URL pointing at this file's fake (host.docker.internal:54399) and
// GATEWAY_SECRET equal to the Vault secret `gateway_secret` (A5, R16).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "../_shared/core/deps.ts";

const API = Deno.env.get("API_URL")!;
const ANON = Deno.env.get("ANON_KEY")!;
const SERVICE = Deno.env.get("SERVICE_ROLE_KEY")!;
const PAYSTACK_SECRET = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
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
  warehouse: crypto.randomUUID(),
  tfZone: crypto.randomUUID(),
  tfTerritory: crypto.randomUUID(),
  tfWarehouse: crypto.randomUUID(),
};
// the TEAFAIR tenant (seeded by a migration) takes every codeless web order
const TEAFAIR = "7eaf0000-0000-4000-8000-000000000001";
const TF_SKU = `IT-${run.toUpperCase()}`;
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

// a fake Paystack (Initialize, Verify, List Refunds, Fetch Subaccount, List
// Settlements, Settlement Transactions; shapes per the D1 plan's F1-F4) and a
// fake Turnstile, reached from the edge runtime via host.docker.internal:54399
const paystackLedger = new Map<string, Record<string, unknown>>();
const refundLedger: Array<Record<string, unknown>> = [];
const settlementLedger: Array<Record<string, unknown> & { transactions: Array<Record<string, unknown>> }> = [];
const initialized: Array<Record<string, unknown>> = [];
const SUBACCOUNT_ID = 55;
// a fake WhatsApp Cloud API (A5 §7): records template sends; the next
// `whatsappFailures` sends answer 500
const whatsappSends: Array<{ to: string; template: string; params: string[] }> = [];
let whatsappFailures = 0;
const page = (data: unknown[]) =>
  Response.json({ status: true, message: "Retrieved", data, meta: { total: data.length, perPage: 100, page: 1, pageCount: 1 } });
const notFound = (message: string) => Response.json({ status: false, message }, { status: 404 });
const fakePaystack = Deno.serve({ hostname: "0.0.0.0", port: 54399, onListen() {} }, async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;
  if (path === "/turnstile/v0/siteverify") {
    const form = await req.formData();
    return Response.json({ success: form.get("response") === "pass" });
  }
  const wa = path.match(/^\/v[0-9.]+\/[0-9]+\/messages$/);
  if (wa && req.method === "POST") {
    if (whatsappFailures > 0) {
      whatsappFailures--;
      return Response.json({ error: { code: 131000, message: "fake failure" } }, { status: 500 });
    }
    const sent = await req.json() as { to: string; template: { name: string; components: Array<{ type: string; parameters: Array<{ text: string }> }> } };
    whatsappSends.push({
      to: sent.to, template: sent.template.name,
      params: sent.template.components.find((c) => c.type === "body")!.parameters.map((p) => p.text),
    });
    return Response.json({ messages: [{ id: `wamid.${whatsappSends.length}` }] });
  }
  if (path === "/transaction/initialize") {
    const body = await req.json() as Record<string, unknown>;
    initialized.push(body);
    const ref = String(body.reference);
    return Response.json({ status: true, data: { authorization_url: `https://checkout.paystack.test/${ref}`, access_code: `ac_${ref}`, reference: ref } });
  }
  if (path.startsWith("/transaction/verify/")) {
    const data = paystackLedger.get(decodeURIComponent(path.slice("/transaction/verify/".length)));
    return data
      ? Response.json({ status: true, message: "Verification successful", data })
      : Response.json({ status: false, message: "Transaction reference not found" }, { status: 400 });
  }
  if (path === "/refund") {
    const reference = url.searchParams.get("reference");
    return page(refundLedger.filter((r) => reference === null || r.transaction_reference === reference));
  }
  if (path.startsWith("/subaccount/")) {
    return decodeURIComponent(path.slice("/subaccount/".length)) === "ACCT_it01"
      ? Response.json({ status: true, message: "Subaccount retrieved", data: { id: SUBACCOUNT_ID, subaccount_code: "ACCT_it01" } })
      : notFound("Subaccount not found");
  }
  if (path === "/settlement") {
    const mine = url.searchParams.get("subaccount") === String(SUBACCOUNT_ID) && url.searchParams.get("status") === "success";
    return page(mine ? settlementLedger.map(({ transactions: _, ...s }) => s) : []);
  }
  const txs = path.match(/^\/settlement\/([^/]+)\/transactions$/);
  if (txs) {
    const settlement = settlementLedger.find((s) => String(s.id) === decodeURIComponent(txs[1]));
    return settlement ? page(settlement.transactions) : notFound("Settlement not found");
  }
  return notFound(`fake Paystack has no ${req.method} ${path}`);
});

// a Verify (F1) record: unsplit unless the subaccount's share is given
let txId = 4_000_000_000 + Math.floor(Math.random() * 1_000_000_000);
function verified(reference: string, amountMinor: number, shareMinor?: number): Record<string, unknown> {
  return {
    id: txId++, status: "success", reference, amount: amountMinor, currency: "NGN", paid_at: new Date().toISOString(),
    subaccount: shareMinor === undefined ? {} : { id: SUBACCOUNT_ID, subaccount_code: "ACCT_it01" },
    fees_split: shareMinor === undefined ? null : {
      paystack: 9370, integration: amountMinor - shareMinor - 9370, subaccount: shareMinor,
      params: { bearer: "account", transaction_charge: String(amountMinor - shareMinor), percentage_charge: "0" },
    },
  };
}

async function deliver(payload: unknown, signature?: string): Promise<{ status: number; body: Record<string, unknown> }> {
  const body = JSON.stringify(payload);
  const res = await fetch(`${FN}/process-payment`, {
    method: "POST", body, headers: { "x-paystack-signature": signature ?? await sign(body) },
  });
  return { status: res.status, body: await res.json() };
}

const cron = (fn: string, body: unknown, secret = CRON_SECRET) =>
  fetch(`${FN}/${fn}`, {
    method: "POST", headers: { "content-type": "application/json", "x-cron-secret": secret }, body: JSON.stringify(body),
  });

let users: Record<"tm" | "dsm" | "dsa" | "owner" | "agent" | "tfTm" | "tfWm" | "tfDsm" | "tfDsa" | "tfZsm", { id: string; email: string }>;
let IKEJA: string;

Deno.test({
  name: "fixtures",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    users = {
      tm: await createUser(1), dsm: await createUser(2), dsa: await createUser(3),
      owner: await createUser(4), agent: await createUser(5), tfTm: await createUser(6),
      tfWm: await createUser(7), tfDsm: await createUser(8), tfDsa: await createUser(9), tfZsm: await createUser(10),
    };
    const [lga] = (await must(admin.from("ng_lgas").select("id").eq("state_code", "LA").eq("name", "Ikeja"))) ?? [];
    IKEJA = lga.id;
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
      { tenant_id: ids.tenant, sku_code: "MILO-400", product_name: "Milo 400g", brand: "Milo", category: "Beverages", unit_price: 2500, wholesale_price: 2000, nafdac_number: "A1-0001" },
      { tenant_id: ids.tenant, sku_code: "MAGGI-12", product_name: "Maggi 12 cubes", brand: "Maggi", category: "Seasoning", unit_price: 1200, wholesale_price: 1000, nafdac_number: "A1-0004" },
    ]));

    // D1 routing: the territory ships web orders from its own regional warehouse
    await must(admin.from("warehouses").insert({ id: ids.warehouse, tenant_id: ids.tenant, name: `IT Ikeja ${run}`, kind: "REGIONAL", territory_id: ids.territory }));
    await must(admin.from("territories").update({ web_fulfilment_warehouse_id: ids.warehouse }).eq("id", ids.territory));
    await must(admin.from("territory_coverage").insert({ tenant_id: ids.tenant, state_code: "LA", lga_id: IKEJA, territory_id: ids.territory }));

    // codeless orders go to TEAFAIR: a per-run territory with an ACTIVE TM and a
    // regional warehouse, a per-run product, and the Ikeja coverage (upserted:
    // the local database keeps it between runs, and it is unique per LGA)
    await must(admin.from("zones").insert({ id: ids.tfZone, tenant_id: TEAFAIR, zone_name: `IT Lagos ${run}` }));
    await must(admin.from("territories").insert({ id: ids.tfTerritory, tenant_id: TEAFAIR, zone_id: ids.tfZone, territory_name: `IT Ikeja ${run}` }));
    await must(admin.from("tenant_users").insert({
      tenant_id: TEAFAIR, profile_id: users.tfTm.id, role: "TM", territory_id: ids.tfTerritory, status: "ACTIVE", is_primary: true,
    }));
    await must(admin.from("warehouses").insert({ id: ids.tfWarehouse, tenant_id: TEAFAIR, name: `IT Ikeja ${run}`, kind: "REGIONAL", territory_id: ids.tfTerritory, manager_id: users.tfWm.id }));
    // A5 fulfilment staff: a warehouse manager (a member who manages the warehouse),
    // a DSM and DSA of the territory, and a tenant-wide ZSM
    const [tfTmRow] = (await must(admin.from("tenant_users").select("id").eq("tenant_id", TEAFAIR).eq("profile_id", users.tfTm.id))) ?? [];
    const [tfDsmRow] = (await must(admin.from("tenant_users").insert(
      { tenant_id: TEAFAIR, profile_id: users.tfDsm.id, role: "DSM", territory_id: ids.tfTerritory, reports_to_id: tfTmRow.id, status: "ACTIVE", is_primary: true },
    ).select("id"))) ?? [];
    await must(admin.from("tenant_users").insert([
      { tenant_id: TEAFAIR, profile_id: users.tfDsa.id, role: "DSA", territory_id: ids.tfTerritory, reports_to_id: tfDsmRow.id, status: "ACTIVE", is_primary: true },
      { tenant_id: TEAFAIR, profile_id: users.tfWm.id, role: "ASM", territory_id: ids.tfTerritory, reports_to_id: tfTmRow.id, status: "ACTIVE", is_primary: true },
      { tenant_id: TEAFAIR, profile_id: users.tfZsm.id, role: "ZSM", zone_id: ids.tfZone, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("territories").update({ tm_id: users.tfTm.id, web_fulfilment_warehouse_id: ids.tfWarehouse }).eq("id", ids.tfTerritory));
    await must(admin.from("central_products").insert({
      tenant_id: TEAFAIR, sku_code: TF_SKU, product_name: `IT Tea ${run}`, brand: "Teafair", category: "Beverages", unit_price: 1500, wholesale_price: 1200, nafdac_number: "A1-0007",
    }));
    await must(admin.from("territory_coverage").upsert(
      { tenant_id: TEAFAIR, state_code: "LA", lga_id: IKEJA, territory_id: ids.tfTerritory },
      { onConflict: "tenant_id,state_code,lga_id" },
    ));
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

    const forged = await deliver({ event: "charge.success", data: { reference } }, "00");
    assertEquals(forged.status, 401);

    const stale = await deliver({ event: "charge.success", data: { reference, paid_at: new Date(Date.now() - 3_600_000).toISOString() } });
    assertEquals([stale.status, stale.body.outcome], [200, "stale"]);
    const audit = await must(admin.from("audit_logs").select("operation").eq("operation", "WEBHOOK_STALE").eq("tenant_id", ids.tenant));
    assertEquals(audit?.length, 1);

    paystackLedger.set(reference, verified(reference, 250000));
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

// A5 §3: a checkout carries consent (policy tag + acceptance) and a single-use
// WhatsApp verification token for the buyer's number. Each call verifies the
// phone through the fake WhatsApp; a retry with the same idempotency key reuses
// its token. Each verification comes from its own address (cf-connecting-ip), so
// the 10-per-IP-per-hour start limit never bites between runs.
const tokenByKey = new Map<string, string>();
let policyTag: string | undefined;

async function activePolicyTag(): Promise<string> {
  if (!policyTag) {
    const res = await fetch(`${FN}/storefront-refund-policy`, { headers: { Origin: WEB } });
    const policy = await res.json();
    assertEquals(res.status, 200, JSON.stringify(policy));
    policyTag = policy.version_tag as string;
  }
  return policyTag;
}

async function verifyPhone(phoneNumber: string): Promise<string> {
  const ip = `10.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}.${1 + Math.floor(Math.random() * 250)}`;
  const started = await fetch(`${FN}/checkout-phone-verify-start`, {
    method: "POST", headers: { Origin: WEB, "content-type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ turnstile_token: "pass", phone: phoneNumber }),
  });
  const start = await started.json();
  assertEquals(started.status, 200, JSON.stringify(start));
  const sent = [...whatsappSends].reverse().find((m) => m.template === "teafair_otp" && m.to === phoneNumber.replace(/^\+/, ""));
  assert(sent, "the code arrives over the fake WhatsApp");
  const confirmed = await fetch(`${FN}/checkout-phone-verify-confirm`, {
    method: "POST", headers: { Origin: WEB, "content-type": "application/json" },
    body: JSON.stringify({ verification_id: start.verification_id, code: sent.params[0] }),
  });
  const confirm = await confirmed.json();
  assertEquals(confirmed.status, 200, JSON.stringify(confirm));
  return confirm.verification_token as string;
}

async function checkout(body: Record<string, unknown>) {
  const key = String(body.idempotency_key);
  if (!tokenByKey.has(key)) {
    tokenByKey.set(key, await verifyPhone((body.customer as { phone: string }).phone));
  }
  return fetch(`${FN}/web-checkout`, {
    method: "POST", headers: { Origin: WEB, "content-type": "application/json" },
    body: JSON.stringify({
      accept_refund_policy: true, policy_version_tag: await activePolicyTag(),
      phone_verification_token: tokenByKey.get(key), ...body,
    }),
  });
}

// a distinct buyer phone per order keeps clear of the 5-unpaid-orders-per-phone limit
let buyer = 0;
const webOrder = (over: Record<string, unknown> = {}) => ({
  idempotency_key: crypto.randomUUID(),
  code: CODE,
  lga_id: IKEJA,
  items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
  // a real Nigerian mobile shape (234 + [789][01] + 8 digits), as normalizePhone requires
  customer: { name: "Ada Obi", phone: `+23480${String(Date.now()).slice(-6)}${buyer++ % 10}7`, delivery_address: "5 Opebi Road, Ikeja" },
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

    const [payment] = (await must(admin.from("payments").select("payment_status, amount, split_subaccount_code, split_amount").eq("paystack_reference", placed.paystack_reference))) ?? [];
    assertEquals([payment.payment_status, Number(payment.amount), payment.split_subaccount_code, Number(payment.split_amount)],
      ["INITIATED", 5580, "ACCT_it01", 83.7]);

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
    const [order] = (await must(admin.from("orders").select("attributed_terminal_id, teafair_agent_id, payment_route, territory_id, fulfilment_warehouse_id").eq("id", placed.order_id))) ?? [];
    assertEquals([order.attributed_terminal_id, order.teafair_agent_id, order.payment_route, order.territory_id, order.fulfilment_warehouse_id],
      [ids.terminal, users.tm.id, "POS_AGENT", ids.territory, ids.warehouse]);
    const payments = await must(admin.from("payments").select("id").eq("order_id", placed.order_id));
    assertEquals(payments?.length, 0);
  },
});

const codeless = (over: Record<string, unknown> = {}) =>
  webOrder({ code: undefined, items: [{ sku_code: TF_SKU, qty: 2 }], ...over });

async function place(body: Record<string, unknown>): Promise<Record<string, string | number | null>> {
  const res = await checkout(body);
  const placed = await res.json();
  assertEquals(res.status, 200, JSON.stringify(placed));
  return placed;
}

async function orderOf(id: unknown): Promise<{ status: string }> {
  const [order] = (await must(admin.from("orders").select("status").eq("id", id))) ?? [];
  return order;
}

async function paymentOf(reference: unknown): Promise<{ id: string; payment_status: string }> {
  const [payment] = (await must(admin.from("payments").select("id, payment_status").eq("paystack_reference", reference))) ?? [];
  return payment;
}

const orderStatus = (body: unknown) =>
  fetch(`${FN}/web-order-status`, { method: "POST", headers: { Origin: WEB, "content-type": "application/json" }, body: JSON.stringify(body) });

Deno.test({
  name: "codeless checkout → charge.success → PAID → status read",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const locations = await fetch(`${FN}/storefront-locations`, { headers: { Origin: WEB } });
    const located = await locations.json();
    assertEquals(locations.status, 200, JSON.stringify(located));
    const lagos = (located.states as Array<{ code: string; lgas: Array<{ id: string; deliverable: boolean }> }>).find((s) => s.code === "LA")!;
    assert(lagos.lgas.find((l) => l.id === IKEJA)!.deliverable, "codeless Ikeja is deliverable");

    const placed = await place(codeless());
    const [order] = (await must(admin.from("orders").select("tenant_id, territory_id, fulfilment_warehouse_id, teafair_agent_id, delivery_lga_id").eq("id", placed.order_id))) ?? [];
    assertEquals([order.tenant_id, order.territory_id, order.fulfilment_warehouse_id, order.teafair_agent_id, order.delivery_lga_id],
      [TEAFAIR, ids.tfTerritory, ids.tfWarehouse, users.tfTm.id, IKEJA]);
    const init = initialized.find((i) => i.reference === placed.paystack_reference)!;
    assertEquals([init.amount, init.subaccount], [375000, undefined], "a codeless order has no split");

    const reference = String(placed.paystack_reference);
    paystackLedger.set(reference, verified(reference, 375000));
    const settled = await deliver({ event: "charge.success", data: { reference, paid_at: new Date().toISOString() } });
    assertEquals([settled.status, settled.body.outcome], [200, "updated"], JSON.stringify(settled.body));
    assertEquals((await orderOf(placed.order_id)).status, "PAID");

    const status = await orderStatus({ public_reference: placed.public_reference, paystack_reference: reference });
    const read = await status.json();
    assertEquals(status.status, 200, JSON.stringify(read));
    assertEquals([read.order_status, read.payment_status, Number(read.total)], ["PAID", "SUCCESS", 3750]);

    const wrong = await orderStatus({ public_reference: placed.public_reference, paystack_reference: `TFW-${crypto.randomUUID()}` });
    assertEquals([wrong.status, (await wrong.json()).error.code], [404, "NOT_FOUND"]);
  },
});

Deno.test({
  name: "terminal checkout → SPLIT → release → SETTLED",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const placed = await place(webOrder());
    const reference = String(placed.paystack_reference);
    // 5580.00 at 150 bps: the partner's share is 83.70
    const charge = verified(reference, 558000, 8370);
    paystackLedger.set(reference, charge);
    const settled = await deliver({ event: "charge.success", data: { reference, paid_at: new Date().toISOString() } });
    assertEquals([settled.status, settled.body.outcome], [200, "updated"], JSON.stringify(settled.body));

    const payment = await paymentOf(reference);
    const [commission] = (await must(admin.from("commission_records").select("id, status, amount").eq("payment_id", payment.id))) ?? [];
    assertEquals([commission.status, Number(commission.amount)], ["SPLIT", 83.7]);
    // the release reads only SPLIT rows older than 24 h
    await must(admin.from("commission_records").update({ created_at: new Date(Date.now() - 25 * 3_600_000).toISOString() }).eq("id", commission.id));

    const settlementId = 7_000_000 + Math.floor(Math.random() * 1_000_000);
    settlementLedger.push({
      id: settlementId, status: "success", currency: "NGN", total_amount: 8370, settlement_date: new Date().toISOString(),
      transactions: [{ id: charge.id, reference, amount: 558000, subaccount: { subaccount_code: "ACCT_it01" }, fees_split: charge.fees_split }],
    });
    const res = await cron("fintech-commission-release", {});
    const counts = await res.json();
    assertEquals(res.status, 200, JSON.stringify(counts));
    assert((counts.outcomes.settled ?? 0) >= 1, JSON.stringify(counts));

    const [after] = (await must(admin.from("commission_records").select("status, paystack_settlement_id, settled_at").eq("id", commission.id))) ?? [];
    assertEquals([after.status, after.paystack_settlement_id], ["SETTLED", String(settlementId)]);
    assert(after.settled_at);
  },
});

Deno.test({
  name: "a dropped webhook is recovered by the sweep",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const placed = await place(codeless());
    const reference = String(placed.paystack_reference);
    // the sweep goes oldest first, 50 at a time. Each run dates its payment
    // further back than the last, so leftovers from earlier runs never crowd it out.
    const createdAt = new Date(Date.UTC(2000, 0, 1) - Math.floor(Date.now() / 1000) * 1000).toISOString();
    await must(admin.from("payments").update({ created_at: createdAt }).eq("paystack_reference", reference));
    paystackLedger.set(reference, verified(reference, 375000));

    const res = await cron("reconcile-funds", { mode: "sweep" });
    const counts = await res.json();
    assertEquals(res.status, 200, JSON.stringify(counts));
    assertEquals([(await paymentOf(reference)).payment_status, (await orderOf(placed.order_id)).status], ["SUCCESS", "PAID"], JSON.stringify(counts));
  },
});

Deno.test({
  name: "refund.processed → REFUNDED",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const placed = await place(codeless());
    const reference = String(placed.paystack_reference);
    const charge = verified(reference, 375000);
    paystackLedger.set(reference, charge);
    const paid = await deliver({ event: "charge.success", data: { reference, paid_at: new Date().toISOString() } });
    assertEquals(paid.body.outcome, "updated", JSON.stringify(paid.body));
    assertEquals((await orderOf(placed.order_id)).status, "PAID");

    // a refund id is an at-most-once key and the local database persists, so one per run
    refundLedger.push({
      id: 900_000_000 + Math.floor(Math.random() * 100_000_000), status: "processed", amount: 375000, currency: "NGN",
      transaction: charge.id, transaction_reference: reference,
    });
    // F4: the webhook carries no refund id and no event timestamp
    const refunded = await deliver({
      event: "refund.processed",
      data: { status: "processed", transaction_reference: reference, refund_reference: null, amount: "375000", currency: "NGN" },
    });
    assertEquals([refunded.status, refunded.body.outcome], [200, "refunded"], JSON.stringify(refunded.body));
    assertEquals([(await paymentOf(reference)).payment_status, (await orderOf(placed.order_id)).status], ["REFUNDED", "REFUNDED"]);
  },
});

Deno.test({
  name: "cron functions reject a wrong secret",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    for (const [fn, body] of [["reconcile-funds", { mode: "sweep" }], ["fintech-commission-release", {}]] as const) {
      const res = await cron(fn, body, "not-the-cron-secret");
      const text = await res.text();
      assertEquals(res.status, 401, `${fn}: ${text}`);
    }
  },
});

const support = (fn: string, body: unknown) =>
  fetch(`${FN}/${fn}`, { method: "POST", headers: { Origin: WEB, "content-type": "application/json" }, body: JSON.stringify(body) });

Deno.test({
  name: "support: open → staff reply → buyer read → buyer message → resolve → close",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    // 1. a pre-purchase ticket for the TEAFAIR territory covering Ikeja
    const openBody = {
      idempotency_key: crypto.randomUUID(), turnstile_token: "pass", category: "DELIVERY",
      message: "Do you deliver to Ikeja?",
      customer: { name: "Ada Obi", phone: `+23480${String(Date.now()).slice(-6)}87` },
      location: { lga_id: IKEJA },
    };
    const opened = await support("support-ticket-open", openBody);
    const ticket = await opened.json();
    assertEquals(opened.status, 200, JSON.stringify(ticket));
    assert(/^TK-[0-9A-HJKMNP-TV-Z]{6}$/.test(ticket.public_reference));
    const secret: string = ticket.secret;
    const ref: string = ticket.public_reference;

    // 1b. a retry with the same idempotency key (the first reply was lost)
    // returns the same ticket and the same, working, secret
    const retried = await support("support-ticket-open", openBody);
    const again = await retried.json();
    assertEquals(retried.status, 200, JSON.stringify(again));
    assertEquals([again.public_reference, again.secret], [ref, secret]);
    const [row] = (await must(admin.from("support_tickets").select("id, tenant_id").eq("public_reference", ref))) ?? [];
    assertEquals(row.tenant_id, TEAFAIR);

    // 2. the territory's TM replies through PostgREST (which claims the ticket)
    const tmJwt = await signIn(users.tfTm.email);
    const tm = createClient(API, ANON, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${tmJwt}` } } });
    await must(tm.rpc("reply_ticket", { p_idempotency_key: crypto.randomUUID(), p_ticket_id: row.id, p_body: "Yes, we deliver to Ikeja." }));

    // 3. the buyer reads it back as "teafair"
    const readRes = await support("support-ticket-read", { public_reference: ref, secret });
    const read = await readRes.json();
    assertEquals(readRes.status, 200, JSON.stringify(read));
    const mine = (read.messages as Array<{ sender: string; body: string }>).map((m) => [m.sender, m.body]);
    assert(mine.some(([s, b]) => s === "teafair" && b === "Yes, we deliver to Ikeja."), JSON.stringify(read));

    // 4. the buyer follows up
    const followUp = await support("support-ticket-message", {
      idempotency_key: crypto.randomUUID(), public_reference: ref, secret, message: "Great, thank you.",
    });
    assertEquals(followUp.status, 200, await followUp.text());

    // 5. the same TM (the assignee) resolves and closes it
    for (const status of ["RESOLVED", "CLOSED"]) {
      await must(tm.rpc("update_ticket_status", { p_idempotency_key: crypto.randomUUID(), p_ticket_id: row.id, p_status: status }));
    }

    // 6. a closed conversation takes no more messages
    const late = await support("support-ticket-message", {
      idempotency_key: crypto.randomUUID(), public_reference: ref, secret, message: "One more thing.",
    });
    const lateBody = await late.json();
    assertEquals(late.status, 422, JSON.stringify(lateBody));
    assertEquals(lateBody.error.message, "This conversation is closed. Open a new ticket if you still need help.");

    // 7. a wrong secret is a 404
    const wrong = await support("support-ticket-read", { public_reference: ref, secret: "A".repeat(43) });
    assertEquals([wrong.status, (await wrong.json()).error.code], [404, "NOT_FOUND"]);
  },
});

// ── A5: verified checkout → dispatch → delivery → damage ticket → evidence ──
async function asUser(email: string) {
  const jwt = await signIn(email);
  const post = (fn: string, body: unknown) =>
    fetch(`${FN}/${fn}`, { method: "POST", headers: { Authorization: `Bearer ${jwt}`, "content-type": "application/json" }, body: JSON.stringify(body) });
  const db = createClient(API, ANON, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${jwt}` } } });
  return { post, db };
}

// the signed URLs are built from the edge runtime's internal Storage address; reach them from the host
const fromHost = (url: string) => url.replace(/^https?:\/\/[^/]+/, API);

async function uploadTo(signedUrl: string, bytes: Uint8Array<ArrayBuffer>, type: string): Promise<void> {
  const form = new FormData();
  form.append("cacheControl", "3600");
  form.append("", new Blob([bytes], { type }));
  const res = await fetch(fromHost(signedUrl), { method: "PUT", headers: { apikey: ANON }, body: form });
  assert(res.ok, `upload failed with ${res.status}: ${await res.text()}`);
}

const photoBytes = (n: number): Uint8Array<ArrayBuffer> => new Uint8Array(n).fill(7);

// a codeless order placed through the verified checkout and paid
async function paidOrder(name: string, phoneNumber: string): Promise<Record<string, string | number | null>> {
  const placed = await place(codeless({ customer: { name, phone: phoneNumber, delivery_address: "5 Opebi Road, Ikeja" } }));
  const reference = String(placed.paystack_reference);
  paystackLedger.set(reference, verified(reference, 375000));
  const settled = await deliver({ event: "charge.success", data: { reference, paid_at: new Date().toISOString() } });
  assertEquals(settled.body.outcome, "updated", JSON.stringify(settled.body));
  assertEquals((await orderOf(placed.order_id)).status, "PAID");
  return placed;
}

Deno.test({
  name: "A5: verified checkout → dispatch → delivery code via WhatsApp → delivery → damage ticket with photo → evidence",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    // 1-2. verification and consenting checkout (checkout() verifies through the fake WhatsApp)
    const buyerName = "Ada Obi";
    const buyerPhone = `+23480${String(Date.now()).slice(-6)}${buyer++ % 10}3`;
    const tag = await activePolicyTag();

    // a missing consent is refused before anything else
    const noConsent = await fetch(`${FN}/web-checkout`, {
      method: "POST", headers: { Origin: WEB, "content-type": "application/json" },
      body: JSON.stringify({ ...codeless(), accept_refund_policy: false, policy_version_tag: tag, phone_verification_token: "A".repeat(43) }),
    });
    const refused = await noConsent.json();
    assertEquals([noConsent.status, refused.error.message], [400, "You must accept the refund policy to place an order."]);

    const placed = await paidOrder(buyerName, buyerPhone);
    const orderId = String(placed.order_id);
    const [order] = (await must(admin.from("orders").select("policy_version_tag, policy_accepted_at").eq("id", orderId))) ?? [];
    assertEquals(order.policy_version_tag, tag);
    assert(order.policy_accepted_at);

    // 3. the warehouse manager dispatches; the code reaches the buyer over WhatsApp
    const wm = await asUser(users.tfWm.email);
    const dispatched = await wm.post("order-dispatch", { idempotency_key: crypto.randomUUID(), order_id: orderId, tracking_reference: `IT-${run}` });
    const dispatch = await dispatched.json();
    assertEquals(dispatched.status, 200, JSON.stringify(dispatch));
    assertEquals([dispatch.status, dispatch.delivery_code_sent, dispatch.channel], ["IN_TRANSIT", true, "WHATSAPP"], JSON.stringify(dispatch));
    assert(!JSON.stringify(dispatch).includes(buyerPhone.slice(1)), "the buyer's phone never reaches the dispatcher");
    const codeMessage = [...whatsappSends].reverse().find((m) => m.template === "teafair_delivery_code" && m.to === buyerPhone.slice(1))!;
    assert(codeMessage, "the delivery code message went out over the fake WhatsApp");
    assertEquals(codeMessage.params[0], placed.public_reference);
    const pin = codeMessage.params[1];
    assert(/^[0-9]{4}$/.test(pin));

    // 4. the territory's DSA uploads a delivery photo, a wrong code is refused, the right one delivers
    const dsa = await asUser(users.tfDsa.email);
    const photo = photoBytes(2048);
    const slotRes = await dsa.post("order-delivery-photo", {
      idempotency_key: crypto.randomUUID(), order_id: orderId, mime_type: "image/png", size_bytes: photo.length,
    });
    const slot = await slotRes.json();
    assertEquals(slotRes.status, 200, JSON.stringify(slot));
    await uploadTo(slot.upload_url, photo, "image/png");

    const wrongPin = pin === "0000" ? "1111" : "0000";
    const wrong = await dsa.post("order-delivery-confirm", {
      idempotency_key: crypto.randomUUID(), order_id: orderId, pin: wrongPin, photo_attachment_id: slot.attachment_id,
    });
    assertEquals([wrong.status, (await wrong.json()).error.code], [422, "WRONG_PIN"]);

    const confirmed = await dsa.post("order-delivery-confirm", {
      idempotency_key: crypto.randomUUID(), order_id: orderId, pin, photo_attachment_id: slot.attachment_id,
    });
    const delivered = await confirmed.json();
    assertEquals(confirmed.status, 200, JSON.stringify(delivered));
    assertEquals([delivered.status, delivered.delivered_via], ["DELIVERED", "FIELD_STAFF"]);
    assertEquals((await orderOf(orderId)).status, "DELIVERED");

    // 5. the buyer opens a DELIVERY ticket, requests an attachment, uploads it, posts with it
    const opened = await support("support-ticket-open", {
      idempotency_key: crypto.randomUUID(), turnstile_token: "pass", category: "DELIVERY", message: "The box arrived crushed.",
      customer: { name: buyerName, phone: buyerPhone },
      order: { public_reference: placed.public_reference, paystack_reference: placed.paystack_reference },
    });
    const ticket = await opened.json();
    assertEquals(opened.status, 200, JSON.stringify(ticket));
    const buyerSlotRes = await support("support-ticket-attachment", {
      idempotency_key: crypto.randomUUID(), public_reference: ticket.public_reference, secret: ticket.secret,
      mime_type: "image/jpeg", size_bytes: 1500,
    });
    const buyerSlot = await buyerSlotRes.json();
    assertEquals(buyerSlotRes.status, 200, JSON.stringify(buyerSlot));
    await uploadTo(buyerSlot.upload_url, photoBytes(1500), "image/jpeg");
    const posted = await support("support-ticket-message", {
      idempotency_key: crypto.randomUUID(), public_reference: ticket.public_reference, secret: ticket.secret,
      message: "Photo of the damage.", attachment_ids: [buyerSlot.attachment_id],
    });
    assertEquals(posted.status, 200, await posted.text());

    const readBack = await (await support("support-ticket-read", { public_reference: ticket.public_reference, secret: ticket.secret })).json();
    const urls = (readBack.messages as Array<{ attachments?: Array<{ url: string | null }> }>).flatMap((m) => m.attachments ?? []);
    assertEquals(urls.length, 1, JSON.stringify(readBack));
    assert(urls[0].url, "the buyer reads back a signed URL");

    // the ZSM sees that the ticket came within the 24-hour damage window
    const zsm = await asUser(users.tfZsm.email);
    const tickets = (await must(zsm.db.from("support_tickets").select("within_damage_window").eq("order_id", orderId))) ?? [];
    assertEquals(tickets.map((t: { within_damage_window: boolean | null }) => t.within_damage_window), [true]);

    // 6. the ZSM's dispute evidence bundle
    const evidenceRes = await zsm.post("order-dispute-evidence", { order_id: orderId });
    const evidence = await evidenceRes.json();
    assertEquals(evidenceRes.status, 200, JSON.stringify(evidence));
    assertEquals(evidence.consent.policy_version_tag, tag);
    assert(evidence.consent.policy_accepted_at && evidence.consent.content);
    assert(evidence.contact.phone_verified_at, "the WhatsApp verification is in the bundle");
    assertEquals(evidence.contact.phone_verified_channel, "WHATSAPP");
    assertEquals([evidence.fulfilment.pin_verified, evidence.fulfilment.delivered_via], [true, "FIELD_STAFF"]);
    assert(typeof evidence.fulfilment.delivery_photo.url === "string", "delivery photo URL");
    const evidenceAttachments = evidence.tickets[0].messages.flatMap((m: { attachments: Array<{ url: string | null }> }) => m.attachments);
    assertEquals(evidenceAttachments.length, 1);
    assert(typeof evidenceAttachments[0].url === "string", "ticket photo URL");
    assertEquals(evidence.tickets[0].within_damage_window, true);
    const text = JSON.stringify(evidence);
    assert(!text.includes('"storage_path"') && !text.includes('"bucket"'), "no Storage path or bucket leaves the gateway");

    // the signed photo URL works
    const fetched = await fetch(fromHost(String(evidence.fulfilment.delivery_photo.url)), { headers: { apikey: ANON } });
    assertEquals(fetched.status, 200);
    assertEquals((await fetched.arrayBuffer()).byteLength, 2048);
  },
});

Deno.test({
  name: "A5: a failing WhatsApp falls back to SMS and the delivery log says so",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const buyerPhone = `+23480${String(Date.now()).slice(-6)}${buyer++ % 10}5`;
    const placed = await paidOrder("Bola Ade", buyerPhone);
    const orderId = String(placed.order_id);
    const wm = await asUser(users.tfWm.email);

    whatsappFailures = 1;
    let dispatch: Record<string, unknown>;
    try {
      const res = await wm.post("order-dispatch", { idempotency_key: crypto.randomUUID(), order_id: orderId });
      dispatch = await res.json();
      assertEquals(res.status, 200, JSON.stringify(dispatch));
    } finally {
      whatsappFailures = 0;
    }
    assertEquals([dispatch.status, dispatch.delivery_code_sent, dispatch.channel], ["IN_TRANSIT", true, "SMS"], JSON.stringify(dispatch));

    // R18: the router logs the dispatcher's tenant, so the tenant's ZSM reads the
    // log through PostgREST under RLS (notification_logs_select_zsm).
    const zsm = await asUser(users.tfZsm.email);
    const rows = (await must(
      zsm.db.from("notification_logs").select("tenant_id, channel, status, phone_last4")
        .eq("related_id", orderId).eq("purpose", "DELIVERY_CODE"),
    )) as Array<{ tenant_id: string; channel: string; status: string; phone_last4: string }>;
    const logs = rows.map((r) => `${r.channel}|${r.status}|${r.phone_last4}`);
    assert(logs.includes(`SMS|SENT|${buyerPhone.slice(-4)}`), JSON.stringify(rows));
    assert(logs.includes(`WHATSAPP|FAILED|${buyerPhone.slice(-4)}`), JSON.stringify(rows));
    assert(rows.every((r) => r.tenant_id === TEAFAIR), JSON.stringify(rows));

    // a DSA of the same tenant is not a ZSM: RLS hides the log
    const dsa = await asUser(users.tfDsa.email);
    const dsaRows = (await must(dsa.db.from("notification_logs").select("id").eq("related_id", orderId))) as unknown[];
    assertEquals(dsaRows.length, 0);
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
