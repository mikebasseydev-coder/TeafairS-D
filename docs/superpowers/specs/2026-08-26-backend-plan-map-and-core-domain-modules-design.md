# Backend Plan Domain Map + Core Domain Feature Modules Design

Status: draft — pending review
Owner: Michael Bassey
Date: 2026-08-26

## 1. Goal

Two related pieces of follow-up work on top of the already-approved backend design
(`docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md`) and plan
(`docs/superpowers/plans/2026-08-25-backend-foundation.md`):

1. Make the 1886-line backend implementation plan navigable by frontend-feature domain,
   without disturbing its execution-critical task sequencing.
2. Replace the placeholder `core` feature modules that have real backend schema
   (`brands`, `products`, `catalog`, `orders`, `territories`, `aggregator`) with real
   Supabase-backed logic, following the pattern `auth` and `src/lib/profiles.ts` already
   establish.

Revised from the original round: Teafair's product catalogue, brand roster, and territory
coverage are all expected to keep growing, so this round also (a) gives `brands` real
schema — a growing multi-brand catalogue can't be modeled with `products` alone — and
(b) adds offset-based pagination to every list-fetch function, so a fixed `limit` doesn't
silently cap what a growing catalogue/territory list can return. See §2.1 and §3 pagination
note.

Out of scope: `alerts`, `gamification` stay structural placeholders — no table in any spec
defines them yet, and inventing schema for them wasn't approved as part of this round (see
§5).

## 2. Part A — `backend-foundation.md` domain map

### The constraint that shapes this

The plan's 11 tasks are strictly sequential migrations, not independent units — the plan's
own closing section says so explicitly ("each migration depends on the schema state the
previous task left behind"). Task 2 alone creates every table (territories, products,
orders, profiles, inventory, outlet visits, aggregation) in a single Prisma
schema/migration; Task 4 alters what Task 2 created; Task 7/8's RLS policies reference
columns Task 5 added; Task 11 concatenates Tasks 2–9's migration files in order. Reordering
or splitting the tasks by domain would change the actual migration sequence — a materially
bigger and riskier change than a documentation reorg, and not what was asked for.

### The approach

Leave every Task's content, order, and internal steps untouched. Add:

1. A new `## Schema-to-Frontend-Feature Map` section, inserted immediately after
   `## Global Constraints` (before `## Finalized feature/module list`). One `###`
   subheading per frontend feature module that has real schema:
   - `### Auth (profiles)`
   - `### Brands (brands)` — new, see §2.1
   - `### Products & Catalog (products)`
   - `### Orders (orders, order_lines)`
   - `### Territories (supervisors, sales_reps, routes, pickup_points, customers)`
   - `### Inventory (inventory_movements, current_inventory_balance)`
   - `### Outlet Visits (outlet_visits)`
   - `### Aggregator (aggregated_sales, run_sales_aggregator)`

   Each subheading gets: a one-line description of the table(s)/columns it owns, and a
   pointer to the exact Task number(s) and step(s) where it's defined (e.g. "Defined in
   Task 2 Step 3 (Prisma schema, `Product` model); no further raw SQL." / "Defined in
   Task 2 Step 3 (`InventoryMovement`/materialized view skeleton), integrity constraints
   in Task 4, RLS in Task 8's inventory_movements block, indexes: none added directly —
   FK columns already covered by the pool-scoped partial unique indexes.").

2. `####` sub-labels inside the three tasks whose content already spans multiple domains,
   so each domain's slice is independently jump-to-able without moving it:
   - Task 8 (RLS on `inventory_movements`, `outlet_visits`, `aggregated_sales`) — three
     `####` labels, one per table, above each table's `ALTER TABLE ... ENABLE ROW LEVEL
     SECURITY` + policy block.
   - Task 9 (performance indexes) — three `####` labels (orders, outlet_visits,
     aggregated_sales) above the relevant `CREATE INDEX` lines.
   - Task 10 (seed script) — inline comments already exist per entity in the seed script;
     add `####` labels in the surrounding prose (not inside the `js` code block) grouping
     "reference/territory data," "products," "orders," "inventory," "profiles."

No content beyond the new sections above is deleted, rewritten, or reordered.

### 2.1 New: Task 12 — `brands` table

The one substantive schema addition in this round. Appended as a new task *after* Task 11
— it's a new leaf migration (a table nothing else yet depends on), not a change to any
existing task, so it doesn't disturb the sequential dependency chain described above.

```sql
CREATE TABLE brands (
    brand_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    brand_name VARCHAR(150) NOT NULL UNIQUE,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE products ADD COLUMN brand_id UUID REFERENCES brands(brand_id);
CREATE INDEX idx_products_brand_id ON products(brand_id);
```

