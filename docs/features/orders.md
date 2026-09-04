# Orders

**Spec:** §5.5, §6.1, §6.3

## Purpose

Two-stage order capture: a field agent's order is provisional until a second
party confirms.

## Tables

- `orders` — `order_number` (unique, `ORD-YYYYMMDD-NNNN`), `outlet_id`,
  `agent_id`, `market_zone_id`, `source_warehouse_id`, `guarantor_id?` (**required
  by the RPC for any non-`DIRECT_CASH` channel**), `status` (`PENDING/CONFIRMED/
  DISPATCHED/DELIVERED/CANCELLED`), `payment_channel` (`DIRECT_CASH/CASH_AGENT/
  FINTECH_FINANCED`), `subtotal`, `discount`, `tax`, `total` (generated),
  `amount_paid`, `idempotency_key` (unique), `confirmed_by?`, `confirmed_at?`.
- `order_items` — `order_id` (cascade), `product_id`, `quantity` (`> 0`),
  `unit_price` (RPC-snapshotted from `products`), `line_total` (generated).
  `UNIQUE(order_id, product_id)`.

## Lifecycle

`place_order` → `PENDING` (provisional reservation) → `confirm_order` (WM/ADMIN)
→ `CONFIRMED` (reservation committed) → `dispatch_order` (WM) → `DISPATCHED` →
`deliver_order` (FIELD_AGENT, with the signal bundle — see
[location-delivery-verification](location-delivery-verification.md)) →
`DELIVERED` (reservation → `SOLD`). `cancel_order` releases the reservation and
reverses the ledger.

## RPCs

- `place_order(outlet_id, source_warehouse_id, guarantor_id, items, payment_channel, notes, idempotency_key)`
  — FIELD_AGENT/INFORMAL_REP. Validates zone, outlet `ACTIVE`, guarantor when
  credit, product active + stocked, computes prices, atomic reserve. Ledger
  effect by channel:
  - `DIRECT_CASH` / `CASH_AGENT` → `customer_ledger` `INVOICE`, raises
    `outlet_balances`.
  - `FINTECH_FINANCED` → `customer_ledger` `FINANCED` only, **no TEFAIR
    receivable**.
  - source is an `INFORMAL_REP_DEPOT` → also accrues
    `consignment_balances.cash_owed`.
- `confirm_order`, `dispatch_order`, `deliver_order`, `cancel_order`.

## Invariants

- Nothing an agent enters alone is final — `PENDING` moves only provisional
  balances.
- Prices/totals are server-computed; the client sends `product_id` + `quantity`.
- Every credit order names an `ACTIVE` guarantor.

## Open questions

- §13.3 — one guarantor per outlet reused, or a fresh acknowledgement per order?
- §13.4 — does `CASH_AGENT` require a guarantor too? (spec currently says yes)
