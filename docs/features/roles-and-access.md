# Roles & access

**Spec:** §4, §9, §3.7

## Purpose

RBAC + RLS for every table. Identity is centralised in `profiles`; there are no
per-table auth columns.

## Roles (`user_role` enum)

| Role | Tier | App | Scope |
|---|---|---|---|
| `SUPER_ADMIN` | HQ | desktop-windows | global; destructive/config |
| `ADMIN` | HQ | desktop-windows | global; master data, users, finance, fintech program |
| `REGIONAL_MANAGER` | HQ | desktop-windows **+ mobile-android** | assigned zones (`zone_managers`) |
| `COMPLIANCE_OFFICER` | HQ | desktop-windows **+ mobile-android** | global; verification-review + fraud triage only. **Unassigned at launch** |
| `AUDITOR` | HQ | desktop-windows | global read-only + reconciliation tools |
| `WAREHOUSE_MANAGER` | field | mobile-android | one warehouse |
| `INFORMAL_REP` | field | mobile-android | one consignment depot in a market |
| `FIELD_AGENT` | field | mobile-android | one market zone |
| `FINTECH_AGENT` | external | mobile-android | own financing deals + stats; outlets in `operation_zone_id` (read) |

No `CUSTOMER` role at launch — outlets are data records. (Customer view-only
login is a fast-follow, spec §11.)

## Tables

- `profiles` — PK = `auth.users.id`. `role`, `status` (`user_status`),
  name, `phone` (unique), `email`, `market_zone_id?`, `warehouse_id?`,
  `last_login_at`. `chk_profile_scoping` enforces the role→scope-column pairing.
- `zone_managers` (`market_zone_id`, `profile_id`) — regional-manager coverage.

## Mechanisms

- `handle_new_user()` trigger on `auth.users` insert → `profiles` row (role/zone
  from signup metadata, default `FIELD_AGENT` / `PENDING_VERIFICATION`).
- MFA: native `auth.mfa_factors`, enforced for all staff + fintech roles. No MFA
  columns in app tables.
- Private helpers (`SECURITY DEFINER STABLE`, `EXECUTE` revoked from `anon`):
  `private.auth_uid()`, `current_role()`, `current_zone()`, `is_hq()`,
  `managed_warehouse()`, `is_zone_manager_of(zone_id)`, `current_fintech_agent()`.
- Standard zone-scoped SELECT policy:
  ```sql
  using ((select private.is_hq())
         or market_zone_id = (select private.current_zone())
         or (select private.is_zone_manager_of(market_zone_id)))
  ```
- `profiles` allows a narrow self-`UPDATE` (display name, phone) guarded by a
  `BEFORE UPDATE` trigger rejecting `role` / `status` / scope-column changes.

## Invariants

- No INSERT/UPDATE/DELETE grant for `authenticated` on any business table.
- No RLS policy runs a per-row correlated subquery.
- Every column referenced by a policy is indexed.

## RPCs

`invite_staff(p_email, p_role, p_zone_or_warehouse)` — `ADMIN`/`SUPER_ADMIN`.
Entity-verification RPCs live in [onboarding-and-verification](onboarding-and-verification.md).

## Open questions

- §13.9 — can a `REGIONAL_MANAGER` create field staff in their zones, or is it
  `ADMIN`-invite only?