`brand_id` is nullable on `products` — existing/seed products aren't forced to have a brand
assigned immediately, matching how every other optional FK in this schema (e.g.
`orders.customer_id`) is modeled. Follows the same verification-script-first format as
Tasks 1–11 (a `verify-task12.mjs` proving the FK and index exist) when this becomes an
actual plan edit — full step-by-step is written during Part A implementation, not here.

No RLS is added on `brands` — it's reference data every authenticated role (and the public
catalogue) can read; same treatment as `products` itself, which also has no RLS policy in
this plan.

## 3. Part B — Core domain feature modules

Every new function takes an injected `SupabaseClient` as its first argument (never a
module-level singleton), unwraps results through the existing
`src/lib/unwrapSupabaseResult.ts` helper, and lives alongside the existing placeholder
`store.ts` in each feature directory — replacing, not supplementing, the current
`create<Feature>ApiClient(baseUrl)` stub and empty Zustand store. Each module gets its own
`api.test.ts` and `store.test.ts` (mirroring `auth`'s), and is removed from the shared
placeholder loop in `features.test.ts` (which keeps only `alerts`, `gamification`).

None of these functions call `setXStore` internally — same convention as `auth`: `core`
exposes the fetch/mutate function and the store's setter, and the calling app (`mobile`,
later `web`) decides when to wire one to the other.

**Pagination convention:** every list-fetch function below takes `limit = 100` *and*
`offset = 0`, implemented via Supabase's `.range(offset, offset + limit - 1)`. A flat
`limit` with no way to page past it would silently truncate results once the catalogue,
brand roster, or territory list grows past 100 rows — offset pagination is the minimum
needed to keep working as those grow, without building out full keyset/cursor pagination
that nothing has asked for yet.

### 3.1 `brands`

```ts
export interface Brand {
  brandId: string;
  brandName: string;
  isActive: boolean;
}

fetchBrands(client: SupabaseClient, limit = 100, offset = 0): Promise<Brand[]>
```

Queries `brands`, selecting `brand_id, brand_name, is_active`. No mutation function in this
round (creating/editing brands is an HQ-admin operation, presumably via the future `web`
target — not needed by `mobile` or the public catalogue yet).

Store: `{ brands: Brand[]; setBrands(brands: Brand[]): void; clear(): void }`.

### 3.2 `products`

```ts
export interface Product {
  productId: string;
  skuCode: string;
  productName: string;
  category: string | null;
  brandId: string | null;
  basePrice: number;
  wholesalePrice: number;
}

fetchProducts(client: SupabaseClient, limit = 100, offset = 0): Promise<Product[]>
```

Queries `products`, selecting `product_id, sku_code, product_name, category, brand_id,
base_price, wholesale_price`. This is the authenticated/internal view (includes wholesale
price) — distinct from `catalog` below.

Store: `{ products: Product[]; setProducts(products: Product[]): void; clear(): void }`.

### 3.3 `catalog`

```ts
export interface CatalogItem {
  productId: string;
  skuCode: string;
  productName: string;
  category: string | null;
  brandId: string | null;
  basePrice: number;
}

fetchCatalog(client: SupabaseClient, limit = 100, offset = 0): Promise<CatalogItem[]>
```

Same `products` table, but the selected columns omit `wholesale_price` (business-sensitive,
not for public/customer eyes) — matches the backend spec's "catalogue browsing itself stays
public/unauthenticated." `brandId` is included so a public storefront can filter/group by
brand as the roster grows. `fetchCatalog` is meant to be called with an anon/unauthenticated
client; nothing in `core` enforces that distinction, same as `auth` doesn't enforce which
client callers pass.

Store: `{ items: CatalogItem[]; setItems(items: CatalogItem[]): void; clear(): void }`.

### 3.4 `territories`

```ts
export interface Territory {
  routeId: string;
  routeName: string;
  territoryZone: string;
  assignedSupervisorId: string | null;
  assignedRepId: string | null;
}

fetchTerritories(client: SupabaseClient, limit = 100, offset = 0): Promise<Territory[]>
```

Queries `routes` (the table backing "territory" in every spec — `territory_zone` is a
column on `routes`, there is no separate `territories` table). RLS on `routes` isn't
defined in the backend plan yet, so this reads whatever the caller's role is permitted to
see once RLS ships; no client-side filtering is added here.

Store: `{ territories: Territory[]; setTerritories(territories: Territory[]): void; clear(): void }`.

### 3.5 `orders`

