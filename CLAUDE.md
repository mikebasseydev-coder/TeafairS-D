# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

TEFAIR's Route-to-Market platform for the Nigerian informal-retail market:
field agents move consignment stock through market-zone depots to shop owners,
with an **invoice-financing** feature that lets Fintech agents (OPay, PalmPay,
Moniepoint) pay TEFAIR an invoice in full immediately and collect from the
customer over time.

**As of 2026-09-03 the project is mid-pivot to a fully serverless architecture.**
The governing documents:

- `docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md` — **what
  it does**: data model, RPCs, RLS, features, screens.
- `docs/superpowers/specs/2026-09-04-architecture-and-scaffold-design.md` — **how
  it's built**: framework choices, `packages/` layout, build & local-dev
  pipelines, migration from `frontend/`.

Together they supersede the data-model/architecture portions of the three August
specs and make the `2026-08-25-backend-foundation.md` plan (Prisma/Docker)
obsolete.

### Target architecture (per the 2026-09-03 spec)

- **Backend: Supabase only** — Postgres + Auth (MFA) + Storage + `pg_cron` + one
  Edge Function (`notify`). No server, no Docker, no Prisma.
- **Write path = `SECURITY DEFINER` Postgres RPCs**, idempotent on a
  client-supplied key. Business tables grant `authenticated` SELECT only; RLS
  scopes reads via `(select auth.uid())` + `private.*` helper functions.
- `profiles.id` **is** `auth.users.id` (no surrogate-key split).
- Money and inventory are an **append-only ledger + RPC-maintained cache** — no
  mutable balance columns. Dashboards read cache tables refreshed by `pg_cron`,
  never live views.
- **Two apps:** `apps/mobile-android` (**Expo** / React Native — field roles +
  HQ-on-the-go for `REGIONAL_MANAGER` / `COMPLIANCE_OFFICER`, 6 roles) and
  `apps/desktop-windows` (**bare RN + `react-native-windows`** — the full HQ
  workstation). **No web target.**
- `packages/shared-*` (types, schemas, supabase client, offline sync, hooks, ui,
  config) for cross-app code; `pnpm` workspaces + Turborepo.

### Current repository state

Nothing in the target layout is scaffolded yet. What exists:

| Path | Status |
|---|---|
| `docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md` | source of truth for behaviour |
| `docs/superpowers/specs/2026-09-04-architecture-and-scaffold-design.md` | source of truth for structure/build |
| `docs/features/` | per-feature reference docs (seed each implementation plan) |
| `apps/CLAUDE.md`, `supabase/CLAUDE.md` | target conventions — **directories not yet scaffolded** |
| `frontend/` | **legacy** — the old npm-workspaces Expo scaffold (`core` + `mobile`). Kept for reference during migration; see `frontend/CLAUDE.md`. To be replaced by `apps/` + `packages/`. |
| `backend/` | **removed** — Prisma/Docker sandbox is gone |
| the three August specs, `docs/superpowers/plans/` | historical — superseded, kept for rationale |

## Working here right now

The project is in planning. Before implementation:

1. The platform spec (2026-09-03) and architecture spec (2026-09-04) are written
   and under review (open questions in each spec's final section).
2. Still to write: **implementation plans** — first the monorepo-scaffold plan
   (architecture spec §12–13), then one per subsystem via the writing-plans skill
   (roles/access → RTM core + verification → invoice financing →
   onboarding/guarantors).
3. `frontend/` is a **greenfield restart** — patterns carry over (injectable
   Supabase client, `unwrapSupabaseResult`, storage-adapter, auth-store shape),
   code does not.

## Conventions that already hold (from the spec)

- **Never** put a write on a business table for the `authenticated` role. Every
  mutation is an RPC.
- **Never** add a mutable balance column. Post a ledger row; the RPC updates the
  cache in the same transaction.
- Every `SECURITY DEFINER` function pins `SET search_path`.
- RLS predicates use `(select auth.uid())` and `private.*` helpers — never a
  per-row correlated subquery.
- Workflow statuses are `text` + `CHECK` (evolve without `ALTER TYPE`); stable
  sets (role, severity, provider, tier…) are enums.
- `.env` / `.env*.local` are gitignored — never hardcode Supabase URLs/keys.
- Money `NUMERIC(15,2)`, quantities `NUMERIC(14,3)`, timestamps `timestamptz`.

## Feature docs

`docs/features/` — one reference per feature (tables, RPCs, screens by role,
invariants, jobs, open questions), each cross-linked to a spec section. Start
there when implementing a feature; the spec is the authority on cross-feature
rules.
