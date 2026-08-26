# RTM Frontend UI & Caching Architecture

Status: approved
Owner: Michael Bassey
Date: 2026-08-25

Companion to `2026-08-25-backend-aggregator-platform-design.md` (data model,
RBAC roles, `profiles`/`pickup_point_operators`). This doc covers the frontend
surfaces, their offline-first caching behavior, and shared UI components for
the Route-to-Market (RTM) omni-channel application.

## 1. Surfaces overview

| Surface | Target | Role | Auth |
|---|---|---|---|
| HQ Executive Command Console | `windows` (`react-native-windows`) | `admin` | email/password |
| Regional Supervisor Hub | `windows` + `web` | `supervisor` | email/password |
| Field Execution Interface | `mobile` | `rep` | email/password |
| Pick-Up Point Micro-Portal | `mobile` (light) / `web` | `pickup_agent` | email/password |
| Customer Catalogue & Ordering | `web` (public) | `customer` | phone + OTP, order-scoped |

`windows` stays on `react-native-windows`, not a native .NET rewrite — it
consumes the same `ui` package as `mobile`/`web`. Local SQLite access on
Windows goes through an RN-compatible SQLite binding (e.g. `op-sqlite` or
WatermelonDB), not Entity Framework Core.

## 2. HQ Executive Command Console (`windows`, `admin`)

**Analytics Matrix View**
- Cross-tab tables and a revenue-distribution view split by `sale_type`
  (Pre-sale / Street Campaign / Online_Delivery / Online_Pickup).
- Reads the precompiled `aggregated_sales` cache table, never raw `orders` —
  matches the backend spec's "don't recompute on read" convention.
- Local SQLite mirrors `aggregated_sales` for instant renders; a background
  sync pulls deltas from Supabase every 30 minutes.

**Global Multi-Tier Inventory Balancing View**
- Pivot matrix of all SKUs across `Main_Warehouse` / `Supervisor_Hub` /
  `Pickup_Point` / `Van_Stock`, with deficit-alert styling.
- Reads the `current_inventory_balance` materialized view (**not**
  `inventory_ledger` — that table doesn't exist in the approved schema;
  the ledger is `inventory_movements`, and current balances are the
  materialized view derived from it).
- Local delta-tracking records transfers instantly in the local cache;
  pushes to Supabase asynchronously to batch writes.

## 3. Regional Supervisor Hub (`windows` + `web`, `supervisor`)

**Territory Fulfillment Queue**
- Dual-pane: unassigned incoming orders vs. processing queue, scoped to the
  supervisor's own `supervisor_id`.
- Subscribes to Supabase Realtime channel `realtime:territory_channel:{supervisor_id}`
  for live order/status updates — no polling against `orders`.

**Van Load-In Verification & Gate-Pass Module**
- Balancing ledger mapping assigned reps against current van capacity, with
  quantity inputs capped to available `Supervisor_Hub` stock.
- Changes stage locally; "Approve & Transfer" fires one batch RPC that writes
  the corresponding `inventory_movements` rows (`Transfer` type, `Supervisor_Hub`
  → `Van_Stock`) rather than one call per line item.

## 4. Field Execution Interface (`mobile`, `rep`)

**Active Day-Route Map & Visit Module**
- Sequential retailer list ordered by GPS, with visit-status badges
  (`Pending` / `Visited: Pre-sale Captured` / `Visited: No Sale`).
- Strict offline-first: the list reads entirely from local storage; each
  visit result writes to `outlet_visits` locally with `synced = false`,
  reconciled to Supabase when connectivity returns.

**Point-of-Sale (POS) Street Campaign Checkout**
- Compact item-grid basket builder; payment-method toggle
  (`Cash` / `Mobile Transfer` / `On Credit`).
- Basket math runs against a locally cached `wholesale_price` schedule.
  Confirming a sale writes an `orders`/`order_lines` row and an
  `inventory_movements` row (`Sold`, `Van_Stock`, negative `qty_delta`)
  locally first, fully functional while offline.

## 5. Pick-Up Point Micro-Portal (`mobile` light / `web`, `pickup_agent`)

