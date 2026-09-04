# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

TEFAIR's Route-to-Market platform for the Nigerian informal-retail market:
field agents move consignment stock through market-zone depots to shop owners,
with an **invoice-financing** feature that lets Fintech agents (OPay, PalmPay,
Moniepoint) pay TEFAIR an invoice in full immediately and collect from the
customer over time.

**As of 2026-09-03 the project is mid-pivot to a fully serverless architecture.**
The governing document is
`docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md`. It
supersedes the data-model/architecture portions of the three August specs and
makes the `2026-08-25-backend-foundation.md` plan (Prisma/Docker) obsolete.

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
- **Two apps:** `apps/mobile-android` (React Native — field: sales agents, depot
  reps, warehouse managers, fintech agents) and `apps/desktop-windows`
  (`react-native-windows` — HQ: admins, regional managers, compliance,
  auditors). **No web target.**
- `packages/shared-*` for cross-app code; `pnpm` workspaces.

### Current repository state

Nothing in the target layout is scaffolded yet. What exists:

| Path | Status |
|---|---|
| `docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md` | the current source of truth |
| `docs/features/` | per-feature reference docs (seed each implementation plan) |
| `apps/CLAUDE.md`, `supabase/CLAUDE.md` | target conventions — **directories not yet scaffolded** |
| `frontend/` | **legacy** — the old npm-workspaces Expo scaffold (`core` + `mobile`). Kept for reference during migration; see `frontend/CLAUDE.md`. To be replaced by `apps/` + `packages/`. |
| `backend/` | **removed** — Prisma/Docker sandbox is gone |
| the three August specs, `docs/superpowers/plans/` | historical — superseded, kept for rationale |

## Working here right now

The project is in planning. Before implementation:

1. The 2026-09-03 spec is written and under review (§13 has open questions).
2. Still to write: an **architecture / repo-scaffold spec** (`apps/` + `packages/`
   structure, pnpm, APK/MSIX build, shared Supabase client, session storage,
   generated types), then **implementation plans** per subsystem via the
   writing-plans skill (RTM core + verification → invoice financing →
   onboarding/guarantors).
3. `frontend/` is a **greenfield restart** under the new layout — patterns carry
   over (injectable Supabase client, `unwrapSupabaseResult`, storage-adapter,
   auth-store shape), code does not.

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
