# Backend + Aggregator Platform Design

Status: approved (with mandated modifications: strict CHECK constraints on inventory movement targeting, materialized view for current inventory balance — both applied below)
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

A single table centralizes the Supabase-Auth link, role, and the pointer to
whichever business entity that user is — one direction only (profile →
entity), so no reverse FK can drift out of sync with it:

```sql
CREATE TYPE user_role_enum AS ENUM ('hq_admin', 'supervisor', 'sales_rep', 'pickup_agent', 'customer');

CREATE TABLE profiles (
    profile_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email VARCHAR(100),   -- nullable: customer profiles authenticate by phone, not email
    role user_role_enum NOT NULL,
    associated_supervisor_id UUID REFERENCES supervisors(supervisor_id) ON DELETE SET NULL,
    associated_rep_id UUID REFERENCES sales_reps(rep_id) ON DELETE SET NULL,
    associated_pickup_point_id UUID REFERENCES pickup_points(pickup_point_id) ON DELETE SET NULL,
    associated_customer_id UUID REFERENCES customers(customer_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Exactly the association matching role may be set, the other three must
    -- be NULL — same pool-targeting pattern as inventory_movements' CHECK.
    CONSTRAINT chk_profile_role_targeting CHECK (
        (role = 'hq_admin'     AND associated_supervisor_id IS NULL     AND associated_rep_id IS NULL     AND associated_pickup_point_id IS NULL AND associated_customer_id IS NULL)
        OR (role = 'supervisor'   AND associated_supervisor_id IS NOT NULL AND associated_rep_id IS NULL     AND associated_pickup_point_id IS NULL AND associated_customer_id IS NULL)
        OR (role = 'sales_rep'    AND associated_rep_id IS NOT NULL     AND associated_supervisor_id IS NULL  AND associated_pickup_point_id IS NULL AND associated_customer_id IS NULL)
        OR (role = 'pickup_agent' AND associated_pickup_point_id IS NOT NULL AND associated_supervisor_id IS NULL AND associated_rep_id IS NULL     AND associated_customer_id IS NULL)
        OR (role = 'customer'     AND associated_customer_id IS NOT NULL AND associated_supervisor_id IS NULL  AND associated_rep_id IS NULL     AND associated_pickup_point_id IS NULL)
    )
);
```

`profile_id` **is** `auth.users.id` — no separate generated UUID, since a
profile is always exactly 1:1 with an auth user. This replaces the earlier
`pickup_point_operators` join table and the `profile_id` columns on
`sales_reps`/`supervisors`/`customers`: the pointer lives only on `profiles`,
so an RLS policy resolves `auth.uid()` to a scope in one row lookup instead of
a join.

**Auto-provisioning.** A `profiles` row is created automatically when a user
signs up, from metadata passed at signup — an admin invites a rep/supervisor/
pickup agent with `role`/`rep_id`/`supervisor_id`/`pickup_point_id` set in
`raw_user_meta_data`; a customer's `customer_id` is attached the same way, or
linked on their first order if new:

```sql
CREATE OR REPLACE FUNCTION handle_new_user_signup()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (profile_id, email, role, associated_supervisor_id, associated_rep_id, associated_pickup_point_id, associated_customer_id)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE((NEW.raw_user_meta_data->>'role')::user_role_enum, 'customer'::user_role_enum),
        (NEW.raw_user_meta_data->>'supervisor_id')::UUID,
        (NEW.raw_user_meta_data->>'rep_id')::UUID,
        (NEW.raw_user_meta_data->>'pickup_point_id')::UUID,
        (NEW.raw_user_meta_data->>'customer_id')::UUID
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE TRIGGER trg_on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION handle_new_user_signup();
```

`SECURITY DEFINER` functions must pin `search_path` explicitly (`SET
search_path = public` above) — without it, the function is vulnerable to
search-path hijacking. Every `SECURITY DEFINER` function in this schema
follows this rule, including `run_sales_aggregator` (§4.4).

**Row-level security**, enabled on every operational table (`orders`,
`inventory_movements`, etc.) and resolved through `profiles` in one lookup:

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_global_access ON orders AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'hq_admin')
);

CREATE POLICY supervisor_territory_isolation ON orders AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'supervisor' AND associated_supervisor_id = orders.supervisor_id)
);

CREATE POLICY sales_rep_isolation ON orders AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'sales_rep' AND associated_rep_id = orders.rep_id)
);

