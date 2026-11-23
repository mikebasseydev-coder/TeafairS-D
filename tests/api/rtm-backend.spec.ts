// RTM backend API tests against the local stack, as the seeded personas.
// Reads go through PostgREST under RLS; the only mutation goes through an Edge
// Function with the caller's JWT. The DB connection is used only to arrange a
// fresh PAID order (no local API can take a real Paystack charge), never to
// assert: every check reads what the persona itself is allowed to see.
//
// Prerequisites: `supabase start`, `pnpm db:seed`, `pnpm functions:serve:api`.
// No token, password, code or full phone number is ever printed.
import { randomUUID } from "node:crypto";
import path from "node:path";
import { config as loadEnv } from "dotenv";
import { expect, type APIRequestContext, test } from "@playwright/test";
import { createPaidWebOrder, openDb, PASSWORD, SEED, sid } from "../../supabase/seed";

loadEnv({ path: path.join(__dirname, "..", "..", "supabase", ".env.test.local"), quiet: true });
const API_KEY = process.env.PUBLISHABLE_KEY || process.env.ANON_KEY || "";

type Session = { token: string; userId: string; claims: Record<string, any> };

function decodeJwt(token: string): Record<string, any> {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
}

async function signIn(request: APIRequestContext, email: string, password = PASSWORD) {
  return request.post("/auth/v1/token?grant_type=password", {
    headers: { apikey: API_KEY, "Content-Type": "application/json" },
    data: { email, password },
  });
}

async function session(request: APIRequestContext, email: string): Promise<Session> {
  const res = await signIn(request, email);
  expect(res.status(), `sign-in for ${email}`).toBe(200);
  const token = (await res.json()).access_token as string;
  const claims = decodeJwt(token);
  return { token, userId: claims.sub, claims };
}

const authHeaders = (s?: Session) => ({
  apikey: API_KEY,
  ...(s ? { Authorization: `Bearer ${s.token}` } : {}),
});

async function rows<T = any>(request: APIRequestContext, s: Session, query: string): Promise<T[]> {
  const res = await request.get(`/rest/v1/${query}`, { headers: authHeaders(s) });
  expect(res.status(), `GET ${query.split("?")[0]}`).toBe(200);
  return res.json();
}

async function callFunction(request: APIRequestContext, name: string, s: Session | undefined, body: unknown) {
  return request.post(`/functions/v1/${name}`, {
    headers: { ...authHeaders(s), "Content-Type": "application/json" },
    data: body,
  });
}

test.describe.configure({ mode: "serial" });

let rep1: Session;
let rep2: Session;
let manager: Session;

test.beforeAll(async ({ request }) => {
  expect(API_KEY, "supabase/.env.test.local must hold the local publishable/anon key").not.toBe("");
  rep1 = await session(request, SEED.users.rep1.email);
  rep2 = await session(request, SEED.users.rep2.email);
  manager = await session(request, SEED.users.manager.email);
});

// ── a) auth and JWT claims ──────────────────────────────────────────────
test.describe("auth and JWT claims", () => {
  test("rep1 signs in with a password and gets TEAFAIR / TM claims from the access token hook", () => {
    const c = rep1.claims;
    expect(c.role).toBe("authenticated");
    expect(c.email).toBe(SEED.users.rep1.email);
    expect(c.app_metadata.active_tenant_id).toBe(SEED.teafairTenantId);
    expect(c.app_metadata.tenant_role).toBe("TM");
    expect(c.app_metadata.tenant_ids).toEqual([SEED.teafairTenantId]);
    expect(c.app_metadata.tenant_ids).not.toContain(SEED.otherTenantId);
    expect(c.app_metadata.platform_role ?? null).toBeNull();
  });

  test("the manager is the zone's ZSM and rep2 is the other territory's TM", () => {
    expect(manager.claims.app_metadata.tenant_role).toBe("ZSM");
    expect(rep2.claims.app_metadata.tenant_role).toBe("TM");
    expect(rep2.claims.app_metadata.active_tenant_id).toBe(SEED.teafairTenantId);
  });

  test("the claim matches the live membership row rep1 can read", async ({ request }) => {
    const me = await rows(request, rep1,
      `tenant_users?profile_id=eq.${rep1.userId}&select=tenant_id,role,territory_id,status`);
    expect(me).toEqual([{ tenant_id: SEED.teafairTenantId, role: "TM", territory_id: SEED.ojoduTerritoryId, status: "ACTIVE" }]);
  });

  test("a wrong password is refused", async ({ request }) => {
    const res = await signIn(request, SEED.users.rep1.email, "not-the-password");
    expect(res.status()).toBe(400);
  });
});

