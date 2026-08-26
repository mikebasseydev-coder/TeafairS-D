# Backend Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Teafair's backend foundation — the full RTM Postgres schema (Prisma-managed where possible, hand-written SQL where Prisma can't express it), RLS-enforced RBAC across every territory-scoped table, the aggregation function, performance indexes, seed data, and a `supabase/migrations/` bundle ready to push to the hosted Supabase project.

**Architecture:** `backend/` is a local-only Prisma+Docker sandbox (never deployed) used to author and test schema changes fast; validated changes get assembled into flat SQL files under `supabase/migrations/` and applied to Supabase, which stays the production source of truth. A local Postgres container carries two small stub objects (a fake `auth.users` table and Supabase's `auth.uid()` function) that exist only so migrations, the auto-provisioning trigger, and RLS policies can be authored and tested locally — Supabase provides the real versions of both in production, and the stub SQL never leaves `backend/docker/init/`.

**Tech Stack:** PostgreSQL 16 (Docker), Prisma ORM **6.19.3** pinned exactly (both `prisma` and `@prisma/client` — `npx prisma` alone currently resolves to `8.0.0-rc.10`, a different CLI generation with no `migrate` command; verified during spec review, see Global Constraints), `pg` for verification scripts, Supabase CLI (`npx supabase`) for the migration bundle.

**Spec:** `docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md` (data model, RBAC, RLS) and `docs/superpowers/specs/2026-08-25-rtm-frontend-ui-caching-design.md` (roles this schema serves) — this plan implements the backend portions of both; the five frontend surfaces (`ui`, `web`, `mobile` offline-sync layer, `windows`) are separate follow-up plans, out of scope here.

## Global Constraints

- Pin `prisma`/`@prisma/client` to exactly `6.19.3` in `backend/package.json` — do not use `npx prisma` unpinned or `"latest"`; it resolves to the incompatible `8.0.0-rc.10` CLI.
- All UUID primary keys use `@default(dbgenerated("gen_random_uuid()"))`, not Prisma's `@default(uuid())` — this guarantees a real Postgres-level default (`gen_random_uuid()`, built into PG13+, no extension needed) rather than relying on version-specific Prisma client-vs-DB default behavior. This is a deliberate deviation from the `uuid_generate_v4()`/`uuid-ossp` shown in the original pasted schema — functionally equivalent, one fewer extension dependency.
- Every `SECURITY DEFINER` function must pin `SET search_path = public` (backend spec §4.1, backend/CLAUDE.md).
- `inventory_movements` pool-targeting and `profiles` role-targeting each need a CHECK constraint (backend spec §4.1–4.2) — Prisma can't express either; both are hand-written SQL.
- Every territory-scoped table (`orders`, `inventory_movements`, `outlet_visits`, `aggregated_sales`) needs RLS enabled with the role-appropriate policy set before it ships — not just `orders`.
- `run_sales_aggregator()` must reject callers whose `profiles.role` isn't `hq_admin`/`supervisor` — it's a company-wide recompute, not something any authenticated session (including a customer's) should be able to trigger.
- Local Docker Postgres is never connected to by any deployed app — it exists solely for authoring/testing migrations (backend/CLAUDE.md).

---

## Finalized feature/module list (for reference — this plan covers only the italicized items)

**Backend (this plan):**
- *Full RTM schema*: reference tables (supervisors, sales_reps, routes, pickup_points, customers, products), transactional tables (orders, order_lines), inventory (append-only `inventory_movements` ledger + `current_inventory_balance` materialized view), `outlet_visits`, `aggregated_sales`
- *RBAC*: centralized `profiles` table, auto-provisioning trigger, `chk_profile_role_targeting`
- *RLS*: five-role policy pattern on `orders`, plus role-appropriate policies on `inventory_movements`, `outlet_visits`, and `aggregated_sales`
- *Aggregation*: `run_sales_aggregator()`, privilege-guarded, plus a `pg_cron` daily schedule (Supabase-only)
- *Performance*: indexes on every FK/date column RLS policies and the aggregator filter on
- *Seed data* for local development
- *`supabase/migrations/` bundle*, ready to push

**Frontend (future plans, not covered here):**
- `frontend/ui` — shared RN+NativeWind components
- `frontend/web` — Next.js + react-native-web, HQ Aggregation platform
- `frontend/mobile` offline-first sync layer (Room/SQLite, `synced:false` queue, `place_confirmed_order` RPC)
- `frontend/windows` — react-native-windows scaffold + its own SQLite cache

---

### Task 1: Scaffold `backend/` and local Postgres

**Files:**
- Create: `backend/package.json`
- Create: `backend/docker-compose.yml`
- Create: `backend/docker/init/01-local-auth-stub.sql`
- Create: `backend/.gitignore`
- Create: `backend/.env.example`
- Create: `backend/.env`
- Create: `backend/scripts/verify-task1.mjs`
- Delete: `prisma.config.ts` (repo root — untracked, built for the incompatible `8.0.0-rc.10` CLI's `skills` feature; `backend/` is the real home for Prisma tooling per the backend spec §3, and classic Prisma 6.x needs no config file beyond `schema.prisma` + `DATABASE_URL`)

**Interfaces:**
- Produces: a reachable Postgres at `postgresql://teafair:teafair_dev@localhost:5433/teafair_dev`, with a local-only `auth.users` stub table and `auth.uid()` function that later tasks depend on for testing the auto-provisioning trigger and RLS.

- [ ] **Step 1: Write the verification script (it should fail — nothing is running yet)**

Create `backend/scripts/verify-task1.mjs`:

```js
import { Client } from "pg";

const client = new Client({ connectionString: process.env.DATABASE_URL });

async function main() {
  await client.connect();

  const authUsers = await client.query(
    `SELECT to_regclass('auth.users') AS exists`
  );
  if (!authUsers.rows[0].exists) {
    throw new Error("auth.users stub table does not exist");
  }

  const authUidFn = await client.query(
    `SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'auth' AND p.proname = 'uid'`
  );
  if (authUidFn.rowCount !== 1) {
    throw new Error("auth.uid() stub function does not exist");
  }

  const authenticatedRole = await client.query(
    `SELECT 1 FROM pg_roles WHERE rolname = 'authenticated'`
  );
  if (authenticatedRole.rowCount !== 1) {
    throw new Error("authenticated role does not exist");
  }

  console.log("PASS: local Postgres stub (auth.users, auth.uid(), authenticated role) present");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails (nothing is up yet)**

Run: `node backend/scripts/verify-task1.mjs` (from repo root, with `DATABASE_URL=postgresql://teafair:teafair_dev@localhost:5433/teafair_dev node backend/scripts/verify-task1.mjs`)
Expected: FAIL — connection refused (no Postgres running on port 5433).

- [ ] **Step 3: Create the package, compose file, and init stub**

Create `backend/package.json`:

```json
{
  "name": "@teafair/backend",
  "private": true,
  "version": "0.1.0",
  "scripts": {
    "db:up": "docker compose up -d",
    "db:down": "docker compose down",
    "migrate": "prisma migrate dev",
    "generate": "prisma generate",
    "seed": "prisma db seed"
  },
  "prisma": {
    "seed": "node prisma/seed.mjs"
  },
  "devDependencies": {
    "prisma": "6.19.3",
    "pg": "^8.13.1",
    "dotenv": "^16.4.7"
  },
  "dependencies": {
    "@prisma/client": "6.19.3"
  }
}
```

Create `backend/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: teafair
      POSTGRES_PASSWORD: teafair_dev
      POSTGRES_DB: teafair_dev
    ports:
      - "5433:5432"
    volumes:
      - teafair_pg_data:/var/lib/postgresql/data
      - ./docker/init:/docker-entrypoint-initdb.d:ro

volumes:
  teafair_pg_data:
```

Create `backend/docker/init/01-local-auth-stub.sql`:

```sql
-- LOCAL DEV ONLY. Supabase provides the real `auth` schema, `auth.uid()`,
-- and `authenticated`/`anon` roles in production. This stub exists purely so
-- migrations, the auto-provisioning trigger, and RLS policies can be
-- authored and tested against a disposable local Postgres. Never copied
-- into supabase/migrations/.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255),
    phone VARCHAR(20),
    raw_user_meta_data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA auth TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
```

Create `backend/.gitignore`:

```
node_modules/
.env
```

Create `backend/.env.example`:

```
DATABASE_URL="postgresql://teafair:teafair_dev@localhost:5433/teafair_dev"
```

Create `backend/.env` with the same content as `.env.example` (no real secrets locally, so they're identical for now).

Remove the stray root config: delete `prisma.config.ts` at the repo root.

- [ ] **Step 4: Install and bring the stack up**

Run: `cd backend && npm install`
Expected: installs `prisma`, `@prisma/client`, `pg`, `dotenv` with no errors.

Run: `cd backend && npm run db:up`
Expected: `docker compose up -d` reports the `postgres` service started/healthy.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task1.mjs`
Expected: `PASS: local Postgres stub (auth.users, auth.uid(), authenticated role) present`

- [ ] **Step 6: Commit**

```bash
git add backend/package.json backend/docker-compose.yml backend/docker/init/01-local-auth-stub.sql backend/.gitignore backend/.env.example backend/scripts/verify-task1.mjs
git rm prisma.config.ts
git commit -m "feat(backend): scaffold local Prisma+Docker sandbox with auth stub"
```

(`backend/.env` stays untracked, matching `.gitignore`.)

---

### Task 2: Baseline Prisma schema — reference and transactional tables

**Files:**
- Create: `backend/prisma/schema.prisma`
- Create: `backend/scripts/verify-task2.mjs`

**Interfaces:**
- Consumes: `DATABASE_URL` from `backend/.env` (Task 1).
- Produces: tables `supervisors`, `sales_reps`, `routes`, `pickup_points`, `customers`, `products`, `orders`, `order_lines`, `inventory_movements` (base columns only — CHECK/partial-indexes in Task 4), `outlet_visits`, `aggregated_sales` (base columns only — grouping unique index in Task 6), `profiles` (base columns only — `auth.users` FK/CHECK in Task 5). All enums.

- [ ] **Step 1: Write the verification script (it should fail — no tables exist yet)**

Create `backend/scripts/verify-task2.mjs`:

```js
import { Client } from "pg";

const client = new Client({ connectionString: process.env.DATABASE_URL });

const EXPECTED_TABLES = [
  "supervisors", "sales_reps", "routes", "pickup_points", "customers",
  "products", "orders", "order_lines", "inventory_movements",
  "outlet_visits", "aggregated_sales", "profiles",
];

async function main() {
  await client.connect();
  for (const table of EXPECTED_TABLES) {
    const { rows } = await client.query(`SELECT to_regclass($1) AS exists`, [`public.${table}`]);
    if (!rows[0].exists) {
      throw new Error(`table "${table}" does not exist`);
    }
  }
  console.log(`PASS: all ${EXPECTED_TABLES.length} baseline tables exist`);
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task2.mjs`
Expected: FAIL — `table "supervisors" does not exist`

- [ ] **Step 3: Write the Prisma schema**

Create `backend/prisma/schema.prisma`:

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

enum SaleType {
  PreSale        @map("Pre-sale")
  StreetCampaign @map("Street Campaign")
  OnlineDelivery @map("Online_Delivery")
  OnlinePickup   @map("Online_Pickup")

  @@map("sale_type_enum")
}

enum OrderStatus {
  Pending
  Processing
  ReadyForPickup @map("Ready_For_Pickup")
  Delivered
  Collected
  Cancelled

  @@map("order_status_enum")
}

enum PaymentStatus {
  Paid
  Pending
  Partial
  BadDebt @map("Bad Debt")

  @@map("payment_status_enum")
}

enum InventoryPool {
  MainWarehouse @map("Main_Warehouse")
  SupervisorHub @map("Supervisor_Hub")
  PickupPoint   @map("Pickup_Point")
  VanStock      @map("Van_Stock")

  @@map("inventory_pool_enum")
}

enum InventoryMovementType {
  Received
  Sold
  Returned
  PhysicalCount @map("Physical_Count")
  Transfer

  @@map("inventory_movement_enum")
}

enum UserRole {
  hq_admin
  supervisor
  sales_rep
  pickup_agent
  customer

  @@map("user_role_enum")
}

model Supervisor {
  supervisorId String   @id @default(dbgenerated("gen_random_uuid()")) @map("supervisor_id") @db.Uuid
  name         String   @db.VarChar(100)
  phone        String   @unique @db.VarChar(20)
  isActive     Boolean  @default(true) @map("is_active")
  createdAt    DateTime @default(now()) @map("created_at") @db.Timestamptz

  reps               SalesRep[]
  routes             Route[]
  profiles           Profile[]
  ordersAsSupervisor Order[]             @relation("OrderSupervisor")
  inventoryMovements InventoryMovement[]
  aggregatedSales    AggregatedSales[]

  @@map("supervisors")
}

model SalesRep {
  repId        String   @id @default(dbgenerated("gen_random_uuid()")) @map("rep_id") @db.Uuid
  supervisorId String?  @map("supervisor_id") @db.Uuid
  name         String   @db.VarChar(100)
  phone        String   @unique @db.VarChar(20)
  isActive     Boolean  @default(true) @map("is_active")
  createdAt    DateTime @default(now()) @map("created_at") @db.Timestamptz

  supervisor         Supervisor?         @relation(fields: [supervisorId], references: [supervisorId], onDelete: SetNull)
  routes             Route[]
  profiles           Profile[]
  orders             Order[]
  outletVisits       OutletVisit[]
  inventoryMovements InventoryMovement[]
  aggregatedSales    AggregatedSales[]

  @@map("sales_reps")
}

model Route {
  routeId              String   @id @default(dbgenerated("gen_random_uuid()")) @map("route_id") @db.Uuid
  routeName            String   @map("route_name") @db.VarChar(100)
  territoryZone        String   @map("territory_zone") @db.VarChar(100)
  assignedSupervisorId String?  @map("assigned_supervisor_id") @db.Uuid
  assignedRepId        String?  @map("assigned_rep_id") @db.Uuid
  createdAt            DateTime @default(now()) @map("created_at") @db.Timestamptz

  assignedSupervisor Supervisor?       @relation(fields: [assignedSupervisorId], references: [supervisorId], onDelete: SetNull)
  assignedRep        SalesRep?         @relation(fields: [assignedRepId], references: [repId], onDelete: SetNull)
  pickupPoints       PickupPoint[]
  customers          Customer[]
  orders             Order[]
  outletVisits       OutletVisit[]
  aggregatedSales    AggregatedSales[]

  @@map("routes")
}

model PickupPoint {
  pickupPointId String   @id @default(dbgenerated("gen_random_uuid()")) @map("pickup_point_id") @db.Uuid
  pointName     String   @map("point_name") @db.VarChar(150)
  routeId       String?  @map("route_id") @db.Uuid
  address       String
  latitude      Decimal? @db.Decimal(9, 6)
  longitude     Decimal? @db.Decimal(9, 6)
  isActive      Boolean  @default(true) @map("is_active")

  route    Route?    @relation(fields: [routeId], references: [routeId], onDelete: Cascade)
  orders   Order[]
  profiles Profile[]

  @@map("pickup_points")
}

model Customer {
  customerId      String   @id @default(dbgenerated("gen_random_uuid()")) @map("customer_id") @db.Uuid
  businessName    String   @map("business_name") @db.VarChar(150)
  contactName     String?  @map("contact_name") @db.VarChar(100)
  phone           String?  @db.VarChar(20)
  email           String?  @unique @db.VarChar(100)
  routeId         String?  @map("route_id") @db.Uuid
  deliveryAddress String?  @map("delivery_address")
  createdAt       DateTime @default(now()) @map("created_at") @db.Timestamptz

  route        Route?        @relation(fields: [routeId], references: [routeId], onDelete: SetNull)
  orders       Order[]
  profiles     Profile[]
  outletVisits OutletVisit[]

  @@map("customers")
}

model Product {
  productId      String  @id @default(dbgenerated("gen_random_uuid()")) @map("product_id") @db.Uuid
  skuCode        String  @unique @map("sku_code") @db.VarChar(50)
  productName    String  @map("product_name") @db.VarChar(150)
  category       String? @db.VarChar(50)
  basePrice      Decimal @map("base_price") @db.Decimal(10, 2)
  wholesalePrice Decimal @map("wholesale_price") @db.Decimal(10, 2)

  orderLines         OrderLine[]
  inventoryMovements InventoryMovement[]

  @@map("products")
}

model Order {
  orderId       String        @id @default(dbgenerated("gen_random_uuid()")) @map("order_id") @db.Uuid
  saleType      SaleType      @map("sale_type")
  orderStatus   OrderStatus   @default(Pending) @map("order_status")
  paymentStatus PaymentStatus @default(Pending) @map("payment_status")
  customerId    String?       @map("customer_id") @db.Uuid
  repId         String?       @map("rep_id") @db.Uuid
  supervisorId  String?       @map("supervisor_id") @db.Uuid
  routeId       String?       @map("route_id") @db.Uuid
  pickupPointId String?       @map("pickup_point_id") @db.Uuid
  totalAmount   Decimal       @default(0.00) @map("total_amount") @db.Decimal(12, 2)
  amountPaid    Decimal       @default(0.00) @map("amount_paid") @db.Decimal(12, 2)
  orderDate     DateTime      @default(now()) @map("order_date") @db.Timestamptz
  syncedAt      DateTime      @default(now()) @map("synced_at") @db.Timestamptz

  customer           Customer?           @relation(fields: [customerId], references: [customerId], onDelete: SetNull)
  rep                SalesRep?           @relation(fields: [repId], references: [repId], onDelete: SetNull)
  supervisor         Supervisor?         @relation("OrderSupervisor", fields: [supervisorId], references: [supervisorId], onDelete: SetNull)
  route              Route?              @relation(fields: [routeId], references: [routeId], onDelete: SetNull)
  pickupPoint        PickupPoint?        @relation(fields: [pickupPointId], references: [pickupPointId], onDelete: SetNull)
  orderLines         OrderLine[]
  outletVisits       OutletVisit[]
  inventoryMovements InventoryMovement[]

  @@map("orders")
}

model OrderLine {
  lineId    String  @id @default(dbgenerated("gen_random_uuid()")) @map("line_id") @db.Uuid
  orderId   String  @map("order_id") @db.Uuid
  productId String  @map("product_id") @db.Uuid
  qtySold   Int     @map("qty_sold")
  unitPrice Decimal @map("unit_price") @db.Decimal(10, 2)
  // total_line_amount is a Postgres GENERATED ALWAYS AS ... STORED column,
  // added via raw SQL in Task 3 — not a writable/readable Prisma field here.

  order   Order   @relation(fields: [orderId], references: [orderId], onDelete: Cascade)
  product Product @relation(fields: [productId], references: [productId])

  @@map("order_lines")
}

model InventoryMovement {
  movementId          String                @id @default(dbgenerated("gen_random_uuid()")) @map("movement_id") @db.Uuid
  poolType            InventoryPool         @map("pool_type")
  supervisorId        String?               @map("supervisor_id") @db.Uuid
  pickupPointId       String?               @map("pickup_point_id") @db.Uuid
  repId               String?               @map("rep_id") @db.Uuid
  productId           String                @map("product_id") @db.Uuid
  movementType        InventoryMovementType @map("movement_type")
  qtyDelta            Int                   @map("qty_delta")
  referenceOrderId    String?               @map("reference_order_id") @db.Uuid
  occurredAt          DateTime              @default(now()) @map("occurred_at") @db.Timestamptz
  recordedByProfileId String?               @map("recorded_by_profile_id") @db.Uuid
  // chk_movement_pool_targeting CHECK and the three pool-scoped partial
  // unique indexes are added via raw SQL in Task 4 — Prisma can't express
  // either.

  supervisor     Supervisor?  @relation(fields: [supervisorId], references: [supervisorId])
  pickupPoint    PickupPoint? @relation(fields: [pickupPointId], references: [pickupPointId])
  rep            SalesRep?    @relation(fields: [repId], references: [repId])
  product        Product      @relation(fields: [productId], references: [productId])
  referenceOrder Order?       @relation(fields: [referenceOrderId], references: [orderId])
  recordedBy     Profile?     @relation(fields: [recordedByProfileId], references: [profileId])

  @@map("inventory_movements")
}

model OutletVisit {
  visitId      String   @id @default(dbgenerated("gen_random_uuid()")) @map("visit_id") @db.Uuid
  customerId   String   @map("customer_id") @db.Uuid
  repId        String   @map("rep_id") @db.Uuid
  routeId      String   @map("route_id") @db.Uuid
  visitedAt    DateTime @default(now()) @map("visited_at") @db.Timestamptz
  isProductive Boolean  @default(false) @map("is_productive")
  orderId      String?  @map("order_id") @db.Uuid

  customer Customer @relation(fields: [customerId], references: [customerId])
  rep      SalesRep @relation(fields: [repId], references: [repId])
  route    Route    @relation(fields: [routeId], references: [routeId])
  order    Order?   @relation(fields: [orderId], references: [orderId])

  @@map("outlet_visits")
}

model AggregatedSales {
  aggregationId    String   @id @default(dbgenerated("gen_random_uuid()")) @map("aggregation_id") @db.Uuid
  summaryDate      DateTime @map("summary_date") @db.Date
  saleType         SaleType @map("sale_type")
  supervisorId     String?  @map("supervisor_id") @db.Uuid
  routeId          String?  @map("route_id") @db.Uuid
  repId            String?  @map("rep_id") @db.Uuid
  totalOrdersCount Int      @default(0) @map("total_orders_count")
  grossRevenue     Decimal  @default(0.00) @map("gross_revenue") @db.Decimal(14, 2)
  cashCollected    Decimal  @default(0.00) @map("cash_collected") @db.Decimal(14, 2)
  computedAt       DateTime @default(now()) @map("computed_at") @db.Timestamptz
  // The grouping unique index (COALESCE-based, so NULL supervisor/route/rep
  // rollups still collide correctly) is added via raw SQL in Task 6 —
  // Prisma's @@unique can't express the COALESCE expression.

  supervisor Supervisor? @relation(fields: [supervisorId], references: [supervisorId])
  route      Route?      @relation(fields: [routeId], references: [routeId])
  rep        SalesRep?   @relation(fields: [repId], references: [repId])

  @@map("aggregated_sales")
}

model Profile {
  profileId               String   @id @db.Uuid @map("profile_id")
  email                    String?  @db.VarChar(100)
  role                     UserRole
  associatedSupervisorId   String?  @map("associated_supervisor_id") @db.Uuid
  associatedRepId          String?  @map("associated_rep_id") @db.Uuid
  associatedPickupPointId  String?  @map("associated_pickup_point_id") @db.Uuid
  associatedCustomerId     String?  @map("associated_customer_id") @db.Uuid
  createdAt                DateTime @default(now()) @map("created_at") @db.Timestamptz
  // The FK into Supabase-managed auth.users, and chk_profile_role_targeting,
  // are added via raw SQL in Task 5 — Prisma can't express a cross-schema FK
  // into a schema it doesn't manage.

  associatedSupervisor  Supervisor?         @relation(fields: [associatedSupervisorId], references: [supervisorId], onDelete: SetNull)
  associatedRep         SalesRep?           @relation(fields: [associatedRepId], references: [repId], onDelete: SetNull)
  associatedPickupPoint PickupPoint?        @relation(fields: [associatedPickupPointId], references: [pickupPointId], onDelete: SetNull)
  associatedCustomer    Customer?           @relation(fields: [associatedCustomerId], references: [customerId], onDelete: SetNull)
  recordedMovements     InventoryMovement[]

  @@map("profiles")
}
```

- [ ] **Step 4: Generate and apply the migration**

Run: `cd backend && npx prisma migrate dev --name baseline_schema`
Expected: Prisma creates `backend/prisma/migrations/<timestamp>_baseline_schema/migration.sql`, applies it, and prints `Your database is now in sync with your schema.`

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task2.mjs`
Expected: `PASS: all 12 baseline tables exist`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/schema.prisma backend/prisma/migrations backend/scripts/verify-task2.mjs
git commit -m "feat(backend): baseline Prisma schema for reference and transactional tables"
```

---

### Task 3: Raw SQL — `order_lines.total_line_amount` generated column

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_add_order_line_generated_total/migration.sql` (created empty by `--create-only`, then hand-written)
- Create: `backend/scripts/verify-task3.mjs`

**Interfaces:**
- Consumes: `order_lines` table from Task 2 (`orderId`, `productId`, `qtySold`, `unitPrice`).
- Produces: `order_lines.total_line_amount` (`qty_sold * unit_price`, stored, not writable).

- [ ] **Step 1: Write the verification script (it should fail — column doesn't exist yet)**

Create `backend/scripts/verify-task3.mjs`:

```js
import { Client } from "pg";
import { randomUUID } from "node:crypto";

const client = new Client({ connectionString: process.env.DATABASE_URL });

async function main() {
  await client.connect();

  const productId = randomUUID();
  const orderId = randomUUID();
  await client.query(
    `INSERT INTO products (product_id, sku_code, product_name, base_price, wholesale_price)
     VALUES ($1, 'SKU-TEST-1', 'Test Product', 10.00, 8.00)`,
    [productId]
  );
  await client.query(
    `INSERT INTO orders (order_id, sale_type) VALUES ($1, 'Street Campaign')`,
    [orderId]
  );

  const { rows } = await client.query(
    `INSERT INTO order_lines (line_id, order_id, product_id, qty_sold, unit_price)
     VALUES (gen_random_uuid(), $1, $2, 3, 8.00)
     RETURNING total_line_amount`,
    [orderId, productId]
  );

  if (Number(rows[0].total_line_amount) !== 24.0) {
    throw new Error(`expected total_line_amount 24.00, got ${rows[0].total_line_amount}`);
  }

  console.log("PASS: order_lines.total_line_amount computes qty_sold * unit_price");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task3.mjs`
Expected: FAIL — `column "total_line_amount" of relation "order_lines" does not exist`

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name add_order_line_generated_total`
Expected: creates an empty `backend/prisma/migrations/<timestamp>_add_order_line_generated_total/migration.sql`.

Edit that file to:

```sql
ALTER TABLE order_lines
    ADD COLUMN total_line_amount NUMERIC(12,2) GENERATED ALWAYS AS (qty_sold * unit_price) STORED;
```

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies the hand-written migration, `Your database is now in sync with your schema.`

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task3.mjs`
Expected: `PASS: order_lines.total_line_amount computes qty_sold * unit_price`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task3.mjs
git commit -m "feat(backend): add generated total_line_amount column to order_lines"
```

---

### Task 4: Raw SQL — inventory pool-targeting CHECK, partial unique indexes, materialized balance view

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_inventory_movement_integrity/migration.sql`
- Create: `backend/scripts/verify-task4.mjs`

**Interfaces:**
- Consumes: `inventory_movements` table from Task 2.
- Produces: `chk_movement_pool_targeting` CHECK constraint, three partial unique indexes, `current_inventory_balance` materialized view + its concurrent-refresh-safe unique index.

- [ ] **Step 1: Write the verification script (it should fail — constraint doesn't exist yet)**

Create `backend/scripts/verify-task4.mjs`:

```js
import { Client } from "pg";
import { randomUUID } from "node:crypto";

const client = new Client({ connectionString: process.env.DATABASE_URL });

async function main() {
  await client.connect();

  const productId = randomUUID();
  const repId = randomUUID();
  await client.query(
    `INSERT INTO products (product_id, sku_code, product_name, base_price, wholesale_price)
     VALUES ($1, 'SKU-TEST-2', 'Test Product 2', 10.00, 8.00)`,
    [productId]
  );
  await client.query(
    `INSERT INTO sales_reps (rep_id, name, phone) VALUES ($1, 'Test Rep', '+2340000000001')`,
    [repId]
  );

  // Valid: Van_Stock row with only rep_id set.
  await client.query(
    `INSERT INTO inventory_movements (movement_id, pool_type, rep_id, product_id, movement_type, qty_delta)
     VALUES (gen_random_uuid(), 'Van_Stock', $1, $2, 'Received', 20)`,
    [repId, productId]
  );

  // Invalid: Van_Stock row with supervisor_id also set — must be rejected.
  let rejected = false;
  try {
    await client.query(
      `INSERT INTO inventory_movements (movement_id, pool_type, rep_id, supervisor_id, product_id, movement_type, qty_delta)
       VALUES (gen_random_uuid(), 'Van_Stock', $1, gen_random_uuid(), $2, 'Received', 5)`,
      [repId, productId]
    );
  } catch (err) {
    if (err.code === "23514") rejected = true; // check_violation
    else throw err;
  }
  if (!rejected) {
    throw new Error("mistargeted inventory_movements row was accepted, expected CHECK violation");
  }

  await client.query(`REFRESH MATERIALIZED VIEW current_inventory_balance`);
  const { rows } = await client.query(
    `SELECT qty_on_hand FROM current_inventory_balance WHERE pool_type = 'Van_Stock' AND rep_id = $1 AND product_id = $2`,
    [repId, productId]
  );
  if (rows.length !== 1 || Number(rows[0].qty_on_hand) !== 20) {
    throw new Error(`expected current_inventory_balance qty_on_hand 20, got ${JSON.stringify(rows)}`);
  }

  console.log("PASS: pool-targeting CHECK enforced, current_inventory_balance materialized view correct");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task4.mjs`
Expected: FAIL — mistargeted row was accepted (no CHECK constraint yet) or `relation "current_inventory_balance" does not exist`.

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name inventory_movement_integrity`

Edit the generated `migration.sql`:

```sql
ALTER TABLE inventory_movements
    ADD CONSTRAINT chk_movement_pool_targeting CHECK (
        (pool_type = 'Van_Stock'      AND rep_id IS NOT NULL        AND supervisor_id IS NULL AND pickup_point_id IS NULL)
        OR (pool_type = 'Pickup_Point'   AND pickup_point_id IS NOT NULL AND rep_id IS NULL        AND supervisor_id IS NULL)
        OR (pool_type = 'Supervisor_Hub' AND supervisor_id IS NOT NULL  AND rep_id IS NULL        AND pickup_point_id IS NULL)
        OR (pool_type = 'Main_Warehouse' AND supervisor_id IS NULL      AND rep_id IS NULL        AND pickup_point_id IS NULL)
    );

CREATE UNIQUE INDEX uniq_movement_van_stock
    ON inventory_movements (rep_id, product_id, occurred_at)
    WHERE pool_type = 'Van_Stock';
CREATE UNIQUE INDEX uniq_movement_pickup_point
    ON inventory_movements (pickup_point_id, product_id, occurred_at)
    WHERE pool_type = 'Pickup_Point';
CREATE UNIQUE INDEX uniq_movement_supervisor_hub
    ON inventory_movements (supervisor_id, product_id, occurred_at)
    WHERE pool_type = 'Supervisor_Hub';

CREATE MATERIALIZED VIEW current_inventory_balance AS
SELECT pool_type, supervisor_id, pickup_point_id, rep_id, product_id,
       SUM(qty_delta) AS qty_on_hand
FROM inventory_movements
GROUP BY pool_type, supervisor_id, pickup_point_id, rep_id, product_id;

CREATE UNIQUE INDEX uniq_current_inventory_balance ON current_inventory_balance (
    pool_type,
    COALESCE(supervisor_id, '00000000-0000-0000-0000-000000000000'),
    COALESCE(pickup_point_id, '00000000-0000-0000-0000-000000000000'),
    COALESCE(rep_id, '00000000-0000-0000-0000-000000000000'),
    product_id
);
```

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies cleanly.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task4.mjs`
Expected: `PASS: pool-targeting CHECK enforced, current_inventory_balance materialized view correct`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task4.mjs
git commit -m "feat(backend): enforce inventory pool targeting, add balance materialized view"
```

---

### Task 5: Raw SQL — `profiles` → `auth.users` FK, role-targeting CHECK, auto-provisioning trigger

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_profiles_auth_integration/migration.sql`
- Create: `backend/scripts/verify-task5.mjs`

**Interfaces:**
- Consumes: `profiles` table from Task 2, `auth.users` stub from Task 1.
- Produces: `profiles.profile_id` FK to `auth.users(id)`, `chk_profile_role_targeting`, `handle_new_user_signup()` trigger function (search_path pinned) + `trg_on_auth_user_created` trigger.

- [ ] **Step 1: Write the verification script (it should fail — no FK/trigger yet)**

Create `backend/scripts/verify-task5.mjs`:

```js
import { Client } from "pg";
import { randomUUID } from "node:crypto";

const client = new Client({ connectionString: process.env.DATABASE_URL });

async function main() {
  await client.connect();

  const repId = randomUUID();
  await client.query(
    `INSERT INTO sales_reps (rep_id, name, phone) VALUES ($1, 'Auto Rep', '+2340000000002')`,
    [repId]
  );

  const authUserId = randomUUID();
  await client.query(
    `INSERT INTO auth.users (id, email, raw_user_meta_data)
     VALUES ($1, 'rep@example.com', $2::jsonb)`,
    [authUserId, JSON.stringify({ role: "sales_rep", rep_id: repId })]
  );

  const { rows } = await client.query(
    `SELECT role, associated_rep_id FROM profiles WHERE profile_id = $1`,
    [authUserId]
  );
  if (rows.length !== 1) {
    throw new Error("no profile row auto-created for new auth.users insert");
  }
  if (rows[0].role !== "sales_rep" || rows[0].associated_rep_id !== repId) {
    throw new Error(`profile row has wrong role/association: ${JSON.stringify(rows[0])}`);
  }

  // Mistargeted profile (role sales_rep but wrong association) must be rejected.
  let rejected = false;
  try {
    await client.query(
      `INSERT INTO profiles (profile_id, role, associated_supervisor_id)
       VALUES (gen_random_uuid(), 'sales_rep', gen_random_uuid())`
    );
  } catch (err) {
    if (err.code === "23514") rejected = true;
    else throw err;
  }
  if (!rejected) {
    throw new Error("mistargeted profile row was accepted, expected CHECK violation");
  }

  console.log("PASS: auto-provisioning trigger and chk_profile_role_targeting both work");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task5.mjs`
Expected: FAIL — `no profile row auto-created for new auth.users insert`

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name profiles_auth_integration`

Edit the generated `migration.sql`:

```sql
ALTER TABLE profiles
    ADD CONSTRAINT profiles_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE profiles
    ADD CONSTRAINT chk_profile_role_targeting CHECK (
        (role = 'hq_admin'     AND associated_supervisor_id IS NULL     AND associated_rep_id IS NULL     AND associated_pickup_point_id IS NULL AND associated_customer_id IS NULL)
        OR (role = 'supervisor'   AND associated_supervisor_id IS NOT NULL AND associated_rep_id IS NULL     AND associated_pickup_point_id IS NULL AND associated_customer_id IS NULL)
        OR (role = 'sales_rep'    AND associated_rep_id IS NOT NULL     AND associated_supervisor_id IS NULL  AND associated_pickup_point_id IS NULL AND associated_customer_id IS NULL)
        OR (role = 'pickup_agent' AND associated_pickup_point_id IS NOT NULL AND associated_supervisor_id IS NULL AND associated_rep_id IS NULL     AND associated_customer_id IS NULL)
        OR (role = 'customer'     AND associated_customer_id IS NOT NULL AND associated_supervisor_id IS NULL  AND associated_rep_id IS NULL     AND associated_pickup_point_id IS NULL)
    );

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

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies cleanly.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task5.mjs`
Expected: `PASS: auto-provisioning trigger and chk_profile_role_targeting both work`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task5.mjs
git commit -m "feat(backend): wire profiles to auth.users with auto-provisioning trigger"
```

---

### Task 6: Raw SQL — `aggregated_sales` grouping index and privilege-guarded `run_sales_aggregator()`

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_sales_aggregation_function/migration.sql`
- Create: `backend/scripts/verify-task6.mjs`

**Interfaces:**
- Consumes: `orders`, `aggregated_sales` from Task 2; `profiles`/`auth.uid()` from Task 5/1.
- Produces: `aggregated_sales_grouping_key` unique index (COALESCE-based — plain `(summary_date, route_id, rep_id, sale_type)` has the same NULL-not-distinct gap caught earlier in `inventory_movements`, since company-wide rollups leave `supervisor_id`/`route_id`/`rep_id` NULL), `run_sales_aggregator(target_date DATE)` function that rejects any caller whose `profiles.role` isn't `hq_admin`/`supervisor`.

- [ ] **Step 1: Write the verification script (it should fail — function doesn't exist yet)**

Create `backend/scripts/verify-task6.mjs`:

```js
import { Client } from "pg";
import { randomUUID } from "node:crypto";

const admin = new Client({ connectionString: process.env.DATABASE_URL });

async function withAuthedRole(authId, fn) {
  const conn = new Client({ connectionString: process.env.DATABASE_URL });
  await conn.connect();
  try {
    await conn.query("BEGIN");
    await conn.query("SET LOCAL ROLE authenticated");
    await conn.query(`SET LOCAL request.jwt.claim.sub = '${authId}'`);
    const result = await fn(conn);
    await conn.query("COMMIT");
    return result;
  } catch (err) {
    await conn.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    await conn.end();
  }
}

async function main() {
  await admin.connect();

  const repId = randomUUID();
  await admin.query(
    `INSERT INTO sales_reps (rep_id, name, phone) VALUES ($1, 'Agg Rep', '+2340000000003')`,
    [repId]
  );
  await admin.query(
    `INSERT INTO orders (order_id, sale_type, rep_id, total_amount, amount_paid, order_date)
     VALUES (gen_random_uuid(), 'Street Campaign', $1, 100.00, 100.00, '2026-08-25'),
            (gen_random_uuid(), 'Street Campaign', $1, 50.00, 50.00, '2026-08-25')`,
    [repId]
  );

  const hqAuthId = randomUUID();
  await admin.query(
    `INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, 'hq@example.com', $2::jsonb)`,
    [hqAuthId, JSON.stringify({ role: "hq_admin" })]
  );
  const repAuthId = randomUUID();
  await admin.query(
    `INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, 'rep@example.com', $2::jsonb)`,
    [repAuthId, JSON.stringify({ role: "sales_rep", rep_id: repId })]
  );

  // Negative: a sales_rep caller must be rejected.
  let rejected = false;
  try {
    await withAuthedRole(repAuthId, (conn) => conn.query(`SELECT run_sales_aggregator('2026-08-25'::date)`));
  } catch (err) {
    if (/insufficient privilege/.test(err.message)) rejected = true;
    else throw err;
  }
  if (!rejected) {
    throw new Error("sales_rep was able to call run_sales_aggregator, expected rejection");
  }

  // Positive: hq_admin caller succeeds.
  await withAuthedRole(hqAuthId, (conn) => conn.query(`SELECT run_sales_aggregator('2026-08-25'::date)`));

  const { rows } = await admin.query(
    `SELECT total_orders_count, gross_revenue FROM aggregated_sales
     WHERE summary_date = '2026-08-25' AND sale_type = 'Street Campaign' AND rep_id = $1`,
    [repId]
  );
  if (rows.length !== 1 || rows[0].total_orders_count !== 2 || Number(rows[0].gross_revenue) !== 150) {
    throw new Error(`unexpected aggregate row: ${JSON.stringify(rows)}`);
  }

  // Re-running for the same day must upsert, not duplicate.
  await withAuthedRole(hqAuthId, (conn) => conn.query(`SELECT run_sales_aggregator('2026-08-25'::date)`));
  const { rows: rows2 } = await admin.query(
    `SELECT COUNT(*)::int AS n FROM aggregated_sales
     WHERE summary_date = '2026-08-25' AND sale_type = 'Street Campaign' AND rep_id = $1`,
    [repId]
  );
  if (rows2[0].n !== 1) {
    throw new Error(`expected exactly 1 row after re-running aggregator, got ${rows2[0].n}`);
  }

  console.log("PASS: run_sales_aggregator rejects non-privileged callers, computes and upserts correctly for hq_admin");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => admin.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task6.mjs`
Expected: FAIL — `function run_sales_aggregator(date) does not exist`

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name sales_aggregation_function`

Edit the generated `migration.sql`:

```sql
CREATE UNIQUE INDEX aggregated_sales_grouping_key ON aggregated_sales (
    summary_date,
    sale_type,
    COALESCE(supervisor_id, '00000000-0000-0000-0000-000000000000'),
    COALESCE(route_id, '00000000-0000-0000-0000-000000000000'),
    COALESCE(rep_id, '00000000-0000-0000-0000-000000000000')
);

CREATE OR REPLACE FUNCTION run_sales_aggregator(target_date DATE)
RETURNS VOID AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role IN ('hq_admin', 'supervisor')
    ) THEN
        RAISE EXCEPTION 'insufficient privilege to run sales aggregation';
    END IF;

    INSERT INTO aggregated_sales (summary_date, sale_type, supervisor_id, route_id, rep_id, total_orders_count, gross_revenue, cash_collected, computed_at)
    SELECT
        order_date::DATE AS summary_date,
        sale_type,
        supervisor_id,
        route_id,
        rep_id,
        COUNT(order_id) AS total_orders_count,
        SUM(total_amount) AS gross_revenue,
        SUM(amount_paid) AS cash_collected,
        NOW() AS computed_at
    FROM orders
    WHERE order_date::DATE = target_date
    GROUP BY order_date::DATE, sale_type, supervisor_id, route_id, rep_id
    ON CONFLICT (
        summary_date,
        sale_type,
        COALESCE(supervisor_id, '00000000-0000-0000-0000-000000000000'),
        COALESCE(route_id, '00000000-0000-0000-0000-000000000000'),
        COALESCE(rep_id, '00000000-0000-0000-0000-000000000000')
    )
    DO UPDATE SET
        total_orders_count = EXCLUDED.total_orders_count,
        gross_revenue = EXCLUDED.gross_revenue,
        cash_collected = EXCLUDED.cash_collected,
        computed_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION run_sales_aggregator(DATE) TO authenticated;
```

(The `authenticated` grant looks broad, but the `IF NOT EXISTS ... RAISE EXCEPTION` guard inside the function body is the real enforcement — Postgres `GRANT EXECUTE` can't express a role-conditional check on its own, so the check has to live in the function.)

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies cleanly.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task6.mjs`
Expected: `PASS: run_sales_aggregator rejects non-privileged callers, computes and upserts correctly for hq_admin`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task6.mjs
git commit -m "feat(backend): add privilege-guarded run_sales_aggregator with NULL-safe grouping key"
```

---

### Task 7: Raw SQL — enable RLS and the five-role policy pattern on `orders`

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_orders_rls/migration.sql`
- Create: `backend/scripts/verify-task7.mjs`

**Interfaces:**
- Consumes: `orders`, `profiles` from Task 2/5, `authenticated` role and `auth.uid()` stub from Task 1.
- Produces: RLS enabled on `orders`, five policies (`hq_global_access`, `supervisor_territory_isolation`, `sales_rep_isolation`, `pickup_agent_isolation`, `customer_own_orders_only`).

- [ ] **Step 1: Write the verification script (it should fail — RLS not enabled yet)**

Create `backend/scripts/verify-task7.mjs`:

```js
import { Client } from "pg";
import { randomUUID } from "node:crypto";

const admin = new Client({ connectionString: process.env.DATABASE_URL });

async function asRep(repAuthId, fn) {
  const conn = new Client({ connectionString: process.env.DATABASE_URL });
  await conn.connect();
  await conn.query("BEGIN");
  await conn.query("SET LOCAL ROLE authenticated");
  await conn.query(`SET LOCAL request.jwt.claim.sub = '${repAuthId}'`);
  try {
    return await fn(conn);
  } finally {
    await conn.query("ROLLBACK");
    await conn.end();
  }
}

async function main() {
  await admin.connect();

  const repAId = randomUUID();
  const repBId = randomUUID();
  await admin.query(
    `INSERT INTO sales_reps (rep_id, name, phone) VALUES ($1, 'Rep A', '+2340000000004'), ($2, 'Rep B', '+2340000000005')`,
    [repAId, repBId]
  );
  const repAAuthId = randomUUID();
  await admin.query(
    `INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, 'repa@example.com', $2::jsonb)`,
    [repAAuthId, JSON.stringify({ role: "sales_rep", rep_id: repAId })]
  );

  const orderForA = randomUUID();
  const orderForB = randomUUID();
  await admin.query(
    `INSERT INTO orders (order_id, sale_type, rep_id) VALUES ($1, 'Street Campaign', $2), ($3, 'Street Campaign', $4)`,
    [orderForA, repAId, orderForB, repBId]
  );

  const visibleToRepA = await asRep(repAAuthId, (conn) =>
    conn.query(`SELECT order_id FROM orders`)
  );
  const ids = visibleToRepA.rows.map((r) => r.order_id);
  if (!ids.includes(orderForA) || ids.includes(orderForB)) {
    throw new Error(`sales_rep_isolation failed: rep A sees ${JSON.stringify(ids)}`);
  }

  console.log("PASS: RLS enabled on orders, sales_rep_isolation policy enforced");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => admin.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task7.mjs`
Expected: FAIL — rep A sees both orders (RLS not enabled, `teafair` connection owns the tables and every role can currently read everything).

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name orders_rls`

Edit the generated `migration.sql`:

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

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

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies cleanly.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task7.mjs`
Expected: `PASS: RLS enabled on orders, sales_rep_isolation policy enforced`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task7.mjs
git commit -m "feat(backend): enable RLS and five-role policy pattern on orders"
```

---

### Task 8: Raw SQL — RLS on `inventory_movements`, `outlet_visits`, `aggregated_sales`

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_territory_rls_extension/migration.sql`
- Create: `backend/scripts/verify-task8.mjs`

**Interfaces:**
- Consumes: `inventory_movements`, `outlet_visits`, `aggregated_sales`, `sales_reps`, `profiles` from earlier tasks.
- Produces: RLS enabled and role-appropriate policies on all three tables — closing the gap flagged as an open follow-up in backend spec §8 (RLS existed only for `orders` until now).

- [ ] **Step 1: Write the verification script (it should fail — RLS not enabled on these tables yet)**

Create `backend/scripts/verify-task8.mjs`:

```js
import { Client } from "pg";
import { randomUUID } from "node:crypto";

const admin = new Client({ connectionString: process.env.DATABASE_URL });

async function asAuthed(authId, fn) {
  const conn = new Client({ connectionString: process.env.DATABASE_URL });
  await conn.connect();
  await conn.query("BEGIN");
  await conn.query("SET LOCAL ROLE authenticated");
  await conn.query(`SET LOCAL request.jwt.claim.sub = '${authId}'`);
  try {
    return await fn(conn);
  } finally {
    await conn.query("ROLLBACK");
    await conn.end();
  }
}

async function main() {
  await admin.connect();

  const productId = randomUUID();
  const repAId = randomUUID();
  const repBId = randomUUID();
  const customerId = randomUUID();
  const routeId = randomUUID();
  await admin.query(
    `INSERT INTO products (product_id, sku_code, product_name, base_price, wholesale_price)
     VALUES ($1, 'SKU-TEST-3', 'Test Product 3', 10.00, 8.00)`,
    [productId]
  );
  await admin.query(
    `INSERT INTO sales_reps (rep_id, name, phone) VALUES ($1, 'Rep A2', '+2340000000006'), ($2, 'Rep B2', '+2340000000007')`,
    [repAId, repBId]
  );
  await admin.query(
    `INSERT INTO routes (route_id, route_name, territory_zone) VALUES ($1, 'Route 1', 'Zone 1')`,
    [routeId]
  );
  await admin.query(
    `INSERT INTO customers (customer_id, business_name, route_id) VALUES ($1, 'Test Shop', $2)`,
    [customerId, routeId]
  );
  const repAAuthId = randomUUID();
  await admin.query(
    `INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, 'repa2@example.com', $2::jsonb)`,
    [repAAuthId, JSON.stringify({ role: "sales_rep", rep_id: repAId })]
  );

  await admin.query(
    `INSERT INTO inventory_movements (movement_id, pool_type, rep_id, product_id, movement_type, qty_delta)
     VALUES (gen_random_uuid(), 'Van_Stock', $1, $2, 'Received', 10),
            (gen_random_uuid(), 'Van_Stock', $3, $2, 'Received', 15)`,
    [repAId, productId, repBId]
  );
  await admin.query(
    `INSERT INTO outlet_visits (visit_id, customer_id, rep_id, route_id)
     VALUES (gen_random_uuid(), $1, $2, $3), (gen_random_uuid(), $1, $4, $3)`,
    [customerId, repAId, routeId, repBId]
  );

  const movementsForA = await asAuthed(repAAuthId, (conn) =>
    conn.query(`SELECT rep_id FROM inventory_movements`)
  );
  const movementReps = movementsForA.rows.map((r) => r.rep_id);
  if (!movementReps.includes(repAId) || movementReps.includes(repBId)) {
    throw new Error(`inventory_movements RLS failed: rep A sees ${JSON.stringify(movementReps)}`);
  }

  const visitsForA = await asAuthed(repAAuthId, (conn) =>
    conn.query(`SELECT rep_id FROM outlet_visits`)
  );
  const visitReps = visitsForA.rows.map((r) => r.rep_id);
  if (!visitReps.includes(repAId) || visitReps.includes(repBId)) {
    throw new Error(`outlet_visits RLS failed: rep A sees ${JSON.stringify(visitReps)}`);
  }

  const { rows: rlsFlags } = await admin.query(
    `SELECT relname, relrowsecurity FROM pg_class
     WHERE relname IN ('inventory_movements', 'outlet_visits', 'aggregated_sales') AND relkind = 'r'`
  );
  for (const row of rlsFlags) {
    if (!row.relrowsecurity) throw new Error(`RLS not enabled on ${row.relname}`);
  }

  console.log("PASS: RLS enforced on inventory_movements, outlet_visits; enabled on aggregated_sales");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => admin.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task8.mjs`
Expected: FAIL — rep A sees both reps' inventory movements (no RLS yet).

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name territory_rls_extension`

Edit the generated `migration.sql`:

```sql
-- inventory_movements: hq_admin unrestricted; supervisor sees their own
-- Supervisor_Hub pool and their team's Van_Stock; sales_rep sees only their
-- own Van_Stock; pickup_agent sees only their own Pickup_Point pool.
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_global_access_movements ON inventory_movements AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'hq_admin')
);

CREATE POLICY supervisor_hub_and_team_van_stock ON inventory_movements AS PERMISSIVE FOR ALL USING (
    EXISTS (
        SELECT 1 FROM profiles p
        WHERE p.profile_id = auth.uid() AND p.role = 'supervisor' AND (
            (inventory_movements.pool_type = 'Supervisor_Hub' AND inventory_movements.supervisor_id = p.associated_supervisor_id)
            OR (inventory_movements.pool_type = 'Van_Stock' AND EXISTS (
                SELECT 1 FROM sales_reps sr WHERE sr.rep_id = inventory_movements.rep_id AND sr.supervisor_id = p.associated_supervisor_id
            ))
        )
    )
);

CREATE POLICY sales_rep_own_van_stock ON inventory_movements AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'sales_rep' AND associated_rep_id = inventory_movements.rep_id)
);

