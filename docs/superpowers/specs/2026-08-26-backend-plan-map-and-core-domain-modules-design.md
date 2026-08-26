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
2. Replace every placeholder `core` feature module — `brands`, `products`, `catalog`,
   `orders`, `territories`, `aggregator`, `alerts`, `gamification` — with real
   Supabase-backed logic, following the pattern `auth` and `src/lib/profiles.ts` already
   establish. After this round, `core` has no remaining structural placeholder modules
   (see §6 for the `features.test.ts` implication of that).

Revised twice from the original round:
- Teafair's product catalogue, brand roster, and territory coverage are all expected to
  keep growing, so `brands` gets real schema (a growing multi-brand catalogue can't be
  modeled with `products` alone), and every list-fetch function gets offset-based
  pagination so a fixed `limit` doesn't silently cap what a growing list can return (§2.1,
  §3 pagination note).
- `alerts` and `gamification` also get real schema: alerts covering stock expiry, product
  recalls, inventory deficits, top-territory recognition, and daily sales digests;
  gamification covering a scored/ranked index per sales rep, supervisor, and customer,
  plus an achievement/badge catalog (§2.2, §2.3).

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
   - `### Alerts (alerts, product_recalls)` — new, see §2.2
   - `### Gamification (gamification_scores, achievements, actor_achievements)` — new, see §2.3

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

### 2.2 New: Task 13 — `alerts` schema

Appended after Task 12. One generic `alerts` table with an `alert_type` enum, rather than a
table per type — this matches how the existing schema already handles variants
(`movement_type`, `sale_type`, `pool_type`), and lets every alert type share one RLS
policy set instead of five.

```sql
CREATE TYPE alert_type_enum AS ENUM (
    'stock_expiry', 'product_recall', 'inventory_deficit', 'top_territory', 'daily_sales_summary'
);
CREATE TYPE alert_severity_enum AS ENUM ('info', 'warning', 'critical');

CREATE TABLE alerts (
    alert_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_type   alert_type_enum NOT NULL,
    severity     alert_severity_enum NOT NULL DEFAULT 'info',
    title        VARCHAR(150) NOT NULL,
    message      TEXT NOT NULL,

    -- Targeting: same one-of-four-or-company-wide pattern as inventory_movements/profiles.
    -- All four NULL means company-wide (e.g. top_territory, daily_sales_summary for hq_admin).
    supervisor_id   UUID REFERENCES supervisors(supervisor_id),
    rep_id          UUID REFERENCES sales_reps(rep_id),
    pickup_point_id UUID REFERENCES pickup_points(pickup_point_id),
    customer_id     UUID REFERENCES customers(customer_id),

    -- Populated depending on alert_type (e.g. product_id for stock_expiry/product_recall,
    -- route_id for top_territory).
    product_id UUID REFERENCES products(product_id),
    route_id   UUID REFERENCES routes(route_id),

    created_at             TIMESTAMPTZ DEFAULT NOW(),
    acknowledged_at        TIMESTAMPTZ,
    acknowledged_by_profile_id UUID REFERENCES profiles(profile_id),

    CONSTRAINT chk_alert_single_target CHECK (
        (supervisor_id IS NOT NULL)::int + (rep_id IS NOT NULL)::int
        + (pickup_point_id IS NOT NULL)::int + (customer_id IS NOT NULL)::int <= 1
    )
);

CREATE TABLE product_recalls (
    recall_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id    UUID NOT NULL REFERENCES products(product_id),
    reason        TEXT NOT NULL,
    recalled_by_profile_id UUID REFERENCES profiles(profile_id),
    recalled_at   TIMESTAMPTZ DEFAULT NOW()
);
```

Two upstream additions this depends on:
- `inventory_movements.best_before_date` (nullable `DATE`, meaningful only on `'Received'`
  rows) — no new batch-tracking subsystem; just tags received stock with an expiry so a
  scheduled scan can find pools holding stock nearing it.
