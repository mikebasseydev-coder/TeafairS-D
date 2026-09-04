# TEFAIR Serverless RTM Platform — Design Spec

**Date:** 2026-09-03
**Status:** Draft for review
**Supersedes:** the data-model and architecture portions of
`2026-08-25-backend-aggregator-platform-design.md`,
`2026-08-26-backend-plan-map-and-core-domain-modules-design.md`, and
`2026-08-25-rtm-frontend-ui-caching-design.md`. Makes the
`2026-08-25-backend-foundation.md` plan (Prisma/Docker) obsolete.

---

## 1. Why this spec exists

TEFAIR is pivoting to a **cost-managed, fully serverless** architecture. There is
no dedicated server, no container orchestration, no DevOps. The entire backend is
Supabase: Postgres, Auth (with MFA), Storage, one Edge Function, and `pg_cron`.
Two client apps talk to it directly:

- **`apps/mobile-android`** — React Native, the field app (sales agents, depot
  reps, warehouse managers, fintech agents)
- **`apps/desktop-windows`** — React Native Windows, the HQ app (admins, regional
  managers, auditors). This replaces the previously-planned Next.js web platform.
  There is no web target.

The flagship business capability is the Route-to-Market omni-channel sales and
inventory platform, plus a **receivables-factoring feature** ("Micro / Invoice
Discount") that sells credit invoices to Fintech agents (OPay, PalmPay,
Moniepoint, …) at a discount to accelerate cash flow and offload default risk.

### The cost objective, made concrete

Minimising Supabase spend drives the whole design:

- Dashboards read **cache tables** refreshed on a schedule — never live views or
  live aggregation over raw tables.
- The **entire write path is `SECURITY DEFINER` Postgres RPC functions**. An RPC
  call is a single database round-trip, billed like a query. Edge Function
  invocations are metered; we use exactly one.
- Inventory and financial balances are an **append-only ledger + an
  RPC-maintained cache**, never recomputed on read, never a mutable balance
  column touched by clients.
- RLS policies use `(select auth.uid())` and `SECURITY DEFINER` helper functions
  — no per-row correlated subqueries.
- Indexes are matched exactly to RLS predicates and RPC filters. No speculative
  indexes (they cost storage and slow writes).