CREATE POLICY pickup_agent_own_pool ON inventory_movements AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'pickup_agent' AND associated_pickup_point_id = inventory_movements.pickup_point_id)
);

-- outlet_visits: hq_admin unrestricted; supervisor sees their team's visits;
-- sales_rep sees only their own. No pickup_agent/customer visibility.
ALTER TABLE outlet_visits ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_global_access_visits ON outlet_visits AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'hq_admin')
);

CREATE POLICY supervisor_team_visits ON outlet_visits AS PERMISSIVE FOR ALL USING (
    EXISTS (
        SELECT 1 FROM profiles p JOIN sales_reps sr ON sr.rep_id = outlet_visits.rep_id
        WHERE p.profile_id = auth.uid() AND p.role = 'supervisor' AND sr.supervisor_id = p.associated_supervisor_id
    )
);

CREATE POLICY sales_rep_own_visits ON outlet_visits AS PERMISSIVE FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'sales_rep' AND associated_rep_id = outlet_visits.rep_id)
);

-- aggregated_sales: read-only for regular roles (only run_sales_aggregator,
-- running as the function owner, ever writes to this table — RLS doesn't
-- apply to the owner regardless of these policies).
ALTER TABLE aggregated_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY hq_global_access_aggregates ON aggregated_sales AS PERMISSIVE FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'hq_admin')
);

