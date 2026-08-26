# Backend + Aggregator Platform Design

Status: draft, pending review
Owner: Michael Bassey
Date: 2026-08-25

## 1. Goal

Move Teafair from "backend undecided" to a real backend, built around Supabase as
the production source of truth, and stand up the "HQ Aggregation platform"
(Route-to-Market omni-channel sales aggregation) as a first-class feature spanning
a new web target and the already-planned Windows target.

## 2. Frontend targets

```
frontend/
  core/    existing — logic only, zero platform imports
  ui/      NEW — RN + NativeWind components (Button, InputField, aggregator screens),
           consumed by mobile, web, and (later) windows
  mobile/  existing — Expo/Android, field-rep data capture (orders, van stock, visits)
  web/     NEW — Next.js + react-native-web, HQ Aggregation platform's primary UI
  windows/ still planned, not yet scaffolded — will also consume ui once built
```

`ui` is extracted now (not deferred) because `web` needs shared components from day
one — building `web`-only copies of `Button`/`InputField` would immediately diverge
from `mobile`.

## 3. Backend / schema tooling layout

```
backend/            NEW — local schema dev sandbox
  prisma/schema.prisma
  docker-compose.yml   (local throwaway Postgres, for fast iteration)
  package.json
  CLAUDE.md          (new, backend-specific)

supabase/            NEW — Supabase CLI project (migrations, config.toml)
  migrations/
  config.toml
```

Workflow: iterate schema against local Dockerized Postgres via Prisma (`prisma
migrate dev`) → once validated, generate SQL (`prisma migrate diff --script`) →
land it in `supabase/migrations/` → apply to the hosted Supabase project via
Supabase CLI/MCP `apply_migration`. Supabase remains the source of truth in
production; Prisma+Docker exist purely for fast, disposable local iteration.

Not every construct in the schema below is Prisma-representable — generated
columns (`GENERATED ALWAYS AS ... STORED`) aren't expressible in Prisma's schema
language as of the pinned CLI version, so `order_lines.total_line_amount` needs a
raw SQL migration layered on top of what Prisma generates, tracked directly in
`supabase/migrations/`.

## 4. Data model

Base schema per the pasted RTM design, with the corrections/additions below.
Unlisted tables (`routes`, `pickup_points`, `products`, `orders`, `order_lines`)
are adopted as pasted.

### 4.1 RBAC — centralized `profiles` table

Rather than each entity table (`customers`, `sales_reps`, `supervisors`) carrying
its own Supabase-Auth link independently, a single table centralizes it so a JWT
resolves to a role in one place:

```sql
CREATE TYPE user_role_enum AS ENUM ('rep', 'supervisor', 'customer', 'admin');

CREATE TABLE profiles (
    profile_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    auth_user_id UUID UNIQUE NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role user_role_enum NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

`sales_reps`, `supervisors`, and `customers` each replace any direct
`supabase_auth_id` column with `profile_id UUID UNIQUE REFERENCES profiles(profile_id)`.
RLS policies and app-side RBAC resolve `auth.uid()` → `profiles.role` once, instead
of checking three tables inconsistently.

### 4.2 Inventory — movement ledger, not balance snapshot

`inventory_ledger` (as pasted) stores only a current `qty_on_hand` per pool, which
can't reconstruct `Starting + Received − Sold − Returned` for the variance
formula. Replaced with an append-only event log; current balance is derived by
summing:

```sql
CREATE TYPE inventory_movement_enum AS ENUM ('Received', 'Sold', 'Returned', 'Physical_Count', 'Transfer');

CREATE TABLE inventory_movements (
    movement_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pool_type inventory_pool_enum NOT NULL,
    supervisor_id UUID REFERENCES supervisors(supervisor_id),
    pickup_point_id UUID REFERENCES pickup_points(pickup_point_id),
    rep_id UUID REFERENCES sales_reps(rep_id),
    product_id UUID NOT NULL REFERENCES products(product_id),
    movement_type inventory_movement_enum NOT NULL,
    qty_delta INT NOT NULL,           -- positive for Received/Physical_Count-up, negative for Sold/Returned-out
    reference_order_id UUID REFERENCES orders(order_id),  -- set when movement_type = 'Sold'
    occurred_at TIMESTAMPTZ DEFAULT NOW(),
    recorded_by_profile_id UUID REFERENCES profiles(profile_id)
);

