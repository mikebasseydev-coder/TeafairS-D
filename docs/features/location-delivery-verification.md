# Location & delivery verification

**Spec:** §6.3, §5.13, §3.4

## Principle

Capture every free signal, enforce by risk tier, **server decides**. The client
submits a signal bundle to the RPC with an idempotency key (offline bundles
replay with their original `captured_at`). The RPC computes the tier from
server-side history + `verification_config`, decides which signals are mandatory,
enforces the geofence where the tier requires it, writes the `*_verifications`
row, sets `review_status`.

GPS has **no per-request cost** (`haversine_km` in SQL). Capture a fix whenever
available; the tier only decides whether the geofence is enforced.

## Tier ladder

| Tier | Signals | When |
|---|---|---|
| T0 | pre-registered location + passive `depot_checkins` heartbeat | routine depot presence |
| T1 | PIN + `cell_id` + photo (GPS advisory) | default — transfers, repeat-outlet deliveries |
| T2 | T1 + GPS geofence **enforced** | value > `t2_gps_enforced_above`, agent anomaly flags, prior dispute on the pair |
| T3 | T2 + server-verified SMS OTP | **first delivery to a new outlet only**, or value > `t3_sms_above` |

SMS: T3 only, only for non-app-user counterparties (customers), **never** on the
offline critical path (a T3 delivery in dead signal completes on T2 with
`review_status = NEEDS_REVIEW`), **never** for staff↔staff transfers.

## Tables

- `verification_config` — per-zone tuning (+ global default). `sms_on_new_outlet_only`,
  `t2_gps_enforced_above`, `t3_sms_above`, `heartbeat_grace_hours` (48),
  `photo_retention_days` (90). ADMIN-editable.
- `transfer_verifications` (see [transfers](transfers.md)) — gains `tier`,
  `methods[]`, `cell_id`, `review_status`.
- `delivery_verifications` — INSERT-only, for `deliver_order`. `order_id`,
  `outlet_id`, `verified_by`, `tier`, `methods[]`, `gps_*?`, `cell_id?`,
  `photo_path`, `signature_path`, `sms_confirmed?`, `risk_tier`, `review_status`,
  `captured_at`, `verified_at`.
- `depot_checkins` — INSERT-only. `warehouse_id`, `profile_id`, `source`
  (`LOGIN|MANUAL`), `gps_*?`, `cell_id?`, `photo_path?` (weekly), `occurred_at`.
- `location_cell_observations` — learned cell-ID set per location.
  `location_type` (`WAREHOUSE|OUTLET`), `location_id`, `cell_id`, `first_seen_at`,
  `last_seen_at`, `observation_count`. Unseen cell after warm-up → `cell drift`
  alert. Replaces any tower registry.
- `location_update_requests` — a depot/outlet moved. Multi-sample GPS median,
  `status` (`PENDING/APPROVED/REJECTED`).
- `verification_reviews` — INSERT-only. `kind`, `verification_id`, `agent_id`,
  `decision` (`CLEARED|CONFIRMED_ISSUE`), `reviewed_by`. Trailing-window input to
  an agent's **computed** anomaly score.

## RPCs

`verify_transfer`, `deliver_order`, `receive_stock` (signal bundles);
`depot_checkin`; `request_location_update` / `approve_location_update`
(REGIONAL_MANAGER/ADMIN — resets the location's cell warm-up);
`resolve_verification_review(kind, verification_id, decision, note)` —
REGIONAL_MANAGER/COMPLIANCE_OFFICER/ADMIN.

## Review is assurance, never a gate

By the time a `NEEDS_REVIEW` row exists the stock has moved. The item carries an
SLA clock (auto-escalates to ADMIN past SLA via `expire_pending_verifications`),
never blocks the transaction, and its resolution feeds the agent's anomaly score,
which raises the **tier** of their future transactions. Worked by
`REGIONAL_MANAGER` at launch; `COMPLIANCE_OFFICER` when volume justifies it.

## Platform

Verification + depot heartbeat are **`apps/mobile-android` only, by design** — HQ
users are never at a depot or outlet. Coarse IP-geo on HQ login is an
auth-hardening concern, deferred.

## Jobs

- `expire_pending_verifications()` — hourly: unreconciled offline bundles →
  `NEEDS_REVIEW`; `NEEDS_REVIEW` past SLA → escalate to ADMIN.
- `downgrade_stale_photos()` — nightly: photos past `photo_retention_days` on
  non-disputed records → thumbnail, purge full-res.

## Open questions

- §13.6 — `radius_km` per warehouse + same-zone vs cross-zone tightening.
- §13.7 — the `NEEDS_REVIEW` SLA duration.