CREATE POLICY supervisor_own_aggregates ON aggregated_sales AS PERMISSIVE FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'supervisor' AND associated_supervisor_id = aggregated_sales.supervisor_id)
);

CREATE POLICY sales_rep_own_aggregates ON aggregated_sales AS PERMISSIVE FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE profile_id = auth.uid() AND role = 'sales_rep' AND associated_rep_id = aggregated_sales.rep_id)
);
```

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies cleanly.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task8.mjs`
Expected: `PASS: RLS enforced on inventory_movements, outlet_visits; enabled on aggregated_sales`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task8.mjs
git commit -m "feat(backend): extend RLS to inventory_movements, outlet_visits, aggregated_sales"
```

---

### Task 9: Raw SQL — performance indexes

**Files:**
- Modify: `backend/prisma/migrations/<timestamp>_performance_indexes/migration.sql`
- Create: `backend/scripts/verify-task9.mjs`

**Interfaces:**
- Consumes: `orders`, `outlet_visits`, `aggregated_sales` from earlier tasks.
- Produces: indexes on every FK/date column the RLS policies (Task 7/8) and `run_sales_aggregator` (Task 6) filter or group on — Postgres does not auto-index FK columns (only the referenced PK side), so without these every RLS-filtered query and the daily aggregator full-scans `orders` as it grows.

- [ ] **Step 1: Write the verification script (it should fail — indexes don't exist yet)**

Create `backend/scripts/verify-task9.mjs`:

```js
import { Client } from "pg";

