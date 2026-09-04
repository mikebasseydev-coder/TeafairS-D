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
inventory platform, plus an **invoice-financing feature** ("Micro / Invoice
Discount"): a Fintech agent (OPay, PalmPay, Moniepoint, …) pays TEFAIR an invoice
in full and immediately, then collects from the customer over time. TEFAIR never
carries the principal — the customer's debt is to the Fintech, the Fintech is
indemnified at signup and the customer names a guarantor — and TEFAIR's cost is a
capped fee: the negotiated rate (≤ 10%) on successful repayment, or a flat 10%
compensation if the Fintech declares default.

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
5. **The financing loop closes without HQ touching the database.** A field agent
   registers an outlet and a fintech agent (who accepts the indemnity), HQ
   verifies both, the agent places an order and creates a financing deal, the
   fintech pays TEFAIR in full (recorded and finance-verified), the fintech
   records customer repayments until complete (or declares default), TEFAIR pays
   the fee — negotiated ≤ 10% on success, flat 10% compensation on default — and
   `fintech_agent_stats` + `customer_credit_profile` reflect it — every step an
   RPC with a screen, no manual SQL.
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
| `flag_financing_fees_due()` | nightly | `REPAID` or `DEFAULTED` invoices with no `fee_paid_at` → surface in the ADMIN fee queue (negotiated fee / flat-10% compensation) |
| `flag_stale_financing()` | nightly | `COLLECTING` past `expected_repayment_date` → alert; the Fintech decides whether to `declare_default` |
| `reconcile_stock_balances()` | nightly | recompute balances from ledger, alert on any drift |
| `reconcile_financials()` | nightly | ledger vs `outlet_balances` / `consignment_balances` / `customer_credit_profile`, alert on drift |
| `run_fraud_scans()` | nightly | the fraud rules in §6 → alerts |
| `expire_pending_verifications()` | hourly | offline bundles never reconciled → `NEEDS_REVIEW`; `NEEDS_REVIEW` items past their SLA → escalate to `ADMIN`, alert |
| `downgrade_stale_photos()` | nightly | verification/delivery photos older than `photo_retention_days` on non-disputed records → thumbnail, purge full-res |
| `drain_notifications_outbox()` | every 1 min | invoke the `notify` Edge Function |

### 3.5 Realtime

One channel: a `FINTECH_AGENT` subscribes to `postgres_changes` on
`invoice_financings` filtered to `fintech_agent_id = <their id>`, so newly
offered deals and status changes appear without polling. Every other screen
refetches on focus. HQ dashboards poll their cache tables on an interval.

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
| `COMPLIANCE_OFFICER` | HQ | desktop-windows | global; verification-review + fraud-alert triage only. **Unassigned at launch** — `REGIONAL_MANAGER` covers the work until volume justifies staffing it |
| `AUDITOR` | HQ | desktop-windows | global **read-only** + reconciliation/compliance tools |
| `WAREHOUSE_MANAGER` | field | mobile-android | one warehouse (`profiles.warehouse_id`) |
| `INFORMAL_REP` | field | mobile-android | one consignment depot in an area market (see below) |
| `FIELD_AGENT` | field | mobile-android | one zone (`profiles.market_zone_id`) |
| `FINTECH_AGENT` | external | mobile-android | own financing deals, own stats, outlets in `operation_zone_id` (read) |

No `CUSTOMER` role at launch. Outlets (shop owners) are data records created by
field agents; they do not authenticate. View-only customer login is a planned
fast-follow (§11).

**`INFORMAL_REP` is a consignment sub-distributor** — the pivotal field role.
They run a depot (a `warehouse` of `type = INFORMAL_REP_DEPOT`,
`custody_type = CONSIGNMENT`) inside one area market, holding TEFAIR-owned stock
on consignment. Stock on their premises stays TEFAIR's asset until sold; as it
sells through orders sourced from their depot they accrue **cash owed to TEFAIR**
against a `debt_limit`, tracked in `consignment_balances` (§5.4) and remitted via
`record_remittance` (§7). Field agents in that market draw stock from the rep's
depot. Their app duties are field-agent duties **plus** depot custody (receive,
count, verify inbound transfers, remit).

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
| `user_role` | SUPER_ADMIN, ADMIN, REGIONAL_MANAGER, COMPLIANCE_OFFICER, AUDITOR, WAREHOUSE_MANAGER, INFORMAL_REP, FIELD_AGENT, FINTECH_AGENT |
| `user_status` | PENDING_VERIFICATION, ACTIVE, SUSPENDED, LOCKED |
| `entity_status` | PENDING_VERIFICATION, ACTIVE, SUSPENDED |
| `zone_tier` | INTER_STATE, LAGOS_INTRA_CITY, OTHER_INTRA_STATE |
| `warehouse_type` | CENTRAL_DEPOT, INFORMAL_REP_DEPOT, MICRO_FULFILLMENT, DARK_STORE |
| `custody_type` | CONSIGNMENT, OUTRIGHT, HYBRID, TEMPORARY |
| `movement_type` | RECEIVED, SOLD, RESERVED, UNRESERVED, TRANSFER_OUT, TRANSFER_IN, RETURNED, DAMAGED, COUNT_ADJUSTMENT, REVERSAL |
| `payment_channel` | DIRECT_CASH, CASH_AGENT, FINTECH_FINANCED |
| `alert_severity` | INFO, WARNING, CRITICAL, EMERGENCY |
| `fintech_provider` | OPAY, PALMPAY, MONIEPOINT, PAYSTACK, FLUTTERWAVE, KUDA, CARBON, PAGA, FIRST_BANK_MOBILE, OTHER |
| `fintech_status` | PENDING_VERIFICATION, ACTIVE, SUSPENDED, DEACTIVATED, UNDER_REVIEW |
| `financing_event_type` | FUNDED, FUNDING_VERIFIED, CUSTOMER_REPAYMENT, REPAYMENT_COMPLETE, FEE_PAID, DEFAULT_DECLARED, DISPUTED, CANCELLED |

### 5.2 Workflow statuses (`text` + `CHECK` — evolve without `ALTER TYPE`)

| Column | Allowed values |
|---|---|
| `orders.status` | PENDING, CONFIRMED, DISPATCHED, DELIVERED, CANCELLED |
| `inventory_transfers.status` | PENDING, IN_TRANSIT, DELIVERED, RECONCILED, DISPUTED, CANCELLED, EXPIRED |
| `invoice_financings.status` | PENDING, FUNDED, COLLECTING, REPAID, FEE_PAID, DEFAULTED, DISPUTED, CANCELLED |
| `stock_counts.status` | PENDING_REVIEW, ACCEPTED, REJECTED |
| `transfer_disputes.status` | OPEN, RESOLVED |
| `location_update_requests.status` | PENDING, APPROVED, REJECTED |
| `*_verifications.review_status` | AUTO_OK, NEEDS_REVIEW |
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

**`consignment_balances`** — RPC-maintained cache for `INFORMAL_REP_DEPOT` /
`CONSIGNMENT` warehouses. `warehouse_id` (PK), `stock_value_held` (TEFAIR-owned
stock currently at the depot, at cost), `cash_owed` (accrued as stock sells
through the depot, minus remittances), `remitted_to_date`, `debt_limit` (copied
from `warehouses` for the drift check), `updated_at`. Maintained by `place_order`
(accrues `cash_owed` when a depot is the source), `record_remittance` (reduces
it), and `receive_stock`/transfer RPCs (adjust `stock_value_held`).
`reconcile_financials()` recomputes from the ledger + `payments` +
`remittances` nightly.

### 5.5 Orders

**`orders`** — `order_number` (unique, `ORD-YYYYMMDD-NNNN`), `outlet_id` (FK),
`agent_id` (FK profile), `market_zone_id` (FK), `source_warehouse_id` (FK),
`guarantor_id` (FK `outlet_guarantors`, nullable — **required by the RPC for any
non-`DIRECT_CASH` channel**), `status`, `payment_channel`, `subtotal`, `discount`
(default 0), `tax` (default 0), `total` **GENERATED** `subtotal - discount + tax`,
`amount_paid` (default 0), `notes`, `idempotency_key` (unique), `created_by`,
`confirmed_by`, `confirmed_at`.

**`order_items`** — `order_id` (FK, cascade), `product_id` (FK), `quantity`
(`CHECK > 0`), `unit_price` (set by RPC from `products`), `line_total`
**GENERATED** `quantity * unit_price`. `UNIQUE(order_id, product_id)`.

Two-stage: an order created by a field agent is `PENDING` and only holds a
provisional stock reservation. `confirm_order` (warehouse manager / HQ) commits
it. Any order where stock leaves on credit (`payment_channel` is `CASH_AGENT` or
`FINTECH_FINANCED`) **must name an `ACTIVE` guarantor on the outlet** — the
customer is liable for stock collected and the guarantor backs that liability
(§5.8).

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
`methods` (text[] — which signals were present), `tier` (`T0..T3`, §6.3),
`gps_lat?`, `gps_lng?`, `gps_distance_m?`, `cell_id?`, `photo_path` (Storage key),
`review_status` (`AUTO_OK|NEEDS_REVIEW`), `captured_at`, `verified_at`. Replaces
the ~20 `sender_*`/`receiver_*` columns in the earlier draft. Transfers are
staff↔staff — routine verification is PIN + GPS-fix (when available) + photo from
both ends; **never SMS**.

**`transfer_disputes`** — `transfer_id` (FK), `opened_by` (FK), `reason`,
`status`, `resolution?`, `resolved_by?`, `resolved_at?`.

### 5.7 Stock counts

**`stock_counts`** — `warehouse_id` (FK), `product_id` (FK), `batch_number?`,
`counted_qty`, `system_qty` (snapshot at submission), `discrepancy` **GENERATED**
`counted_qty - system_qty`, `counted_by` (FK), `status`, `reviewed_by?`,
`reviewed_at?`, `note?`. `ACCEPTED` → `review_stock_count` posts a
`COUNT_ADJUSTMENT` movement.

### 5.8 Payments, customer debt & guarantors

**The customer is liable for stock collected.** Any credit collection
(`CASH_AGENT` or `FINTECH_FINANCED` channel) requires a named, `ACTIVE`
guarantor on the outlet — captured in-app so the debt holder (TEFAIR or the
Fintech) has recourse evidence.

**`outlet_guarantors`** — `outlet_id` (FK), `full_name`, `phone`, `address`,
`relationship`, `id_document_path` (Storage), `photo_path` (Storage), `status`
(`entity_status`), `verified_by?`, `verified_at?`, `created_by`. An outlet may
have several; at least one must be `ACTIVE` before a credit order is allowed.

**`payments`** — INSERT-only. `outlet_id` (FK), `order_id?` (FK), `amount`
(`CHECK > 0`), `channel` (`payment_channel`), `method`, `reference`, `received_by`
(FK profile), `verified_by?`, `verified_at?`, `occurred_at`, `idempotency_key`
(unique).

**`remittances`** — INSERT-only. `INFORMAL_REP` depot cash paid to TEFAIR.
`warehouse_id` (FK), `amount` (`CHECK > 0`), `method`, `reference`,
`recorded_by` (FK), `verified_by?`, `verified_at?`, `occurred_at`,
`idempotency_key` (unique).

**`outlet_balances`** — RPC-maintained cache. `outlet_id` (PK), `total_invoiced`,
`total_paid`, `balance` **GENERATED** `total_invoiced - total_paid`,
`open_invoice_count`, `updated_at`. **A `FINTECH_FINANCED` order does not raise
`outlet_balances`** — once the Fintech's payment is verified the customer's debt
is to the Fintech, not TEFAIR (§5.9). If an order was placed on normal credit and
financed later, `verify_fintech_funding` records a `payments` row that clears the
TEFAIR balance for that order.

**`customer_ledger`** — INSERT-only. `outlet_id` (FK), `entry_type`
(`INVOICE|PAYMENT|DEFAULT|ADJUSTMENT|FINANCED`), `amount` (signed),
`reference_type`, `reference_id`, `description`, `recorded_by`, `occurred_at`.

### 5.9 Invoice financing ("Micro / Invoice Discount")

**Model — TEFAIR's exposure is capped at 10% and it never loses principal.**
TEFAIR is the merchant; the Fintech agent is the financier.

1. A field agent issues an invoice to a customer for **₦X** = Σ(SKU
   `unit_price` × qty) for a `CONFIRMED` order. The customer is liable and has a
   named guarantor (§5.8).
2. The Fintech agent pays TEFAIR **₦X in full**, immediately. On
   `verify_fintech_funding` (finance confirms the money landed) TEFAIR has its
   cash and never loses it.
3. The customer repays **the Fintech** ₦X on any schedule (proximity
   cash-collection — many Fintech agents are market traders near the customer).
   This is a Fintech↔customer debt; TEFAIR only records repayment events.
4. **On successful repayment** — TEFAIR pays the Fintech a **financing fee** of
   the negotiated `fee_rate` % of ₦X (field-agent negotiated, **capped at 10%**),
   paid whenever repayment completes.
5. **On default** — the Fintech declares bad debt (`DEFAULTED`). TEFAIR pays the
   Fintech a flat **10% of ₦X** as default compensation ("cost of money" — TEFAIR
   pays for the float whether or not the downstream customer paid). The Fintech
   still absorbs the remaining ~90% loss and pursues the customer + guarantor.
6. Either way TEFAIR's payout to the Fintech is recorded on the invoice with a
   `fee_basis` of `SUCCESS` or `DEFAULT`; the invoice ends `FEE_PAID`.

**Indemnity.** A Fintech agent cannot be verified until they accept TEFAIR's
indemnity agreement in-app (e-signature). The indemnity + guarantor are what keep
TEFAIR's loss to the capped fee — it never carries the principal.

**Self-dealing note.** Many shop owners are themselves Fintech agents. Outlets
aren't users and Fintech agents are, so there's no data collision, but a Fintech
financing invoices for an outlet it is connected to is a fraud vector — see the
collusion / phone-match rules in §6.

**`fintech_agents`** — `profile_id` (FK, unique — the agent's login),
`provider`, `provider_account_id`, `full_name`, `phone` (unique), `email?`,
`business_name?`, `business_address?`, `operation_zone_id` (FK, not null),
`registered_by` (FK), `status` (`fintech_status`), `verified_by?`,
`verified_at?`, `secret_pin_hash`, `pin_changed_at`, `pin_attempts`,
`pin_locked_until`, `funding_capacity?` (soft cap), `invite_code?` (nullable,
consumed on link), `indemnity_version?`, `indemnity_accepted_at?`,
`indemnity_document_path?` (signed copy in Storage). `UNIQUE(provider,
provider_account_id)`. No stored running totals.

**`fintech_agent_stats`** — cache. `fintech_agent_id` (PK),
`total_financed_volume`, `total_fees_earned`, `outstanding_customer_debt`
(the Fintech's own exposure on `COLLECTING` deals — informational, not TEFAIR's),
`active_deals`, `completed_deals`, `defaulted_deals`, `default_rate`,
`avg_repayment_days`, `last_deal_at`, `updated_at`.

**`invoice_financings`** — `invoice_number` (unique, `INV-YYYYMMDD-NNNN`),
`order_id` (FK, **unique** — one financing per order), `outlet_id` (FK),
`sales_agent_id` (FK), `fintech_agent_id` (FK), `market_zone_id` (FK),
`guarantor_id` (FK `outlet_guarantors`), `invoice_total` (₦X),
`fintech_funding_amount` (= `invoice_total`; stored to guard partial funding),
`fee_rate` (`CHECK fee_rate > 0 AND fee_rate <= 10` — the negotiated success
rate), `success_fee_amount` **GENERATED** `invoice_total * fee_rate / 100`,
`default_fee_amount` **GENERATED** `invoice_total * 0.10`, `status`,
`invoice_date`, `expected_repayment_date` (`invoice_date + 45`, soft),
`funded_at?`, `funding_reference?`, `funding_verified_by?`,
`funding_verified_at?`, `repayment_completed_at?`, `defaulted_at?`,
`default_note?`, `fee_basis?` (`SUCCESS|DEFAULT`), `fee_paid_amount?`,
`fee_paid_at?`, `fee_reference?`, `fee_paid_by?`, `created_by`.

**`invoice_financing_events`** — INSERT-only. `invoice_financing_id` (FK),
`event_type` (`financing_event_type`), `amount?`, `reference?`, `actor_id` (FK),
`pin_verified` (bool), `note?`, `occurred_at`, `idempotency_key` (unique). The
audit trail; parent `status` is derived by the RPC that writes the event.

**`fintech_adjustments`** — rare manual corrections/bonuses only.
`fintech_agent_id` (FK), `invoice_financing_id?` (FK), `kind`
(`CORRECTION|BONUS|REFUND`), `amount` (signed), `reason`, `method?`,
`reference?`, `processed_by`, `processed_at`.

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
`agent_id?`, `order_count`, `gross_revenue`, `cash_collected`, `financed_volume`,
`computed_at`. Unique grouping key with `COALESCE(dim, '00000000-…')` so
company-wide and per-dimension rollups coexist.

**`zone_health`** — `market_zone_id` (PK), `warehouse_count`, `outlet_count`,
`active_agents`, `stock_value`, `outlet_debt`, `debt_utilization_pct`,
`consignment_owed`, `open_alerts`, `computed_at`.

**`fintech_program_health`** — one row per zone plus a global row.
`active_agents`, `total_financed_volume`, `total_fees_paid`, `fees_due`,
`fintech_outstanding_debt`, `default_rate`, `avg_repayment_days`,
`disputes_open`, `computed_at`.

### 5.12 Notifications

**`notifications_outbox`** — INSERT-only by RPCs. `channel` (`sms|push`),
`recipient`, `template`, `params` (jsonb), `status` (`PENDING|SENT|FAILED`),
`attempts`, `sent_at?`, `created_at`. Drained every minute by `notify`.

### 5.13 Verification & location (§6.3)

**`verification_config`** — per-zone tuning (one row per `market_zone_id`, plus a
global default row). `sms_on_new_outlet_only` (bool, default true),
`t2_gps_enforced_above` (₦ value — geofence strictly enforced above this),
`t3_sms_above` (₦ value — SMS co-presence required above this, new outlets
always), `heartbeat_grace_hours` (default 48), `photo_retention_days`
(default 90). `ADMIN`-editable.

**`delivery_verifications`** — INSERT-only, for `deliver_order` (Stage 4/5).
`order_id` (FK), `outlet_id` (FK), `verified_by` (FK profile), `tier`
(`T0..T3`), `methods` (text[]), `gps_lat?`, `gps_lng?`, `gps_distance_m?`
(vs `outlets` GPS), `cell_id?`, `photo_path`, `signature_path`, `sms_confirmed?`
(bool), `risk_tier`, `review_status` (`AUTO_OK|NEEDS_REVIEW`), `captured_at`,
`verified_at`. Offline-captured bundles replay with their original `captured_at`
+ an idempotency key.

**`depot_checkins`** — INSERT-only. `warehouse_id` (FK), `profile_id` (FK),
`source` (`LOGIN|MANUAL`), `gps_lat?`, `gps_lng?`, `cell_id?`, `photo_path?`
(weekly), `occurred_at`. Passive on login; a weekly photo is prompted.

**`location_cell_observations`** — the learned cell-ID set per location.
`location_type` (`WAREHOUSE|OUTLET`), `location_id`, `cell_id`, `first_seen_at`,
`last_seen_at`, `observation_count`. Populated by every verification/checkin;
after a warm-up (≥ N observations) a verification from an unseen cell for that
location is flagged.

**`location_update_requests`** — a depot/outlet moved. `location_type`,
`location_id`, `requested_by` (FK), `new_lat`, `new_lng`, `new_address`,
`capture_samples` (jsonb — the multi-sample GPS median), `status`
(`PENDING|APPROVED|REJECTED`), `reviewed_by?`, `reviewed_at?`.

**`verification_reviews`** — INSERT-only. `kind` (`TRANSFER|DELIVERY`),
`verification_id`, `agent_id` (FK), `decision` (`CLEARED|CONFIRMED_ISSUE`),
`note`, `reviewed_by` (FK), `reviewed_at`. The trailing-window input to an
agent's computed anomaly score.

### 5.14 Storage buckets

All private. `transfer_photos`, `count_photos`, `delivery_photos`, `signatures`,
`depot_photos`, `product_images`, `guarantor_documents` (ID + photo),
`financing_docs` (signed indemnity, deal acknowledgements). Access via signed
URLs minted by RPCs / policies scoped to the requesting role's zone. A retention
job downgrades photos to thumbnails after `photo_retention_days` unless the
parent record is disputed.

---

## 6. Integrity model (how wrong entries are stopped)

### 6.1 Layers

Seven layers, all near-zero incremental cost:

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
   `payments`, `remittances`, `customer_ledger`, `invoice_financing_events`,
   `audit_logs` have no UPDATE/DELETE policy. Corrections are compensating rows
   (`REVERSAL`, `ADJUSTMENT`) with a reason and an approver.
6. **Guarantor gate** — no credit stock (`CASH_AGENT` / `FINTECH_FINANCED`)
   leaves without a named `ACTIVE` guarantor on the outlet.
7. **Batch anomaly detection** — nightly `run_fraud_scans()` plus ledger/cache
   reconciliation jobs raise `alerts`; nothing runs per-write.

### 6.2 Fraud rules (nightly, → `alerts`)

| Rule | Trigger |
|---|---|
| Default rate | fintech agent's rolling default rate > 5% |
| Volume cap | fintech agent > 10 new financing deals in a day |
| Repayment pattern | repayment events clustered unnaturally (full amount day-1 repeatedly, all round numbers) |
| Zone match | deal's outlet / fintech / agent not all in one zone (also blocked at RPC time; the scan catches drift) |
| Collusion | same (fintech agent, outlet) pair above a frequency threshold in a window |
| Self-dealing | fintech agent's phone / name matches an outlet contact or guarantor on a deal they financed |
| Depot silent | no `depot_checkins` row for a consignment depot in `heartbeat_grace_hours` |
| Cell drift | a verification / checkin cell_id not in `location_cell_observations` for that location after warm-up |
| GPS spoof pattern | verification GPS identical to the pre-registered point to > 5 decimals, repeatedly (replayed coordinates) |

### 6.3 Location & delivery verification

**Principle: capture everything free, enforce by risk tier, server decides.**
The client captures a signal bundle — a GPS fix (whenever location permission is
granted and a fix is available), best-effort `cell_id`, photo(s), signature — and
submits it in one RPC call with an idempotency key (so an offline-queued bundle
replays cleanly). The **RPC** computes the risk tier from server-side history +
`verification_config`, decides which signals are mandatory, validates what's
present, enforces the geofence where the tier requires it, writes the
`*_verifications` row and sets `review_status`. The client never scores its own
risk.

GPS has **no per-request cost** here (geofence = `haversine_km` in SQL, no Maps
API). It is captured on every verification when available and is the strongest
signal; the tier only decides whether the geofence is strictly enforced or
advisory.

**Tier ladder:**

| Tier | Signals | When |
|---|---|---|
| **T0** | pre-registered location + passive `depot_checkins` heartbeat | routine depot presence (Level 1, Level 3) |
| **T1** | PIN + `cell_id` + photo (+ GPS fix advisory) | default for transfers and repeat-outlet deliveries |
| **T2** | T1 + GPS fix with geofence **enforced** (`gps_distance_m <= radius_km`) | value > `t2_gps_enforced_above`, or agent has recent anomaly flags, or prior dispute on this counterparty pair |
| **T3** | T2 + **SMS co-presence** to the customer (server-generated OTP, hashed, TTL, server-verified) | **first delivery to a new outlet only**, or value > `t3_sms_above` |

SMS appears **only at T3**, only when the counterparty is not an app user
(customers), and never on the offline critical path — a T3 delivery in a
dead-signal market proceeds on T2 signals with `review_status = NEEDS_REVIEW` and
the SMS reconciles later.

**Learned cell IDs.** Every verification and checkin upserts
`location_cell_observations`. After a warm-up (`observation_count >= N`), a
verification from a cell never seen at that location is flagged (`cell drift`
rule) — this replaces any fictional "tower registry".

**Location moved.** `request_location_update` captures a multi-sample GPS median
on-site; `REGIONAL_MANAGER` approves; the location's `latitude`/`longitude` and
its `location_cell_observations` warm-up reset.

**Review is assurance, never a gate.** By the time a `NEEDS_REVIEW` row exists the
stock has already moved and the order is `DELIVERED`. The item:
- carries an SLA clock; unreviewed past SLA → `expire_pending_verifications`
  escalates it to `ADMIN` and alerts;
- **never blocks** the transaction or the agent's next action;
- its resolution feeds the agent's **anomaly score** — a rolling count of
  `CONFIRMED_ISSUE` reviews + open fraud alerts over a trailing window, *computed*
  by the tier selector, not a stored counter — which raises the *tier* of that
  agent's *future* transactions (T1 → T2 → T3).

So an unworked backlog degrades to "trusted more than ideal for a window," not
"operations halt". At launch the queue is worked by `REGIONAL_MANAGER`;
`COMPLIANCE_OFFICER` is staffed when volume justifies it. Keep tier thresholds
conservative so only genuinely anomalous transactions generate a review item.

**Platform.** Verification and depot heartbeat are **`apps/mobile-android`
only, by design** — HQ (`desktop-windows`) users are never at a depot or outlet.
`depot_checkins` / `delivery_verifications` are never written from Windows;
`location_cell_observations` covers only `WAREHOUSE` / `OUTLET`. Coarse IP-geo on
HQ login (impossible-travel detection) is an auth-session-security concern,
deferred to the auth-hardening follow-on — not this spec.

---

## 7. RPC surface (the entire write API)

Each is `SECURITY DEFINER`, idempotent on `p_idempotency_key`, role-checked
internally. Grouped by area.

### Onboarding
- `register_outlet(p_business_name, p_contact_name, p_phone, p_address, p_lat, p_lng, p_credit_limit, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; zone from caller; status `PENDING_VERIFICATION`.
- `register_guarantor(p_outlet_id, p_full_name, p_phone, p_address, p_relationship, p_id_document_path, p_photo_path, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; status `PENDING_VERIFICATION`.
- `verify_outlet(p_outlet_id)` / `verify_guarantor(p_guarantor_id)` — `ADMIN`/`REGIONAL_MANAGER` (of the zone).
- `register_fintech_agent(p_provider, p_provider_account_id, p_full_name, p_phone, p_email, p_business_name, p_business_address, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; creates a `fintech_agents` row (no `profile_id` yet), status `PENDING_VERIFICATION`, returns a one-time `invite_code`.
- `link_fintech_agent(p_invite_code)` — caller is a freshly phone-OTP-signed-up user; binds `fintech_agents.profile_id = auth.uid()`, sets `profiles.role = FINTECH_AGENT`.
- `accept_fintech_indemnity(p_indemnity_version, p_signature_path)` — `FINTECH_AGENT` (own, not yet verified); records `indemnity_accepted_at` + stored signed copy. **Required before verification.**
- `verify_fintech_agent(p_fintech_agent_id)` — `ADMIN`/`REGIONAL_MANAGER`; rejects if indemnity not accepted; status `ACTIVE`; generates the 6-digit transaction PIN, stores the bcrypt hash, queues an SMS.
- `set_fintech_status(p_fintech_agent_id, p_status, p_reason)` — `ADMIN`.
- `rotate_warehouse_pin(p_warehouse_id)` / `rotate_fintech_pin(p_fintech_agent_id)` — `ADMIN`; new PIN, SMS.

### Orders & payments
- `place_order(p_outlet_id, p_source_warehouse_id, p_guarantor_id, p_items jsonb, p_payment_channel, p_notes, p_idempotency_key)` — `FIELD_AGENT`/`INFORMAL_REP`; validates zone, outlet `ACTIVE`, **`guarantor_id` present and `ACTIVE` when channel is not `DIRECT_CASH`**, each product `is_active` and stocked, computes prices, atomically checks `available >= qty` and reserves (`RESERVED` movement + `stock_balances`), inserts `orders` `PENDING` + `order_items`. For `DIRECT_CASH`/`CASH_AGENT` it writes `customer_ledger` `INVOICE` and raises `outlet_balances`; for `FINTECH_FINANCED` it writes `customer_ledger` `FINANCED` only (no TEFAIR receivable). If the source is an `INFORMAL_REP_DEPOT`, also accrues `consignment_balances.cash_owed`.
- `confirm_order(p_order_id)` — `WAREHOUSE_MANAGER`(source)/`ADMIN`; `PENDING → CONFIRMED`.
- `dispatch_order(p_order_id)` — `WAREHOUSE_MANAGER`; `CONFIRMED → DISPATCHED`.
- `deliver_order(p_order_id, p_signal_bundle jsonb, p_idempotency_key)` — `FIELD_AGENT`; `p_signal_bundle` = `{gps?, cell_id?, photo_path, signature_path, sms_otp?, captured_at}`; RPC computes the tier (§6.3) from order value + outlet newness + agent flags + `verification_config`, enforces the mandatory signals for that tier, writes `delivery_verifications`, `DISPATCHED → DELIVERED`, converts reservation to `SOLD`. A tier-3 delivery with no SMS confirmation still completes as `DELIVERED` with `review_status = NEEDS_REVIEW`.
- `cancel_order(p_order_id, p_reason)` — releases reservation (`UNRESERVED`), reverses ledger.
- `record_payment(p_outlet_id, p_order_id, p_amount, p_channel, p_method, p_reference, p_idempotency_key)` — `FIELD_AGENT`/`WAREHOUSE_MANAGER`; inserts `payments`, `customer_ledger` `PAYMENT`, updates `outlet_balances`.
- `verify_payment(p_payment_id)` — `ADMIN`/`AUDITOR` (finance).
- `record_remittance(p_warehouse_id, p_amount, p_method, p_reference, p_idempotency_key)` — `INFORMAL_REP`/`WAREHOUSE_MANAGER`; depot cash paid to TEFAIR; inserts `remittances`, reduces `consignment_balances.cash_owed`.
- `verify_remittance(p_remittance_id)` — `ADMIN`/`AUDITOR` (finance).

### Transfers
- `initiate_transfer(p_source_warehouse_id, p_dest_warehouse_id, p_items jsonb, p_idempotency_key)` — `WAREHOUSE_MANAGER`(source)/`ADMIN`; reserves at source, sets `expires_at`, flags `is_cross_zone`.
- `verify_transfer(p_transfer_id, p_party, p_pin, p_signal_bundle jsonb, p_idempotency_key)` — the source/dest warehouse manager; `p_signal_bundle` = `{gps?, cell_id?, photo_path, captured_at}` (**no SMS — staff↔staff**); bcrypt PIN check with 5-attempt/15-min lockout; RPC computes the tier, runs `haversine_km` vs the relevant warehouse (geofence enforced at T2+), upserts `location_cell_observations`, inserts `transfer_verifications`, advances `PENDING → IN_TRANSIT` when the sender verifies.
- `mark_transfer_delivered(p_transfer_id)` — carrier/receiver; `IN_TRANSIT → DELIVERED`.
- `reconcile_transfer(p_transfer_id, p_received jsonb)` — dest `WAREHOUSE_MANAGER`; sets `qty_received` per line, posts `TRANSFER_OUT` at source and `TRANSFER_IN` at dest, `DELIVERED → RECONCILED`, or opens a `transfer_disputes` row and `→ DISPUTED` on any mismatch.
- `resolve_transfer_dispute(p_transfer_id, p_resolution, p_adjustments jsonb)` — `REGIONAL_MANAGER`/`ADMIN`; posts adjustment movements, `→ RECONCILED`.

### Counts & adjustments
- `submit_stock_count(p_warehouse_id, p_lines jsonb)` — `WAREHOUSE_MANAGER`/`INFORMAL_REP`; snapshots `system_qty` per line.
- `review_stock_count(p_count_id, p_decision, p_note)` — `REGIONAL_MANAGER`/`ADMIN`; `ACCEPTED` → `COUNT_ADJUSTMENT` movement.
- `post_adjustment(p_warehouse_id, p_product_id, p_batch_number, p_qty_delta, p_reason)` — `ADMIN`; explicit `REVERSAL`/adjustment movement with reason.
- `receive_stock(p_warehouse_id, p_lines jsonb, p_reference, p_photo_path, p_waybill_photo_path, p_idempotency_key)` — `WAREHOUSE_MANAGER`; `RECEIVED` movements (inbound supply, not a transfer); records a T0/T1 verification (pre-registered depot + photo).
- `depot_checkin(p_warehouse_id, p_signal_bundle jsonb)` — any staff assigned to the warehouse; passive on login, weekly photo prompt; inserts `depot_checkins`, upserts `location_cell_observations`.
- `request_location_update(p_location_type, p_location_id, p_new_lat, p_new_lng, p_new_address, p_capture_samples jsonb)` — `WAREHOUSE_MANAGER`/`FIELD_AGENT`; `approve_location_update(p_request_id, p_decision)` — `REGIONAL_MANAGER`/`ADMIN`; on approve, updates the location and resets its cell warm-up.
- `resolve_verification_review(p_kind, p_verification_id, p_decision, p_note)` — `REGIONAL_MANAGER`/`COMPLIANCE_OFFICER`/`ADMIN`; `p_kind` = `TRANSFER|DELIVERY`; `p_decision` = `CLEARED|CONFIRMED_ISSUE`; sets `review_status`; on `CONFIRMED_ISSUE` writes a `verification_reviews` row (the trailing-window input to the agent's anomaly score) and opens an alert.

### Financing
- `create_invoice_financing(p_order_id, p_fintech_agent_id, p_fee_rate, p_idempotency_key)` — `FIELD_AGENT`; order belongs to caller, is `CONFIRMED`+, channel `FINTECH_FINANCED`, has an `ACTIVE` guarantor, not already financed; fintech `ACTIVE`, indemnity accepted, same zone; `fee_rate` in `(0, 10]`; `invoice_total` = order total; status `PENDING`; `customer_ledger` `FINANCED`; queues fintech notification + realtime.
- `accept_invoice_financing(p_invoice_financing_id, p_acknowledgement_version)` / `decline_invoice_financing(p_invoice_financing_id, p_reason)` — `FINTECH_AGENT` (own). Accept **requires an in-app acknowledgement** of the deal terms (Fintech carries collection + the ~90% default loss; TEFAIR indemnified and never carries principal; on success TEFAIR pays the negotiated fee, on default TEFAIR pays a flat 10% compensation) — the app must present this panel and record the acknowledgement version; the RPC rejects a stale/missing version.
- `record_fintech_funding(p_invoice_financing_id, p_amount, p_reference)` — `FINTECH_AGENT` (own) or `ADMIN`; `p_amount` must equal `fintech_funding_amount`; inserts `FUNDED` event, status `PENDING → FUNDED` (provisional).
- `verify_fintech_funding(p_invoice_financing_id)` — `ADMIN`/`AUDITOR` (finance); confirms the full amount landed; status `FUNDED → COLLECTING`; if the order was previously on TEFAIR credit, records a `payments` row clearing `outlet_balances` for that order.
- `record_customer_repayment(p_invoice_financing_id, p_amount, p_reference, p_pin, p_idempotency_key)` — `FINTECH_AGENT` (own); bcrypt PIN check; inserts `CUSTOMER_REPAYMENT` event; when cumulative `>= invoice_total` → `REPAYMENT_COMPLETE` event, status `→ REPAID`, `repayment_completed_at`, updates `fintech_agent_stats` + `customer_credit_profile` (positive).
- `declare_default(p_invoice_financing_id, p_note)` — `FINTECH_AGENT` (own); `ADMIN` may override; only from `COLLECTING`; status `→ DEFAULTED`; `customer_ledger` `DEFAULT`; alert; `customer_credit_profile` (negative). Surfaces in the ADMIN fee queue for the flat-10% default compensation. (The batch job only *alerts* on stale deals — it never auto-defaults.)
- `process_fintech_fee(p_invoice_financing_id, p_amount, p_method, p_reference)` — `ADMIN` (finance); from `REPAID` → pays `success_fee_amount`, `fee_basis = SUCCESS`; from `DEFAULTED` → pays `default_fee_amount` (flat 10%), `fee_basis = DEFAULT`. `p_amount` must equal the applicable amount. Inserts `FEE_PAID` event, records `fee_paid_amount`/`fee_paid_at`, status `→ FEE_PAID`, updates `fintech_agent_stats.total_fees_earned`.
- `dispute_invoice_financing(p_invoice_financing_id, p_reason)` — `FINTECH_AGENT` or `FIELD_AGENT`; `→ DISPUTED`, alert.
- `resolve_financing_dispute(p_invoice_financing_id, p_resolution, p_new_status)` — `REGIONAL_MANAGER`/`ADMIN`.
- `post_fintech_adjustment(p_fintech_agent_id, p_invoice_financing_id, p_kind, p_amount, p_reason, p_method, p_reference)` — `ADMIN`; `CORRECTION`/`BONUS`/`REFUND` only.

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
| Outlet detail | balance, credit limit, guarantors, order & payment history | `outlets`, `outlet_guarantors`, `customer_ledger`, `orders` |
| Register outlet | capture business, contact, GPS, requested limit | `register_outlet` |
| Register guarantor | name, phone, relationship, ID photo, passport photo | `register_guarantor`, Storage |
| New order | outlet → warehouse → **guarantor (if credit)** → add products/qty → channel → review totals → submit | `products`, `stock_balances` (read), `place_order` |
| Orders list + detail | my orders, status, cancel | `orders` (RLS) |
| Deliver order | confirm delivery + signature capture | `deliver_order`, Storage |
| Record payment | amount, method, reference | `record_payment` |
| Create financing deal | pick confirmed `FINTECH_FINANCED` order → pick fintech in zone → negotiate fee rate (≤ 10%) → summary (invoice ₦X / fintech pays ₦X / TEFAIR fee) → submit | `create_invoice_financing` |
| My financing deals | status of deals I created (`PENDING`→`FEE_PAID`, defaults) | `invoice_financings` (RLS) |
| Register fintech agent | collect provider + KYC → show invite code to share | `register_fintech_agent` |
| My registered fintechs | verification + indemnity status | `fintech_agents` (RLS) |
| Profile | details, change password, MFA, sign out | Auth |

#### INFORMAL_REP (consignment depot custodian — §4)
Everything the FIELD_AGENT has, plus:
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Depot & Field"** | hero: **cash owed to TEFAIR vs `debt_limit`** gauge; consignment stock value; today's sales; low stock; incoming transfers; needs-attention | `consignment_balances`, `stock_balances`, `inventory_transfers`, `alerts` |
| Depot stock | consignment on-hand by product/batch, low-stock flags | `stock_balances` |
| Receive stock | record inbound supply | `receive_stock` |
| Incoming transfers | list, verify receipt (PIN + GPS + photo), reconcile | `verify_transfer`, `reconcile_transfer` |
| Submit stock count | per-product counted qty | `submit_stock_count` |
| Remittances | record cash paid to TEFAIR (reduces cash owed), history + verification status | `record_remittance`, `remittances` |

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
| Depot check-in | weekly photo prompt; check-in history | `depot_checkin`, `depot_checkins` |
| Alerts | warehouse alerts, acknowledge | `acknowledge_alert` |
| Profile | — | Auth |

#### FINTECH_AGENT
| Screen | Purpose | Data source |
|---|---|---|
| Sign up (phone OTP) + invite code | account creation and link | Auth, `link_fintech_agent` |
| **Indemnity agreement** | read the full terms, e-sign; **blocks everything else until accepted** | `accept_fintech_indemnity`, Storage |
| Login / MFA / transaction-PIN setup & change | auth + PIN | Auth, `rotate_fintech_pin` |
| **Dashboard — "Fees & Repayments"** | total fees earned, outstanding customer debt (my exposure), active deals, default rate, weekly activity; new-offer badge; deadlines approaching | `fintech_agent_stats` |
| Offers (pending) | realtime list; deal detail (order contents, outlet + credit history + guarantor, ₦X, my fee ≤ 10%); **terms & risk panel** → acknowledge → accept / decline | `invoice_financings` (realtime), `accept_invoice_financing`, `decline_invoice_financing` |
| Record funding | pay TEFAIR ₦X in full → enter bank/transfer reference | `record_fintech_funding` |
| Active deals | `FUNDED`/`COLLECTING`, per-deal repayment progress bar | `invoice_financings`, `invoice_financing_events` |
| Record repayment | customer payment to me: amount + reference + transaction PIN | `record_customer_repayment` |
| Declare default / Dispute | with note — default → I get flat 10% from TEFAIR, absorb the rest | `declare_default`, `dispute_invoice_financing` |
| Completed | `REPAID` / `FEE_PAID` / `DEFAULTED` history | `invoice_financings` |
| Fees detail | fees received from TEFAIR over time, per-deal breakdown (success vs default basis), adjustments | `fintech_agent_stats`, `fintech_adjustments` |
| Outlets (read-only) | credit status of outlets I finance for | `customer_credit_profile` (RLS, limited columns) |
| Profile | business info, provider account, change PIN, MFA, sign out | Auth |

### 8.2 `apps/desktop-windows`

Shared shell: left nav, global search, alert/notification centre, user menu.
Every dashboard reads **only cache tables** and polls on an interval.

#### REGIONAL_MANAGER (scoped to assigned zones)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Regional Health"** | per-zone cards: warehouses, outlets, active agents, stock value, outlet debt, consignment owed, utilisation, open alerts; sales trend; financing summary | `zone_health`, `daily_sales_rollup`, `fintech_program_health` |
| Zones | zone detail, agent roster, warehouse roster | `market_zones`, `profiles`, `warehouses` |
| Verification queue | pending outlets, guarantors, fintech agents; `NEEDS_REVIEW` deliveries/transfers; `location_update_requests` → approve / reject | `verify_outlet`, `verify_guarantor`, `verify_fintech_agent`, `approve_location_update` |
| Orders | all in region, filters, detail | `orders` |
| Transfers + disputes | region transfers, resolve disputes | `inventory_transfers`, `resolve_transfer_dispute` |
| Stock count review | accept / reject submitted counts | `review_stock_count` |
| Financing deals | region deals, overdue & defaulted, resolve disputes | `invoice_financings`, `resolve_financing_dispute` |
| Alerts | region alerts, acknowledge / resolve | `acknowledge_alert`, `resolve_alert` |
| Reports | sales by zone/agent/product, debt aging, consignment exposure, financing performance, agent productivity | cache tables + read views |

#### COMPLIANCE_OFFICER (unassigned at launch — `REGIONAL_MANAGER` covers this)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Review Queue"** | `NEEDS_REVIEW` deliveries & transfers with SLA clocks; fraud alerts (cell drift, depot silent, GPS-spoof, collusion, self-dealing) grouped by agent/pair | `delivery_verifications`, `transfer_verifications`, `alerts` |
| Review item | signal bundle (photo, GPS, cell, signature), history for the agent/pair → `CLEARED` / `CONFIRMED_ISSUE` | `resolve_verification_review` |
| Agent risk | anomaly-flag score per agent, tier history, recent flags | `profiles` + verification history |
| Alert triage | acknowledge / resolve / escalate fraud alerts | `acknowledge_alert`, `resolve_alert` |
| Read-only | orders, transfers, financing deals, ledgers (no writes beyond review actions) | business tables |

#### ADMIN (global — all of the above unscoped, plus)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Company Overview"** | national sales, outlet debt, consignment owed, inventory value, financing exposure, top/bottom zones, alert summary | `daily_sales_rollup` (global), `zone_health`, `fintech_program_health` |
| **Dashboard — "Fintech Program"** | active agents, financed volume, fees paid, fees due, agent outstanding debt, default rate, avg repayment days, open disputes | `fintech_program_health`, `fintech_agent_stats` |
| **Dashboard — "Finance"** | funding-verification queue, **fee-payment queue** (`REPAID` / `DEFAULTED`, unpaid), payment & remittance reconciliation | `invoice_financings`, `payments`, `remittances` |
| Master data | products, warehouses, market zones, zone-manager assignments (CRUD) | `upsert_*`, `assign_zone_manager` |
| Users | staff list, invite staff, role assignment, suspend / lock, PIN rotation | `invite_staff`, `rotate_warehouse_pin`, `rotate_fintech_pin` |
| Fintech program admin | all agents, capacity, indemnity status, status changes | `set_fintech_status` |
| Finance actions | verify fintech funding, verify payments/remittances, process fintech fee (success/default), post adjustment/bonus | `verify_fintech_funding`, `verify_payment`, `verify_remittance`, `process_fintech_fee`, `post_fintech_adjustment` |
| Adjustments | post stock adjustments, view reversal log | `post_adjustment`, `inventory_movements` |
| Alert & verification config | fraud-rule thresholds, reorder points, per-zone `verification_config` (tier thresholds, SMS-on-new-outlet flag, retention days) | config tables |
| System | audit-log browser, scheduled-job status, cache-refresh freshness | `audit_logs`, `cron.job_run_details` |

#### SUPER_ADMIN
ADMIN plus destructive/rare: delete master data, manage other admins, break-glass
access, environment config.

#### AUDITOR (read-only everywhere + reconciliation tools)
| Screen | Purpose | Data source |
|---|---|---|
| **Dashboard — "Reconciliation"** | ledger vs cache drift, funding claimed vs verified, repayment events vs invoice totals, consignment owed vs ledger, open discrepancies | `inventory_movements` vs `stock_balances`; `customer_ledger` vs `outlet_balances`; `invoice_financing_events` vs `invoice_financings`; `remittances` vs `consignment_balances` |
| **Dashboard — "Compliance"** | financing exposure, default analysis, guarantor coverage, verification `NEEDS_REVIEW` backlog, cell-drift / depot-silent flags, zone-violation log, PIN-attempt log, dispute log, indemnity register | `alerts`, `invoice_financings`, `outlet_guarantors`, `fintech_agents`, `transfer_verifications`, `delivery_verifications`, `depot_checkins`, `audit_logs` |
| Audit-log browser | filter by table / actor / date / action; view diffs | `audit_logs` |
| Read-only views | every dashboard, order, transfer, financing deal, ledger | all cache + business tables |
| Export | CSV export of any report | client-side |

No write actions for `AUDITOR` beyond exporting.

---

## 9. RLS policy inventory (summary)

"HQ" below = `SUPER_ADMIN`, `ADMIN`, `REGIONAL_MANAGER` (zone-scoped),
`COMPLIANCE_OFFICER` (global read), `AUDITOR` (global read).

| Table | SELECT scope | Writes |
|---|---|---|
| `profiles` | self; HQ all; zone manager sees zone staff | self-`UPDATE` (display fields, trigger-guarded); rest RPC |
| `market_zones`, `products` | all authenticated (reference data) | RPC (`ADMIN`) |
| `warehouses` | zone-scoped + HQ | RPC |
| `outlets`, `outlet_guarantors`, `outlet_balances`, `customer_ledger`, `customer_credit_profile` | zone-scoped + HQ; fintech sees limited columns for outlets/guarantors on their deals | RPC |
| `orders`, `order_items` | agent's own + warehouse's + zone manager + HQ | RPC |
| `inventory_movements`, `stock_balances`, `consignment_balances`, `stock_counts` | warehouse + zone manager + HQ | RPC (movements INSERT-only, no update/delete) |
| `inventory_transfers`, `transfer_items`, `transfer_verifications`, `transfer_disputes` | source/dest warehouse + zone managers + HQ | RPC |
| `delivery_verifications`, `depot_checkins`, `location_update_requests`, `verification_reviews` | agent's own + warehouse + zone manager + HQ | RPC (verifications INSERT-only; review sets `review_status` via `resolve_verification_review` — `REGIONAL_MANAGER`/`COMPLIANCE_OFFICER`/`ADMIN`) |
| `verification_config` | all authenticated (read) | RPC (`ADMIN`) |
| `location_cell_observations` | zone manager + HQ | job/RPC upsert only |
| `payments`, `remittances` | zone-scoped + HQ | RPC (INSERT-only) |
| `fintech_agents`, `fintech_agent_stats` | own + registering agent + zone manager + HQ | RPC |
| `invoice_financings`, `invoice_financing_events` | fintech (own) + sales agent (own) + zone manager + HQ | RPC |
| `fintech_adjustments` | fintech (own) + HQ | RPC (`ADMIN`) |
| `alerts` | scoped to zone/warehouse/agent + HQ | RPC (ack/resolve) |
| `audit_logs` | `ADMIN`, `SUPER_ADMIN`, `AUDITOR`, `COMPLIANCE_OFFICER` | trigger only |
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
  `post_adjustment` and `post_fintech_adjustment` until specified).
- **Route optimisation** internals, promotions/price lists, push notifications
  (SMS only at launch), gamification.
- **Prisma / Docker** local schema tooling — replaced by the Supabase CLI local
  stack.

---

## 11. Planned fast-follows

1. **Customer view-only app** — `outlets.profile_id` nullable FK, `CUSTOMER`
   role, phone-OTP claim flow (`link_outlet_account(invite_code)` matched on
   phone), SELECT-only RLS on the customer's own orders / ledger / financing
   deals / credit profile, a read-only dashboard.
2. **Provider payment integration** — one Edge Function with per-provider
   adapters, credentials in Supabase Vault, webhook handlers, calling
   `record_fintech_funding` / `verify_fintech_funding` / `process_fintech_fee`.
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
- **Implementation plans** — one per subsystem (RTM core + verification → invoice
  financing → onboarding/guarantors), each via the writing-plans skill.

---

## 13. Open questions

1. **Default fee rate** — on default the spec pays a flat 10% (`default_fee_amount`)
   regardless of the negotiated `fee_rate`. Confirm it's always 10%, not the
   negotiated rate.
2. **Fee timing** — `process_fintech_fee` runs when finance chooses (queue-driven)
   after `REPAID`/`DEFAULTED`. Is there an SLA (e.g. within 7 days), and is it
   ever automatic rather than an ADMIN action?
3. **Guarantor reuse** — one guarantor per outlet reused across all its credit
   orders, or must each credit order name a fresh guarantor acknowledgement?
4. **Guarantor for `CASH_AGENT`** — the spec requires a guarantor for any
   non-`DIRECT_CASH` channel. Confirm `CASH_AGENT` (non-fintech credit) also
   requires one.
5. **PIN delivery** — SMS-only for the fintech transaction PIN, or also in-app
   secure display at verification time?
6. **Transfer GPS tolerance** — confirm `radius_km` per warehouse is the right
   knob, and the same-zone vs cross-zone tightening factor.
7. **Verification review SLA** — how many days before a `NEEDS_REVIEW` item
   auto-escalates to `ADMIN`? (Decided: `REGIONAL_MANAGER` works the queue,
   `COMPLIANCE_OFFICER` staffed later, review never blocks — §6.3.)
8. **Auditor exports** — any regulatory format required (CBN reporting?), or is
   CSV sufficient?
9. **Staff onboarding** — do `WAREHOUSE_MANAGER`/`FIELD_AGENT` accounts get
   created by `ADMIN` invite only, or can a `REGIONAL_MANAGER` create field staff
   in their zones?
