# Transfers

**Spec:** §5.6, §6.3, §3.4

## Purpose

Stock moves between warehouses under dual-party verification. Staff↔staff — no
SMS, ever.

## Tables

- `inventory_transfers` — `waybill_number` (unique), `source_warehouse_id`,
  `dest_warehouse_id` (`<> source`), `source_zone_id`, `dest_zone_id`,
  `is_cross_zone` (generated), `status` (`PENDING/IN_TRANSIT/DELIVERED/RECONCILED/
  DISPUTED/CANCELLED/EXPIRED`), `total_value`, `item_count`, `initiated_by`,
  `idempotency_key` (unique), `dispatched_at?`, `delivered_at?`,
  `reconciled_at?`, `expires_at`.
- `transfer_items` — `qty_sent` (`> 0`), `qty_received?`, `unit_value`.
  `UNIQUE(transfer_id, product_id, batch_number)`.
- `transfer_verifications` — INSERT-only. `party` (`SENDER|RECEIVER`),
  `verified_by`, `pin_verified`, `methods[]`, `tier` (`T0..T3`), `gps_*?`,
  `cell_id?`, `photo_path`, `review_status` (`AUTO_OK|NEEDS_REVIEW`),
  `captured_at`, `verified_at`.
- `transfer_disputes` — `opened_by`, `reason`, `status` (`OPEN|RESOLVED`),
  `resolution?`, `resolved_by?`.

## Lifecycle

`initiate_transfer` (reserve at source, set `expires_at`) → sender
`verify_transfer` → `IN_TRANSIT` → `mark_transfer_delivered` → `DELIVERED` →
receiver `reconcile_transfer` (set `qty_received` per line, post `TRANSFER_OUT` at
source / `TRANSFER_IN` at dest) → `RECONCILED`, or any qty mismatch → open
`transfer_disputes`, `→ DISPUTED` → `resolve_transfer_dispute`
(REGIONAL_MANAGER/ADMIN, posts adjustment movements).

## RPCs

- `initiate_transfer(source, dest, items, idempotency_key)` — WM(source)/ADMIN.
- `verify_transfer(transfer_id, party, pin, signal_bundle, idempotency_key)` —
  source/dest WM. `signal_bundle = {gps?, cell_id?, photo_path, captured_at}`;
  bcrypt PIN + 5-attempt/15-min lockout; server computes tier, runs
  `haversine_km` (geofence enforced at T2+), upserts
  `location_cell_observations`.
- `mark_transfer_delivered`, `reconcile_transfer`, `resolve_transfer_dispute`.

## Jobs

- `expire_stale_transfers()` — hourly: `PENDING` past `expires_at` → `EXPIRED`,
  release the reservation.

## Invariants

- Both parties verify independently; the both-verified check re-reads state
  inside the transaction (no stale read).
- Any qty mismatch forces `DISPUTED` — never silently accepted.