- Nothing else — `product_recall` fans out from `current_inventory_balance` (already
  exists per backend spec §4.2), `top_territory`/`daily_sales_summary` read from
  `aggregated_sales` (already exists).

Generation, mirroring `run_sales_aggregator`'s function+`pg_cron` shape:
- `generate_stock_expiry_alerts()`, `generate_daily_sales_summary_alerts()`,
  `generate_top_territory_alert()` — scheduled functions, `pg_cron`-triggered.
- `trigger_product_recall(product_id, reason)` — `hq_admin`-only (same
  `SECURITY DEFINER` + role-check + pinned `search_path` pattern as
  `run_sales_aggregator`), inserts one `product_recalls` audit row plus one `alerts` row
  per pool currently holding that product.

RLS on `alerts`: `hq_admin` sees all; `supervisor` sees rows targeted at them, their reps,
their pickup points, or company-wide; `sales_rep`/`pickup_agent`/`customer` see their own
targeted rows plus company-wide — same shape as the `inventory_movements` policy set in
Task 8, just with `alerts`' four target columns instead of three.

### 2.3 New: Task 14 — `gamification` schema

Appended after Task 13. A scoring layer on top of data the backend already computes —
no new raw data collection, just a precomputed, ranked cache (same "don't recompute on
read" philosophy as `aggregated_sales`).

```sql
CREATE TYPE gamification_actor_type_enum AS ENUM ('sales_rep', 'supervisor', 'customer');

CREATE TABLE gamification_scores (
    score_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_type    gamification_actor_type_enum NOT NULL,
    rep_id        UUID REFERENCES sales_reps(rep_id),
    supervisor_id UUID REFERENCES supervisors(supervisor_id),
    customer_id   UUID REFERENCES customers(customer_id),
    period_start  DATE NOT NULL,
    period_end    DATE NOT NULL,
    points        INT NOT NULL DEFAULT 0,
    rank_in_period INT,
    computed_at   TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT chk_gamification_actor_targeting CHECK (
        (actor_type = 'sales_rep'  AND rep_id IS NOT NULL        AND supervisor_id IS NULL AND customer_id IS NULL)
        OR (actor_type = 'supervisor' AND supervisor_id IS NOT NULL AND rep_id IS NULL      AND customer_id IS NULL)
        OR (actor_type = 'customer'   AND customer_id IS NOT NULL   AND rep_id IS NULL      AND supervisor_id IS NULL)
    )
);

CREATE TABLE achievements (
    achievement_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code           VARCHAR(50) NOT NULL UNIQUE,   -- e.g. 'TOP_REP_MONTH', 'ZERO_VARIANCE_WEEK'
    title          VARCHAR(150) NOT NULL,
    description    TEXT
);

CREATE TABLE actor_achievements (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    achievement_id UUID NOT NULL REFERENCES achievements(achievement_id),
    actor_type     gamification_actor_type_enum NOT NULL,
    rep_id         UUID REFERENCES sales_reps(rep_id),
    supervisor_id  UUID REFERENCES supervisors(supervisor_id),
    customer_id    UUID REFERENCES customers(customer_id),
    earned_at      TIMESTAMPTZ DEFAULT NOW(),
    period_start   DATE,
    period_end     DATE,

    CONSTRAINT chk_actor_achievement_targeting CHECK (
        (actor_type = 'sales_rep'  AND rep_id IS NOT NULL        AND supervisor_id IS NULL AND customer_id IS NULL)
        OR (actor_type = 'supervisor' AND supervisor_id IS NOT NULL AND rep_id IS NULL      AND customer_id IS NULL)
        OR (actor_type = 'customer'   AND customer_id IS NOT NULL   AND rep_id IS NULL      AND supervisor_id IS NULL)
    )
);
```

`run_gamification_scoring(period_start, period_end)` — same `SECURITY DEFINER` +
`hq_admin`/`supervisor`-only guard + pinned `search_path` shape as `run_sales_aggregator` —
computes and upserts `gamification_scores` per actor:

- **Sales rep points** = `(gross_revenue / 1000) + (strike_rate × 2) + (10 if zero
  inventory variance that period else 0)` — reads `aggregated_sales` for revenue,
  `outlet_visits`/`customers.route_id` for Strike Rate, `current_inventory_balance`
  reconciliation for the variance bonus. Weighted this way deliberately: a rep who
  oversells and can't account for stock shouldn't outrank one who sells less but
  reconciles cleanly — this is what actually protects margin, not just top-line revenue.
- **Supervisor points** = sum of their team's rep points for the period — rewards coaching
  a team up, not just personally selling.
- **Customer points** = a function of order frequency + total spend + on-time payment rate
  (from `orders.payment_status`) — turns repeat/reliable-paying shops into something
  visibly rewarded, which is the actual retention lever for a route-based wholesale
  business.
- `rank_in_period` is a `RANK() OVER (PARTITION BY actor_type, period_start, period_end
  ORDER BY points DESC)` computed in the same statement.

RLS on `gamification_scores`/`actor_achievements`: `hq_admin` sees all; `supervisor` sees
their own row plus their team's rep rows; `sales_rep`/`customer` see only their own row —
same shape as `aggregated_sales`' policy set in Task 8. `achievements` (the small catalog
table) is public-read, like `products`/`brands`.

