// Local RTM seed for the API tests (pnpm db:seed). Idempotent: every row has a
// deterministic id, so a re-run updates or skips instead of duplicating.
//
// What it builds, in the TEAFAIR tenant (Spec A: Teafair is itself a tenant):
//   zone "Lagos Mainland North" (LA), ZSM manager@rtm.local
//   ├── territory "Ojodu-Berger"     TM rep1@rtm.local, "Ojodu Stockist Depot" (rep1 manages it)
//   └── territory "Omole-Agidingbi"  TM rep2@rtm.local, "Omole Stockist Depot" (rep2 manages it)
//   15 retail shops in the Ojodu/Ikeja box (8 covered by Ojodu, 7 by Omole),
//   20 FMCG SKUs (fictional house brands), one batch per SKU per depot,
//   two PAID web orders with buyer contacts (one per territory), stock reserved.
//   Monvelo (A6) opted in: area "Ojodu Central" and its ASA asa@rtm.local
//   (reports to rep1), the zone's ZSA zsa@rtm.local (reports to the ZSM), an
//   ACTIVE POS agent the ASA recruited with its staff pos-agent@rtm.local (the
//   Monvelo "fintech agent"), the platform operator monvelo-ops@rtm.local, and
//   the owner of the first Ojodu outlet, shop-owner@rtm.local.
// Plus a second tenant, LAGOSFMCG, with its own zone, territory, depot and
// SKUs, not opted in to Monvelo, whose only members are a TM
// (lagos-tm@rtm.local) and an ASA under them (lagos-asa@rtm.local), so the
// tests can prove tenant isolation.
//
// Users go through the Auth admin API (supabase-js, secret key). Domain rows are
// fixtures written as `postgres` over the local DB URL: clients never write
// tables (Spec A §9), and the stock reservation writers have no API grant at
// all, so a PostgREST service-role write could not build a reserved order.
//
// Local only: it refuses any API or DB URL that is not on 127.0.0.1/localhost.
// It prints no secret, token or full phone number.
import { createHash } from "node:crypto";
import path from "node:path";
import { config as loadEnv } from "dotenv";
import { fakerEN_NG as faker } from "@faker-js/faker";
import { createClient } from "@supabase/supabase-js";
import postgres from "postgres";

const SUPABASE_DIR = __dirname;
loadEnv({ path: path.join(SUPABASE_DIR, ".env.test.local"), quiet: true });
loadEnv({ path: path.join(SUPABASE_DIR, "..", ".env"), quiet: true });