**Package Verification & Delivery Terminal**
- Order-ID/account lookup, item checklist for verification before handover.
- Scoped via `pickup_point_operators` (`profile_id` → `pickup_point_id`):
  the realtime/query filter restricts to `orders` where
  `order_status = 'Ready_For_Pickup'` and `pickup_point_id` matches the
  operator's assigned point.
- Marking a package collected calls an RPC that sets `order_status =
  'Collected'` and writes the corresponding `inventory_movements` row —
  this is also the "feedback loop" that confirms pickup back to HQ/the customer.

## 6. Customer Catalogue & Ordering (`web`, public + `customer`)

New surface, not in the original four — the public entry point for
social-media-driven traffic.

- **Catalogue/landing page is fully public** — browsing `products` requires
  no authentication at all.
- Placing an order (`Online_Delivery` / `Online_Pickup`) requires a
  lightweight **phone + OTP** session (Supabase Auth phone auth), not a full
  email/password account — minimizes friction from a social-media click to
  a placed order.
- Order-status tracking (including the `Ready_For_Pickup` → `Collected`
  transition from §5) is visible to the customer through the same OTP
  session — this is the customer-facing half of the pickup feedback loop.

## 7. Role-Based Access Control (RBAC)

Five roles (`profiles.role`, see backend spec §4.1):

- **`admin`** (HQ, windows/web) — global scope: all territories, config,
  master items, combined financial summaries.
- **`supervisor`** (windows/web) — boundary-locked to matching
  `supervisor_id`: inventory, delivery lines, assigned reps, local online-sales queue.
- **`rep`** (mobile) — sandboxed to their own `rep_id`: van stock, day-route
  customer list.
- **`pickup_agent`** (mobile light/web) — sandboxed to their assigned
  `pickup_point_id` via `pickup_point_operators`: `Ready_For_Pickup` orders
  only, checkout capability only.
- **`customer`** (public web + phone-OTP) — sandboxed to their own orders;
  no visibility into any other customer, route, or inventory data.

## 8. Persistent reactive caching (windows + mobile)

Offline-first caching layer for `windows` and `mobile` (not `web`, which is
always-online by nature):

1. **Reads** come from a local database engine — SQLite (via an RN-compatible
   binding) on `windows`, Room/SQLite on `mobile` (Android). The UI never
   reads live network calls directly.
2. **Writes** land in the local cache instantly with a `synced: false` flag.
3. A persistent background queue worker replicates pending writes to
   Supabase sequentially, batching offline-accumulated entries into a single
   push rather than one request per row, to limit both connection use and
   Supabase compute cost.

This layer is a real architectural addition beyond what the backend spec
assumed (direct-to-Supabase via the injectable client, no local persistence)
— `core`'s data-access pattern needs a sync/cache abstraction added on top of
the existing per-feature `api.ts` functions; the injectable-`SupabaseClient`
calls become what the sync worker uses to flush the queue, not what UI code
calls directly for reads.

## 9. Reusable UI components (in `ui` package)

- **`OfflineSyncIndicator`** — global header widget; three states: Green
  (connected, queue empty), Amber (syncing, background push in progress),
  Red (offline, shows count of locally queued records).
- **`SKUQuantityCounter`** — validated quantity input; blocks quantities
  exceeding the relevant stock pool (`Van_Stock` for street-campaign
  checkout, `Supervisor_Hub` for online-order allocation), reading from
  `current_inventory_balance`.
- **`HybridCustomerSelector`** — context-aware customer search: "Pre-sale"
  filters to customers on the active route; "Street Campaign" allows
  creating an unlinked customer record with captured GPS coordinates.

## 10. Open follow-ups

- RLS policy definitions per role (referenced, not detailed, in backend
  spec §8) now also need to account for `pickup_agent` and `customer`.
- Exact RN SQLite binding choice for `windows`/`mobile` local cache
  (`op-sqlite` vs. WatermelonDB vs. other) — implementation detail, not
  architecture.
- Supabase Realtime channel authorization for `realtime:territory_channel:{supervisor_id}`
  needs a matching RLS/channel-auth rule so a supervisor can't subscribe to
  another territory's channel.