## 3. Part B — Core domain feature modules

Every new function takes an injected `SupabaseClient` as its first argument (never a
module-level singleton), unwraps results through the existing
`src/lib/unwrapSupabaseResult.ts` helper, and lives alongside the existing placeholder
`store.ts` in each feature directory — replacing, not supplementing, the current
`create<Feature>ApiClient(baseUrl)` stub and empty Zustand store. Each module gets its own
`api.test.ts` and `store.test.ts` (mirroring `auth`'s), and is removed from the shared
placeholder loop in `features.test.ts`. All 8 non-`auth` modules get real logic this round,
so that shared loop's `features` array ends up empty — see §6 for what to do about that.

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

### 3.7 `alerts`

```ts
export interface Alert {
  alertId: string;
  alertType: 'stock_expiry' | 'product_recall' | 'inventory_deficit' | 'top_territory' | 'daily_sales_summary';
  severity: 'info' | 'warning' | 'critical';
  title: string;
  message: string;
  supervisorId: string | null;
  repId: string | null;
  pickupPointId: string | null;
  customerId: string | null;
  productId: string | null;
  routeId: string | null;
  createdAt: string;
  acknowledgedAt: string | null;
}

fetchAlerts(client: SupabaseClient, limit = 100, offset = 0): Promise<Alert[]>

acknowledgeAlert(client: SupabaseClient, alertId: string): Promise<void>
```

`fetchAlerts` relies on RLS to scope results to the caller (§2.2's policy set), ordered
newest-first. `acknowledgeAlert` updates `acknowledged_at`/`acknowledged_by_profile_id` on
the given row via the caller's own `profiles.profile_id` (resolved server-side from
`auth.uid()`, not passed by the client).

Store: `{ alerts: Alert[]; setAlerts(alerts: Alert[]): void; markAcknowledged(alertId: string): void; clear(): void }`
— `markAcknowledged` updates local state after a successful `acknowledgeAlert` call, same
division of responsibility as `auth`'s `setSession` (the fetch/mutate function never
touches the store itself).

### 3.8 `gamification`

