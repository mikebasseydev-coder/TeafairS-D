# Inventory

**Spec:** §5.4, §5.7, §6.1, §3.4

## Purpose

Stock as an append-only ledger with RPC-maintained balance caches. No mutable
balance column anywhere.

## Tables

- `inventory_movements` — **INSERT-only, no UPDATE/DELETE policy ever.**
  `warehouse_id`, `product_id`, `batch_number?`, `expiry_date?`, `movement_type`
  (`RECEIVED/SOLD/RESERVED/UNRESERVED/TRANSFER_OUT/TRANSFER_IN/RETURNED/DAMAGED/COUNT_ADJUSTMENT/REVERSAL`),
  `qty_delta` (signed, `<> 0`), `reference_type`
  (`order|transfer|count|adjustment|receipt`), `reference_id?`, `reason?`,
  `reversal_of?` (self-FK), `recorded_by`, `occurred_at`, `idempotency_key`
  (unique).
- `stock_balances` — cache, PK (`warehouse_id`, `product_id`, `batch_number`).
  `on_hand`, `reserved`, `damaged`. `CHECK on_hand >= 0 AND reserved >= 0 AND
  reserved <= on_hand`. Available = `on_hand - reserved`.
- `consignment_balances` — cache for `INFORMAL_REP_DEPOT` / `CONSIGNMENT`
  warehouses, PK `warehouse_id`. `stock_value_held`, `cash_owed`,
  `remitted_to_date`, `debt_limit`. See
  [payments-debt-remittances](payments-debt-remittances.md).
- `stock_counts` — `warehouse_id`, `product_id`, `batch_number?`, `counted_qty`,
  `system_qty` (snapshot), `discrepancy` (generated), `counted_by`, `status`
  (`PENDING_REVIEW/ACCEPTED/REJECTED`), `reviewed_by?`.

## RPCs

- `receive_stock(warehouse_id, lines, reference, photo_path, waybill_photo_path, idempotency_key)`
  — WAREHOUSE_MANAGER; `RECEIVED` movements + a T0/T1 verification.
- `submit_stock_count(warehouse_id, lines)` — WAREHOUSE_MANAGER/INFORMAL_REP;
  snapshots `system_qty` per line.
- `review_stock_count(count_id, decision, note)` — REGIONAL_MANAGER/ADMIN;
  `ACCEPTED` → `COUNT_ADJUSTMENT` movement.
- `post_adjustment(warehouse_id, product_id, batch_number, qty_delta, reason)` —
  ADMIN; explicit `REVERSAL`/adjustment with reason.
- Stock is also moved by `place_order` (reserve), `deliver_order` (→ SOLD),
  `cancel_order` (release), and the transfer RPCs.

## Invariants

- A wrong entry is corrected by a compensating movement, never an edit.
- Only RPCs write `stock_balances` / `consignment_balances`, in the same
  transaction as the movement.
- Availability check + reserve is atomic (`UPDATE … WHERE available >= qty`
  inside the transaction) — no check-then-act race.

## Jobs

- `reconcile_stock_balances()` — nightly: recompute from the ledger, alert on any
  drift.