```ts
export interface OrderLine {
  productId: string;
  qtySold: number;
  unitPrice: number;
}

export interface Order {
  orderId: string;
  saleType: string;
  orderStatus: string;
  paymentStatus: string;
  customerId: string | null;
  repId: string | null;
  supervisorId: string | null;
  routeId: string | null;
  pickupPointId: string | null;
  totalAmount: number;
  amountPaid: number;
  orderDate: string;
}

fetchOrders(client: SupabaseClient, limit = 100, offset = 0): Promise<Order[]>

createOrder(
  client: SupabaseClient,
  input: {
    saleType: string;
    customerId?: string;
    repId?: string;
    supervisorId?: string;
    routeId?: string;
    pickupPointId?: string;
    lines: OrderLine[];
  }
): Promise<Order>
```

`fetchOrders` relies entirely on RLS to scope results to the caller (Task 7's five-role
policy pattern) — no client-side role branching. `createOrder` computes `totalAmount` as
`sum(qty_sold * unit_price)` over `lines`, inserts the `orders` row, then inserts the
`order_lines` rows referencing the returned `order_id` (two sequential Supabase calls — the
generated `total_line_amount` column is server-computed per line, not passed in).

Store: `{ orders: Order[]; setOrders(orders: Order[]): void; addOrder(order: Order): void; clear(): void }`.

### 3.6 `aggregator`

```ts
export interface AggregatedSales {
  aggregationId: string;
  summaryDate: string;
  saleType: string;
  supervisorId: string | null;
  routeId: string | null;
  repId: string | null;
  totalOrdersCount: number;
  grossRevenue: number;
  cashCollected: number;
  computedAt: string;
}

fetchAggregatedSales(
  client: SupabaseClient,
  filters?: { summaryDate?: string },
  limit = 100,
  offset = 0
): Promise<AggregatedSales[]>

runSalesAggregator(client: SupabaseClient, targetDate: string): Promise<void>
```

`fetchAggregatedSales` reads the `aggregated_sales` cache table (optionally filtered by
`summary_date`), never recomputing from `orders` — matches the backend design's
"aggregator reads never recompute live" principle. `runSalesAggregator` calls the
`run_sales_aggregator` Postgres RPC via `client.rpc('run_sales_aggregator', { target_date:
targetDate })`; privilege enforcement (`hq_admin`/`supervisor` only) happens server-side
inside the function per the backend design, so this wrapper does no role checking of its
own — it just surfaces the RPC's error (e.g. "insufficient privilege...") through
`unwrapSupabaseResult`/a thrown `Error`, same as every other Supabase call in `core`.

Store: `{ aggregatedSales: AggregatedSales[]; setAggregatedSales(sales: AggregatedSales[]): void; clear(): void }`.

## 4. Testing

Each of the 6 modules (`brands`, `products`, `catalog`, `orders`, `territories`,
`aggregator`) gets:
- `api.test.ts` — mocks `SupabaseClient.from(...).select(...)`/`.insert(...)`/`.rpc(...)`
  chains the same way `auth/api.test.ts` mocks `client.auth.*`, asserting both the
  success path (correct table/columns queried, result shape) and the thrown-error path
  when Supabase returns `{ error }`.
- `store.test.ts` — asserts initial state, each setter, and `clear()`, mirroring
  `auth/store.test.ts`.

`features.test.ts`'s shared `describe.each` loop drops all 6 and keeps only `alerts`,
`gamification`.

## 5. Explicitly out of scope

- `alerts`, `gamification` — no backend schema exists anywhere in the specs; left as
  placeholders. Designing schema for these is a separate future round.
- Any change to `backend/`, `supabase/`, or an actual running Postgres database — Part A
  and Task 12 (§2.1) only change plan/spec *documents*; no migration is generated or
  applied against any database as part of this round. Task 12 becomes a real migration
  only when Part A's plan edit is later executed via `subagent-driven-development`/
  `executing-plans`, same as Tasks 1–11 already are.
- RLS/CHECK constraints on `routes` (territories) or `brands` — not defined in the existing
  backend plan; `fetchTerritories`/`fetchBrands` are written against the tables as
  currently specified (open reference data, no row-level restriction).
- Route Profitability fields (commission/fuel cost) — still flagged not-yet-modeled in the
  backend spec §4.5; not touched here.

## 6. Open follow-ups

- Whether `routes`/`brands` need their own RLS policies (currently unspecified —
  `fetchTerritories`/`fetchBrands` will return whatever the underlying table's default
  access allows until that's decided).
- Whether `brands` needs its own admin-facing create/update functions in `core` once `web`
  (HQ admin surface) exists — deferred; this round only adds the read path every consumer
  needs first.
- Whether `createOrder`'s two-sequential-insert approach (orders row, then order_lines)
  needs to become a single RPC for atomicity — flagged here, not solved; the mobile
  offline-sync layer (a separate future plan per the backend plan's "Frontend (future
  plans)" list) may supersede this anyway with a `place_confirmed_order` RPC.