// ── b) RLS: territory and tenant isolation, write protection ────────────
test.describe("RLS isolation and write protection", () => {
  test("rep1 reads their territory and its 8 covered outlets", async ({ request }) => {
    const [t] = await rows(request, rep1, `territories?id=eq.${SEED.ojoduTerritoryId}&select=territory_name,tm_id`);
    expect(t).toEqual({ territory_name: "Ojodu-Berger", tm_id: rep1.userId });

    const cover = await rows(request, rep1,
      `tenant_shop_coverage?territory_id=eq.${SEED.ojoduTerritoryId}&select=retail_shop_id`);
    expect(cover).toHaveLength(8);
    const shops = await rows(request, rep1,
      `retail_shops?id=in.(${cover.map((c) => c.retail_shop_id).join(",")})&select=id,shop_name`);
    expect(shops).toHaveLength(8);
  });

  test("territory, outlet and stock rows are tenant-wide by design (Spec A policies), so rep1 sees rep2's territory", async ({ request }) => {
    // If this starts failing, the RLS model changed: territory scoping is only
    // on buyer contacts, audit rows and fulfilments (asserted below).
    const t = await rows(request, rep1, `territories?id=eq.${SEED.omoleTerritoryId}&select=id`);
    expect(t).toHaveLength(1);
  });

  test("rep2's buyer contacts are hidden from rep1; rep1 sees their own order's contact", async ({ request }) => {
    expect(await rows(request, rep1, `order_contacts?order_id=eq.${SEED.rep2OrderId}&select=order_id`)).toHaveLength(0);
    expect(await rows(request, rep1, `order_contacts?order_id=eq.${SEED.rep1OrderId}&select=order_id`)).toHaveLength(1);
    // and the other way round
    expect(await rows(request, rep2, `order_contacts?order_id=eq.${SEED.rep1OrderId}&select=order_id`)).toHaveLength(0);
    // the ZSM sees both (A2)
    expect(await rows(request, manager,
      `order_contacts?order_id=in.(${SEED.rep1OrderId},${SEED.rep2OrderId})&select=order_id`)).toHaveLength(2);
  });

  test("nothing of another tenant reaches rep1", async ({ request }) => {
    const O = SEED.otherTenantId;
    for (const table of ["tenants", "zones", "territories", "warehouses", "central_products", "inventory_batches"]) {
      const key = table === "tenants" ? "id" : "tenant_id";
      expect(await rows(request, rep1, `${table}?${key}=eq.${O}&select=${key}`), table).toHaveLength(0);
    }
  });

  test("direct table writes are refused, so the Edge Functions cannot be bypassed", async ({ request }) => {
    const h = { ...authHeaders(rep1), "Content-Type": "application/json", Prefer: "return=minimal" };
    const batchId = sid(`batch:${SEED.ojoduDepotId}:SB-VEG-OIL-1L`);
    const [before] = await rows(request, rep1, `inventory_batches?id=eq.${batchId}&select=quantity`);

    const insert = await request.post("/rest/v1/orders", {
      headers: h,
      data: { tenant_id: SEED.teafairTenantId, channel: "FIELD_SALES", teafair_agent_id: rep1.userId, total_amount: 1 },
    });
    expect(insert.status()).toBe(403);

    const update = await request.patch(`/rest/v1/inventory_batches?id=eq.${batchId}`, { headers: h, data: { quantity: 99999 } });
    expect(update.status()).toBe(403);

    const del = await request.delete(`/rest/v1/order_contacts?order_id=eq.${SEED.rep1OrderId}`, { headers: h });
    expect(del.status()).toBe(403);

    const [after] = await rows(request, rep1, `inventory_batches?id=eq.${batchId}&select=quantity`);
    expect(after.quantity).toBe(before.quantity);
  });

  test("calling the dispatch RPC straight through PostgREST fails the gateway proof", async ({ request }) => {
    const res = await request.post("/rest/v1/rpc/mark_order_dispatched", {
      headers: { ...authHeaders(rep1), "Content-Type": "application/json" },
      data: {
        p_idempotency_key: randomUUID(), p_order_id: SEED.rep1OrderId,
        p_tracking_reference: null, p_pin: "1234", p_gateway_proof: "guessed",
      },
    });
    expect(res.status()).toBe(403);
    const [o] = await rows(request, rep1, `orders?id=eq.${SEED.rep1OrderId}&select=status`);
    expect(o.status).toBe("PAID");
  });

  test("an anonymous caller reads nothing", async ({ request }) => {
    const res = await request.get(`/rest/v1/orders?select=id`, { headers: { apikey: API_KEY } });
    expect([401, 403]).toContain(res.status());
  });
});

