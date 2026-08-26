# CLAUDE.md (backend)

## Status

Not yet scaffolded. This file documents the target architecture from
`docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md`
(§3–4) so implementation follows it. `prisma/schema.prisma`,
`docker-compose.yml`, and `package.json` don't exist yet — scaffolding them is
a separate implementation step, not done by writing this file.

## Purpose

`backend/` is not a runtime server and is never deployed. Production backend
is Supabase (Postgres + Auth) — see repo-root `CLAUDE.md`. This directory
exists solely so schema changes can be authored and tested fast against a
disposable local Postgres before being promoted to Supabase migrations.

## Workflow

1. Edit `backend/prisma/schema.prisma`.
2. `docker-compose up -d` to bring up a throwaway local Postgres
   (`backend/docker-compose.yml`).
3. `npx prisma migrate dev` against that local DB to iterate and test.
4. Once validated, `npx prisma migrate diff --script` to generate the
   equivalent SQL.
5. Copy/adapt that SQL into repo-root `supabase/migrations/`
   (Supabase-CLI-managed) and apply it to the hosted Supabase project. That's
   the only path a schema change takes to production — `backend/`'s local
   Postgres is never itself deployed or connected to by any app.

Some constructs Prisma can't express directly — Postgres
`GENERATED ALWAYS AS ... STORED` columns, multi-column `CHECK` constraints,
materialized views — need hand-written SQL added to the `supabase/migrations/`
output; don't expect `prisma migrate diff` to produce them.

## Architecture conventions

Full data model and rationale: `docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md`.
When touching schema here:

- RBAC is centralized through `profiles` (`profile_id` = `auth.users.id`
  directly, `role` enum, plus one `associated_*_id` column per role pointing
  at `supervisors`/`sales_reps`/`pickup_points`/`customers`). The pointer
  direction is profile → entity, one way only — never add a reverse
  `profile_id` column on an entity table, and never add a role without a
  matching arm in `chk_profile_role_targeting`.
- Every `SECURITY DEFINER` function (the auto-provisioning trigger,
  `run_sales_aggregator`, any future one) must pin `SET search_path = public`
  — omitting it is a search-path-hijacking vulnerability, not a style nit.
- RLS is the actual enforcement boundary, not client-side filtering. A new
  territory-scoped table needs the same five-policy pattern as `orders`
  (`hq_global_access`, `supervisor_territory_isolation`, `sales_rep_isolation`,
  `pickup_agent_isolation`, `customer_own_orders_only`) before shipping.
- Inventory is an append-only `inventory_movements` ledger, not a balance
  column — never add a `qty_on_hand` field to a pool-owning table. Current
  balance is read from the `current_inventory_balance` materialized view
  (refreshed end-of-day, not per-write).
- `inventory_movements` rows are pool-targeted via the
  `chk_movement_pool_targeting` CHECK constraint, enforcing that exactly one
  of `rep_id`/`pickup_point_id`/`supervisor_id` is set per `pool_type`. Don't
  relax this to make an edge case easier — add a new `pool_type` instead.
- `aggregated_sales` is populated by a Postgres function
  (`run_sales_aggregator`-style, `INSERT ... ON CONFLICT DO UPDATE`) called at
  end-of-day, not queried live from `orders`. New aggregate metrics should
  follow the same cache-table-plus-function pattern rather than computing on
  read.

## Commands

Not runnable yet — nothing in `backend/` besides this file exists until the
implementation plan scaffolds `package.json`, `docker-compose.yml`, and
`prisma/schema.prisma`.
