# CLAUDE.md (supabase)

## Status

**Not yet scaffolded.** This file records the target conventions from
`docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md`. The
`supabase/` directory currently holds only this file. Scaffolding (`config.toml`,
`migrations/`, `functions/notify/`, `seeds/`) is a separate implementation step.

## What lives here

Supabase is the **entire backend** — Postgres + Auth (MFA) + Storage + `pg_cron`
+ one Edge Function. There is no server, no Docker, no Prisma. This directory is
the production source of truth, managed by the Supabase CLI.

```
supabase/
├── config.toml
├── migrations/          # ordered SQL — schema, RLS, functions, cron, buckets
├── seeds/               # local dev seed data (all roles)
└── functions/notify/    # the ONLY Edge Function (SMS now, push later)
```

## Non-negotiable conventions

### Write path
- Every mutation is a `SECURITY DEFINER` function in a private schema, exposed as
  an RPC. Business tables `GRANT SELECT` to `authenticated` and nothing else.
- Each RPC: pins `SET search_path`; resolves the caller with
  `(select auth.uid())` and checks role/zone **in the body**; takes
  `p_idempotency_key uuid` and returns the prior result if the key was seen;
  does all reads and writes in one transaction; writes the ledger row(s) and
  updates the cache table(s) together.

### RLS
- Policies use `(select auth.uid())` and `SECURITY DEFINER STABLE` helpers in a
  private schema (`private.current_role()`, `private.current_zone()`,
  `private.is_hq()`, …) with `EXECUTE` revoked from `anon`. **No per-row
  correlated subquery in a policy.**
- `profiles.id` = `auth.users.id`. A `handle_new_user()` trigger provisions the
  `profiles` row on `auth.users` insert.
- Every column a policy filters on is indexed. No speculative indexes.

### Data model
- Money and inventory are an **append-only ledger** (`inventory_movements`,
  `payments`, `remittances`, `customer_ledger`, `invoice_financing_events`,
  `*_verifications`, `audit_logs`) — no UPDATE/DELETE policy, ever. Corrections
  are compensating rows (`REVERSAL` / `ADJUSTMENT`) with a reason + approver.
- Balances (`stock_balances`, `outlet_balances`, `consignment_balances`,
  `fintech_agent_stats`, `customer_credit_profile`) are **caches maintained by
  RPCs** in the same transaction as the ledger write, reconciled nightly against
  the ledger.
- Dashboards read **cache tables** (`daily_sales_rollup`, `zone_health`,
  `fintech_program_health`) refreshed by `pg_cron`. **No live views.**
- Workflow statuses: `text` + `CHECK`. Stable sets: enums.
- Extensions: `pgcrypto` only. No `uuid-ossp`, no PostGIS (`haversine_km()` SQL
  helper for GPS proximity).
- PINs: bcrypt via `pgcrypto` (`crypt` / `gen_salt('bf', 12)`) + attempt
  lockout. MFA is native `auth.mfa_factors` — no MFA columns in app tables.

### Edge Functions
- Exactly one at launch: `notify`, invoked once per minute by `pg_cron` to drain
  `notifications_outbox` (SMS; push later).
- Anything that is pure DB logic is an **RPC**, not an Edge Function. Anything
  scheduled and pure-SQL is a `pg_cron` job, not an Edge Function.
- Post-launch, every Edge Function is an **outbound connector** on the
  integration framework: `sync-firs` (Phase 1), `sync-quickbooks` (Phase 1.5),
  `sync-payroll` (Phase 2). Each drains `integration_outbox` for its `target`,
  creds in Vault. The framework tables (`integration_outbox`,
  `integration_entity_map`, `integration_config`, `fx_rates`) and the RPC
  enqueue hooks are in the **launch schema**; only the functions are phased.

### Currency
- Internal money is **NGN, single currency** — no per-row currency column. USD is
  reporting-only, derived from `fx_rates` at report/sync time (`set_fx_rate`,
  `ADMIN`).

### Money flow (invoice financing)
- Fintech pays TEFAIR **100%** upfront (verified by finance). TEFAIR's cost is a
  capped fee: negotiated **≤ 10%** on successful repayment, flat **10%** on
  Fintech-declared default. **TEFAIR never carries principal.**
- Fintech accepts an **indemnity** e-agreement before verification; the customer
  names a **guarantor** for any credit stock.

## Per-feature detail

`docs/features/` — one doc per feature with its tables, RPCs, jobs, invariants,
and the spec section it derives from.