- Realtime is used in exactly one place (a fintech agent's invoice inbox).
  Everything else polls cache tables on screen focus.
- Notifications are batched through a single outbox drained once per minute.

---

## 2. What success looks like

1. **Runs entirely on Supabase.** Deploy is `supabase db push` +
   `supabase functions deploy notify`. No server, no container, no second vendor.
2. **Cost stays flat as volume grows.** Every dashboard view is O(1) cache-table
   reads; every mutation is one RPC call; notifications are one Edge invocation
   per minute regardless of traffic. 10× the orders does not 10× the bill beyond
   raw storage growth. Target: stays within the Supabase Pro tier for the first
   operating year.
3. **No write bypasses validation.** The `authenticated` role holds **zero**
   INSERT/UPDATE/DELETE grants on business tables. A hostile insert from the
   client fails on every table. Every mutation runs through an RPC that checks
   identity, zone, and business rules inside one transaction.
4. **Wrong entries are contained.** Field entries land `PENDING` and move only
   provisional balances. Mistakes are corrected by reversal rows, never edits.
   The ledger reconciles to the cache every night (drift alert = 0). Every
   sensitive change is in `audit_logs`.
5. **The factoring loop closes without HQ touching the database.** A field agent
   registers an outlet and a fintech agent, HQ verifies both, the agent places an
   order, factors it, the fintech funds it (recorded and finance-verified), the
   fintech records collections, the invoice reaches `COLLECTED`, and
   `fintech_agent_stats` + `customer_credit_profile` reflect it.
6. **Both apps ship.** Signed `Teafair.apk` and `Teafair.msix`, built from
   `apps/`, sharing `packages/shared-*`, talking only to Supabase.
7. **RLS performance holds.** `EXPLAIN` on every hot list/dashboard query shows
   index usage, not sequential scans; no policy runs a per-row correlated
   subquery.
8. **Offline tolerance.** Every RPC is idempotent on a client-supplied key. A
   retried submission over a flaky connection never double-writes.

---

## 3. Architecture

### 3.1 Repository layout

```
teafair/
├── apps/
│   ├── mobile-android/          # React Native — field app
│   └── desktop-windows/         # React Native Windows — HQ app
├── packages/
│   ├── shared-types/            # generated Supabase types + domain models
│   ├── shared-utils/            # money math, haversine, formatting, idempotency keys
│   ├── shared-hooks/            # data hooks over the Supabase client
│   ├── shared-components/       # cross-app RN UI primitives
│   └── validation-schemas/      # Zod schemas mirroring every RPC's args
├── supabase/
│   ├── migrations/              # ordered SQL — the production source of truth
│   ├── seeds/
│   ├── functions/notify/        # the only Edge Function
│   └── config.toml
├── build/                       # Teafair.apk, Teafair.msix
└── scripts/                     # build-android, build-windows, deploy-supabase
```

Package manager: **pnpm** workspaces. The old `frontend/` (`core` + `mobile`
Expo scaffold) and `backend/` (Prisma/Docker) are removed; see §12 for migration.

### 3.2 Write path

Clients never write to business tables. Every mutation is a call to a
`SECURITY DEFINER` function in a private schema, exposed as an RPC:

```
client → supabase.rpc('place_order', { ... }) → Postgres function (one txn)
```

Each RPC:

- pins `SET search_path = ''` (or an explicit schema list),
- resolves the caller with `(select auth.uid())` and checks role/zone **inside
  the function body**,
- takes a `p_idempotency_key uuid` and returns the prior result if the key was
  already used,
- performs all reads and writes in a single implicit transaction,
- writes the append-only ledger row(s) and updates the cache table(s) together,
- returns a typed row or a structured error.

Business tables `GRANT SELECT` to `authenticated` and nothing else. RLS then
scopes what each role can read.

### 3.3 Edge Functions

**One, at launch:** `notify` — drains the `notifications_outbox` table and sends
SMS (and later push) through an external gateway. Invoked once per minute by
`pg_cron`, so cost is fixed regardless of message volume.

Everything else that a naive design would make an Edge Function is either an RPC
(pure DB logic) or a `pg_cron` SQL job (scheduled pure-SQL work). A second Edge
Function appears only if/when fintech-provider payment APIs are integrated — and
it will call the same RPCs.

### 3.4 Scheduled jobs (`pg_cron`, pure SQL unless noted)

| Job | Cadence | Purpose |
|---|---|---|
| `run_daily_rollup()` | nightly + hourly for current day | populate `daily_sales_rollup` |
| `refresh_zone_health()` | every 20 min | populate `zone_health` |
| `refresh_fintech_stats()` | every 30 min | populate `fintech_agent_stats`, `fintech_program_health` |
| `expire_stale_transfers()` | hourly | `PENDING` past `expires_at` → `EXPIRED`, release reservation |
| `flag_overdue_invoices()` | nightly | past `collection_deadline` and not `COLLECTED` → alert; auto-`DEFAULTED` after grace |
| `reconcile_stock_balances()` | nightly | recompute balances from ledger, alert on any drift |
| `reconcile_financials()` | nightly | ledger vs `outlet_balances` / `customer_credit_profile`, alert on drift |
| `run_fraud_scans()` | nightly | the five factoring fraud rules → alerts |
| `drain_notifications_outbox()` | every 1 min | invoke the `notify` Edge Function |

### 3.5 Realtime

One channel: a `FINTECH_AGENT` subscribes to `postgres_changes` on
`invoice_discounts` filtered to `fintech_agent_id = <their id>`, so newly offered
invoices and status changes appear without polling. Every other screen refetches
on focus. HQ dashboards poll their cache tables on an interval.

### 3.6 Extensions

`pgcrypto` only (`gen_random_uuid()`, `crypt()` / `gen_salt('bf', 12)` for PIN
hashing). **No `uuid-ossp`, no PostGIS.** GPS proximity uses a `haversine_km()`
SQL helper against a warehouse's stored `latitude`/`longitude` + `radius_km`.

### 3.7 Auth & MFA

- `profiles.id` **is** `auth.users.id` (shared primary key). No surrogate
  `user_id`/`auth_id` split — that pattern forces a join in every RLS policy.
- MFA is Supabase Auth native (`auth.mfa_factors`), enforced for all staff and
  fintech roles. No MFA-secret columns in application tables.
- A trigger `handle_new_user()` on `auth.users` insert creates the matching
  `profiles` row (role and zone from signup metadata; default `FIELD_AGENT` /
  `PENDING_VERIFICATION`).
- Fintech agents self-sign-up in the app with **phone OTP**, then bind to a
  pending record via `link_fintech_agent(invite_code)` (see §7).
- Session tokens are stored in platform-secure storage (`react-native-keychain`
  on Android, the equivalent credential store on Windows) — never plain
  `AsyncStorage`.

---

## 4. Roles & access model

| Role | Tier | App | Scope |
|---|---|---|---|
| `SUPER_ADMIN` | HQ | desktop-windows | global; destructive/config actions |
| `ADMIN` | HQ | desktop-windows | global; master data, users, finance, fintech program |
| `REGIONAL_MANAGER` | HQ | desktop-windows | assigned zones (`zone_managers`) |
| `AUDITOR` | HQ | desktop-windows | global **read-only** + reconciliation/compliance tools |
| `WAREHOUSE_MANAGER` | field | mobile-android | one warehouse (`profiles.warehouse_id`) |
| `INFORMAL_REP` | field | mobile-android | one zone; runs a depot (field-agent duties + depot stock) |
| `FIELD_AGENT` | field | mobile-android | one zone (`profiles.market_zone_id`) |
| `FINTECH_AGENT` | external | mobile-android | own invoices, own stats, outlets in `operation_zone_id` (read) |

No `CUSTOMER` role at launch. Outlets (shop owners) are data records created by
field agents; they do not authenticate. View-only customer login is a planned
fast-follow (§11).

**RLS helper functions** (private schema, `SECURITY DEFINER STABLE`, `EXECUTE`
revoked from `anon`): `auth_uid()`, `current_role()`, `current_zone()`,
`is_hq()`, `managed_warehouse()`, `is_zone_manager_of(zone_id)`,
`current_fintech_agent()`.

Standard SELECT pattern per zone-scoped table:

```sql
create policy <t>_select on <t> for select using (
  (select private.is_hq())
  or market_zone_id = (select private.current_zone())
  or (select private.is_zone_manager_of(market_zone_id))
);
```

`profiles` allows a narrow self-`UPDATE` (display name, phone) guarded by a
`BEFORE UPDATE` trigger that rejects changes to `role`, `status`, `market_zone_id`,
`warehouse_id`. All other writes are RPC-only.

---

## 5. Data model

Money is `NUMERIC(15,2)`; quantities `NUMERIC(14,3)` (fractional units exist);
timestamps `TIMESTAMPTZ`. All PKs `uuid DEFAULT gen_random_uuid()` except
`profiles` (= `auth.users.id`). Every table has `created_at`; mutable tables have
`updated_at` maintained by a shared trigger.

### 5.1 Enums (stable sets)

| Enum | Values |
|---|---|
| `user_role` | SUPER_ADMIN, ADMIN, REGIONAL_MANAGER, AUDITOR, WAREHOUSE_MANAGER, INFORMAL_REP, FIELD_AGENT, FINTECH_AGENT |
| `user_status` | PENDING_VERIFICATION, ACTIVE, SUSPENDED, LOCKED |
| `entity_status` | PENDING_VERIFICATION, ACTIVE, SUSPENDED |
| `zone_tier` | INTER_STATE, LAGOS_INTRA_CITY, OTHER_INTRA_STATE |
| `warehouse_type` | CENTRAL_DEPOT, INFORMAL_REP_DEPOT, MICRO_FULFILLMENT, DARK_STORE |
| `custody_type` | CONSIGNMENT, OUTRIGHT, HYBRID, TEMPORARY |
| `movement_type` | RECEIVED, SOLD, RESERVED, UNRESERVED, TRANSFER_OUT, TRANSFER_IN, RETURNED, DAMAGED, COUNT_ADJUSTMENT, REVERSAL |
| `payment_channel` | DIRECT_CASH, CASH_AGENT, FINTECH_FACTORED |
| `alert_severity` | INFO, WARNING, CRITICAL, EMERGENCY |
| `fintech_provider` | OPAY, PALMPAY, MONIEPOINT, PAYSTACK, FLUTTERWAVE, KUDA, CARBON, PAGA, FIRST_BANK_MOBILE, OTHER |
| `fintech_status` | PENDING_VERIFICATION, ACTIVE, SUSPENDED, DEACTIVATED, UNDER_REVIEW |
| `discount_event_type` | FUNDED, COLLECTION, DEFAULT_DECLARED, SETTLED, DISPUTED, CANCELLED |

### 5.2 Workflow statuses (`text` + `CHECK` — evolve without `ALTER TYPE`)

| Column | Allowed values |
|---|---|
| `orders.status` | PENDING, CONFIRMED, DISPATCHED, DELIVERED, CANCELLED |
| `inventory_transfers.status` | PENDING, IN_TRANSIT, DELIVERED, RECONCILED, DISPUTED, CANCELLED, EXPIRED |
| `invoice_discounts.status` | PENDING, FUNDED, COLLECTING, COLLECTED, SETTLED, DEFAULTED, DISPUTED, CANCELLED |
| `stock_counts.status` | PENDING_REVIEW, ACCEPTED, REJECTED |
| `transfer_disputes.status` | OPEN, RESOLVED |
| `settlements.status` | PENDING, PROCESSING, COMPLETED, FAILED, REVERSED |
| `alerts.status` | OPEN, ACKNOWLEDGED, RESOLVED |

### 5.3 Identity & geography

**`profiles`** — `id` (PK = auth.users.id), `role`, `status`, `first_name`,
`last_name`, `phone` (unique), `email`, `market_zone_id?`, `warehouse_id?`,
`last_login_at`. `chk_profile_scoping`: `WAREHOUSE_MANAGER` requires
`warehouse_id`; `FIELD_AGENT`/`INFORMAL_REP` require `market_zone_id`; HQ roles
have neither; `FINTECH_AGENT` has neither (scope lives on `fintech_agents`).

**`zone_managers`** — (`market_zone_id`, `profile_id`) PK. Which regional manager
covers which zones.

**`market_zones`** — `name` (unique), `lga`, `state`, `tier`, `centroid_lat`,
`centroid_lng`, `radius_km`, `is_active`.

**`warehouses`** — `name` (unique), `code` (unique), `type`, `custody_type`,
`market_zone_id` (FK, not null), `manager_profile_id?`, `address`, `latitude`,
`longitude`, `capacity`, `debt_limit`, `verification_pin_hash`, `pin_changed_at`,
`pin_attempts`, `pin_locked_until`, `is_active`.

**`outlets`** — `business_name`, `contact_name`, `phone`, `market_zone_id` (FK,
not null), `address`, `latitude`, `longitude`, `credit_limit` (default 0),
`registered_by` (FK profile), `status` (`entity_status`), `verified_by`,
`verified_at`.

**`products`** — `sku` (unique), `barcode?` (unique), `name`, `category`,
`description`, `unit_price`, `wholesale_price`, `cost_price`, `weight_kg`,
`is_perishable`, `shelf_life_days`, `reorder_point`, `is_active`. **The RPC layer
is the only reader the client trusts for price** — clients never send prices.

### 5.4 Inventory (ledger + cache)

**`inventory_movements`** — INSERT-only, no UPDATE/DELETE policy ever.
`warehouse_id` (FK), `product_id` (FK), `batch_number?`, `expiry_date?`,
`movement_type`, `qty_delta` (signed, `CHECK qty_delta <> 0`), `reference_type`
(`order|transfer|count|adjustment|receipt`), `reference_id?`, `reason?`,
`reversal_of?` (self-FK), `recorded_by` (FK profile), `occurred_at`,
`idempotency_key` (unique).

**`stock_balances`** — RPC-maintained cache. PK (`warehouse_id`, `product_id`,
`batch_number`). `on_hand`, `reserved`, `damaged`, `updated_at`.
`CHECK on_hand >= 0 AND reserved >= 0 AND reserved <= on_hand`.
Available = `on_hand - reserved`. `reconcile_stock_balances()` recomputes from the
ledger nightly and alerts on any mismatch.

### 5.5 Orders

**`orders`** — `order_number` (unique, `ORD-YYYYMMDD-NNNN`), `outlet_id` (FK),
`agent_id` (FK profile), `market_zone_id` (FK), `source_warehouse_id` (FK),
`status`, `payment_channel`, `subtotal`, `discount` (default 0), `tax`
(default 0), `total` **GENERATED** `subtotal - discount + tax`, `amount_paid`
(default 0), `notes`, `idempotency_key` (unique), `created_by`, `confirmed_by`,
`confirmed_at`.

**`order_items`** — `order_id` (FK, cascade), `product_id` (FK), `quantity`
(`CHECK > 0`), `unit_price` (set by RPC from `products`), `line_total`
**GENERATED** `quantity * unit_price`. `UNIQUE(order_id, product_id)`.

Two-stage: an order created by a field agent is `PENDING` and only holds a
provisional stock reservation. `confirm_order` (warehouse manager / HQ) commits
it.

### 5.6 Transfers

**`inventory_transfers`** — `waybill_number` (unique), `source_warehouse_id` (FK),
`dest_warehouse_id` (FK, `CHECK <> source`), `source_zone_id`, `dest_zone_id`,
`is_cross_zone` **GENERATED** `source_zone_id <> dest_zone_id`, `status`,
`total_value`, `item_count`, `initiated_by` (FK), `idempotency_key` (unique),
`dispatched_at`, `delivered_at`, `reconciled_at`, `expires_at`.

**`transfer_items`** — `transfer_id` (FK, cascade), `product_id` (FK),
`batch_number?`, `qty_sent` (`CHECK > 0`), `qty_received?`, `unit_value`.
`UNIQUE(transfer_id, product_id, batch_number)`.

**`transfer_verifications`** — INSERT-only. `transfer_id` (FK), `party`
(`SENDER|RECEIVER`), `verified_by` (FK profile), `pin_verified` (bool),
`gps_lat`, `gps_lng`, `gps_distance_m`, `photo_path` (Storage key), `verified_at`.
Replaces the ~20 `sender_*`/`receiver_*` columns in the earlier draft.

**`transfer_disputes`** — `transfer_id` (FK), `opened_by` (FK), `reason`,
`status`, `resolution?`, `resolved_by?`, `resolved_at?`.

### 5.7 Stock counts

**`stock_counts`** — `warehouse_id` (FK), `product_id` (FK), `batch_number?`,
`counted_qty`, `system_qty` (snapshot at submission), `discrepancy` **GENERATED**
`counted_qty - system_qty`, `counted_by` (FK), `status`, `reviewed_by?`,
`reviewed_at?`, `note?`. `ACCEPTED` → `review_stock_count` posts a
`COUNT_ADJUSTMENT` movement.

### 5.8 Payments & customer debt

**`payments`** — INSERT-only. `outlet_id` (FK), `order_id?` (FK), `amount`
(`CHECK > 0`), `channel` (`payment_channel`), `method`, `reference`, `received_by`
(FK profile), `verified_by?`, `verified_at?`, `occurred_at`, `idempotency_key`
(unique).

**`outlet_balances`** — RPC-maintained cache. `outlet_id` (PK), `total_invoiced`,
`total_paid`, `balance` **GENERATED** `total_invoiced - total_paid`,
`open_invoice_count`, `updated_at`.

**`customer_ledger`** — INSERT-only. `outlet_id` (FK), `entry_type`
(`INVOICE|PAYMENT|DEFAULT|ADJUSTMENT`), `amount` (signed), `reference_type`,
`reference_id`, `description`, `recorded_by`, `occurred_at`.

### 5.9 Receivables factoring

Money flow (corrected from the earlier draft): the fintech agent pays TEFAIR
**90% of the invoice upfront**; the fintech then collects **100% from the
customer** over the term and keeps the 10% by construction. **TEFAIR never pays
the fintech.** `settlements` rows exist only for exceptions (refund, promotional
bonus, correction).

**`fintech_agents`** — `profile_id` (FK, unique — the agent's login),
`provider`, `provider_account_id`, `full_name`, `phone` (unique), `email?`,
`business_name?`, `business_address?`, `operation_zone_id` (FK, not null),
`registered_by` (FK), `status` (`fintech_status`), `verified_by?`,
`verified_at?`, `secret_pin_hash`, `pin_changed_at`, `pin_attempts`,
`pin_locked_until`, `funding_capacity?` (soft cap), `invite_code?` (nullable,
consumed on link). `UNIQUE(provider, provider_account_id)`. No stored running
totals.

**`fintech_agent_stats`** — cache. `fintech_agent_id` (PK),
`total_discounted_volume`, `total_earnings`, `outstanding_collections`,
`total_transactions`, `defaulted_count`, `default_rate`, `avg_collection_days`,
`last_txn_at`, `updated_at`.

**`invoice_discounts`** — `invoice_number` (unique, `INV-YYYYMMDD-NNNN`),
`order_id` (FK, **unique** — one discount per order), `outlet_id` (FK),
`sales_agent_id` (FK), `fintech_agent_id` (FK), `market_zone_id` (FK),
`discount_rate` (`CHECK BETWEEN 5 AND 25`), `invoice_total`, `discount_amount`
**GENERATED** `invoice_total * discount_rate / 100`, `fintech_payment_amount`
**GENERATED** `invoice_total - discount_amount`, `customer_payment_amount`
(= `invoice_total`), `invoice_date`, `due_date`, `collection_deadline`
(`invoice_date + 45`), `status`, `funded_at?`, `funding_reference?`,
`funding_verified_by?`, `funding_verified_at?`, `collected_at?`, `defaulted_at?`,
`default_handled_by?`, `default_resolution?`, `created_by`.

**`invoice_discount_events`** — INSERT-only. `invoice_discount_id` (FK),
`event_type` (`discount_event_type`), `amount?`, `reference?`, `actor_id` (FK),
`pin_verified` (bool), `note?`, `occurred_at`, `idempotency_key` (unique). This is
the audit trail; parent `status` is derived by the RPC that writes the event.

**`settlements`** — `settlement_reference` (unique), `fintech_agent_id` (FK),
`invoice_discount_id` (FK), `settlement_type` (`EARNINGS|REFUND|BONUS`), `amount`,
`status`, `method?`, `reference?`, `processed_by`, `processed_at?`. Exceptions
only.

**`customer_credit_profile`** — cache. `outlet_id` (PK), `credit_limit`,
`outstanding_balance`, `open_invoices`, `completed_invoices`,
`defaulted_invoices`, `on_time_rate`, `updated_at`. No algorithmic score at
launch — `credit_limit` is set manually by HQ; the profile is the decision
support.

### 5.10 Alerts & audit

**`alerts`** — `alert_type`, `severity`, `market_zone_id?`, `warehouse_id?`,
`fintech_agent_id?`, `outlet_id?`, `title`, `message`, `context` (jsonb, small),
`status`, `acknowledged_by?`, `acknowledged_at?`, `resolved_by?`,
`resolved_at?`, `auto_resolved`. Written by RPCs and batch jobs; ack/resolve via
RPC.

**`audit_logs`** — INSERT-only, written by a generic `SECURITY DEFINER` trigger
on sensitive tables. `table_name`, `record_id`, `action`, `actor_id`, `diff`
(jsonb), `occurred_at`. Read policy: `ADMIN`, `SUPER_ADMIN`, `AUDITOR`.

### 5.11 Aggregation caches

**`daily_sales_rollup`** — `summary_date`, `market_zone_id?`, `warehouse_id?`,
`agent_id?`, `order_count`, `gross_revenue`, `cash_collected`, `factored_volume`,
`computed_at`. Unique grouping key with `COALESCE(dim, '00000000-…')` so
company-wide and per-dimension rollups coexist.

**`zone_health`** — `market_zone_id` (PK), `warehouse_count`, `outlet_count`,
`active_agents`, `stock_value`, `outlet_debt`, `debt_utilization_pct`,
`open_alerts`, `computed_at`.

**`fintech_program_health`** — one row per zone plus a global row.
`active_agents`, `total_factored_volume`, `total_earnings`,
`outstanding_collections`, `default_rate`, `avg_collection_days`,
`disputes_open`, `computed_at`.

### 5.12 Notifications

**`notifications_outbox`** — INSERT-only by RPCs. `channel` (`sms|push`),
`recipient`, `template`, `params` (jsonb), `status` (`PENDING|SENT|FAILED`),
`attempts`, `sent_at?`, `created_at`. Drained every minute by `notify`.

### 5.13 Storage buckets

All private. `transfer_photos`, `count_photos`, `signatures`, `product_images`.
Access via signed URLs minted by RPCs / policies scoped to the requesting role's
zone.

---

## 6. Integrity model (how wrong entries are stopped)

Six layers, all near-zero incremental cost:

1. **Structural constraints** — `CHECK`s (`quantity > 0`, `amount_paid <= total`,
   GPS ranges, valid status), FKs, generated totals (`line_total`, `total`,
   `discount_amount`), unique keys (order/invoice/waybill numbers, idempotency
   keys), `chk_profile_scoping`.
2. **Server owns the facts the client shouldn't supply** — the client sends
   `product_id` + `quantity`; the RPC reads price, credit limit, zone, custody
   type from the database. The client cannot send a price or a total.
3. **Business rules in the RPC, one transaction** — identity + zone + stock
   availability + debt limit checked atomically before any write; all-or-nothing.
4. **Two-stage posting** — nothing a field user enters alone is final.
   `PENDING` orders hold provisional reservations; a second party confirms.
   Transfers need sender dispatch + receiver receipt; mismatch → `DISPUTED`.
5. **Immutable history** — `inventory_movements`, `transfer_verifications`,
   `payments`, `customer_ledger`, `invoice_discount_events`, `audit_logs` have no
   UPDATE/DELETE policy. Corrections are compensating rows (`REVERSAL`,
   `ADJUSTMENT`) with a reason and an approver.
6. **Batch anomaly detection** — nightly `run_fraud_scans()` plus ledger/cache
   reconciliation jobs raise `alerts`; nothing runs per-write.

### Factoring fraud rules (nightly, → `alerts`)

| Rule | Trigger |
|---|---|
| Default rate | fintech agent's rolling default rate > 5% |
| Volume cap | fintech agent > 10 new invoice discounts in a day |
| Payment pattern | collection events clustered unnaturally (e.g. full amount day-1 repeatedly, or all round numbers) |
| Zone match | invoice's outlet / fintech / agent not all in one zone (also blocked at RPC time; the scan catches drift) |
| Collusion | same (fintech agent, outlet) pair above a frequency threshold in a window |

---

## 7. RPC surface (the entire write API)

Each is `SECURITY DEFINER`, idempotent on `p_idempotency_key`, role-checked
internally. Grouped by area.

### Onboarding
- `register_outlet(p_business_name, p_contact_name, p_phone, p_address, p_lat, p_lng, p_credit_limit, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; zone from caller; status `PENDING_VERIFICATION`.
- `verify_outlet(p_outlet_id)` — `ADMIN`/`REGIONAL_MANAGER` (of the zone).
- `register_fintech_agent(p_provider, p_provider_account_id, p_full_name, p_phone, p_email, p_business_name, p_business_address, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; creates a `fintech_agents` row (no `profile_id` yet), status `PENDING_VERIFICATION`, returns a one-time `invite_code`.
- `link_fintech_agent(p_invite_code)` — caller is a freshly phone-OTP-signed-up user; binds `fintech_agents.profile_id = auth.uid()`, sets `profiles.role = FINTECH_AGENT`.
- `verify_fintech_agent(p_fintech_agent_id)` — `ADMIN`/`REGIONAL_MANAGER`; status `ACTIVE`; generates the 6-digit transaction PIN, stores the bcrypt hash, queues an SMS.
- `set_fintech_status(p_fintech_agent_id, p_status, p_reason)` — `ADMIN`.
- `rotate_warehouse_pin(p_warehouse_id)` / `rotate_fintech_pin(p_fintech_agent_id)` — `ADMIN`; new PIN, SMS.

### Orders & payments
- `place_order(p_outlet_id, p_source_warehouse_id, p_items jsonb, p_payment_channel, p_notes, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; validates zone, outlet `ACTIVE`, each product `is_active` and stocked, computes prices, atomically checks `available >= qty` and reserves (`RESERVED` movement + `stock_balances`), inserts `orders` `PENDING` + `order_items`, writes `customer_ledger` `INVOICE`, updates `outlet_balances`.
- `confirm_order(p_order_id)` — `WAREHOUSE_MANAGER`(source)/`ADMIN`; `PENDING → CONFIRMED`.
- `dispatch_order(p_order_id)` — `WAREHOUSE_MANAGER`; `CONFIRMED → DISPATCHED`.
- `deliver_order(p_order_id, p_signature_path)` — `FIELD_AGENT`; `DISPATCHED → DELIVERED`, converts reservation to `SOLD`.
- `cancel_order(p_order_id, p_reason)` — releases reservation (`UNRESERVED`), reverses ledger.
- `record_payment(p_outlet_id, p_order_id, p_amount, p_channel, p_method, p_reference, p_idempotency_key)` — `FIELD_AGENT`/`WAREHOUSE_MANAGER`; inserts `payments`, `customer_ledger` `PAYMENT`, updates `outlet_balances`.
- `verify_payment(p_payment_id)` — `ADMIN`/`AUDITOR` (finance).

### Transfers
- `initiate_transfer(p_source_warehouse_id, p_dest_warehouse_id, p_items jsonb, p_idempotency_key)` — `WAREHOUSE_MANAGER`(source)/`ADMIN`; reserves at source, sets `expires_at`, flags `is_cross_zone`.
- `verify_transfer(p_transfer_id, p_party, p_pin, p_gps_lat, p_gps_lng, p_photo_path)` — the source/dest warehouse manager; `haversine_km` vs the relevant warehouse (`<= radius_km`, tighter for same-zone), bcrypt PIN check with 5-attempt/15-min lockout, inserts `transfer_verifications`, advances `PENDING → IN_TRANSIT` when the sender verifies.
- `mark_transfer_delivered(p_transfer_id)` — carrier/receiver; `IN_TRANSIT → DELIVERED`.
- `reconcile_transfer(p_transfer_id, p_received jsonb)` — dest `WAREHOUSE_MANAGER`; sets `qty_received` per line, posts `TRANSFER_OUT` at source and `TRANSFER_IN` at dest, `DELIVERED → RECONCILED`, or opens a `transfer_disputes` row and `→ DISPUTED` on any mismatch.
- `resolve_transfer_dispute(p_transfer_id, p_resolution, p_adjustments jsonb)` — `REGIONAL_MANAGER`/`ADMIN`; posts adjustment movements, `→ RECONCILED`.

### Counts & adjustments
- `submit_stock_count(p_warehouse_id, p_lines jsonb)` — `WAREHOUSE_MANAGER`/`INFORMAL_REP`; snapshots `system_qty` per line.
- `review_stock_count(p_count_id, p_decision, p_note)` — `REGIONAL_MANAGER`/`ADMIN`; `ACCEPTED` → `COUNT_ADJUSTMENT` movement.
- `post_adjustment(p_warehouse_id, p_product_id, p_batch_number, p_qty_delta, p_reason)` — `ADMIN`; explicit `REVERSAL`/adjustment movement with reason.
- `receive_stock(p_warehouse_id, p_lines jsonb, p_reference)` — `WAREHOUSE_MANAGER`; `RECEIVED` movements (inbound supply, not a transfer).

### Factoring
- `create_invoice_discount(p_order_id, p_fintech_agent_id, p_discount_rate, p_idempotency_key)` — `FIELD_AGENT`; order belongs to caller, is `CONFIRMED`+, not already discounted; fintech `ACTIVE` and same zone; computes amounts, `due_date`/`collection_deadline`, status `PENDING`; `customer_ledger` `INVOICE`; queues fintech SMS + realtime.
- `accept_invoice_discount(p_invoice_discount_id)` / `decline_invoice_discount(p_invoice_discount_id, p_reason)` — `FINTECH_AGENT` (own).
- `record_fintech_funding(p_invoice_discount_id, p_amount, p_reference)` — `FINTECH_AGENT` (own) or `ADMIN`; inserts `FUNDED` event, status `PENDING → FUNDED` (provisional).
- `verify_fintech_funding(p_invoice_discount_id)` — `ADMIN`/`AUDITOR` (finance); confirms the 90% landed, status `FUNDED → COLLECTING`, releases the invoice to the customer.
- `record_fintech_collection(p_invoice_discount_id, p_amount, p_reference, p_pin, p_idempotency_key)` — `FINTECH_AGENT` (own); bcrypt PIN check; inserts `COLLECTION` event; when cumulative `>= customer_payment_amount` → status `COLLECTED`, `collected_at`, updates `fintech_agent_stats` + `customer_credit_profile`, `customer_ledger` `PAYMENT`.
- `declare_default(p_invoice_discount_id, p_note)` — `FINTECH_AGENT` (own) or batch job; status `→ DEFAULTED`, `customer_ledger` `DEFAULT`, alert, credit profile update.
- `resolve_default(p_invoice_discount_id, p_resolution)` — `REGIONAL_MANAGER`/`ADMIN`.
- `dispute_invoice_discount(p_invoice_discount_id, p_reason)` — `FINTECH_AGENT` or `FIELD_AGENT`; `→ DISPUTED`, alert.
- `resolve_invoice_dispute(p_invoice_discount_id, p_resolution, p_new_status)` — `REGIONAL_MANAGER`/`ADMIN`.
- `process_settlement(p_invoice_discount_id, p_type, p_amount, p_method, p_reference)` — `ADMIN`; `REFUND`/`BONUS`/correction only.

### Alerts & master data
- `acknowledge_alert(p_alert_id)` / `resolve_alert(p_alert_id, p_note)` — role-appropriate to the alert's scope.
- `upsert_product(...)`, `upsert_warehouse(...)`, `upsert_market_zone(...)`,
  `assign_zone_manager(...)`, `invite_staff(p_email, p_role, p_zone_or_warehouse)` — `ADMIN`/`SUPER_ADMIN`.

---

## 8. Screens & dashboards by role

### 8.1 `apps/mobile-android`

#### FIELD_AGENT
| Screen | Purpose | Data source |
|---|---|---|
| Login / MFA / Forgot password | auth | Supabase Auth |
| **Dashboard — "My Day"** | today's order count & value, pending confirmations, my open alerts, outstanding outlet debt in zone | `daily_sales_rollup` (agent), `alerts`, `outlet_balances` |
| Outlets list + map | outlets in my zone, search, credit status | `outlets` + `outlet_balances` (RLS) |
| Outlet detail | balance, credit limit, order & payment history | `outlets`, `customer_ledger`, `orders` |
| Register outlet | capture business, contact, GPS, requested limit | `register_outlet` |
| New order | outlet → warehouse → add products/qty → channel → review totals → submit | `products`, `stock_balances` (read), `place_order` |
| Orders list + detail | my orders, status, cancel | `orders` (RLS) |
| Deliver order | confirm delivery + signature capture | `deliver_order`, Storage |
| Record payment | amount, method, reference | `record_payment` |
| Create invoice discount | pick confirmed order → pick fintech in zone → rate → summary (invoice / fintech pays / customer pays / deadline) → submit | `create_invoice_discount` |
| My factored invoices | status of discounts I created | `invoice_discounts` (RLS) |
| Register fintech agent | collect provider + KYC → show invite code to share | `register_fintech_agent` |
| My registered fintechs | verification status | `fintech_agents` (RLS) |
| Profile | details, change password, MFA, sign out | Auth |

#### INFORMAL_REP
Everything the FIELD_AGENT has, plus:
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Depot & Field"** | field KPIs + depot stock value, low stock, incoming transfers | `stock_balances`, `inventory_transfers` |
| Depot stock | on-hand by product/batch, low-stock flags | `stock_balances` |
| Receive stock | record inbound supply | `receive_stock` |
| Incoming transfers | list, verify receipt (PIN + GPS + photo), reconcile | `verify_transfer`, `reconcile_transfer` |
| Submit stock count | per-product counted qty | `submit_stock_count` |

#### WAREHOUSE_MANAGER
| Screen | Purpose | Data source |
|---|---|---|
| Login / MFA | auth | Auth |
| **Dashboard — "Warehouse Overview"** | stock value, pending inbound/outbound transfers, low-stock count, open discrepancies, alerts | `stock_balances`, `inventory_transfers`, `stock_counts`, `alerts` |
| Stock list + product detail | on-hand/reserved/damaged, movement history | `stock_balances`, `inventory_movements` |
| Low stock / reorder | items at/below `reorder_point` | `stock_balances` + `products` |
| Receive stock | inbound supply | `receive_stock` |
| Outgoing transfers | initiate, verify dispatch (PIN + GPS + photo) | `initiate_transfer`, `verify_transfer` |
| Incoming transfers | verify receipt, reconcile, view mismatches | `verify_transfer`, `reconcile_transfer` |
| Transfer detail | items, verifications, dispute status | `inventory_transfers`, `transfer_verifications`, `transfer_disputes` |
| Orders to fulfil | confirm `PENDING` orders on my warehouse, dispatch | `confirm_order`, `dispatch_order` |
| Stock counts | submit, track review outcome | `submit_stock_count` |
| Alerts | warehouse alerts, acknowledge | `acknowledge_alert` |
| Profile | — | Auth |

#### FINTECH_AGENT
| Screen | Purpose | Data source |
|---|---|---|
| Sign up (phone OTP) + invite code | account creation and link | Auth, `link_fintech_agent` |
| Login / MFA / transaction-PIN setup & change | auth + PIN | Auth, `rotate_fintech_pin` |
| **Dashboard — "Earnings & Collections"** | earnings to date, outstanding collections, active invoices, default rate, weekly activity | `fintech_agent_stats` |
| Pending invoices (offered) | list (realtime), invoice detail (order, outlet, amount, my 90%, deadline), accept / decline | `invoice_discounts` (realtime), `accept_invoice_discount`, `decline_invoice_discount` |
| Record funding | amount + bank/transfer reference for the 90% | `record_fintech_funding` |
| Active collections | `FUNDED`/`COLLECTING` invoices, per-invoice collection progress | `invoice_discounts`, `invoice_discount_events` |
| Record collection | amount + reference + transaction PIN | `record_fintech_collection` |
| Declare default / Dispute | with note | `declare_default`, `dispute_invoice_discount` |
| Completed | `COLLECTED`/`SETTLED` history | `invoice_discounts` |
| Earnings detail | chart over time, per-invoice breakdown, settlement (refund/bonus) history | `fintech_agent_stats`, `settlements` |
| Outlets (read-only) | credit status of outlets I factor for | `customer_credit_profile` (RLS, limited columns) |
| Profile | business info, provider account, change PIN, MFA, sign out | Auth |

### 8.2 `apps/desktop-windows`

Shared shell: left nav, global search, alert/notification centre, user menu.
Every dashboard reads **only cache tables** and polls on an interval.

#### REGIONAL_MANAGER (scoped to assigned zones)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Regional Health"** | per-zone cards: warehouses, outlets, active agents, stock value, debt, utilisation, open alerts; sales trend; factoring summary | `zone_health`, `daily_sales_rollup`, `fintech_program_health` |
| Zones | zone detail, agent roster, warehouse roster | `market_zones`, `profiles`, `warehouses` |
| Verification queue | pending outlets and fintech agents → approve / reject | `verify_outlet`, `verify_fintech_agent` |
| Orders | all in region, filters, detail | `orders` |
| Transfers + disputes | region transfers, resolve disputes | `inventory_transfers`, `resolve_transfer_dispute` |
| Stock count review | accept / reject submitted counts | `review_stock_count` |
| Invoice discounts | region discounts, overdue & defaulted, resolve default / dispute | `invoice_discounts`, `resolve_default`, `resolve_invoice_dispute` |
| Alerts | region alerts, acknowledge / resolve | `acknowledge_alert`, `resolve_alert` |
| Reports | sales by zone/agent/product, debt aging, factoring performance, agent productivity | cache tables + read views |

#### ADMIN (global — all of the above unscoped, plus)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Company Overview"** | national sales, debt, inventory value, factoring exposure, top/bottom zones, alert summary | `daily_sales_rollup` (global), `zone_health`, `fintech_program_health` |
| **Dashboard — "Fintech Program"** | active agents, factored volume, earnings, outstanding, default rate, avg collection days, open disputes | `fintech_program_health`, `fintech_agent_stats` |
| **Dashboard — "Finance"** | funding-verification queue, payment-reconciliation queue, settlement ledger | `invoice_discounts`, `payments`, `settlements` |
| Master data | products, warehouses, market zones, zone-manager assignments (CRUD) | `upsert_*`, `assign_zone_manager` |
| Users | staff list, invite staff, role assignment, suspend / lock, PIN rotation | `invite_staff`, `rotate_warehouse_pin`, `rotate_fintech_pin` |
| Fintech program admin | all agents, capacity, status changes | `set_fintech_status` |
| Finance actions | verify fintech funding, verify payments, process settlement (refund/bonus) | `verify_fintech_funding`, `verify_payment`, `process_settlement` |
| Adjustments | post stock adjustments, view reversal log | `post_adjustment`, `inventory_movements` |
| Alert config | fraud-rule thresholds, reorder points | config table |
| System | audit-log browser, scheduled-job status, cache-refresh freshness | `audit_logs`, `cron.job_run_details` |

#### SUPER_ADMIN
ADMIN plus destructive/rare: delete master data, manage other admins, break-glass
access, environment config.

#### AUDITOR (read-only everywhere + reconciliation tools)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Reconciliation"** | ledger vs cache drift, funding claimed vs verified, collection events vs invoice totals, open discrepancies | `inventory_movements` vs `stock_balances`; `customer_ledger` vs `outlet_balances`; `invoice_discount_events` vs `invoice_discounts` |
| **Dashboard — "Compliance"** | factoring exposure, default analysis, zone-violation log, PIN-attempt log, dispute log | `alerts`, `invoice_discounts`, `transfer_verifications`, `audit_logs` |
| Audit-log browser | filter by table / actor / date / action; view diffs | `audit_logs` |
| Read-only views | every dashboard, order, transfer, invoice, settlement, ledger | all cache + business tables |
| Export | CSV export of any report | client-side |

No write actions for `AUDITOR` beyond exporting.

---

## 9. RLS policy inventory (summary)

| Table | SELECT scope | Writes |
|---|---|---|
| `profiles` | self; HQ all; zone manager sees zone staff | self-`UPDATE` (display fields, trigger-guarded); rest RPC |
| `market_zones`, `products` | all authenticated (reference data) | RPC (`ADMIN`) |
| `warehouses` | zone-scoped + HQ | RPC |
| `outlets`, `outlet_balances`, `customer_ledger`, `customer_credit_profile` | zone-scoped + HQ; fintech sees limited columns for factored outlets | RPC |
| `orders`, `order_items` | agent's own + warehouse's + zone manager + HQ | RPC |
| `inventory_movements`, `stock_balances`, `stock_counts` | warehouse + zone manager + HQ | RPC (movements INSERT-only, no update/delete) |
| `inventory_transfers`, `transfer_items`, `transfer_verifications`, `transfer_disputes` | source/dest warehouse + zone managers + HQ | RPC |
| `payments` | zone-scoped + HQ | RPC (INSERT-only) |
| `fintech_agents`, `fintech_agent_stats` | own + registering agent + zone manager + HQ | RPC |
| `invoice_discounts`, `invoice_discount_events` | fintech (own) + sales agent (own) + zone manager + HQ | RPC |
| `settlements` | fintech (own) + HQ | RPC (`ADMIN`) |
| `alerts` | scoped to zone/warehouse/agent + HQ | RPC (ack/resolve) |
| `audit_logs` | `ADMIN`, `SUPER_ADMIN`, `AUDITOR` | trigger only |
| `daily_sales_rollup`, `zone_health`, `fintech_program_health` | HQ; zone rows visible to that zone's manager | job only |
| `notifications_outbox` | none (service role only) | RPC insert; `notify` updates |

---

## 10. Out of scope for launch

- View-only / self-service **customer login** (fast-follow — §11).
- **Fintech-provider payment APIs** (OPay/PalmPay/Moniepoint). Launch records
  fund movements manually with a reference; the RPC interface is designed so a
  provider-API Edge Function can call the same RPCs later.
- **Algorithmic credit scoring.** Launch uses a manual `credit_limit` and the
  `customer_credit_profile` counters.
- **Returns / refunds** as a first-class flow (handled ad hoc via
  `post_adjustment` and `process_settlement` until specified).
- **Route optimisation** internals, promotions/price lists, push notifications
  (SMS only at launch), gamification.
- **Prisma / Docker** local schema tooling — replaced by the Supabase CLI local
  stack.

---

## 11. Planned fast-follows

1. **Customer view-only app** — `outlets.profile_id` nullable FK, `CUSTOMER`
   role, phone-OTP claim flow (`link_outlet_account(invite_code)` matched on
   phone), SELECT-only RLS on the customer's own invoices / ledger / credit
   profile, a read-only dashboard.
2. **Provider payment integration** — one Edge Function with per-provider
   adapters, credentials in Supabase Vault, webhook handlers, calling
   `record_fintech_funding` / `verify_fintech_funding`.
3. **Price lists** — zone- and custody-type-scoped pricing, read by the pricing
   helper the order RPC already uses.

---

## 12. Migration from the current repo

The current `frontend/` (npm workspaces: `core` + `mobile` Expo scaffold, 24
commits, auth wired to Supabase, 39 passing tests) is a **greenfield restart**
under the new layout — ideas and patterns carry over, code does not:

- Keep: the injectable Supabase-client idea, the `unwrapSupabaseResult` pattern,
  the storage-adapter concept, the auth store shape.
- Rebuild under `apps/` + `packages/` with pnpm; `packages/shared-*` replaces
  `core`; `apps/mobile-android` replaces `mobile`.
- Delete `backend/` (Prisma/Docker) and `prisma.config.ts` (already removed).
- The three superseded specs stay in the repo for history with a superseded
  banner; `2026-08-25-backend-foundation.md` is marked obsolete.

Follow-on documents (not this spec):

- **Architecture / repo-scaffold spec** — the `apps/`+`packages/` structure,
  pnpm, build pipeline for APK/MSIX, the shared Supabase client, session storage,
  generated types.
- **CLAUDE.md rewrites** — root `CLAUDE.md`, new `apps/CLAUDE.md` and
  `supabase/CLAUDE.md`, delete `backend/CLAUDE.md`.
- **Implementation plans** — one per subsystem (RTM core → factoring →
  onboarding), each via the writing-plans skill.

---

## 13. Open questions

1. **PIN delivery** — is SMS-only acceptable for the fintech transaction PIN, or
   is in-app secure display at verification time also wanted?
2. **Funding provisional window** — should a `FUNDED`-but-not-yet-verified
   invoice be visible to the customer / block a second discount on the same
   order, or is it fully inert until `verify_fintech_funding`?
3. **Transfer GPS tolerance** — confirm `radius_km` per warehouse is the right
   knob, and the same-zone vs cross-zone tightening factor.
4. **Auditor exports** — any regulatory format required (CBN reporting?), or is
   CSV sufficient?
5. **Staff onboarding** — do `WAREHOUSE_MANAGER`/`FIELD_AGENT` accounts get
   created by `ADMIN` invite only, or can a `REGIONAL_MANAGER` create field staff
   in their zones?
