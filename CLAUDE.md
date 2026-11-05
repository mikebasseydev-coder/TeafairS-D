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
| `supabase/` | **Phases 1–3 done**: 113 migrations, 3785 pgTAP assertions in 69 files, 33 Edge Functions; addenda A1 (web storefront) and A2 (buyer contact privacy) pushed to the remote on 2026-10-15; Spec D1 (web money loop), addendum A3 (web chat and ticketing), addendum A4 (internal staff messaging) and addendum A5 (refund policy, WhatsApp-verified checkout, fulfilment, support photos) and per-tenant sale categories with NAFDAC numbers break-bulk wholesale packs and Teafairweb retail pricing (no discounts, transport fare, POS agent commission), Sentry observability, and auth hardening with the Send SMS (WhatsApp) and Send Email (Resend) hooks, A6 Monvelo Step 1 and the A6 §15 domain separation (`web_*` and `monvelo_*` names; the `fintech_*` names are gone), and A6 Step 1c (CSM, contact reports, zero-backdoor citations) and Step 2 (supply days, pledges, trade orders, stock reservation, operational states, financings, claims, the tenant ledger) built locally, not pushed; A6 Step 3 (funding over Paystack bank transfer with the payer binding, dispatch, the shop owner's delivery and repayment codes, the late charge, the money sweep, Monvelo refunds) built locally, not pushed; the A6 §19.4 addition (the open exposure cap (₦1,000,000 since the A6 §21 tenfold scaling of 2026-11-03; it was ₦100,000), REFUND_DUE freeing room at once, the pledge restored when the refund is confirmed, the lender reconciliation summary for agents, ZSAs and ASAs) built locally, not pushed; the A6 §20 market-maker allowance (a claim blocked only by the exposure cap is held 15 minutes; since A6 §22 (2026-11-03) the zone's ZSA or the area's ASA decides, the ZSM oversees read-only and decides only when no field agent is eligible; never the raiser nor a member of the agent; up to ₦3,000,000 without seeing the agent) built locally, not pushed; the agent exposure meter `get_monvelo_agent_exposure(p_agent_id uuid default null)` (members and Monvelo staff only, 42501 for everyone else; A6 §21.3) built locally, not pushed; the two deferred Step 1c/2 minors (claims, hold allows and TM approvals refuse an ended supply day live; ZSM nomination reads scoped to their zones) built locally, not pushed; addendum A7 (tenant support tickets for TENANT_ADMIN to the CSM or the MONVELO_OPERATOR pool, and buyer and tenant ticket emails through `email_outbox` and the `email-outbox-send` cron function) built locally on branch `feature/addendum-a7-tenant-support`, not merged or pushed. See `supabase/CLAUDE.md` |
| `docs/superpowers/specs/2026-10-05-…` | Spec A — the authority |
| `docs/superpowers/specs/2026-10-15-web-…` | Addendum A1 to Spec A — web storefront, agent codes, terminal venues |
| `docs/superpowers/specs/2026-10-15-buyer-…` | Addendum A2 to Spec A — buyer contact privacy |
| `docs/superpowers/specs/2026-10-21-addendum-a3-…` | Addendum A3 to Spec A — web chat and ticketing |
| `docs/superpowers/specs/2026-10-21-addendum-a4-…` | Addendum A4 to Spec A — internal staff messaging |
| `docs/superpowers/specs/2026-10-23-addendum-a5-…` | Addendum A5 to Spec A — refund policy, WhatsApp-verified checkout, fulfilment and delivery code, support photos (built locally, not pushed) |
| `docs/superpowers/specs/2026-10-28-addendum-a6-…` | Addendum A6 to Spec A — Monvelo (B2B trade financing) and §15 domain separation (built locally, not pushed); §16–§18 (Step 1c and Step 2: CSM, TENANT_ADMIN, LOGISTICS_MANAGER, contact reports, the tenant ledger, stock, operational states, financings and claims) built locally, not pushed; plan at `docs/superpowers/plans/2026-10-29-monvelo-step1c-step2.md`; §19 (Step 3 calls: funding, delivery, repayment) built locally, not pushed; plan at `docs/superpowers/plans/2026-10-31-monvelo-step3-funding-repayment.md`; §20 (the market-maker allowance) built locally, not pushed; plan at `docs/superpowers/plans/2026-11-02-monvelo-market-maker-allowance.md`; §21 (the limits scaled to ₦1,000,000 and ₦3,000,000; §21.3 the agent exposure meter RPC) built locally, not pushed; §22 (field agents decide holds) built locally, not pushed |
| `docs/superpowers/specs/2026-11-05-addendum-a7-…` | Addendum A7 to Spec A — tenant support tickets and ticket emails (built locally, not pushed); plan at `docs/superpowers/plans/2026-11-05-addendum-a7-tenant-support-and-ticket-emails.md` |
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
- Buyer contact details live only in `order_contacts` (the ZSM and the order's TM).
- `teafair_agent_id` is `NOT NULL` on `orders`, `payments`,
  `web_commissions`; nullable on `audit_logs` only for cron/webhook rows.
- Naming: the `fintech_liquidity_*` migration files keep their historical names; they hold OTP, the Paystack webhook and D1 money. The domains are `web_*` (storefront) and `monvelo_*`; web never touches Monvelo (A6 §15).
- Workflow statuses are `text` + `CHECK`; stable sets are enums.
- Money `NUMERIC(15,2)`, quantities `NUMERIC(14,3)`, timestamps `timestamptz`.
- `.env` / `.env*.local` are gitignored. Never hardcode Supabase URLs or keys.
- **Ruling 46 (service-role key standard)**, detailed in `supabase/CLAUDE.md`:
  (1) API keys are read only through `_shared/core/keys.ts`, which prefers the
  `sb_secret_` / `sb_publishable_` keys and falls back to the legacy keys.
  Every secret key has full `service_role` power: a key's name is for
  revocation, not scope. (2) Only reviewed system and public functions reach
  the secret key, each authenticating its caller first. No Monvelo gateway
  holds it, and the database still decides every write. (3) No secret is ever
  under `EXPO_PUBLIC_`, `NEXT_PUBLIC_` or `VITE_`, or in a client tree. The
  tests `service-role-guard`, `secret-scoping` and `keys` enforce all three.

## Commands

```bash
supabase start          # local stack (needs Docker Desktop running)
supabase db reset       # wipe local DB, replay every migration
supabase migration up   # apply only new migrations
supabase test db        # run all pgTAP tests — look for "Result: PASS"
```

Linked to remote project `vwmjyfjdwrohfizljxrq`. Per the 2026-10-15 push
(GitHub `main` at `42dd15b`), it has the 29 migrations through A1 and A2 and
six Edge Functions; Spec D1 is not deployed. See `supabase/CLAUDE.md` for the
remote secrets and the D1 deploy steps. Nothing else is pushed until
explicitly asked.