CREATE POLICY pickup_agent_isolation ON orders AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'pickup_agent' AND associated_pickup_point_id = orders.pickup_point_id)
);

CREATE POLICY customer_own_orders_only ON orders AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'customer' AND associated_customer_id = orders.customer_id)
);
```

Equivalent policies also apply to `inventory_movements` (supervisor sees their
own `Supervisor_Hub` pool plus their team's `Van_Stock`; `sales_rep` sees only
their own `Van_Stock`; `pickup_agent` sees only their own `Pickup_Point`; no
`customer` policy needed), `outlet_visits` (`sales_rep` own visits,
`supervisor` their team's, `hq_admin` unrestricted), and `aggregated_sales`
(`FOR SELECT` only — writes happen exclusively through `run_sales_aggregator`,
which runs as the function owner and bypasses RLS regardless of these
policies). Full policy SQL: `docs/superpowers/plans/2026-08-25-backend-foundation.md` Task 8.

`run_sales_aggregator` (§4.4) additionally checks the caller's `profiles.role`
inside the function body (`hq_admin`/`supervisor` only, `RAISE EXCEPTION`
otherwise) — `GRANT EXECUTE` alone can't express a role-conditional check, so
the guard has to live in the function.

`customer` profiles authenticate via Supabase Auth **phone + OTP**, not
email/password — catalogue browsing (`products`) itself stays public/unauthenticated;
a phone-OTP session is only required to place an order or view/confirm its
pickup status. `hq_admin`/`supervisor`/`sales_rep`/`pickup_agent` use standard
email/password auth, same as the existing `auth` module.

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
    recorded_by_profile_id UUID REFERENCES profiles(profile_id),

    -- Mandated: strict targeting — exactly the FK matching pool_type may be set,
    -- the other two must be NULL. Closes the gap partial unique indexes alone
    -- don't cover (a row could otherwise be uniquely valid but mistargeted,
    -- e.g. pool_type = 'Van_Stock' with supervisor_id also populated).
    CONSTRAINT chk_movement_pool_targeting CHECK (
        (pool_type = 'Van_Stock'      AND rep_id IS NOT NULL        AND supervisor_id IS NULL AND pickup_point_id IS NULL)
        OR (pool_type = 'Pickup_Point'   AND pickup_point_id IS NOT NULL AND rep_id IS NULL        AND supervisor_id IS NULL)
        OR (pool_type = 'Supervisor_Hub' AND supervisor_id IS NOT NULL  AND rep_id IS NULL        AND pickup_point_id IS NULL)
        OR (pool_type = 'Main_Warehouse' AND supervisor_id IS NULL      AND rep_id IS NULL        AND pickup_point_id IS NULL)
    )
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
columns. Mandated: exposed as a **materialized view**, not a live view, so
balance reads don't re-scan the full movement history on every query:

```sql
CREATE MATERIALIZED VIEW current_inventory_balance AS
SELECT pool_type, supervisor_id, pickup_point_id, rep_id, product_id,
       SUM(qty_delta) AS qty_on_hand
FROM inventory_movements
GROUP BY pool_type, supervisor_id, pickup_point_id, rep_id, product_id;

-- REFRESH MATERIALIZED VIEW CONCURRENTLY requires a unique index; COALESCE
-- collapses the pool-specific NULLs to a sentinel so the index is well-defined
-- across all four pool types.
CREATE UNIQUE INDEX uniq_current_inventory_balance ON current_inventory_balance (
    pool_type,
    COALESCE(supervisor_id, '00000000-0000-0000-0000-000000000000'),
    COALESCE(pickup_point_id, '00000000-0000-0000-0000-000000000000'),
    COALESCE(rep_id, '00000000-0000-0000-0000-000000000000'),
    product_id
);
```

Refreshed (`REFRESH MATERIALIZED VIEW CONCURRENTLY current_inventory_balance`) on
the same cadence as `aggregated_sales` — end-of-day, alongside
`run_sales_aggregator`, not on every movement insert (that would recreate the
compute bottleneck it's meant to avoid). `aggregated_sales` itself already
follows the same "don't recompute on read" philosophy via its
function-populated cache table, so it's left as pasted rather than converted to
a materialized view — the two mechanisms (materialized view vs. function +
cache table) serve the same goal for their respective tables.

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
- Whether `web` uses Next.js App Router or Pages Router — implementation detail, not architecture
