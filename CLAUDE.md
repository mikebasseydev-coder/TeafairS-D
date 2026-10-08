# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Teafair is a **multi-tenant Route-to-Market (RTM) and embedded-liquidity
platform** for African FMCG supply chains. Several brand owners (Nestlé,
Unilever, …) run their own distribution networks on one Supabase deployment,
over a shared registry of retail shops. **Teafair is itself a tenant**
(`TEAFAIR`), selling its own house brands.

Third-party POS agents (Moniepoint, OPay, PalmPay) act as liquidity nodes that
replace high-interest street credit for shop owners. **Paystack is the
exclusive collection engine** and splits each partner's commission natively
through Subaccounts.

## The governing document

**`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`
(Spec A) is the authority.** Read its §2 locked decisions before changing
anything structural. The August and September 2026 specs and plans it
superseded have been removed; git history still holds them.

Spec A is the first of four (§12): B app shell, C RTM core, D money and
integrations. Its implementation runs in four phases (§14).

## Repository state

| Path | Status |
|---|---|
| `supabase/` | **Phases 1–3 done**: 20 migrations, 287 pgTAP assertions, 4 Edge Functions. See `supabase/CLAUDE.md` |
| `docs/superpowers/specs/2026-10-05-…` | Spec A — the authority |
| client app | **none yet**: built fresh under Spec B as a flat `src/`. `frontend/`, `apps/` and `docs/features/` were removed (§13) |

Phase 4 (client offline queue) needs the Spec B app shell.

## Architecture in one screen

```
Android app (React Native/Expo, MMKV offline queue)
  │ POST /functions/v1/<name>   Authorization: Bearer <user JWT>
  ▼
Edge Function gateway (Deno)    JWT, Zod, PIN, Paystack/KudiSMS/KYC IO
  │ forwards the caller's JWT — never the service-role key for user work
  ▼
Postgres SECURITY DEFINER RPC   the transaction: idempotency, live
                                membership + role check, writes, audit
```

Supabase only: Auth with a Custom Access Token Hook, Vault, Deno Edge
Functions, `pg_cron`, PostGIS. **No Azure, no Prisma, no server of our own.**
Android only at launch; the Windows HQ client is deferred.

## Rules that hold everywhere (Spec A §9)

- **No direct client writes.** `authenticated` has `SELECT` only. Every
  mutation is a `SECURITY DEFINER` RPC.
- **Never accept `tenantId` from a client.** The tenant comes from the JWT
  (`public.jwt_tenant_id()`) and is re-verified **live** against
  `tenant_users`. Claims propose; the database decides.
- **Never call an RPC from a user-facing Edge Function with the service-role
  key.** Forward the caller's `Authorization` header.
- **Nothing in the `auth` schema.** Helpers live in `public` and read claims
  through `auth.jwt()`, never `current_setting('request.jwt.claim.*')`.
- Every `SECURITY DEFINER` function pins `SET search_path = public, pg_temp`.
- RLS policies are `FOR SELECT` only, using `(select auth.uid())` and
  `public.*` helpers — never a per-row correlated subquery.
- Every mutation takes a client-generated `p_idempotency_key uuid` first,
  generated at enqueue time, not send time.
- `bvn_nin_hash` lives only in `user_secure_profiles` (owner-only).
- `teafair_agent_id` is `NOT NULL` on `orders`, `payments`,
  `commission_records`; nullable on `audit_logs` only for cron/webhook rows.
- Workflow statuses are `text` + `CHECK`; stable sets are enums.
- Money `NUMERIC(15,2)`, quantities `NUMERIC(14,3)`, timestamps `timestamptz`.
- `.env` / `.env*.local` are gitignored. Never hardcode Supabase URLs or keys.

## Commands

```bash
supabase start          # local stack (needs Docker Desktop running)
supabase db reset       # wipe local DB, replay every migration
supabase migration up   # apply only new migrations
supabase test db        # run all pgTAP tests — look for "Result: PASS"
```

Linked to remote project `vwmjyfjdwrohfizljxrq`; all 20 migrations and the
four Edge Functions are deployed there (2026-10-08). See `supabase/CLAUDE.md`
for the remote secrets. Nothing else is pushed until explicitly asked.