```ts
export interface GamificationScore {
  scoreId: string;
  actorType: 'sales_rep' | 'supervisor' | 'customer';
  repId: string | null;
  supervisorId: string | null;
  customerId: string | null;
  periodStart: string;
  periodEnd: string;
  points: number;
  rankInPeriod: number | null;
}

export interface Achievement {
  achievementId: string;
  code: string;
  title: string;
  description: string | null;
}

export interface ActorAchievement {
  id: string;
  achievementId: string;
  actorType: 'sales_rep' | 'supervisor' | 'customer';
  repId: string | null;
  supervisorId: string | null;
  customerId: string | null;
  earnedAt: string;
}

fetchGamificationScores(
  client: SupabaseClient,
  filters?: { actorType?: string; periodStart?: string; periodEnd?: string },
  limit = 100,
  offset = 0
): Promise<GamificationScore[]>

fetchAchievements(client: SupabaseClient): Promise<Achievement[]>

fetchActorAchievements(client: SupabaseClient, limit = 100, offset = 0): Promise<ActorAchievement[]>
```

`fetchGamificationScores` reads the precomputed `gamification_scores` cache (never
recomputing from `aggregated_sales`/`outlet_visits` live), optionally filtered by actor
type or period. `fetchAchievements` reads the small public `achievements` catalog table —
no pagination params, it's not expected to grow past a page. `fetchActorAchievements`
relies on RLS to scope to the caller.

Store: `{ scores: GamificationScore[]; achievements: Achievement[]; actorAchievements: ActorAchievement[]; setScores(scores): void; setAchievements(achievements): void; setActorAchievements(actorAchievements): void; clear(): void }`.

## 4. Testing

Each of the 8 modules (`brands`, `products`, `catalog`, `orders`, `territories`,
`aggregator`, `alerts`, `gamification`) gets:
- `api.test.ts` — mocks `SupabaseClient.from(...).select(...)`/`.insert(...)`/`.rpc(...)`
  chains the same way `auth/api.test.ts` mocks `client.auth.*`, asserting both the
  success path (correct table/columns queried, result shape) and the thrown-error path
  when Supabase returns `{ error }`.
- `store.test.ts` — asserts initial state, each setter, and `clear()`, mirroring
  `auth/store.test.ts`.

`features.test.ts`'s shared `describe.each` loop drops all 8, leaving its `features` array
empty — see §6.

## 5. Explicitly out of scope

- Any change to `backend/`, `supabase/`, or an actual running Postgres database — Part A
  and Tasks 12–14 (§2.1–2.3) only change plan/spec *documents*; no migration is generated
  or applied against any database as part of this round. They become real migrations only
  when Part A's plan edit is later executed via `subagent-driven-development`/
  `executing-plans`, same as Tasks 1–11 already are.
- RLS/CHECK constraints on `routes` (territories) or `brands` — not defined in the existing
  backend plan; `fetchTerritories`/`fetchBrands` are written against the tables as
  currently specified (open reference data, no row-level restriction). `alerts` and
  `gamification_scores` do get RLS, specified in §2.2/§2.3.
- Route Profitability fields (commission/fuel cost) — still flagged not-yet-modeled in the
  backend spec §4.5; not touched here.
- Any UI for alerts/leaderboards/badges — this round is schema + `core` data-access
  functions only; screens are a `mobile`/future-`web` concern, not covered here.
- Backfilling `best_before_date` on existing/seeded `inventory_movements` rows, or defining
  per-product default shelf life — Task 13 adds the column; populating it (manually per
  receipt, or a `products.default_shelf_life_days` convenience column) is left for
  implementation time, not decided here.

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
- `features.test.ts`'s shared placeholder loop has zero entries after this round (every
  non-`auth` module now has dedicated tests). The file/mechanism should stay in place
  as-is (empty `describe.each([])` is valid, not a failure) for whatever placeholder module
  gets scaffolded next, rather than being deleted — but this is worth flagging explicitly
  during implementation so it doesn't read as an oversight.
- `CLAUDE.md`'s `core` section currently says "Except for auth, every module is still a
  structural placeholder" — that sentence becomes false once this round ships and needs
  updating as part of implementation, not this spec.
- Whether `product_recalls` needs its own `fetchProductRecalls` read function in `core` for
  an HQ audit view, or whether the fan-out `alerts` rows are sufficient — deferred, no
  consumer needs it yet.