const client = new Client({ connectionString: process.env.DATABASE_URL });

const EXPECTED_INDEXES = [
  "idx_orders_rep_id", "idx_orders_supervisor_id", "idx_orders_route_id",
  "idx_orders_customer_id", "idx_orders_pickup_point_id", "idx_orders_order_date",
  "idx_outlet_visits_rep_id", "idx_outlet_visits_route_id", "idx_outlet_visits_visited_at",
  "idx_aggregated_sales_supervisor_id", "idx_aggregated_sales_rep_id",
];

async function main() {
  await client.connect();
  const { rows } = await client.query(
    `SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)`,
    [EXPECTED_INDEXES]
  );
  const found = new Set(rows.map((r) => r.indexname));
  const missing = EXPECTED_INDEXES.filter((name) => !found.has(name));
  if (missing.length > 0) {
    throw new Error(`missing indexes: ${missing.join(", ")}`);
  }
  console.log(`PASS: all ${EXPECTED_INDEXES.length} performance indexes exist`);
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task9.mjs`
Expected: FAIL — `missing indexes: idx_orders_rep_id, ...`

- [ ] **Step 3: Scaffold and hand-write the migration**

Run: `cd backend && npx prisma migrate dev --create-only --name performance_indexes`

Edit the generated `migration.sql`:

```sql
CREATE INDEX idx_orders_rep_id ON orders(rep_id);
CREATE INDEX idx_orders_supervisor_id ON orders(supervisor_id);
CREATE INDEX idx_orders_route_id ON orders(route_id);
CREATE INDEX idx_orders_customer_id ON orders(customer_id);
CREATE INDEX idx_orders_pickup_point_id ON orders(pickup_point_id);
CREATE INDEX idx_orders_order_date ON orders(order_date);

CREATE INDEX idx_outlet_visits_rep_id ON outlet_visits(rep_id);
CREATE INDEX idx_outlet_visits_route_id ON outlet_visits(route_id);
CREATE INDEX idx_outlet_visits_visited_at ON outlet_visits(visited_at);

CREATE INDEX idx_aggregated_sales_supervisor_id ON aggregated_sales(supervisor_id);
CREATE INDEX idx_aggregated_sales_rep_id ON aggregated_sales(rep_id);
```

- [ ] **Step 4: Apply the migration**

Run: `cd backend && npx prisma migrate dev`
Expected: applies cleanly.

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task9.mjs`
Expected: `PASS: all 11 performance indexes exist`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/migrations backend/scripts/verify-task9.mjs
git commit -m "feat(backend): add performance indexes for RLS-filtered and aggregated queries"
```

---

### Task 10: Seed script for local development

**Files:**
- Create: `backend/prisma/seed.mjs`
- Create: `backend/scripts/verify-task10.mjs`

**Interfaces:**
- Consumes: `@prisma/client` generated from Task 2's schema; every table from Tasks 2–9.
- Produces: a repeatable local dataset — 2 supervisors, 4 reps, 3 routes, 2 pickup points, 5 products, 6 customers, sample orders across both sale-flow types, sample inventory movements, and one `auth.users`/`profiles` pair per role — for future frontend work to develop against.

- [ ] **Step 1: Write the verification script (it should fail — nothing seeded yet)**

Create `backend/scripts/verify-task10.mjs`:

```js
import { Client } from "pg";

const client = new Client({ connectionString: process.env.DATABASE_URL });

async function main() {
  await client.connect();

  const { rows: supervisors } = await client.query(`SELECT COUNT(*)::int AS n FROM supervisors`);
  const { rows: reps } = await client.query(`SELECT COUNT(*)::int AS n FROM sales_reps`);
  const { rows: products } = await client.query(`SELECT COUNT(*)::int AS n FROM products`);
  const { rows: profiles } = await client.query(`SELECT COUNT(DISTINCT role)::int AS n FROM profiles`);

  if (supervisors[0].n < 2) throw new Error(`expected >=2 supervisors, got ${supervisors[0].n}`);
  if (reps[0].n < 4) throw new Error(`expected >=4 sales_reps, got ${reps[0].n}`);
  if (products[0].n < 5) throw new Error(`expected >=5 products, got ${products[0].n}`);
  if (profiles[0].n < 5) throw new Error(`expected profiles covering all 5 roles, got ${profiles[0].n} distinct roles`);

  console.log("PASS: seed data present (supervisors, reps, products, one profile per role)");
}

main()
  .catch((err) => {
    console.error("FAIL:", err.message);
    process.exit(1);
  })
  .finally(() => client.end().catch(() => {}));
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd backend && node --env-file=.env scripts/verify-task10.mjs`
Expected: FAIL — `expected >=2 supervisors, got 0`

- [ ] **Step 3: Write the seed script**

Create `backend/prisma/seed.mjs`:

```js
import { PrismaClient } from "@prisma/client";
import { Client as PgClient } from "pg";

const prisma = new PrismaClient();
const pg = new PgClient({ connectionString: process.env.DATABASE_URL });

async function main() {
  await pg.connect();

  const supA = await prisma.supervisor.create({ data: { name: "Amaka Obi", phone: "+2348010000001" } });
  const supB = await prisma.supervisor.create({ data: { name: "Femi Alade", phone: "+2348010000002" } });

  const repA1 = await prisma.salesRep.create({ data: { name: "Tunde Bello", phone: "+2348020000001", supervisorId: supA.supervisorId } });
  const repA2 = await prisma.salesRep.create({ data: { name: "Chidi Nwosu", phone: "+2348020000002", supervisorId: supA.supervisorId } });
  const repB1 = await prisma.salesRep.create({ data: { name: "Bisi Kolawole", phone: "+2348020000003", supervisorId: supB.supervisorId } });
  const repB2 = await prisma.salesRep.create({ data: { name: "Ifeanyi Eze", phone: "+2348020000004", supervisorId: supB.supervisorId } });

  const route1 = await prisma.route.create({ data: { routeName: "Ikeja Central", territoryZone: "Ikeja", assignedSupervisorId: supA.supervisorId, assignedRepId: repA1.repId } });
  const route2 = await prisma.route.create({ data: { routeName: "Surulere North", territoryZone: "Surulere", assignedSupervisorId: supA.supervisorId, assignedRepId: repA2.repId } });
  const route3 = await prisma.route.create({ data: { routeName: "Lagos Mainland", territoryZone: "Mainland", assignedSupervisorId: supB.supervisorId, assignedRepId: repB1.repId } });

  const pickup1 = await prisma.pickupPoint.create({ data: { pointName: "Ikeja Depot", routeId: route1.routeId, address: "12 Awolowo Rd, Ikeja" } });
  const pickup2 = await prisma.pickupPoint.create({ data: { pointName: "Surulere Kiosk", routeId: route2.routeId, address: "8 Bode Thomas St, Surulere" } });

  const products = await Promise.all(
    [
      { skuCode: "TF-BLK-250", productName: "Teafair Black Tea 250g", category: "Tea", basePrice: "1500.00", wholesalePrice: "1200.00" },
      { skuCode: "TF-GRN-250", productName: "Teafair Green Tea 250g", category: "Tea", basePrice: "1600.00", wholesalePrice: "1280.00" },
      { skuCode: "TF-HIB-100", productName: "Teafair Hibiscus 100g", category: "Herbal", basePrice: "900.00", wholesalePrice: "700.00" },
      { skuCode: "TF-GIN-100", productName: "Teafair Ginger 100g", category: "Herbal", basePrice: "950.00", wholesalePrice: "740.00" },
      { skuCode: "TF-MIX-500", productName: "Teafair Mixed Pack 500g", category: "Bundle", basePrice: "3200.00", wholesalePrice: "2600.00" },
    ].map((p) => prisma.product.create({ data: p }))
  );

  const customers = await Promise.all([
    prisma.customer.create({ data: { businessName: "Iya Basira Stores", routeId: route1.routeId, phone: "+2348030000001" } }),
    prisma.customer.create({ data: { businessName: "Chuks Supermarket", routeId: route1.routeId, phone: "+2348030000002" } }),
    prisma.customer.create({ data: { businessName: "Blessed Mini Mart", routeId: route2.routeId, phone: "+2348030000003" } }),
    prisma.customer.create({ data: { businessName: "Grace Provisions", routeId: route2.routeId, phone: "+2348030000004" } }),
    prisma.customer.create({ data: { businessName: "Kola's Corner Shop", routeId: route3.routeId, phone: "+2348030000005" } }),
    prisma.customer.create({ data: { businessName: "Unity Traders", routeId: route3.routeId, phone: "+2348030000006" } }),
  ]);

  await prisma.order.create({
    data: {
      saleType: "PreSale",
      repId: repA1.repId,
      supervisorId: supA.supervisorId,
      routeId: route1.routeId,
      customerId: customers[0].customerId,
      totalAmount: "3000.00",
      amountPaid: "0.00",
      orderLines: { create: [{ productId: products[0].productId, qtySold: 2, unitPrice: "1500.00" }] },
    },
  });

  await prisma.order.create({
    data: {
      saleType: "StreetCampaign",
      repId: repB1.repId,
      supervisorId: supB.supervisorId,
      totalAmount: "900.00",
      amountPaid: "900.00",
      orderLines: { create: [{ productId: products[2].productId, qtySold: 1, unitPrice: "900.00" }] },
    },
  });

  await prisma.inventoryMovement.create({
    data: { poolType: "VanStock", repId: repA1.repId, productId: products[0].productId, movementType: "Received", qtyDelta: 20 },
  });
  await prisma.inventoryMovement.create({
    data: { poolType: "SupervisorHub", supervisorId: supB.supervisorId, productId: products[2].productId, movementType: "Received", qtyDelta: 50 },
  });

  const roleProfiles = [
    { email: "hq@teafair.dev", role: "hq_admin" },
    { email: "supervisor@teafair.dev", role: "supervisor", associated_supervisor_id: supA.supervisorId },
    { email: "rep@teafair.dev", role: "sales_rep", associated_rep_id: repA1.repId },
    { email: "pickup@teafair.dev", role: "pickup_agent", associated_pickup_point_id: pickup1.pickupPointId },
    { email: null, role: "customer", associated_customer_id: customers[0].customerId },
  ];

  for (const p of roleProfiles) {
    const { rows } = await pg.query(
      `INSERT INTO auth.users (email, raw_user_meta_data) VALUES ($1, $2::jsonb) RETURNING id`,
      [p.email, JSON.stringify({ role: p.role, supervisor_id: p.associated_supervisor_id, rep_id: p.associated_rep_id, pickup_point_id: p.associated_pickup_point_id, customer_id: p.associated_customer_id })]
    );
    console.log(`seeded ${p.role} profile: auth.users.id = ${rows[0].id}`);
  }

  console.log("Seed complete.");
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
    await pg.end().catch(() => {});
  });
