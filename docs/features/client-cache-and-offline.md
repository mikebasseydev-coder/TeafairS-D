# Client cache & offline

**Spec:** §3.8, §6.1, §6.2

## Purpose

`apps/mobile-android` works in 2G market stalls. It keeps a persistent client
cache + a write queue. `apps/desktop-windows` is online-only.

## What is cached

Only data the agent could read online (RLS applies at fetch), scoped to their
zone/warehouse:

- their outlets + `outlet_guarantors` + `outlet_balances`
- `products` (catalogue)
- their open/recent `orders` + `order_items`
- their `invoice_financings`
- their `notifications`
- the source depot's `stock_balances` snapshot
- the zone's `verification_config`

**Not cached:** other agents' data, other zones, HQ dashboards, `audit_logs`, any
fintech PIN/secret.

## Sync

Delta, not full refetch. Each collection tracks a `synced_at` cursor; on
reconnect: `WHERE updated_at > cursor` (mutable) or `WHERE created_at > cursor`
(append-only), RLS-scoped. No realtime, no Edge Function.

## Write queue

Ordered `{rpc, args, p_idempotency_key, captured_at}`. Flushes **sequentially per
agent** in `captured_at` order on reconnect.

- validation failure (stock gone, credit exceeded, price changed) → drop item,
  raise a `notification` to redo it
- transient error → keep, retry with backoff

## Cannot happen offline

Live-second-party / live-secret actions: transfer & collection **PIN
verification**, **T3 SMS**, **financing-offer accept** (live terms version).

## Cost

Cost-neutral to positive. Device storage free. Cold-start cache ≈ a few hundred
KB egress once. Delta queries are small. Steady state *reduces* cost — local
reads instead of polling cache tables on every screen focus. A per-flush rate cap
bounds burst load.

## Fraud / abuse validation

Offline capture **never** relaxes validation — every queued action runs the same
RPC on flush:

| Vector | Control |
|---|---|
| Identity spoof | `auth.uid()` from the live JWT, never the payload |
| Stale price | RPC re-reads `products`, reprices; changed price fails the item; totals server-computed |
| Over-stock / over-credit | live atomic check on flush; offline orders are `PENDING` until an online second party confirms |
| Backdating | server sets `created_at = now()`; `captured_at` in the future or older than `max_offline_age_hours` (config, default 48) is rejected; large gap → `run_fraud_scans()` backdating rule |
| Queue tampering (rooted device) | payload still passes full RPC validation; financial facts are server-owned — tampering buys nothing |
| Stale verification bundle | `captured_at` vs photo EXIF; geofence + cell checked on flush; stale → `NEEDS_REVIEW` |
| Volume abuse | daily-volume fraud rule + per-flush cap |

## Open question

- Cache implementation — TanStack Query + MMKV persistence vs a thin SQLite
  mirror. To settle in the architecture/scaffold spec.