-- Partial unique indexes per pool_type, replacing the single combined UNIQUE
-- constraint (which didn't enforce, since NULL != NULL across pool types).
CREATE UNIQUE INDEX uniq_movement_van_stock
    ON inventory_movements (rep_id, product_id, occurred_at)
    WHERE pool_type = 'Van_Stock';
CREATE UNIQUE INDEX uniq_movement_pickup_point
    ON inventory_movements (pickup_point_id, product_id, occurred_at)
    WHERE pool_type = 'Pickup_Point';
CREATE UNIQUE INDEX uniq_movement_supervisor_hub
    ON inventory_movements (supervisor_id, product_id, occurred_at)
    WHERE pool_type = 'Supervisor_Hub';
```

Current balance for any pool = `SUM(qty_delta)` filtered to that pool's identity
columns — exposed as a view (`current_inventory_balance`) rather than a stored
column, so it's always derived from the ledger.

### 4.3 Outlet visits

Needed for Strike Rate's "productive outlets visited" numerator, which is
distinct from "outlets that generated an order":

```sql
CREATE TABLE outlet_visits (
    visit_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL REFERENCES customers(customer_id),
    rep_id UUID NOT NULL REFERENCES sales_reps(rep_id),
    route_id UUID NOT NULL REFERENCES routes(route_id),
    visited_at TIMESTAMPTZ DEFAULT NOW(),
    is_productive BOOLEAN NOT NULL DEFAULT FALSE,   -- true if visit resulted in an order
    order_id UUID REFERENCES orders(order_id)
);
```

Mobile writes a row on every outlet visit; `is_productive` flips true (and
`order_id` populates) if the visit results in an order.

### 4.4 Aggregation cache

`aggregated_sales` adopted as pasted — it's the target table for the
`run_sales_aggregator`-style Postgres function convention, called at end-of-day
by the Windows/Web Aggregator (or scheduled via `pg_cron`).

### 4.5 Not yet modeled (flagged, not blocking)

Route Profitability (`Total Sales Value − (Rep Commission + Delivery Fuel Cost)`)
has no supporting schema yet — no commission-rate structure or fuel-cost capture
exists in the pasted design. Left out of this round; needs its own follow-up
(flat-rate config table vs. per-order commission field, and where fuel cost gets
entered — per route/day, presumably by supervisors).

## 5. Metrics (as given)

- Strike Rate: `(Productive Outlets Visited ÷ Total Outlets on Route) × 100` — from `outlet_visits` + `customers.route_id`
- Drop Size: `Total Revenue Collected ÷ Number of Invoiced Deliveries` — from `orders`/`order_lines`
- Inventory Variance: `(Starting + Received) − (Sold + Returned)` vs. physical count — from `inventory_movements`
- Route Profitability: `Total Sales Value − (Rep Commission + Delivery Fuel Cost)` — blocked on 4.5

## 6. Two sale-flow dynamics

- **Pre-sale / Structured Routing**: rep visits a known `customer_id` on an assigned `route_id`, captures an order, stock isn't handed over yet. Windows/Web Aggregator compiles the day's pre-orders by route+SKU into a picking list and dispatch manifest.
- **Street Campaign (Van Sales)**: rep sells on-the-spot from carried stock; order's `customer_id` may be null for undocumented shops; an `inventory_movements` row (`Sold`, `Van_Stock`) decrements the rep's van stock immediately. Windows/Web Aggregator reconciles end-of-day: electronic sales captured vs. physical stock the rep returns (a `Physical_Count` movement).

Both flows share the same `orders`/`order_lines` tables, distinguished by `sale_type`.

## 7. CLAUDE.md scope for this round

- Root `CLAUDE.md`: replace "backend undecided, no NestJS/Prisma/Docker" language with this architecture; add `ui`/`web`/`backend`/`supabase` to the layout description (flagged planned-but-not-yet-scaffolded where true, matching the existing convention for `windows`).
- New `backend/CLAUDE.md`: documents the Prisma/Docker local-dev → Supabase-migration workflow.

## 8. Open follow-ups

- Route Profitability's commission/fuel-cost data model (§4.5)
- RLS policy design per role (`rep`/`supervisor`/`customer`/`admin`) — not detailed here, follows from §4.1
- Whether `web` uses Next.js App Router or Pages Router — implementation detail, not architecture