// ── deterministic ids ───────────────────────────────────────────────────
/** A stable UUID (v5 layout) for a seed row name, so re-runs hit the same rows. */
export function sid(name: string): string {
  const b = createHash("sha1").update(`teafair-rtm-seed:${name}`).digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export const PASSWORD = "Password123!"; // local seed personas only (minimum length 12)

export const SEED = {
  teafairTenantId: "7eaf0000-0000-4000-8000-000000000001", // created by 20261006130600_teafair_tenant.sql
  otherTenantId: sid("tenant:LAGOSFMCG"),
  zoneId: sid("zone:lagos-mainland-north"),
  ojoduTerritoryId: sid("territory:ojodu-berger"),
  omoleTerritoryId: sid("territory:omole-agidingbi"),
  ojoduDepotId: sid("warehouse:ojodu-depot"),
  omoleDepotId: sid("warehouse:omole-depot"),
  otherZoneId: sid("zone:lagosfmcg-ikeja"),
  otherTerritoryId: sid("territory:lagosfmcg-ikeja-central"),
  otherDepotId: sid("warehouse:lagosfmcg-ikeja"),
  rep1OrderId: sid("order:rep1-with-contact"),
  rep2OrderId: sid("order:rep2-with-contact"),
  /** Ojodu, Lagos: the depot and the field GPS the tests use. */
  ojoduGps: { lat: 6.6285, lng: 3.3612 },
  users: {
    manager: { email: "manager@rtm.local", phone: "2348000000901", name: "Adaeze Okonkwo" },
    rep1: { email: "rep1@rtm.local", phone: "2348000000902", name: "Tunde Bakare" },
    rep2: { email: "rep2@rtm.local", phone: "2348000000903", name: "Ifeoma Nwosu" },
    /** Monvelo street agent (A6 §3): ASA of the Ojodu Central area, reports to rep1 (the territory's TM). */
    asa: { email: "asa@rtm.local", phone: "2348000000904", name: "Bola Adebayo" },
    /** Monvelo platform staff (profiles.platform_role MONVELO_OPERATOR), no tenant membership. */
    monveloOps: { email: "monvelo-ops@rtm.local", phone: "2348000000905", name: "Chidi Obi" },
    /** Monvelo street agent (A6 §3): ZSA of the zone, reports to the ZSM. */
    zsa: { email: "zsa@rtm.local", phone: "2348000000906", name: "Emeka Nnadi" },
    /** The owner of the first Ojodu outlet (retail_shops.owner_id); no tenant membership. */
    shopOwner: { email: "shop-owner@rtm.local", phone: "2348000000907", name: "Funke Akande" },
    /**
     * Monvelo "fintech agent": staff (monvelo_agent_members) of the seeded ACTIVE POS
     * agent the ASA recruited. Not the web POS_AGENT tenant role (A6 §15).
     */
    fintechAgent: { email: "pos-agent@rtm.local", phone: "2348000000908", name: "Yusuf Bello" },
    /** LAGOSFMCG (not opted in to Monvelo): the territory's TM and an ASA under them. */
    lagosTm: { email: "lagos-tm@rtm.local", phone: "2348000000909", name: "Ngozi Eze" },
    lagosAsa: { email: "lagos-asa@rtm.local", phone: "2348000000910", name: "Sola Martins" },
  },
  /** The Ojodu area the ASA works (A6 §3: zone - territory - area). */
  ojoduAreaId: sid("area:ojodu-central"),
  /** LAGOSFMCG's area, for its ASA. */
  otherAreaId: sid("area:lagosfmcg-allen"),
  /** The first Ojodu outlet, owned by the shop owner persona. */
  ownedShopId: sid("shop:0"),
  /** An ACTIVE Monvelo POS agent recruited by the ASA; the fintech agent is its staff. */
  monveloAgentId: sid("monvelo-agent:ojodu-liquidity"),
  monveloAgentNetworkId: "MP-SEED-OJODU-0001",
} as const;

type SkuSeed = {
  code: string; name: string; brand: string; category: string;
  sale: "FOOD" | "COSMETICS"; retail: number; wholesale: number; carton: number;
};

// Fictional brands: nothing here imitates a real manufacturer.
export const SKUS: SkuSeed[] = [
  { code: "TFS-BLACK-TEA-50", name: "Teafair Select Black Tea - 50 bags", brand: "Teafair Select", category: "Beverages", sale: "FOOD", retail: 1800, wholesale: 1500, carton: 24 },
  { code: "TFS-GREEN-TEA-25", name: "Teafair Select Green Tea - 25 bags", brand: "Teafair Select", category: "Beverages", sale: "FOOD", retail: 1600, wholesale: 1350, carton: 24 },
  { code: "TFS-SUGAR-500G", name: "Teafair Select Granulated Sugar - 500g", brand: "Teafair Select", category: "Sugar and sweeteners", sale: "FOOD", retail: 1200, wholesale: 1000, carton: 20 },
  { code: "TFS-CUBE-SUGAR-500G", name: "Teafair Select Cube Sugar - 500g", brand: "Teafair Select", category: "Sugar and sweeteners", sale: "FOOD", retail: 1400, wholesale: 1150, carton: 20 },
  { code: "GH-RICE-LG-5KG", name: "Gold Harvest Long Grain Rice - 5kg", brand: "Gold Harvest", category: "Grains", sale: "FOOD", retail: 9500, wholesale: 8600, carton: 4 },
  { code: "GH-RICE-PB-10KG", name: "Gold Harvest Parboiled Rice - 10kg", brand: "Gold Harvest", category: "Grains", sale: "FOOD", retail: 18500, wholesale: 17000, carton: 2 },
  { code: "GH-HONEY-BEANS-2KG", name: "Gold Harvest Honey Beans - 2kg", brand: "Gold Harvest", category: "Grains", sale: "FOOD", retail: 5200, wholesale: 4600, carton: 6 },
  { code: "GH-YELLOW-GARRI-2KG", name: "Gold Harvest Yellow Garri - 2kg", brand: "Gold Harvest", category: "Grains", sale: "FOOD", retail: 3000, wholesale: 2600, carton: 6 },
  { code: "GH-WHEAT-MEAL-1KG", name: "Gold Harvest Wheat Meal - 1kg", brand: "Gold Harvest", category: "Grains", sale: "FOOD", retail: 2400, wholesale: 2100, carton: 10 },
  { code: "SB-VEG-OIL-1L", name: "Sunbloom Vegetable Oil - 1L", brand: "Sunbloom", category: "Cooking oil", sale: "FOOD", retail: 3200, wholesale: 2850, carton: 12 },
  { code: "SB-VEG-OIL-3L", name: "Sunbloom Vegetable Oil - 3L", brand: "Sunbloom", category: "Cooking oil", sale: "FOOD", retail: 9000, wholesale: 8100, carton: 6 },
  { code: "SB-PALM-OIL-1L", name: "Sunbloom Palm Oil - 1L", brand: "Sunbloom", category: "Cooking oil", sale: "FOOD", retail: 2800, wholesale: 2450, carton: 12 },
  { code: "MD-MILK-POWDER-400G", name: "Morning Dew Full Cream Milk Powder - 400g", brand: "Morning Dew", category: "Dairy", sale: "FOOD", retail: 4500, wholesale: 4000, carton: 12 },
  { code: "MD-EVAP-MILK-160G", name: "Morning Dew Evaporated Milk - 160g", brand: "Morning Dew", category: "Dairy", sale: "FOOD", retail: 650, wholesale: 560, carton: 48 },
  { code: "MD-COCOA-500G", name: "Morning Dew Cocoa Drink - 500g", brand: "Morning Dew", category: "Beverages", sale: "FOOD", retail: 3800, wholesale: 3350, carton: 12 },
  { code: "CB-CREAM-CRACKERS-12", name: "Crispy Bite Cream Crackers - 12 pack", brand: "Crispy Bite", category: "Snacks", sale: "FOOD", retail: 2200, wholesale: 1900, carton: 10 },
  { code: "CB-NOODLES-CHICKEN-70G", name: "Crispy Bite Instant Noodles Chicken - 70g", brand: "Crispy Bite", category: "Noodles and pasta", sale: "FOOD", retail: 300, wholesale: 250, carton: 40 },
  { code: "CB-DIGESTIVE-250G", name: "Crispy Bite Digestive Biscuits - 250g", brand: "Crispy Bite", category: "Snacks", sale: "FOOD", retail: 1100, wholesale: 950, carton: 24 },
  { code: "LF-TABLE-WATER-75CL-12", name: "Lagoon Fresh Table Water - 75cl x 12", brand: "Lagoon Fresh", category: "Beverages", sale: "FOOD", retail: 2400, wholesale: 2000, carton: 1 },
  { code: "BW-BAR-SOAP-200G", name: "Bright Wash Bar Soap - 200g", brand: "Bright Wash", category: "Personal care", sale: "COSMETICS", retail: 700, wholesale: 600, carton: 36 },
];

const OTHER_SKUS: SkuSeed[] = [
  { code: "LFD-SPAGHETTI-500G", name: "Lagos FMCG Spaghetti - 500g", brand: "Eko Pantry", category: "Noodles and pasta", sale: "FOOD", retail: 1300, wholesale: 1100, carton: 20 },
  { code: "LFD-TOMATO-PASTE-70G", name: "Lagos FMCG Tomato Paste - 70g", brand: "Eko Pantry", category: "Condiments", sale: "FOOD", retail: 350, wholesale: 290, carton: 50 },
];

// ── safety and env ──────────────────────────────────────────────────────
const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost"]);

export function requireLocalEnv(): { apiUrl: string; secretKey: string; dbUrl: string } {
  const apiUrl = process.env.API_URL ?? "http://127.0.0.1:54321";
  const dbUrl = process.env.DB_URL ?? "";
  // Ruling 46: prefer the sb_secret_ key, fall back to the legacy one
  const secretKey = process.env.SECRET_KEY || process.env.SERVICE_ROLE_KEY || "";
  if (!dbUrl) {
    throw new Error("no DB_URL: run `supabase status -o env > supabase/.env.test.local`");
  }
  for (const u of [apiUrl, dbUrl]) {
    if (!LOCAL_HOSTS.has(new URL(u).hostname)) {
      throw new Error("refusing to seed: the API and DB URLs must point at the local stack");
    }
  }
  if (!secretKey) {
    throw new Error("no local secret key: run `supabase status -o env > supabase/.env.test.local`");
  }
  return { apiUrl, secretKey, dbUrl };
}

export function openDb(dbUrl = requireLocalEnv().dbUrl) {
  return postgres(dbUrl, { max: 1, onnotice: () => {} });
}
type Sql = ReturnType<typeof openDb>;

const last4 = (phone: string) => `…${phone.slice(-4)}`;

// ── auth users ──────────────────────────────────────────────────────────
async function ensureUser(
  admin: ReturnType<typeof createClient>["auth"]["admin"],
  u: { email: string; phone: string; name: string },
): Promise<string> {
  const attrs = {
    email: u.email,
    phone: u.phone,
    password: PASSWORD,
    email_confirm: true,
    phone_confirm: true,
    // handle_new_user() requires a phone and reads full_name from metadata
    user_metadata: { full_name: u.name, phone: u.phone },
  };
  const created = await admin.createUser(attrs);
  if (!created.error) return created.data.user!.id;

  // already there: find it and reset the password, so the personas always sign in
  for (let page = 1; page < 50; page++) {
    const { data, error } = await admin.listUsers({ page, perPage: 200 });
    if (error) throw new Error(`listing users failed: ${error.message}`);
    const hit = data.users.find((x) => x.email === u.email);
    if (hit) {
      const upd = await admin.updateUserById(hit.id, { password: PASSWORD, email_confirm: true });
      if (upd.error) throw new Error(`updating ${u.email} failed: ${upd.error.message}`);
      return hit.id;
    }
    if (data.users.length < 200) break;
  }
  throw new Error(`creating ${u.email} failed: ${created.error.message}`);
}

// ── fixture orders (also used by the API tests) ─────────────────────────
export type PaidOrderInput = {
  orderId: string;
  territoryId: string;
  warehouseId: string;
  teafairAgentId: string;
  items: { sku: string; qty: number }[];
  contact?: { name: string; phone: string; address: string };
};

/**
 * A PAID web order routed to a territory and depot, with its stock reserved by
 * the real FEFO writer (stock_reserve_order). It stands in for checkout plus a
 * verified Paystack charge, which the local stack cannot complete on its own.
 * Idempotent on orderId.
 */
export async function createPaidWebOrder(sql: Sql, o: PaidOrderInput): Promise<{ id: string; publicReference: string }> {
  return await sql.begin(async (tx) => {
    const existing = await tx<{ public_reference: string }[]>`
      select public_reference from public.orders where id = ${o.orderId}`;
    if (existing.length) return { id: o.orderId, publicReference: existing[0].public_reference };

    const prices = await tx<{ sku_code: string; unit_price: string }[]>`
      select sku_code, unit_price from public.central_products
       where tenant_id = ${SEED.teafairTenantId} and sku_code in ${tx(o.items.map((i) => i.sku))}`;
    const price = new Map(prices.map((p) => [p.sku_code, Number(p.unit_price)]));
    const total = o.items.reduce((s, i) => s + (price.get(i.sku) ?? NaN) * i.qty, 0);
    if (!Number.isFinite(total)) throw new Error("an order line names an unknown SKU");

    const [row] = await tx<{ public_reference: string }[]>`
      insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                                 public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id,
                                 policy_version_tag, policy_accepted_at)
      values (${o.orderId}, ${SEED.teafairTenantId}, 'ONLINE', ${o.teafairAgentId}, ${total}, 'PAID', 'PAYSTACK_WEB',
              public.new_crockford_reference('TF'),
              (select l.id from public.ng_lgas l where l.state_code = 'LA' and l.name = 'Ikeja'),
              ${o.territoryId}, ${o.warehouseId},
              (select version_tag from public.refund_policies where is_active order by version_tag desc limit 1),
              now())
      returning public_reference`;

    for (const i of o.items) {
      await tx`insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
               values (${SEED.teafairTenantId}, ${o.orderId}, ${i.sku}, ${i.qty}, ${price.get(i.sku)!})`;
    }
    if (o.contact) {
      await tx`insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone, delivery_address)
               values (${o.orderId}, ${SEED.teafairTenantId}, ${o.territoryId}, ${o.contact.name}, ${o.contact.phone},
                       ${o.contact.address})`;
    }
    // a paid order's reservation does not expire (the sweep only cancels PENDING orders)
    await tx`select public.stock_reserve_order(o, null) from public.orders o where o.id = ${o.orderId}`;
    return { id: o.orderId, publicReference: row.public_reference };
  });
}

// ── the seed ────────────────────────────────────────────────────────────
async function main() {
  const env = requireLocalEnv();
  const gatewaySecret = loadGatewaySecret();
  faker.seed(20261123);

  const supabase = createClient(env.apiUrl, env.secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const sql = openDb(env.dbUrl);
  const T = SEED.teafairTenantId;

  try {
    const ids = {
      manager: await ensureUser(supabase.auth.admin, SEED.users.manager),
      rep1: await ensureUser(supabase.auth.admin, SEED.users.rep1),
      rep2: await ensureUser(supabase.auth.admin, SEED.users.rep2),
      asa: await ensureUser(supabase.auth.admin, SEED.users.asa),
      monveloOps: await ensureUser(supabase.auth.admin, SEED.users.monveloOps),
      zsa: await ensureUser(supabase.auth.admin, SEED.users.zsa),
      shopOwner: await ensureUser(supabase.auth.admin, SEED.users.shopOwner),
      fintechAgent: await ensureUser(supabase.auth.admin, SEED.users.fintechAgent),
      lagosTm: await ensureUser(supabase.auth.admin, SEED.users.lagosTm),
      lagosAsa: await ensureUser(supabase.auth.admin, SEED.users.lagosAsa),
    };
    for (const [k, u] of Object.entries(SEED.users)) console.log(`user ${k}: ${u.email} (phone ${last4(u.phone)})`);

    await sql.begin(async (tx) => {
      // memberships first: the zone and territory manager triggers need ACTIVE ZSM/TM rows
      const tuManager = sid("tu:manager");
      await tx`
        insert into public.tenant_users (id, tenant_id, profile_id, role, is_primary, status)
        values (${tuManager}, ${T}, ${ids.manager}, 'ZSM', true, 'ACTIVE')
        on conflict (tenant_id, profile_id) do update set role = 'ZSM', status = 'ACTIVE', is_primary = true,
                                                         zone_id = null, territory_id = null, reports_to_id = null`;

      await tx`
        insert into public.zones (id, tenant_id, zone_name, zsm_id, state_code)
        values (${SEED.zoneId}, ${T}, 'Lagos Mainland North', ${ids.manager}, 'LA')
        on conflict (id) do update set zsm_id = excluded.zsm_id`;

      for (const [id, name] of [[SEED.ojoduTerritoryId, "Ojodu-Berger"], [SEED.omoleTerritoryId, "Omole-Agidingbi"]]) {
        await tx`insert into public.territories (id, tenant_id, zone_id, territory_name)
                 values (${id}, ${T}, ${SEED.zoneId}, ${name}) on conflict (id) do nothing`;
      }

      const managerTu = (await tx<{ id: string }[]>`
        select id from public.tenant_users where tenant_id = ${T} and profile_id = ${ids.manager}`)[0].id;
      for (const [rep, territory] of [[ids.rep1, SEED.ojoduTerritoryId], [ids.rep2, SEED.omoleTerritoryId]]) {
        await tx`
          insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, reports_to_id, is_primary, status)
          values (${sid(`tu:${rep}`)}, ${T}, ${rep}, 'TM', ${territory}, ${managerTu}, true, 'ACTIVE')
          on conflict (tenant_id, profile_id) do update set role = 'TM', territory_id = excluded.territory_id,
                                                           reports_to_id = excluded.reports_to_id, status = 'ACTIVE'`;
        await tx`update public.territories set tm_id = ${rep} where id = ${territory}`;
      }

      // depots: each TM manages their territory's stockist, which lets them dispatch from it
      const depots = [
        { id: SEED.ojoduDepotId, name: "Ojodu Stockist Depot", territory: SEED.ojoduTerritoryId, manager: ids.rep1, ...SEED.ojoduGps },
        { id: SEED.omoleDepotId, name: "Omole Stockist Depot", territory: SEED.omoleTerritoryId, manager: ids.rep2, lat: 6.6352, lng: 3.3561 },
      ];
      for (const d of depots) {
        await tx`
          insert into public.warehouses (id, tenant_id, name, kind, territory_id, location, manager_id)
          values (${d.id}, ${T}, ${d.name}, 'STOCKIST', ${d.territory},
                  extensions.st_setsrid(extensions.st_makepoint(${d.lng}, ${d.lat}), 4326), ${d.manager})
          on conflict (id) do update set manager_id = excluded.manager_id, territory_id = excluded.territory_id`;
      }

      // catalogue: NAFDAC numbers are marked SEED so they never pass for real ones
      for (const [n, s] of SKUS.entries()) {
        await tx`
          insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                               nafdac_number, unit_price, wholesale_price, carton_units, is_active)
          values (${T}, ${s.code}, ${s.name}, ${s.brand}, ${s.category}, ${s.sale},
                  ${`SEED-A${(n % 9) + 1}-${String(5000 + n)}`}, ${s.retail}, ${s.wholesale}, ${s.carton}, true)
          on conflict (tenant_id, sku_code) do update
            set product_name = excluded.product_name, unit_price = excluded.unit_price,
                wholesale_price = excluded.wholesale_price, is_active = true`;
        for (const d of depots) {
          await tx`
            insert into public.inventory_batches (id, tenant_id, warehouse_id, sku_code, batch_number, quantity, expires_at)
            values (${sid(`batch:${d.id}:${s.code}`)}, ${T}, ${d.id}, ${s.code}, ${`SEED-${s.code}-B1`},
                    ${faker.number.int({ min: 200, max: 500 })},
                    now() + make_interval(days => ${faker.number.int({ min: 180, max: 540 })}))
            on conflict (warehouse_id, sku_code, batch_number) do nothing`;
        }
      }

      // 15 outlets in the Ojodu/Ikeja box; the first 8 are Ojodu's, the rest Omole's
      const kinds = ["Provisions", "Supermarket", "Stores", "Mini Mart", "Wholesale Depot"];
      const density = ["HIGH_DENSITY", "MARKET_SQUARE", "SUBURBAN", "HIGH_DENSITY", "EVENT_CENTER"] as const;
      for (let i = 0; i < 15; i++) {
        const id = sid(`shop:${i}`);
        const territory = i < 8 ? SEED.ojoduTerritoryId : SEED.omoleTerritoryId;
        const lat = faker.location.latitude({ min: 6.615, max: 6.645, precision: 6 });
        const lng = faker.location.longitude({ min: 3.345, max: 3.375, precision: 6 });
        await tx`
          insert into public.retail_shops (id, shop_name, contact_phone, density_category, location, address_text)
          values (${id}, ${`${faker.person.lastName()} ${kinds[i % kinds.length]}`},
                  ${`+23480${faker.string.numeric(8)}`}, ${density[i % density.length]},
                  extensions.st_setsrid(extensions.st_makepoint(${lng}, ${lat}), 4326),
                  ${`${faker.number.int({ min: 1, max: 120 })} ${faker.location.street()}, ${i < 8 ? "Ojodu" : "Omole"}, Lagos`})
          on conflict (id) do nothing`;
        await tx`
          insert into public.tenant_shop_coverage (tenant_id, retail_shop_id, territory_id, assigned_by)
          values (${T}, ${id}, ${territory}, ${ids.manager})
          on conflict (tenant_id, retail_shop_id) do update set territory_id = excluded.territory_id`;
      }

      // Monvelo (A6): TEAFAIR opts in; an ASA works the Ojodu Central area under rep1 (the TM);
      // a MONVELO_OPERATOR is platform staff with no tenant. LAGOSFMCG stays opted out.
      await tx`insert into public.monvelo_tenant_settings (tenant_id, enabled) values (${T}, true)
               on conflict (tenant_id) do update set enabled = true`;
      await tx`insert into public.areas (id, tenant_id, territory_id, area_name)
               values (${SEED.ojoduAreaId}, ${T}, ${SEED.ojoduTerritoryId}, 'Ojodu Central')
               on conflict (id) do nothing`;
      const rep1Tu = (await tx<{ id: string }[]>`
        select id from public.tenant_users where tenant_id = ${T} and profile_id = ${ids.rep1}`)[0].id;
      await tx`
        insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, area_id, reports_to_id, is_primary, status)
        values (${sid("tu:asa")}, ${T}, ${ids.asa}, 'ASA', ${SEED.ojoduTerritoryId}, ${SEED.ojoduAreaId}, ${rep1Tu}, true, 'ACTIVE')
        on conflict (tenant_id, profile_id) do update set role = 'ASA', territory_id = excluded.territory_id,
                                                         area_id = excluded.area_id, reports_to_id = excluded.reports_to_id,
                                                         status = 'ACTIVE'`;
      await tx`update public.areas set asa_id = ${ids.asa} where id = ${SEED.ojoduAreaId}`;
      await tx`update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = ${ids.monveloOps}`;

      // the ZSA works the zone and reports to its ZSM (tenant_users_zsa_anchor)
      await tx`
        insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, reports_to_id, is_primary, status)
        values (${sid("tu:zsa")}, ${T}, ${ids.zsa}, 'ZSA', ${SEED.zoneId}, ${managerTu}, true, 'ACTIVE')
        on conflict (tenant_id, profile_id) do update set role = 'ZSA', zone_id = excluded.zone_id, territory_id = null,
                                                         area_id = null, reports_to_id = excluded.reports_to_id,
                                                         status = 'ACTIVE'`;

      // the shop owner owns the first Ojodu outlet (the owner reads it under retail_shops_select_network)
      await tx`update public.retail_shops set owner_id = ${ids.shopOwner} where id = ${SEED.ownedShopId}`;

      // an ACTIVE POS agent the ASA recruited and the operator approved (stands in for
      // monvelo-agent-register + approve_monvelo_agent), with the fintech agent as its staff.
      // The account number is a fixture: it never leaves the local stack.
      await tx`
        insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location,
                                           address_text, settlement_account_number, settlement_account_last4,
                                           settlement_bank_code, settlement_account_name, network_kyc_reference,
                                           recruited_by, status, approved_by, approved_at)
        values (${SEED.monveloAgentId}, 'Ojodu Liquidity Point (seed)', 'MONIEPOINT', ${SEED.monveloAgentNetworkId},
                '+2348000000908',
                extensions.st_setsrid(extensions.st_makepoint(${SEED.ojoduGps.lng}, ${SEED.ojoduGps.lat}), 4326)::extensions.geography,
                '2 Ojodu-Berger Road, Ojodu, Lagos', '9000000001', '0001', '058', 'OJODU LIQUIDITY POINT',
                'SEED-KYC-0001', ${ids.asa}, 'ACTIVE', ${ids.monveloOps}, now())
        on conflict (id) do update set status = 'ACTIVE', recruited_by = excluded.recruited_by,
                                       approved_by = excluded.approved_by`;
      await tx`
        insert into public.monvelo_agent_members (agent_id, profile_id, status)
        values (${SEED.monveloAgentId}, ${ids.fintechAgent}, 'ACTIVE')
        on conflict (agent_id, profile_id) do update set status = 'ACTIVE'`;

      // a second tenant with no members: nothing of it may reach a TEAFAIR rep
      const O = SEED.otherTenantId;
      await tx`insert into public.tenants (id, name, code) values (${O}, 'Lagos FMCG Distribution (seed)', 'LAGOSFMCG')
               on conflict (id) do nothing`;
      await tx`insert into public.tenant_settings (tenant_id) values (${O}) on conflict (tenant_id) do nothing`;
      await tx`insert into public.zones (id, tenant_id, zone_name, state_code)
               values (${SEED.otherZoneId}, ${O}, 'Ikeja', 'LA') on conflict (id) do nothing`;
      await tx`insert into public.territories (id, tenant_id, zone_id, territory_name)
               values (${SEED.otherTerritoryId}, ${O}, ${SEED.otherZoneId}, 'Ikeja Central') on conflict (id) do nothing`;
      await tx`insert into public.warehouses (id, tenant_id, name, kind, territory_id)
               values (${SEED.otherDepotId}, ${O}, 'Ikeja Central Depot', 'STOCKIST', ${SEED.otherTerritoryId})
               on conflict (id) do nothing`;
      for (const [n, s] of OTHER_SKUS.entries()) {
        await tx`
          insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                               nafdac_number, unit_price, wholesale_price, carton_units, is_active)
          values (${O}, ${s.code}, ${s.name}, ${s.brand}, ${s.category}, ${s.sale}, ${`SEED-B1-${6000 + n}`},
                  ${s.retail}, ${s.wholesale}, ${s.carton}, true)
          on conflict (tenant_id, sku_code) do nothing`;
        await tx`
          insert into public.inventory_batches (id, tenant_id, warehouse_id, sku_code, batch_number, quantity)
          values (${sid(`batch:${SEED.otherDepotId}:${s.code}`)}, ${O}, ${SEED.otherDepotId}, ${s.code},
                  ${`SEED-${s.code}-B1`}, 300)
          on conflict (warehouse_id, sku_code, batch_number) do nothing`;
      }

      // LAGOSFMCG members for cross-tenant tests: a TM and an ASA under them. LAGOSFMCG has no
      // monvelo_tenant_settings row, so it is not opted in and its ASA is refused by Monvelo.
      await tx`
        insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, is_primary, status)
        values (${sid("tu:lagos-tm")}, ${O}, ${ids.lagosTm}, 'TM', ${SEED.otherTerritoryId}, true, 'ACTIVE')
        on conflict (tenant_id, profile_id) do update set role = 'TM', territory_id = excluded.territory_id, status = 'ACTIVE'`;
      const lagosTmTu = (await tx<{ id: string }[]>`
        select id from public.tenant_users where tenant_id = ${O} and profile_id = ${ids.lagosTm}`)[0].id;
      await tx`insert into public.areas (id, tenant_id, territory_id, area_name)
               values (${SEED.otherAreaId}, ${O}, ${SEED.otherTerritoryId}, 'Allen') on conflict (id) do nothing`;
      await tx`
        insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, area_id, reports_to_id, is_primary, status)
        values (${sid("tu:lagos-asa")}, ${O}, ${ids.lagosAsa}, 'ASA', ${SEED.otherTerritoryId}, ${SEED.otherAreaId},
                ${lagosTmTu}, true, 'ACTIVE')
        on conflict (tenant_id, profile_id) do update set role = 'ASA', territory_id = excluded.territory_id,
                                                         area_id = excluded.area_id, reports_to_id = excluded.reports_to_id,
                                                         status = 'ACTIVE'`;

      // mark_order_dispatched checks the gateway proof against Vault; a db reset wipes Vault
      const [v] = await tx<{ id: string }[]>`select id from vault.secrets where name = 'gateway_secret'`;
      if (v) await tx`select vault.update_secret(${v.id}::uuid, ${gatewaySecret})`;
      else await tx`select vault.create_secret(${gatewaySecret}, 'gateway_secret')`;
    });

    // one PAID web order per territory, each with a buyer contact (A2: ZSM and the order's TM only)
    const o1 = await createPaidWebOrder(sql, {
      orderId: SEED.rep1OrderId, territoryId: SEED.ojoduTerritoryId, warehouseId: SEED.ojoduDepotId,
      teafairAgentId: ids.rep1, items: [{ sku: "SB-VEG-OIL-1L", qty: 6 }, { sku: "TFS-SUGAR-500G", qty: 10 }],
      contact: { name: "Kemi Adeyemi", phone: "+2348000000911", address: "14 Ojodu Road, Ojodu, Lagos" },
    });
    const o2 = await createPaidWebOrder(sql, {
      orderId: SEED.rep2OrderId, territoryId: SEED.omoleTerritoryId, warehouseId: SEED.omoleDepotId,
      teafairAgentId: ids.rep2, items: [{ sku: "GH-RICE-LG-5KG", qty: 2 }, { sku: "MD-EVAP-MILK-160G", qty: 24 }],
      contact: { name: "Chinedu Eze", phone: "+2348000000912", address: "3 Omole Phase 1, Lagos" },
    });

    const [c] = await sql<{ shops: number; skus: number; batches: number }[]>`
      select (select count(*)::int from public.tenant_shop_coverage where tenant_id = ${T}) as shops,
             (select count(*)::int from public.central_products where tenant_id = ${T} and sku_code in ${sql(SKUS.map((s) => s.code))}) as skus,
             (select count(*)::int from public.inventory_batches where warehouse_id in ${sql([SEED.ojoduDepotId, SEED.omoleDepotId])}) as batches`;
    console.log(`TEAFAIR: zone Lagos Mainland North, territories Ojodu-Berger and Omole-Agidingbi`);
    console.log(`outlets covered: ${c.shops}, seed SKUs: ${c.skus}, depot batches: ${c.batches}`);
    console.log(`paid orders: ${o1.publicReference} (Ojodu), ${o2.publicReference} (Omole)`);
    console.log("Monvelo: TEAFAIR opted in; ASA, ZSA, operator, shop owner, 1 ACTIVE POS agent with 1 staff member");
    console.log("second tenant LAGOSFMCG: 1 zone, 1 territory, 1 area, 1 depot, 2 SKUs, a TM and an ASA, Monvelo off");
    console.log("vault gateway_secret: set");
  } finally {
    await sql.end();
  }
}

function loadGatewaySecret(): string {
  const parsed: Record<string, string> = {};
  loadEnv({ path: path.join(SUPABASE_DIR, "functions", ".env"), processEnv: parsed, quiet: true });
  const s = parsed.GATEWAY_SECRET ?? process.env.GATEWAY_SECRET ?? "";
  if (!s) throw new Error("GATEWAY_SECRET is missing from supabase/functions/.env (it must equal the Vault gateway_secret)");
  return s;
}

if (typeof require !== "undefined" && require.main === module) {
  main().catch((e) => {
    // message only: a driver error's detail can echo a row
    console.error(`seed failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