// ── c) Edge Function mutation and idempotency ───────────────────────────
test.describe("order-dispatch: stock deduction, audit and idempotency", () => {
  const LINES = [{ sku: "SB-VEG-OIL-1L", qty: 3 }, { sku: "CB-NOODLES-CHICKEN-70G", qty: 40 }];
  const orderId = randomUUID();
  const key = randomUUID();
  const tracking = `OJD-${Date.now()}`;
  const batchIds = LINES.map((l) => sid(`batch:${SEED.ojoduDepotId}:${l.sku}`));
  let before: Map<string, { quantity: number; quantity_reserved: number }>;

  const readBatches = async (request: APIRequestContext) => {
    const r = await rows<{ id: string; quantity: string; quantity_reserved: string }>(request, rep1,
      `inventory_batches?id=in.(${batchIds.join(",")})&select=id,quantity,quantity_reserved`);
    return new Map(r.map((b) => [b.id, { quantity: Number(b.quantity), quantity_reserved: Number(b.quantity_reserved) }]));
  };

  test.beforeAll(async ({ request }) => {
    // a fresh PAID order from rep1's Ojodu depot (Ojodu GPS 6.6285, 3.3612), stock reserved
    const sql = openDb();
    try {
      await createPaidWebOrder(sql, {
        orderId, territoryId: SEED.ojoduTerritoryId, warehouseId: SEED.ojoduDepotId,
        teafairAgentId: rep1.userId, items: LINES,
      });
    } finally {
      await sql.end();
    }
    before = await readBatches(request);
  });

  test("the reservation holds the stock before dispatch", async ({ request }) => {
    const res = await rows(request, rep1, `stock_reservations?order_id=eq.${orderId}&select=status,quantity`);
    expect(res.length).toBeGreaterThan(0);
    expect(res.every((r) => r.status === "RESERVED")).toBe(true);
  });

  test("without a JWT the gateway answers 401", async ({ request }) => {
    const res = await callFunction(request, "order-dispatch", undefined, { idempotency_key: randomUUID(), order_id: orderId });
    expect(res.status()).toBe(401);
  });

  test("the idempotency key travels in the body: a header alone is a validation error", async ({ request }) => {
    const res = await request.post("/functions/v1/order-dispatch", {
      headers: { ...authHeaders(rep1), "Content-Type": "application/json", "x-idempotency-key": randomUUID() },
      data: { order_id: orderId },
    });
    expect(res.status()).toBe(400);
  });

  test("rep2 may not dispatch from rep1's depot", async ({ request }) => {
    const res = await callFunction(request, "order-dispatch", rep2, { idempotency_key: randomUUID(), order_id: orderId });
    expect(res.status()).toBe(403);
    expect((await res.json()).error.code).toBe("FORBIDDEN");
    const [o] = await rows(request, rep1, `orders?id=eq.${orderId}&select=status`);
    expect(o.status).toBe("PAID");
  });

  test("rep1 dispatches: 200, the order is IN_TRANSIT and the stock is deducted", async ({ request }) => {
    const res = await callFunction(request, "order-dispatch", rep1,
      { idempotency_key: key, order_id: orderId, tracking_reference: tracking });
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ order_id: orderId, status: "IN_TRANSIT", delivery_code_sent: false });
    expect(body).not.toHaveProperty("buyer_phone");

    const [o] = await rows(request, rep1, `orders?id=eq.${orderId}&select=status`);
    expect(o.status).toBe("IN_TRANSIT");

    const after = await readBatches(request);
    for (const [i, l] of LINES.entries()) {
      const b0 = before.get(batchIds[i])!, b1 = after.get(batchIds[i])!;
      expect(b1.quantity, l.sku).toBe(b0.quantity - l.qty);
      expect(b1.quantity_reserved, l.sku).toBe(b0.quantity_reserved - l.qty);
    }

    const moves = await rows(request, rep1,
      `stock_movements?order_id=eq.${orderId}&select=kind,sku_code,quantity,recorded_by&order=sku_code`);
    expect(moves.map((m) => [m.kind, m.sku_code, Number(m.quantity), m.recorded_by])).toEqual(
      [...LINES].sort((a, b) => a.sku.localeCompare(b.sku)).map((l) => ["SALE_DISPATCH", l.sku, l.qty, rep1.userId]),
    );
    const res2 = await rows(request, rep1, `stock_reservations?order_id=eq.${orderId}&select=status`);
    expect(res2.every((r) => r.status === "CONSUMED")).toBe(true);
  });

  test("the dispatch is audited with its idempotency key, visible to rep1 and hidden from rep2", async ({ request }) => {
    const q = `audit_logs?entity_type=eq.orders&entity_id=eq.${orderId}&operation=eq.mark_order_dispatched` +
      `&select=actor_id,actor_role,idempotency_key,source,after`;
    const audit = await rows(request, rep1, q);
    expect(audit).toHaveLength(1);
    expect(audit[0]).toMatchObject({ actor_id: rep1.userId, actor_role: "TM", idempotency_key: key, source: "USER" });
    expect(audit[0].after).toMatchObject({ order_id: orderId, status: "IN_TRANSIT", has_tracking: true });
    expect(audit[0].after.stock).toHaveLength(LINES.length);

    expect(await rows(request, rep2, q)).toHaveLength(0);
    expect(await rows(request, rep1, `order_fulfilments?order_id=eq.${orderId}&select=order_id`)).toHaveLength(1);
    expect(await rows(request, rep2, `order_fulfilments?order_id=eq.${orderId}&select=order_id`)).toHaveLength(0);
  });

  test("an identical retry replays 200 without touching stock or the audit trail again", async ({ request }) => {
    const stock = await readBatches(request);
    const res = await callFunction(request, "order-dispatch", rep1,
      { idempotency_key: key, order_id: orderId, tracking_reference: tracking });
    expect(res.status()).toBe(200);
    expect(await res.json()).toMatchObject({ order_id: orderId, status: "IN_TRANSIT", delivery_code_sent: false });

    expect(await readBatches(request)).toEqual(stock);
    expect(await rows(request, rep1, `stock_movements?order_id=eq.${orderId}&select=id`)).toHaveLength(LINES.length);
    expect(await rows(request, rep1,
      `audit_logs?entity_type=eq.orders&entity_id=eq.${orderId}&operation=eq.mark_order_dispatched&select=id`)).toHaveLength(1);
  });

  test("the same key with a changed payload is 409 IDEMPOTENCY_MISMATCH (TF002)", async ({ request }) => {
    const res = await callFunction(request, "order-dispatch", rep1,
      { idempotency_key: key, order_id: orderId, tracking_reference: `${tracking}-CHANGED` });
    expect(res.status()).toBe(409);
    expect((await res.json()).error.code).toBe("IDEMPOTENCY_MISMATCH");
  });

  test("a fresh key cannot dispatch the order twice", async ({ request }) => {
    const res = await callFunction(request, "order-dispatch", rep1, { idempotency_key: randomUUID(), order_id: orderId });
    expect(res.status()).toBe(422);
    expect((await res.json()).error.code).toBe("BUSINESS_RULE");
  });
});