```

- [ ] **Step 4: Run the seed**

Run: `cd backend && npx prisma generate && node --env-file=.env prisma/seed.mjs`
Expected: prints one `seeded <role> profile: auth.users.id = ...` line per role, then `Seed complete.`

- [ ] **Step 5: Re-run verification to confirm it passes**

Run: `cd backend && node --env-file=.env scripts/verify-task10.mjs`
Expected: `PASS: seed data present (supervisors, reps, products, one profile per role)`

- [ ] **Step 6: Commit**

```bash
git add backend/prisma/seed.mjs backend/package.json backend/scripts/verify-task10.mjs
git commit -m "feat(backend): add seed script with sample data for local development"
```

---

### Task 11: Assemble the `supabase/migrations/` bundle

**Files:**
- Create: `supabase/config.toml` (via `supabase init`)
- Create: `supabase/migrations/<timestamp>_backend_foundation.sql`
- Create: `supabase/migrations/<timestamp+1>_schedule_daily_aggregation.sql`

**Interfaces:**
- Consumes: all `backend/prisma/migrations/*/migration.sql` files from Tasks 2–9, in order.
- Produces: a single ordered SQL bundle Supabase can apply to the hosted project, proven to run cleanly end-to-end against a fresh database, plus a `pg_cron` schedule for `run_sales_aggregator`.

- [ ] **Step 1: Initialize the Supabase CLI project**

Run: `npx supabase init` (from repo root)
Expected: creates `supabase/config.toml` and `supabase/migrations/` (empty). If `npx supabase` resolves to an unexpected major version (check the printed version against https://github.com/supabase/cli/releases), pin it explicitly (`npx supabase@<version>`) rather than proceeding on an unverified CLI — the same lesson learned from the Prisma CLI mismatch earlier in this plan.

- [ ] **Step 2: Assemble the migration bundle**

Concatenate the eight `migration.sql` files from Tasks 2–9 (in that order — `baseline_schema`, `add_order_line_generated_total`, `inventory_movement_integrity`, `profiles_auth_integration`, `sales_aggregation_function`, `orders_rls`, `territory_rls_extension`, `performance_indexes`) into `supabase/migrations/<timestamp>_backend_foundation.sql`, using today's UTC timestamp in `YYYYMMDDHHMMSS` format as the filename prefix (Supabase CLI's required naming). Do **not** include `backend/docker/init/01-local-auth-stub.sql` or `backend/prisma/seed.mjs` — Supabase provides the real `auth` schema, `auth.uid()`, and `authenticated` role already, and seed data is a local-only convenience.

- [ ] **Step 3: Add the production-only `pg_cron` schedule**

Create `supabase/migrations/<timestamp+1>_schedule_daily_aggregation.sql` (one second after the bundle's timestamp, so it applies second):

```sql
-- Requires the pg_cron extension, available on Supabase's hosted Postgres
-- but not present in the local backend/docker-compose.yml Postgres image.
-- This migration is verified only after being applied to the real Supabase
-- project — see Step 4 below for what IS verified locally.
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'daily-sales-aggregation',
    '0 1 * * *',  -- 01:00 UTC daily
    $$SELECT run_sales_aggregator((CURRENT_DATE - INTERVAL '1 day')::date)$$
);
```

- [ ] **Step 4: Verify the schema bundle (not the cron file) applies cleanly end-to-end against a fresh database**

Run (from repo root, using the already-running `backend` Postgres container):

```bash
docker exec -e PGPASSWORD=teafair_dev $(docker compose -f backend/docker-compose.yml ps -q postgres) \
  psql -U teafair -h localhost -c "CREATE DATABASE supabase_bundle_check"

docker exec -e PGPASSWORD=teafair_dev $(docker compose -f backend/docker-compose.yml ps -q postgres) \
  psql -U teafair -h localhost -d supabase_bundle_check -c "CREATE SCHEMA auth; CREATE TABLE auth.users (id UUID PRIMARY KEY DEFAULT gen_random_uuid()); CREATE ROLE authenticated NOLOGIN;"

docker cp supabase/migrations/. $(docker compose -f backend/docker-compose.yml ps -q postgres):/tmp/supabase_migrations

docker exec -e PGPASSWORD=teafair_dev $(docker compose -f backend/docker-compose.yml ps -q postgres) \
  bash -c 'for f in /tmp/supabase_migrations/*_backend_foundation.sql; do psql -U teafair -h localhost -d supabase_bundle_check -f "$f" || exit 1; done'
```

Expected: the `psql -f` invocation exits 0, no errors. (The `_schedule_daily_aggregation.sql` file is intentionally excluded from this loop — the local Postgres image has no `pg_cron` extension available to install, so this file can only be verified after a real Supabase push, not locally.)

- [ ] **Step 5: Clean up the scratch database**

Run:

```bash
docker exec -e PGPASSWORD=teafair_dev $(docker compose -f backend/docker-compose.yml ps -q postgres) \
  psql -U teafair -h localhost -c "DROP DATABASE supabase_bundle_check"
```

- [ ] **Step 6: Commit**

```bash
git add supabase/config.toml supabase/migrations
git commit -m "feat(backend): assemble supabase/migrations bundle, add daily aggregation cron"
```

---

## Self-review

**Spec coverage:**
- Reference/transactional tables, RBAC, inventory ledger + materialized view, aggregation function — Tasks 2–6.
- RLS: full coverage across `orders`, `inventory_movements`, `outlet_visits`, `aggregated_sales` — Tasks 7–8. This closes the open follow-up in backend spec §8 ("RLS policies for inventory_movements and other territory-scoped tables ... not fully enumerated yet").
- Performance/cost-consciousness (CLAUDE.md's "database computations and network traffic must be minimized") — Task 9 (indexes) and Task 11 Step 3 (`pg_cron` daily schedule, so the aggregator runs once automatically rather than needing the Windows/Web app to remember to trigger it).
- Local dev ergonomics for whoever builds `ui`/`web`/`mobile` next — Task 10 (seed data covering all five roles).
- Route Profitability's commission/fuel-cost data (backend spec §4.5, still flagged "not yet modeled") — correctly out of scope for this plan, not silently dropped.
- Frontend surfaces, `ui`/`web`/`windows`/mobile offline-sync — explicitly out of scope, listed as future plans in the feature/module recap.

**Placeholder scan:** no TBD/TODO; every step has real, runnable code and exact expected output.

**Type consistency:** `Profile.recordedMovements` (Task 2) matches `InventoryMovement.recordedBy` field name and direction; enum `@map` values match every raw-SQL string literal used across tasks (`'Street Campaign'`, `'Van_Stock'`, `'sales_rep'`, etc.); Task 8's policies reference `sales_reps.supervisor_id` (Task 2) and `profiles.associated_supervisor_id`/`associated_rep_id` (Task 2/5) consistently; Task 9's index names match exactly what Task 11's bundle-verification and any future migration would expect.

---

## Agents/subagents to deploy for execution

This plan is eleven strictly sequential tasks — each migration depends on the schema state the previous task left behind (Task 4 alters a table Task 2 created; Task 7/8's RLS policies reference `profiles` columns Task 5 added; Task 11 concatenates files Tasks 2–9 produced in order). That sequential dependency, plus each task having its own clean test-then-implement-then-verify cycle, is exactly what **`superpowers:subagent-driven-development`** is built for: a fresh subagent per task, two-stage review between tasks, so a bad assumption in Task 3 gets caught before Task 4 builds on it rather than discovered after all eleven are done.

Recommendation:
- **Executor per task:** default/general-purpose agent (no need for a reasoning-heavy model) — every task's steps are fully specified above; the executor is running exact commands and pasting exact SQL, not designing anything.
- **Reviewer between tasks:** the subagent-driven-development skill's built-in two-stage review is sufficient — the main thing worth a reviewer's attention is exactly the class of bug this plan has been catching all along (NULL-not-distinct unique constraints, missing `search_path`, mistargeted CHECK logic, missing RLS on a new table), so a review pass that specifically re-checks new constraints/policies against those failure modes is worth calling out to the reviewer explicitly, not just "review the diff." Task 8 in particular (the most novel RLS logic — the supervisor policy's OR'd Supervisor_Hub/team-Van_Stock condition) deserves a closer read than the others.
- **No specialized code-review agent needed** beyond that — this is schema/SQL, not application logic with the usual bug classes (null derefs, race conditions, etc.) that a dedicated code-reviewer agent targets.

---
