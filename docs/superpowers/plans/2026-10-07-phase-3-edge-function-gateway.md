# Phase 3 — Edge Function Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Spec A Phase 3 gateway layer: a shared gateway module, the `auth-verify-claims` access-token hook, the `process-payment` Paystack webhook, and OTP issue/verify endpoints. Everything is tested first against the local Supabase stack.

**Architecture:** Each Edge Function is a self-contained feature directory under `supabase/functions/<name>/`:
- `index.ts` only wires live dependencies.
- `handler.ts` exports a `create…Handler(deps)` factory and holds the HTTP logic.
- Unit tests sit beside the handler.

Code shared by more than one function lives in `supabase/functions/_shared/`, one responsibility per file. Database work lives in new `SECURITY DEFINER` functions, one migration per concern, each covered by its own pgTAP file.

**Tech Stack:** Deno 2 (Supabase Edge Runtime) · `npm:@supabase/supabase-js@2` · `npm:zod@3` · `npm:standardwebhooks@1.0.0` · `jsr:@std/assert@1` · Postgres 15 + pgcrypto (`extensions.crypt`, bcrypt) · pgTAP · Supabase CLI 2.119.

**Spec:** `docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md` — §3.1–3.6, §4.4, §5.5, §6.8, §6.11, §7.4, §14 (Phase 3).

## Global Constraints

- The gateway forwards the caller's `Authorization` header to every user RPC; **no user-facing function touches the service-role key** (§3.2, decision 3).
- The service-role key appears only in `auth-verify-claims` and `process-payment` (system flavour, §3.4).
- `tenantId` / `tenant_id` is never accepted from a client: it is stripped before validation (§3.1 step 3, decision 4).
- Every app-callable `jsonb` RPC takes `p_idempotency_key uuid` first (§3.3, enforced by `004_rpcs.test.sql`).
- Every `SECURITY DEFINER` function pins `set search_path = public, pg_temp`. New functions get **no** EXECUTE for anon/authenticated unless granted explicitly.
- Error contract (§3.5), body `{ error: { code, message, details } }`:
  - `P0001` → 422
  - `42501` → 403
  - `23505` → 409
  - `TF001` → 409 + structured detail
  - `TF002` → 409
  - `40001` / `55P03` → 503 (retry)
- Paystack (§3.6), applied in order:
  1. HMAC-SHA512 of the **raw** body with the secret key, compared in constant time.
  2. ±300 s window against `data.paid_at`, falling back to `data.created_at`. A stale event gets `200` and an `audit_logs` row with operation `WEBHOOK_STALE`.
  3. Amount, currency and status come from the Verify API, never from the webhook body.
  4. `(event, data.reference)` is the at-most-once key.
- PIN (§5.5): bcrypt, 5 attempts, then a 15-minute lockout.
- OTP (§6.11): stored hashed, never plaintext. Single use via `consumed_at`, short `expires_at`, `failed_attempts` with `locked_until`, and issuance rate-limited per `subject_id`.
- Audit: system rows use `source = 'WEBHOOK'` with no actor. `teafair_agent_id` comes from the payment (§6.10).
- Never commit `.env` files. Secrets live in `supabase/functions/.env` and `supabase/.env`, both covered by the root `.gitignore` `.env` rule. Commit only `.env.example` files with placeholder values.
- Nothing is pushed to a remote project. No `supabase db push`, no `supabase functions deploy`.

## Decisions this plan makes where the spec is silent

1. **The bcrypt comparison runs in Postgres.** `public.verify_pin(p_pin)` uses pgcrypto `crypt()`; the gateway calls it as step 4 of §3.1. `tenant_users.pin_hash` is not readable by `authenticated`, and the service-role key is forbidden in user functions, so the gateway cannot read the hash itself. Doing it in the database also makes the lockout counter atomic.
2. **`verify_pin` returns a composite `public.pin_check`, not `jsonb`, and is deliberately not idempotent.** A replayed key must never re-grant a PIN pass.
3. **OTP codes are generated in the gateway and stored as bcrypt hashes.** The code is excluded from the idempotency request hash, because a sha256 of 6 digits falls to a lookup table.
4. **`verify_otp` is its own RPC and never raises on a wrong code.** It returns a verdict, so `failed_attempts` persists; a raise would roll the counter back and allow unlimited guessing.
   - Success sets `consumed_at`.
   - Spec D's `complete_pos_backed_order` then requires a consumed `POS_SETTLEMENT` challenge, issued by the same caller and not yet referenced by any payment.
5. **OTP numbers:** 6 digits, 5-minute expiry, 5 wrong attempts lock the challenge, and at most 3 codes per subject and purpose in 10 minutes. Only `DSA` and `FINTECH_AGENT` issue and verify, and only the issuer verifies.
6. **`auth-verify-claims` is an HTTP hook Edge Function, as §3.4 lists it.**
   - The claim rules live in SQL (`public.access_token_claims`), so they are pgTAP-tested.
   - The active tenant is the ACTIVE `is_primary` membership, or the only ACTIVE membership; otherwise null.
7. **`process-payment` acts only on `charge.success`.** Other signed events get `200 {outcome: "ignored"}`. Two cases leave the payment status unchanged and write an audit row:
   - A verified success whose amount or currency disagrees with the payment.
   - A downgrade of a settled payment.
8. **Payment outcomes only.** Order status (`PAID`) and commission rows are untouched; those are Spec C/D RPCs.
9. **Gateway-level error codes:**
   - `400 INVALID_JSON` and `400 VALIDATION_FAILED`
   - `401 UNAUTHENTICATED` and `401 INVALID_SIGNATURE`
   - `403 PIN_INVALID` and `423 PIN_LOCKED`
   - `422 OTP_INVALID`, `OTP_EXPIRED`, `OTP_LOCKED` and `OTP_CONSUMED`
   - `502 SMS_DELIVERY_FAILED` and `502 PAYSTACK_MISMATCH`
   - `500 INTERNAL`, which is generic and never leaks internals
10. **SMS goes through KudiSMS** (the owner holds an account) via `POST https://my.kudisms.net/api/sms` (form fields `token`, `senderID`, `recipients`, `message`; success code `000`). The developer docs host was unreachable while planning, so Task 8 includes a check of the field names against the account dashboard. Locally, `SMS_PROVIDER=log` prints the message to the function log, and there is no default provider.
11. **All four functions set `verify_jwt = false`.** The two user gateways verify the JWT themselves through `auth.getClaims()`, which handles both HS256 and asymmetric signing keys. The hook verifies a Standard Webhooks signature, and the webhook verifies a Paystack HMAC.

## Review Focus

1. **A Paystack retry arriving after 300 s is dropped by design.** The payment must stay `INITIATED` for the `reconcile-funds` sweep, so the stale path must never write the payment row. Pinned in Task 4 (test 24 leaves P1's status alone) and Task 10 (the stale handler test asserts `verifyTransaction` is never called).
2. **An OTP SMS fails after the challenge commits.** The client gets `502`. A retry with the same key must not send a code the database doesn't hold, so a replay reports `sms_sent: false` and the agent requests a new code with a new key. Pinned in Task 11.
3. **A webhook for a reference whose payment row doesn't exist yet.** It must not be marked processed, or the later delivery would become a no-op. Pinned in Task 4 test 21.
4. **A client body carrying `tenant_id` or `tenantId`, at any depth.** It must have no effect. Pinned in Task 6 (`stripTenantKeys`) and Task 11 (the RPC args never contain a tenant key).
5. **A malformed PIN or OTP (`"12"`, `"12ab"`).** It must count as a failed attempt or be rejected before any database work; it must never throw a 500. Pinned in Task 2 test 12, Task 3 test 14 and Task 11 (`400` without an RPC call).

---

## Execution amendments (2026-10-07)

Agreed after plan review, before Task 1. Where a task below disagrees with this section, this section wins.

1. **Domain layout.** Function directories stay flat (`supabase/functions/<name>/`), because the CLI and the §3.4 URLs require it. Shared code is split by domain:
   - `_shared/core/`: `deps`, `env`, `http`, `errors`, `jwt` (the plan's `auth.ts`, renamed so it doesn't clash with the auth domain), `validate`, `db`, `gateway`, `sms`.
   - `_shared/auth/`: `pin`.
   - `_shared/fintech-liquidity/`: `paystack`.
   - Migrations and pgTAP files carry their domain in the name: `…_auth_access_token_claims.sql`, `…_auth_pin_verification.sql`, `…_fintech_liquidity_otp.sql`, `…_fintech_liquidity_paystack_webhook.sql`, and `006_auth_access_token_claims`, `007_auth_pin`, `008_fintech_liquidity_otp`, `009_fintech_liquidity_paystack_webhook`.
   - `commerce` and `rtm-core` get folders once they have code.
2. **The PIN pass is bound in the database (Task 2).** `authenticated` can call RPCs directly through PostgREST, so a PIN check done only in the gateway can be bypassed.
   - `verify_pin` records `tenant_users.pin_pass_at` on success.
   - `public.consume_pin_pass()` is internal, with no EXECUTE for `authenticated`. It requires a pass less than 60 s old and clears it; otherwise it raises `42501 a fresh PIN check is required`.
   - Spec C/D PIN-gated RPCs call it after `idempotency_begin`, so a replay never needs a fresh pass.
   - `007` gains 5 assertions (19 in total), so the suite total is **287**.
3. **`verify_pin` is an explicit exception to "every mutation takes `p_idempotency_key` first".** It is a guard, not a queued write, and a replay must never re-grant a pass. Task 12 records the exception in `supabase/CLAUDE.md`.
4. **`PGRST301`** (a JWT that expired between the gateway and PostgREST) maps to `401 UNAUTHENTICATED`, so the client refreshes instead of retrying (Task 5).
5. **Task 6's `auth.test.ts` block is truncated.** Its last test is closed as `});` followed by a second `});`.

---

## File Structure

```
supabase/
├── config.toml                                   modify: hook + [functions.*] blocks
├── .env.example                                  create: AUTH_HOOK_SECRET placeholder
├── migrations/
│   ├── 20261007120000_access_token_claims.sql    create
│   ├── 20261007120100_pin_verification.sql       create
│   ├── 20261007120200_otp_challenges_rpcs.sql    create
│   └── 20261007120300_paystack_webhook.sql       create
├── tests/database/
│   ├── 006_access_token_claims.test.sql          create
│   ├── 007_pin.test.sql                          create
│   ├── 008_otp.test.sql                          create
│   └── 009_paystack_webhook.test.sql             create
└── functions/
    ├── .env.example                              create
    ├── _shared/
    │   ├── deps.ts          pinned third-party imports, the only place versions appear
    │   ├── env.ts           requireEnv
    │   ├── http.ts          json() response helper
    │   ├── errors.ts        GatewayError, mapPostgresError (§3.5), errorResponse
    │   ├── auth.ts          bearer extraction, claim checks, supabaseTokenVerifier
    │   ├── validate.ts      stripTenantKeys, parseJsonBody, idempotencyKey schema
    │   ├── db.ts            Rpc type, rpcFrom, userRpc (forwards JWT), serviceRpc
    │   ├── gateway.ts       userGateway(): POST → auth → validate → handler → map errors
    │   ├── pin.ts           pinSchema, requirePin
    │   ├── sms.ts           SmsSender, kudiSmsSender, logSmsSender, smsSenderFromEnv
    │   ├── paystack.ts      paystackVerifier (Verify Transaction API)
    │   └── *.test.ts        one per module
    ├── auth-verify-claims/  index.ts · handler.ts · handler.test.ts
    ├── process-payment/     index.ts · handler.ts · signature.ts · replay-window.ts · *.test.ts
    ├── otp-issue/           index.ts · handler.ts · code.ts · handler.test.ts · code.test.ts
    ├── otp-verify/          index.ts · handler.ts · handler.test.ts
    └── _tests/gateway.integration.ts   end-to-end against the local stack
```

Commands used throughout:

```bash
supabase test db                                          # all pgTAP files → "Result: PASS"
deno test --allow-env supabase/functions/                 # all unit tests (integration file excluded by name)
deno check supabase/functions/*/index.ts                  # type-check every function entry point
```

---

### Task 0: Tooling and baseline

**Files:** none committed.

- [ ] **Step 1: Start Docker Desktop.** `docker ps` must succeed. If it reports `dockerDesktopLinuxEngine … cannot find the file`, launch `"C:\Program Files\Docker\Docker\Docker Desktop.exe"` and poll `docker ps` until it succeeds.
- [ ] **Step 2: Install Deno.** `deno --version` must print 2.x. If Deno is missing, run `npm install -g deno` and re-check.
- [ ] **Step 3: Start the stack and confirm the baseline.**

Run: `supabase start` then `supabase db reset` then `supabase test db`
Expected: `Result: PASS` with 200 assertions across files 001–005.

---

### Task 1: `access_token_claims()` — the claims the hook mints

**Files:**
- Create: `supabase/migrations/20261007120000_access_token_claims.sql`
- Test: `supabase/tests/database/006_access_token_claims.test.sql`

**Interfaces:**
- Produces: `public.access_token_claims(p_user_id uuid) returns jsonb`, shaped `{tenant_ids: uuid[], active_tenant_id: uuid|null, tenant_role: text|null, platform_role: text|null}`. EXECUTE goes to `service_role` only. Task 9 calls it.

- [ ] **Step 1: Write the failing test**

```sql
-- Spec A §4.4 — the access-token hook's claims: proposals the database
-- re-checks live, computed here so the rules are tested.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
-- 1 TM in both (primary at Nestle) · 2 one membership, not primary
-- 3 two memberships, neither primary · 4 only INVITED, platform admin
-- 6 primary membership DISABLED, one ACTIVE elsewhere
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN'
 where id = '20000000-0000-0000-0000-000000000004';

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000002', 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000032', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000003', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'RETAIL_SHOP_OWNER', null, 'INVITED', false),
  ('50000000-0000-0000-0000-000000000061', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006', 'RETAIL_SHOP_OWNER', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000062', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000006', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false);

-- privileges: only the system-flavoured hook may compute claims
select ok(not has_function_privilege('authenticated', 'public.access_token_claims(uuid)', 'execute'),
  'authenticated cannot compute anyone''s claims');
select ok(not has_function_privilege('anon', 'public.access_token_claims(uuid)', 'execute'),
  'anon cannot compute claims');
select ok(has_function_privilege('service_role', 'public.access_token_claims(uuid)', 'execute'),
  'the hook (service_role) can compute claims');

-- primary membership wins
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000001', 'the primary ACTIVE membership is the active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') ->> 'tenant_role',
  'TM', 'tenant_role is the role in the active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') -> 'tenant_ids',
  '["10000000-0000-0000-0000-000000000001", "10000000-0000-0000-0000-000000000002"]'::jsonb,
  'tenant_ids lists every ACTIVE membership');

-- a single membership is active without being primary
select is(public.access_token_claims('20000000-0000-0000-0000-000000000002') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000001', 'a lone ACTIVE membership is the active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000002') ->> 'tenant_role',
  'RETAIL_SHOP_OWNER', 'and carries its role');

-- several memberships and no primary: the user must choose
select ok(public.access_token_claims('20000000-0000-0000-0000-000000000003') ->> 'active_tenant_id' is null,
  'no active tenant is guessed among several');
select is(jsonb_array_length(public.access_token_claims('20000000-0000-0000-0000-000000000003') -> 'tenant_ids'),
  2, 'but both memberships are listed');

-- invited only: nothing yet; platform role is carried
select is(public.access_token_claims('20000000-0000-0000-0000-000000000004') -> 'tenant_ids',
  '[]'::jsonb, 'an INVITED membership grants no tenant');
select ok(public.access_token_claims('20000000-0000-0000-0000-000000000004') ->> 'active_tenant_id' is null,
  'and no active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000004') ->> 'platform_role',
  'PLATFORM_SUPER_ADMIN', 'platform_role comes from the profile');

-- unknown user
select is(public.access_token_claims('29999999-0000-0000-0000-000000000000') -> 'tenant_ids',
  '[]'::jsonb, 'an unknown user gets empty claims, not an error');

-- a DISABLED primary is ignored; the remaining ACTIVE membership is used
select is(public.access_token_claims('20000000-0000-0000-0000-000000000006') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000002', 'a disabled primary falls back to the lone ACTIVE membership');

update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000012';
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') -> 'tenant_ids',
  '["10000000-0000-0000-0000-000000000001"]'::jsonb, 'a disabled membership drops out of tenant_ids');

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL in `006_access_token_claims.test.sql` with `function public.access_token_claims(unknown) does not exist`.

- [ ] **Step 3: Write the migration**

```sql
-- Spec A §4.4 — the claims the auth-verify-claims hook mints into every
-- access token, under app_metadata. Computed in SQL so the Edge Function is a
-- thin, signature-checking shell and the rules are pgTAP-tested.
--
-- Claims are a cache, never the authority: every RPC re-reads tenant_users
-- live (is_tenant_member / assert_tenant_role).
--
--   tenant_ids        every ACTIVE membership
--   active_tenant_id  the ACTIVE primary membership (set by set_active_tenant),
--                     else the only ACTIVE membership, else null
--   tenant_role       the role in the active tenant
--   platform_role     PLATFORM_SUPER_ADMIN or null
create or replace function public.access_token_claims(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with active as (
    select tu.tenant_id, tu.role, tu.is_primary
    from public.tenant_users tu
    where tu.profile_id = p_user_id
      and tu.status = 'ACTIVE'
  ),
  chosen as (
    select a.tenant_id, a.role
    from active a
    where a.is_primary or (select count(*) from active) = 1
    order by a.is_primary desc
    limit 1
  )
  select jsonb_build_object(
    'tenant_ids',       coalesce((select jsonb_agg(a.tenant_id order by a.tenant_id) from active a), '[]'::jsonb),
    'active_tenant_id', (select c.tenant_id from chosen c),
    'tenant_role',      (select c.role from chosen c),
    'platform_role',    (select p.platform_role from public.profiles p where p.id = p_user_id)
  );
$$;

-- system-flavoured (§3.4): the hook calls it with the service-role key
revoke execute on function public.access_token_claims(uuid) from public, anon, authenticated;
grant execute on function public.access_token_claims(uuid) to service_role;
```

- [ ] **Step 4: Apply and run tests**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261007120000_access_token_claims.sql supabase/tests/database/006_access_token_claims.test.sql
git commit -m "feat(db): access_token_claims for the access-token hook"
```

---

### Task 2: `verify_pin()` — bcrypt check with lockout

**Files:**
- Create: `supabase/migrations/20261007120100_pin_verification.sql`
- Test: `supabase/tests/database/007_pin.test.sql`

**Interfaces:**
- Produces:
  - type `public.pin_check (ok boolean, attempts_left integer, locked_until timestamptz)`
  - `public.verify_pin(p_pin text) returns public.pin_check`, EXECUTE for `authenticated`
  - Over PostgREST, `rpc('verify_pin', {p_pin})` returns `{ok, attempts_left, locked_until}`. Task 7 consumes it.

- [ ] **Step 1: Write the failing test**

```sql
-- Spec A §5.5 / §7.4 — PIN verification: bcrypt, five attempts, 15-minute lockout.
begin;
create extension if not exists pgtap with schema extensions;

select plan(14);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');
-- 1 TM with PIN 1234 · 2 TM without a PIN · 3 not a member
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, status, is_primary, pin_hash) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000001', 'ACTIVE', true,
   extensions.crypt('1234', extensions.gen_salt('bf'))),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'TM', '40000000-0000-0000-0000-000000000001', 'ACTIVE', true, null);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

select ok(has_function_privilege('authenticated', 'public.verify_pin(text)', 'execute'),
  'the gateway (as the caller) can verify a PIN');
select ok(not has_function_privilege('anon', 'public.verify_pin(text)', 'execute'),
  'anon cannot');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.verify_pin('0000')::text, '(f,4,)', 'a wrong PIN fails and reports attempts left');
select is(public.verify_pin('1234')::text, '(t,5,)', 'the right PIN passes');
select is((select pin_failed_attempts from public.tenant_users where id = '50000000-0000-0000-0000-000000000001'),
  0, 'a pass resets the failure counter');

do $$ begin
  perform public.verify_pin('0000');
  perform public.verify_pin('0000');
  perform public.verify_pin('0000');
end $$;
select is(public.verify_pin('0000')::text, '(f,1,)', 'the fourth wrong PIN leaves one attempt');
select ok((public.verify_pin('0000')).locked_until is not null, 'the fifth wrong PIN locks the membership');
select is((public.verify_pin('1234')).ok, false, 'a locked membership rejects even the right PIN');

reset role;
select is((select count(*)::int from public.audit_logs
            where operation = 'PIN_LOCKED' and entity_id = '50000000-0000-0000-0000-000000000001'),
  1, 'the lockout is audited');
select ok((select pin_locked_until > now() + interval '14 minutes' from public.tenant_users
            where id = '50000000-0000-0000-0000-000000000001'),
  'the lockout lasts fifteen minutes');

update public.tenant_users set pin_locked_until = now() - interval '1 second'
 where id = '50000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((public.verify_pin('1234')).ok, true, 'the right PIN passes once the lockout lapses');
select is(public.verify_pin('12')::text, '(f,4,)', 'a malformed PIN counts as a wrong one');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.verify_pin('1234') $$, 'P0001',
  'no PIN has been set for this membership', 'a membership without a PIN cannot pass');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.verify_pin('1234') $$, '42501',
  'not an active member of the selected tenant', 'a non-member cannot probe PINs');

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL in `007_pin.test.sql` with `function public.verify_pin(unknown) does not exist`.

- [ ] **Step 3: Write the migration**

```sql
-- Spec A §5.5 / §7.4 — PIN verification for PIN-gated gateways (§3.1 step 4).
--
-- The bcrypt comparison runs here, through pgcrypto: pin_hash is not readable
-- by `authenticated` (grants migration) and user-facing gateways never hold
-- the service-role key (§3.2), so the gateway cannot fetch the hash itself.
-- Doing it here also makes the attempt counter atomic.
--
-- The verdict is RETURNED, never raised: a raise would roll back the failure
-- counter and make the lockout useless. It is also deliberately not
-- idempotent — a replayed key must never re-grant a pass — so it returns a
-- composite, not the jsonb of a queued write RPC.
create type public.pin_check as (ok boolean, attempts_left integer, locked_until timestamptz);

create or replace function public.verify_pin(p_pin text)
returns public.pin_check
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer  := 5;
  c_lockout      constant interval := interval '15 minutes';
  v_me  public.tenant_users := public.assert_tenant_role(null);
  v_row public.tenant_users;
begin
  select * into v_row from public.tenant_users where id = v_me.id for update;

  if v_row.pin_hash is null then
    raise exception 'no PIN has been set for this membership' using errcode = 'P0001';
  end if;
  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    return (false, 0, v_row.pin_locked_until)::public.pin_check;
  end if;

  if p_pin ~ '^[0-9]{4}$' and extensions.crypt(p_pin, v_row.pin_hash) = v_row.pin_hash then
    update public.tenant_users
       set pin_failed_attempts = 0, pin_locked_until = null
     where id = v_row.id;
    return (true, c_max_attempts, null)::public.pin_check;
  end if;

  v_row.pin_failed_attempts := v_row.pin_failed_attempts + 1;
  if v_row.pin_failed_attempts >= c_max_attempts then
    update public.tenant_users
       set pin_failed_attempts = 0, pin_locked_until = now() + c_lockout
     where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'PIN_LOCKED', 'tenant_users', v_row.id::text,
                               null, jsonb_build_object('locked_until', now() + c_lockout), null);
    return (false, 0, now() + c_lockout)::public.pin_check;
  end if;

  update public.tenant_users set pin_failed_attempts = v_row.pin_failed_attempts where id = v_row.id;
  return (false, c_max_attempts - v_row.pin_failed_attempts, null)::public.pin_check;
end;
$$;

grant execute on function public.verify_pin(text) to authenticated;
```

- [ ] **Step 4: Apply and run tests**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS`. `004_rpcs.test.sql` still passes: `verify_pin` returns `pin_check`, not `jsonb`, so the idempotency-key-first rule does not apply.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261007120100_pin_verification.sql supabase/tests/database/007_pin.test.sql
git commit -m "feat(db): verify_pin with bcrypt and 15-minute lockout"
```

---

### Task 3: `issue_otp()` / `verify_otp()` — the shop-owner half of §6.11

**Files:**
- Create: `supabase/migrations/20261007120200_otp_challenges_rpcs.sql`
- Test: `supabase/tests/database/008_otp.test.sql`

**Interfaces:**
- Produces:
  - `public.issue_otp(p_idempotency_key uuid, p_subject_id uuid, p_purpose public.otp_purpose_enum, p_code text) returns jsonb`. Fresh: `{challenge_id, expires_at, destination_phone, replayed: false}`. Replay: the same object with `replayed: true`.
  - `public.verify_otp(p_idempotency_key uuid, p_challenge_id uuid, p_code text) returns jsonb`. Returns `{verified: true, challenge_id, purpose, subject_id}` or `{verified: false, reason: 'INVALID'|'EXPIRED'|'LOCKED'|'CONSUMED', attempts_left?}`.
  - Both EXECUTE for `authenticated`. Task 11 consumes them.

- [ ] **Step 1: Write the failing test**

```sql
-- Spec A §6.11 — OTP challenges: hashed, single use, short-lived, attempt
-- lockout, issuance rate-limited per subject.
begin;
create extension if not exists pgtap with schema extensions;

select plan(24);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
-- 1 TM · 2 DSM · 3 DSA (issuer) · 4 second DSA · 5 shop owner · 6 shop owner elsewhere
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'DSM', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 'DSA', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'DSA', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'RETAIL_SHOP_OWNER', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000006', 'RETAIL_SHOP_OWNER', null, null, 'ACTIVE', true);

-- challenges for the verify tests, inserted directly under PICKUP_CONFIRM so
-- they do not count against the POS_SETTLEMENT issuance limit
insert into public.otp_challenges (id, tenant_id, subject_id, purpose, code_hash, destination_phone,
                                   issued_by, expires_at, created_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003', now() + interval '5 minutes', now()),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003', now() + interval '5 minutes', now()),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003',
   now() - interval '6 minutes', now() - interval '11 minutes'),
  ('60000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003', now() + interval '5 minutes', now());

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

select ok(has_function_privilege('authenticated', 'public.issue_otp(uuid,uuid,public.otp_purpose_enum,text)', 'execute'),
  'issue_otp is callable through the gateway');
select ok(has_function_privilege('authenticated', 'public.verify_otp(uuid,uuid,text)', 'execute'),
  'verify_otp is callable through the gateway');
select ok(not has_function_privilege('anon', 'public.issue_otp(uuid,uuid,public.otp_purpose_enum,text)', 'execute'),
  'anon cannot issue codes');

-- ── issue ────────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.issue_otp('b0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '123456') ->> 'replayed',
  'false', 'a DSA issues a code to a shop owner');

reset role;
select is((select destination_phone from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  '+2348000000005', 'the code goes to the owner''s phone from their profile, never from the request');
select ok((select code_hash <> '123456' and extensions.crypt('123456', code_hash) = code_hash
             from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  'the code is stored as a bcrypt hash');
select ok((select expires_at = created_at + interval '5 minutes' from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  'a code lives five minutes');
select is((select count(*)::int from public.audit_logs
            where operation = 'issue_otp' and not (after ? 'code_hash')),
  1, 'issuance is audited without the hash');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.issue_otp('b0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '999999') ->> 'replayed',
  'true', 'a replay returns the first challenge, flagged as a replay');
reset role;
select is((select count(*)::int from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  1, 'a replay issues nothing new');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
do $$ begin
  perform public.issue_otp('b0000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '111111');
  perform public.issue_otp('b0000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '222222');
end $$;
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000004',
                   '20000000-0000-0000-0000-000000000005', 'POS_SETTLEMENT', '333333') $$,
  'P0001', 'too many codes requested for this shop owner; try again later',
  'a fourth code within ten minutes is refused');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000005',
                   '20000000-0000-0000-0000-000000000002', 'POS_SETTLEMENT', '123456') $$,
  'P0001', 'subject is not an active shop owner in this tenant', 'only shop owners receive codes');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000006',
                   '20000000-0000-0000-0000-000000000006', 'POS_SETTLEMENT', '123456') $$,
  'P0001', 'subject is not an active shop owner in this tenant',
  'a shop owner of another tenant cannot be targeted');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000007',
                   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', '12ab') $$,
  'P0001', 'code must be 6 digits', 'a malformed code is refused');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000008',
                   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', '123456') $$,
  '42501', 'role TM may not perform this operation', 'a TM cannot issue codes');

-- ── verify ───────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '000000'),
  '{"verified": false, "reason": "INVALID", "attempts_left": 4}'::jsonb,
  'a wrong code fails and reports attempts left');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '123456') ->> 'verified',
  'false', 'a key spent on a wrong attempt replays that failure: each attempt needs a new key');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001', '123456') ->> 'verified',
  'true', 'the right code verifies');
reset role;
select ok((select consumed_at is not null from public.otp_challenges where id = '60000000-0000-0000-0000-000000000001'),
  'verification consumes the challenge');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000001', '123456') ->> 'reason',
  'CONSUMED', 'a code is single use');

do $$ begin
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
end $$;
select is(public.verify_otp('c0000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000002', '123456') ->> 'reason',
  'LOCKED', 'five wrong codes lock the challenge, even against the right code');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000003', '123456') ->> 'reason',
  'EXPIRED', 'an expired code fails');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.verify_otp('c0000000-0000-0000-0000-000000000006',
                   '60000000-0000-0000-0000-000000000004', '123456') $$,
  'P0001', 'challenge not found', 'only the issuer can verify a challenge');

reset role;
select is((select count(*)::int from public.audit_logs where operation = 'OTP_FAILED'),
  6, 'every failed attempt is audited');

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL in `008_otp.test.sql` with `function public.issue_otp(...) does not exist`.

- [ ] **Step 3: Write the migration**

```sql
-- Spec A §6.11 — the shop-owner OTP: the second proof of the dual-validation
-- handshake. The gateway generates the code and sends the SMS; the database
-- stores only a bcrypt hash and owns every control:
--   single use (consumed_at) · 5-minute expiry · 5 wrong attempts lock the
--   challenge · at most 3 codes per subject and purpose in 10 minutes.
--
-- The code is never part of the idempotency request: request_hash is a plain
-- sha256, and a 6-digit code would fall to a lookup table.
--
-- verify_otp RETURNS its verdict rather than raising, so failed_attempts
-- persists; a raise would roll the counter back. A verified challenge is
-- consumed; Spec D's complete_pos_backed_order binds it to a payment once.

create or replace function public.issue_otp(
  p_idempotency_key uuid,
  p_subject_id      uuid,
  p_purpose         public.otp_purpose_enum,
  p_code            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_ttl           constant interval := interval '5 minutes';
  c_window        constant interval := interval '10 minutes';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(array['DSA', 'FINTECH_AGENT']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_phone text;
  v_row   public.otp_challenges;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'issue_otp',
    jsonb_build_object('subject_id', p_subject_id, 'purpose', p_purpose));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'code must be 6 digits' using errcode = 'P0001';
  end if;

  select p.phone_number into v_phone
  from public.tenant_users tu
  join public.profiles p on p.id = tu.profile_id
  where tu.tenant_id = v_me.tenant_id
    and tu.profile_id = p_subject_id
    and tu.role = 'RETAIL_SHOP_OWNER'
    and tu.status = 'ACTIVE';
  if v_phone is null then
    raise exception 'subject is not an active shop owner in this tenant' using errcode = 'P0001';
  end if;

  -- serialise issuance per subject and purpose, so concurrent requests cannot
  -- both slip under the limit
  perform pg_advisory_xact_lock(hashtextextended('issue_otp:' || p_subject_id || ':' || p_purpose, 0));
  if (select count(*) from public.otp_challenges c
       where c.subject_id = p_subject_id
         and c.purpose = p_purpose
         and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this shop owner; try again later' using errcode = 'P0001';
  end if;

  insert into public.otp_challenges (tenant_id, subject_id, purpose, code_hash, destination_phone,
                                     issued_by, expires_at)
  values (v_me.tenant_id, p_subject_id, p_purpose, extensions.crypt(p_code, extensions.gen_salt('bf', 8)),
          v_phone, v_me.profile_id, now() + c_ttl)
  returning * into v_row;

  perform public.write_audit(v_me.tenant_id, 'issue_otp', 'otp_challenges', v_row.id::text,
                             null, to_jsonb(v_row) - 'code_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id',      v_row.id,
    'expires_at',        v_row.expires_at,
    'destination_phone', v_row.destination_phone,
    'replayed',          false));
end;
$$;

create or replace function public.verify_otp(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_me     public.tenant_users := public.assert_tenant_role(array['DSA', 'FINTECH_AGENT']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_row    public.otp_challenges;
  v_result jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'verify_otp',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_row
  from public.otp_challenges c
  where c.id = p_challenge_id
    and c.tenant_id = v_me.tenant_id
    and c.issued_by = v_me.profile_id
  for update;
  if not found then
    raise exception 'challenge not found' using errcode = 'P0001';
  end if;

  if v_row.consumed_at is not null then
    v_result := jsonb_build_object('verified', false, 'reason', 'CONSUMED');
  elsif v_row.locked_until is not null then
    v_result := jsonb_build_object('verified', false, 'reason', 'LOCKED');
  elsif v_row.expires_at <= now() then
    v_result := jsonb_build_object('verified', false, 'reason', 'EXPIRED');
  elsif p_code ~ '^[0-9]{6}$' and extensions.crypt(p_code, v_row.code_hash) = v_row.code_hash then
    update public.otp_challenges set consumed_at = now() where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'OTP_VERIFIED', 'otp_challenges', v_row.id::text,
                               null, jsonb_build_object('purpose', v_row.purpose), p_idempotency_key);
    v_result := jsonb_build_object('verified', true, 'challenge_id', v_row.id,
                                   'purpose', v_row.purpose, 'subject_id', v_row.subject_id);
  else
    v_row.failed_attempts := v_row.failed_attempts + 1;
    update public.otp_challenges
       set failed_attempts = v_row.failed_attempts,
           -- a locked challenge stays locked until it would have expired anyway
           locked_until = case when v_row.failed_attempts >= c_max_attempts
                               then greatest(v_row.expires_at, now()) end
     where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'OTP_FAILED', 'otp_challenges', v_row.id::text,
                               null, jsonb_build_object('failed_attempts', v_row.failed_attempts),
                               p_idempotency_key);
    v_result := jsonb_build_object('verified', false, 'reason', 'INVALID',
                                   'attempts_left', greatest(c_max_attempts - v_row.failed_attempts, 0));
  end if;

  return public.idempotency_complete(p_idempotency_key, v_result);
end;
$$;

grant execute on function public.issue_otp(uuid, uuid, public.otp_purpose_enum, text) to authenticated;
grant execute on function public.verify_otp(uuid, uuid, text) to authenticated;
```

- [ ] **Step 4: Apply and run tests**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS` (004's contract test also passes: both take `p_idempotency_key uuid` first).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261007120200_otp_challenges_rpcs.sql supabase/tests/database/008_otp.test.sql
git commit -m "feat(db): issue_otp and verify_otp for the dual-validation handshake"
```

---

### Task 4: Paystack webhook RPCs — settle at most once, audit the rest

**Files:**
- Create: `supabase/migrations/20261007120300_paystack_webhook.sql`
- Test: `supabase/tests/database/009_paystack_webhook.test.sql`

**Interfaces:**
- Produces:
  - `public.settle_paystack_payment(p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb) returns jsonb`, returning `{outcome: 'updated'|'unchanged'|'mismatch'|'conflict'|'unknown_reference'|'ambiguous_reference'|'not_final', payment_id?, payment_status?}`.
  - `public.record_stale_paystack_webhook(p_event text, p_reference text, p_event_time timestamptz) returns jsonb`, returning `{outcome: 'stale'}`.
  - Both EXECUTE for `service_role` only. Task 10 consumes them.

- [ ] **Step 1: Write the failing test**

```sql
-- Spec A §3.6 — Paystack webhook: at most once per (event, reference);
-- amounts and status from the Verify API; stale events audited, not applied.
begin;
create extension if not exists pgtap with schema extensions;

select plan(28);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000003', '2348000000003');
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'FIELD_DSA',
   '20000000-0000-0000-0000-000000000003', 10000),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'FIELD_DSA',
   '20000000-0000-0000-0000-000000000003', 10000);
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, payment_status, paystack_reference) values
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 2500.00, 'INITIATED', 'ref_success'),
  ('80000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 1000.00, 'INITIATED', 'ref_mismatch'),
  ('80000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 500.00, 'INITIATED', 'ref_failed'),
  ('80000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 700.00, 'SUCCESS', 'ref_settled'),
  ('80000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 600.00, 'INITIATED', 'ref_pending'),
  ('80000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 100.00, 'INITIATED', 'ref_dup'),
  ('80000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000003', 100.00, 'INITIATED', 'ref_dup');

select has_index('public', 'payments', 'idx_payments_paystack_reference',
  'the webhook finds a payment by reference without knowing its tenant');
select ok(not has_function_privilege('authenticated',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb)', 'execute'),
  'no user can settle a payment');
select ok(not has_function_privilege('authenticated',
  'public.record_stale_paystack_webhook(text,text,timestamptz)', 'execute'),
  'no user can write webhook audit rows');
select ok(has_function_privilege('service_role',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb)', 'execute'),
  'process-payment (service_role) can settle');
select ok(has_function_privilege('service_role',
  'public.record_stale_paystack_webhook(text,text,timestamptz)', 'execute'),
  'process-payment (service_role) can record a stale event');

set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

-- success
select is(public.settle_paystack_payment('charge.success', 'ref_success', 'success', 250000, 'NGN', '{"id": 1}') ->> 'outcome',
  'updated', 'a verified success settles the payment');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000001'),
  'SUCCESS', 'the payment is SUCCESS');
select is((select gateway_response_payload from public.payments where id = '80000000-0000-0000-0000-000000000001'),
  '{"id": 1}'::jsonb, 'the Verify API response is kept on the payment');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'settle_paystack_payment' and entity_id = '80000000-0000-0000-0000-000000000001'
                     and source = 'WEBHOOK' and actor_id is null
                     and teafair_agent_id = '20000000-0000-0000-0000-000000000003'),
  'the settlement is audited as a webhook, owned by the accountable agent');
select is(public.settle_paystack_payment('charge.success', 'ref_success', 'success', 250000, 'NGN', '{"id": 1}') ->> 'outcome',
  'updated', 'a replay returns the first result');
select is((select count(*)::int from public.audit_logs
            where operation = 'settle_paystack_payment' and entity_id = '80000000-0000-0000-0000-000000000001'),
  1, 'a replay writes nothing');

-- amount and currency must agree with the payment
select is(public.settle_paystack_payment('charge.success', 'ref_mismatch', 'success', 50000, 'NGN', '{}') ->> 'outcome',
  'mismatch', 'an amount that disagrees with the payment is not settled');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000002'),
  'INITIATED', 'the mismatched payment is untouched');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'PAYSTACK_MISMATCH' and entity_id = '80000000-0000-0000-0000-000000000002'),
  'the mismatch is audited for review');
select is(public.settle_paystack_payment('charge.success', 'ref_failed', 'success', 50000, 'GHS', '{}') ->> 'outcome',
  'mismatch', 'a currency that disagrees with the tenant is not settled');

-- failure and conflicts
select is(public.settle_paystack_payment('charge.failed', 'ref_failed', 'failed', 50000, 'NGN', '{}') ->> 'outcome',
  'updated', 'a verified failure is recorded');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000003'),
  'FAILED', 'the payment is FAILED');
select is(public.settle_paystack_payment('charge.success', 'ref_settled', 'failed', 70000, 'NGN', '{}') ->> 'outcome',
  'conflict', 'a settled payment is never downgraded');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000004'),
  'SUCCESS', 'it stays SUCCESS');

-- references the database cannot resolve
select is(public.settle_paystack_payment('charge.success', 'ref_unknown', 'success', 100, 'NGN', '{}') ->> 'outcome',
  'unknown_reference', 'an unknown reference is reported');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'PAYSTACK_UNKNOWN_REFERENCE' and entity_id = 'ref_unknown' and tenant_id is null),
  'and audited');
select ok(not exists (select 1 from public.idempotency_logs
                       where key = md5('paystack:charge.success:ref_unknown')::uuid),
  'an unknown reference is not marked processed, so a later delivery can still settle it');
select is(public.settle_paystack_payment('charge.success', 'ref_dup', 'success', 10000, 'NGN', '{}') ->> 'outcome',
  'ambiguous_reference', 'a reference shared by two tenants is not guessed at');
select is((select count(*)::int from public.payments where paystack_reference = 'ref_dup' and payment_status = 'INITIATED'),
  2, 'neither ambiguous payment is touched');

-- non-final status: leave it to the reconcile-funds sweep
select is(public.settle_paystack_payment('charge.success', 'ref_pending', 'ongoing', 60000, 'NGN', '{}') ->> 'outcome',
  'not_final', 'a non-final status changes nothing');
select ok(not exists (select 1 from public.idempotency_logs
                       where key = md5('paystack:charge.success:ref_pending')::uuid),
  'and is not marked processed');

-- stale
select is(public.record_stale_paystack_webhook('charge.success', 'ref_pending', now() - interval '1 hour') ->> 'outcome',
  'stale', 'a stale event is recorded');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'WEBHOOK_STALE' and entity_id = '80000000-0000-0000-0000-000000000005'
                     and tenant_id = '10000000-0000-0000-0000-000000000001' and source = 'WEBHOOK')
          and (select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000005') = 'INITIATED',
  'it is audited against the payment''s tenant and the payment is left for the sweep');

select * from finish();
rollback;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `supabase test db`
Expected: FAIL in `009_paystack_webhook.test.sql`. The first failure is `has_index` (index missing), followed by `function … does not exist`.

- [ ] **Step 3: Write the migration**

```sql
-- Spec A §3.6 — the database half of the Paystack webhook. process-payment
-- (service_role) has already checked the signature and the ±300 s window and
-- re-fetched the transaction from the Verify API; these functions apply the
-- verified result at most once and audit everything they decline to apply.
--
-- Rows are WEBHOOK-sourced with no actor; teafair_agent_id is the payment's
-- accountable agent (§6.10). Order status and commission rows are Spec C/D.

-- payments are unique per (tenant, reference) but the webhook knows no tenant
create index idx_payments_paystack_reference on public.payments (paystack_reference);

create or replace function public.settle_paystack_payment(
  p_event        text,
  p_reference    text,
  p_status       text,
  p_amount_minor bigint,
  p_currency     text,
  p_verified     jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- (event, reference) is the at-most-once key (§3.6 check 4)
  v_key      uuid := md5('paystack:' || p_event || ':' || p_reference)::uuid;
  v_matches  integer;
  v_payment  public.payments;
  v_currency text;
  v_target   public.payment_status_enum;
  v_prior    jsonb;
begin
  select count(*) into v_matches from public.payments where paystack_reference = p_reference;
  if v_matches <> 1 then
    -- not marked processed: a payment row that lands later can still settle
    perform public.write_audit(null,
      case when v_matches = 0 then 'PAYSTACK_UNKNOWN_REFERENCE' else 'PAYSTACK_AMBIGUOUS_REFERENCE' end,
      'payments', p_reference, null,
      jsonb_build_object('event', p_event, 'reference', p_reference, 'matches', v_matches),
      null, 'WEBHOOK');
    return jsonb_build_object('outcome',
      case when v_matches = 0 then 'unknown_reference' else 'ambiguous_reference' end);
  end if;

  v_target := case p_status
                when 'success'   then 'SUCCESS'
                when 'failed'    then 'FAILED'
                when 'abandoned' then 'FAILED'
                when 'reversed'  then 'REFUNDED'
              end;
  if v_target is null then
    -- ongoing / pending / processing: the reconcile-funds sweep settles it later
    return jsonb_build_object('outcome', 'not_final', 'status', p_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'settle_paystack_payment',
    jsonb_build_object('event', p_event, 'reference', p_reference));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_payment from public.payments where paystack_reference = p_reference for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');

  if v_target = 'SUCCESS'
     and (p_amount_minor is distinct from (v_payment.amount * 100)::bigint
          or p_currency is distinct from v_currency) then
    perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_MISMATCH', 'payments', v_payment.id::text,
      jsonb_build_object('amount_minor', (v_payment.amount * 100)::bigint, 'currency', v_currency),
      jsonb_build_object('amount_minor', p_amount_minor, 'currency', p_currency, 'event', p_event),
      v_key, 'WEBHOOK', v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key,
      jsonb_build_object('outcome', 'mismatch', 'payment_id', v_payment.id));
  end if;

  if v_payment.payment_status = v_target then
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'unchanged', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  if v_payment.payment_status = 'REFUNDED'
     or (v_payment.payment_status = 'SUCCESS' and v_target = 'FAILED')
     or (v_target = 'REFUNDED' and v_payment.payment_status <> 'SUCCESS') then
    perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_STATUS_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('verified_status', p_status, 'event', p_event),
      v_key, 'WEBHOOK', v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  update public.payments
     set payment_status = v_target, gateway_response_payload = p_verified
   where id = v_payment.id;

  perform public.write_audit(v_payment.tenant_id, 'settle_paystack_payment', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', v_target, 'event', p_event),
    v_key, 'WEBHOOK', v_payment.teafair_agent_id);

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'updated', 'payment_id', v_payment.id, 'payment_status', v_target));
end;
$$;

-- §3.6 check 2: an event outside ±300 s is not processed, only recorded.
-- The payment is left for the reconcile-funds Verify-API sweep.
create or replace function public.record_stale_paystack_webhook(
  p_event      text,
  p_reference  text,
  p_event_time timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
begin
  if (select count(*) from public.payments where paystack_reference = p_reference) = 1 then
    select * into v_payment from public.payments where paystack_reference = p_reference;
  end if;

  perform public.write_audit(v_payment.tenant_id, 'WEBHOOK_STALE', 'payments',
    coalesce(v_payment.id::text, p_reference), null,
    jsonb_build_object('event', p_event, 'reference', p_reference, 'event_time', p_event_time),
    null, 'WEBHOOK', v_payment.teafair_agent_id);
  return jsonb_build_object('outcome', 'stale');
end;
$$;

revoke execute on function public.settle_paystack_payment(text, text, text, bigint, text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.record_stale_paystack_webhook(text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.settle_paystack_payment(text, text, text, bigint, text, jsonb) to service_role;
grant execute on function public.record_stale_paystack_webhook(text, text, timestamptz) to service_role;
```

- [ ] **Step 4: Apply and run tests**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS`, 200 + 16 + 14 + 24 + 28 = **282** assertions.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261007120300_paystack_webhook.sql supabase/tests/database/009_paystack_webhook.test.sql
git commit -m "feat(db): at-most-once Paystack settlement and stale-webhook audit"
```

---

### Task 5: `_shared` foundations — deps, env, http, error contract

**Files:**
- Create: `supabase/functions/_shared/deps.ts`, `env.ts`, `http.ts`, `errors.ts`
- Test: `supabase/functions/_shared/errors.test.ts`

**Interfaces:**
- Produces:
  - `requireEnv(name: string): string`
  - `json(status: number, body: unknown): Response`
  - `class GatewayError(status: number, code: string, message: string, details?: unknown)`
  - `type PostgresError = { code?: string; message?: string; details?: string | null }`
  - `mapPostgresError(err: PostgresError): GatewayError`
  - `errorResponse(e: unknown): Response`

- [ ] **Step 1: Write the failing test** — `supabase/functions/_shared/errors.test.ts`

```ts
import { assertEquals } from "jsr:@std/assert@1";
import { errorResponse, GatewayError, mapPostgresError } from "./errors.ts";

const contract: Array<[string, number, string]> = [
  ["P0001", 422, "BUSINESS_RULE"],
  ["42501", 403, "FORBIDDEN"],
  ["23505", 409, "CONFLICT"],
  ["TF001", 409, "INSUFFICIENT_STOCK"],
  ["TF002", 409, "IDEMPOTENCY_MISMATCH"],
  ["40001", 503, "RETRY"],
  ["55P03", 503, "RETRY"],
];

for (const [pg, status, code] of contract) {
  Deno.test(`Spec A §3.5: ${pg} maps to ${status} ${code}`, () => {
    const e = mapPostgresError({ code: pg, message: "boom" });
    assertEquals([e.status, e.code], [status, code]);
  });
}

Deno.test("business messages reach the user; retry messages are generic", () => {
  assertEquals(mapPostgresError({ code: "P0001", message: "zone_name is required" }).message, "zone_name is required");
  assertEquals(mapPostgresError({ code: "40001", message: "request x is still in progress" }).message,
    "The server is busy. Please try again.");
});

Deno.test("TF001 carries structured detail parsed from the Postgres DETAIL", () => {
  const e = mapPostgresError({ code: "TF001", message: "insufficient stock", details: '{"sku_code":"MILO-400","available":2}' });
  assertEquals(e.details, { sku_code: "MILO-400", available: 2 });
});

Deno.test("an unknown code is a generic 500 that leaks nothing", () => {
  const e = mapPostgresError({ code: "XX000", message: "relation secret_table does not exist" });
  assertEquals([e.status, e.code, e.message], [500, "INTERNAL", "Something went wrong. Please try again."]);
});

Deno.test("errorResponse renders the client-facing shape", async () => {
  const res = errorResponse(new GatewayError(422, "BUSINESS_RULE", "nope", { field: "x" }));
  assertEquals(res.status, 422);
  assertEquals(await res.json(), { error: { code: "BUSINESS_RULE", message: "nope", details: { field: "x" } } });
});

Deno.test("errorResponse hides unexpected exceptions behind a 500", async () => {
  const res = errorResponse(new Error("stack trace with secrets"));
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error.code, "INTERNAL");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `deno test --allow-env supabase/functions/_shared/errors.test.ts`
Expected: FAIL — `Module not found "…/_shared/errors.ts"`.

- [ ] **Step 3: Write the implementation**

`supabase/functions/_shared/deps.ts`:

```ts
// The only file that names third-party versions. Everything else imports from here.
export { createClient } from "npm:@supabase/supabase-js@2";
export type { SupabaseClient } from "npm:@supabase/supabase-js@2";
export { z } from "npm:zod@3";
export { Webhook } from "npm:standardwebhooks@1.0.0";
```

`supabase/functions/_shared/env.ts`:

```ts
export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing environment variable ${name}`);
  return value;
}
```

`supabase/functions/_shared/http.ts`:

```ts
export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
```

`supabase/functions/_shared/errors.ts`:

```ts
// Spec A §3.5 — the error contract. The offline queue decides retry vs stop
// from the status alone, so this table is the contract, not a convenience.
import { json } from "./http.ts";

export class GatewayError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details: unknown = null,
  ) {
    super(message);
    this.name = "GatewayError";
  }
}

export type PostgresError = { code?: string; message?: string; details?: string | null };

const CONTRACT: Record<string, { status: number; code: string }> = {
  P0001: { status: 422, code: "BUSINESS_RULE" },
  "42501": { status: 403, code: "FORBIDDEN" },
  "23505": { status: 409, code: "CONFLICT" },
  TF001: { status: 409, code: "INSUFFICIENT_STOCK" },
  TF002: { status: 409, code: "IDEMPOTENCY_MISMATCH" },
  "40001": { status: 503, code: "RETRY" },
  "55P03": { status: 503, code: "RETRY" },
};

const GENERIC = "Something went wrong. Please try again.";

export function mapPostgresError(err: PostgresError): GatewayError {
  const hit = err.code ? CONTRACT[err.code] : undefined;
  if (!hit) {
    console.error("unmapped database error", err);
    return new GatewayError(500, "INTERNAL", GENERIC);
  }
  const message = hit.status === 503 ? "The server is busy. Please try again." : (err.message ?? hit.code);
  return new GatewayError(hit.status, hit.code, message, parseDetails(err.details));
}

function parseDetails(details: string | null | undefined): unknown {
  if (!details) return null;
  try {
    return JSON.parse(details);
  } catch {
    return details;
  }
}

export function errorResponse(e: unknown): Response {
  if (e instanceof GatewayError) {
    return json(e.status, { error: { code: e.code, message: e.message, details: e.details } });
  }
  console.error(e);
  return json(500, { error: { code: "INTERNAL", message: GENERIC, details: null } });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `deno test --allow-env supabase/functions/_shared/errors.test.ts`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/deps.ts supabase/functions/_shared/env.ts supabase/functions/_shared/http.ts supabase/functions/_shared/errors.ts supabase/functions/_shared/errors.test.ts
git commit -m "feat(functions): shared error contract and HTTP helpers"
```

---

### Task 6: `_shared` request pipeline — auth, validation, RPC client, `userGateway`

**Files:**
- Create: `supabase/functions/_shared/auth.ts`, `validate.ts`, `db.ts`, `gateway.ts`
- Test: `supabase/functions/_shared/auth.test.ts`, `validate.test.ts`, `gateway.test.ts`

**Interfaces:**
- Consumes: Task 5's `GatewayError`, `mapPostgresError`, `errorResponse`, `json`, `requireEnv`, `z`, `createClient`.
- Produces:
  - `type Caller = { userId: string; authorization: string; activeTenantId: string | null; tenantRole: string | null; platformRole: string | null }`
  - `type TokenVerifier = (token: string) => Promise<Record<string, unknown> | null>`
  - `authenticate(req: Request, verify: TokenVerifier): Promise<Caller>`
  - `supabaseTokenVerifier(): TokenVerifier`
  - `stripTenantKeys(value: unknown): unknown`
  - `parseJsonBody<S extends z.ZodTypeAny>(req: Request, schema: S): Promise<z.infer<S>>`
  - `idempotencyKey: z.ZodString` (uuid)
  - `type Rpc = <T = unknown>(fn: string, args: Record<string, unknown>) => Promise<T>`
  - `rpcFrom(client)`, `userRpc(authorization: string): Rpc`, `serviceRpc(): Rpc`
  - `type UserGatewayDeps = { verifyToken: TokenVerifier; rpcFor: (authorization: string) => Rpc }`
  - `type UserContext<B> = { caller: Caller; body: B; rpc: Rpc }`
  - `userGateway(schema, handle, deps): (req: Request) => Promise<Response>`
  - `liveUserGatewayDeps(): UserGatewayDeps`

- [ ] **Step 1: Write the failing tests**

`supabase/functions/_shared/auth.test.ts`:

```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { authenticate } from "./auth.ts";
import { GatewayError } from "./errors.ts";

const req = (authorization?: string) =>
  new Request("http://x", { method: "POST", headers: authorization ? { Authorization: authorization } : {} });
const verifying = (claims: Record<string, unknown> | null) => () => Promise.resolve(claims);

const user = {
  sub: "20000000-0000-0000-0000-000000000003",
  role: "authenticated",
  app_metadata: { active_tenant_id: "10000000-0000-0000-0000-000000000001", tenant_role: "DSA", platform_role: null },
};

Deno.test("a missing Authorization header is 401", async () => {
  const e = await assertRejects(() => authenticate(req(), verifying(user)), GatewayError);
  assertEquals([e.status, e.code], [401, "UNAUTHENTICATED"]);
});

Deno.test("a non-Bearer header is 401", async () => {
  await assertRejects(() => authenticate(req("Basic abc"), verifying(user)), GatewayError);
});

Deno.test("a token the verifier rejects is 401", async () => {
  await assertRejects(() => authenticate(req("Bearer bad"), verifying(null)), GatewayError);
});

Deno.test("the anon key is not a user (§3.1 step 1)", async () => {
  await assertRejects(() => authenticate(req("Bearer anon"), verifying({ role: "anon" })), GatewayError);
});

Deno.test("anonymous sign-ins are rejected", async () => {
  await assertRejects(
    () => authenticate(req("Bearer t"), verifying({ ...user, is_anonymous: true })),
    GatewayError,
  );
});

Deno.test("a verified user yields the caller and the claims it proposes", async () => {
  const caller = await authenticate(req("Bearer tok"), verifying(user));
  assertEquals(caller, {
    userId: user.sub,
    authorization: "Bearer tok",
    activeTenantId: "10000000-0000-0000-0000-000000000001",
    tenantRole: "DSA",
    platformRole: null,
  });
});
```

`supabase/functions/_shared/validate.test.ts`:

```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { parseJsonBody, stripTenantKeys } from "./validate.ts";

const post = (body: string) => new Request("http://x", { method: "POST", body });

Deno.test("tenant keys are stripped at every depth (decision 4)", () => {
  assertEquals(
    stripTenantKeys({ tenantId: "t", tenant_id: "t", p_tenant_id: "t", a: [{ tenantId: "t", b: 1 }], c: { tenant_id: "t" } }),
    { a: [{ b: 1 }], c: {} },
  );
});

Deno.test("a body that is not JSON is 400 INVALID_JSON", async () => {
  const e = await assertRejects(() => parseJsonBody(post("{nope"), z.object({})), GatewayError);
  assertEquals([e.status, e.code], [400, "INVALID_JSON"]);
});

Deno.test("a body that fails the schema is 400 VALIDATION_FAILED with field errors", async () => {
  const e = await assertRejects(
    () => parseJsonBody(post('{"n":"x"}'), z.object({ n: z.number() })),
    GatewayError,
  );
  assertEquals([e.status, e.code], [400, "VALIDATION_FAILED"]);
  assertEquals(Object.keys((e.details as { fieldErrors: object }).fieldErrors), ["n"]);
});

Deno.test("a client-supplied tenant never reaches the handler, even if the schema names it", async () => {
  const body = await parseJsonBody(post('{"tenant_id":"evil","n":1}'), z.object({ n: z.number(), tenant_id: z.string().optional() }));
  assertEquals(body, { n: 1 });
});
```

`supabase/functions/_shared/gateway.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { userGateway, type UserGatewayDeps } from "./gateway.ts";
import type { Rpc } from "./db.ts";

const claims = { sub: "u1", role: "authenticated", app_metadata: {} };
function deps(rpc: Rpc, seen: string[] = []): UserGatewayDeps {
  return {
    verifyToken: () => Promise.resolve(claims),
    rpcFor: (authorization) => {
      seen.push(authorization);
      return rpc;
    },
  };
}
const okRpc: Rpc = <T>() => Promise.resolve({ done: true } as T);
const call = (handler: (r: Request) => Promise<Response>, method = "POST", body = '{"n":1}') =>
  handler(new Request("http://x", { method, body: method === "GET" ? undefined : body, headers: { Authorization: "Bearer tok" } }));

Deno.test("only POST is accepted", async () => {
  const res = await call(userGateway(z.object({}), () => Promise.resolve({}), deps(okRpc)), "GET");
  assertEquals(res.status, 405);
});

Deno.test("the handler gets the caller's own JWT for its RPC client (§3.2)", async () => {
  const seen: string[] = [];
  const handler = userGateway(z.object({ n: z.number() }), async ({ body, rpc }) => ({ n: body.n, r: await rpc("x", {}) }), deps(okRpc, seen));
  const res = await call(handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { n: 1, r: { done: true } });
  assertEquals(seen, ["Bearer tok"]);
});

Deno.test("a mapped database error keeps its status", async () => {
  const failing: Rpc = () => Promise.reject(new GatewayError(409, "IDEMPOTENCY_MISMATCH", "reused"));
  const handler = userGateway(z.object({ n: z.number() }), ({ rpc }) => rpc("x", {}), deps(failing));
  const res = await call(handler);
  assertEquals(res.status, 409);
});

Deno.test("validation runs before any RPC client is created", async () => {
  const seen: string[] = [];
  const handler = userGateway(z.object({ n: z.string() }), () => Promise.resolve({}), deps(okRpc, seen));
  const res = await call(handler);
  assertEquals(res.status, 400);
  assertEquals(seen, []);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `deno test --allow-env supabase/functions/_shared/`
Expected: FAIL — `Module not found` for `auth.ts`, `validate.ts`, `gateway.ts`.

- [ ] **Step 3: Write the implementation**

`supabase/functions/_shared/auth.ts`:

```ts
// Spec A §3.1 steps 1–2: verify the JWT, reject anonymous callers, read the
// claims. The claims only PROPOSE a tenant; the RPC re-checks it live (§4.4).
import { createClient } from "./deps.ts";
import { requireEnv } from "./env.ts";
import { GatewayError } from "./errors.ts";

export type Caller = {
  userId: string;
  authorization: string;
  activeTenantId: string | null;
  tenantRole: string | null;
  platformRole: string | null;
};

export type TokenVerifier = (token: string) => Promise<Record<string, unknown> | null>;

const unauthenticated = () => new GatewayError(401, "UNAUTHENTICATED", "Sign in to continue.");
const text = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);

export async function authenticate(req: Request, verify: TokenVerifier): Promise<Caller> {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") ?? "");
  if (!match) throw unauthenticated();

  const claims = await verify(match[1]);
  if (
    !claims || typeof claims.sub !== "string" || claims.role !== "authenticated" ||
    claims.is_anonymous === true
  ) {
    throw unauthenticated();
  }

  const app = (claims.app_metadata ?? {}) as Record<string, unknown>;
  return {
    userId: claims.sub,
    authorization: `Bearer ${match[1]}`,
    activeTenantId: text(app.active_tenant_id),
    tenantRole: text(app.tenant_role),
    platformRole: text(app.platform_role),
  };
}

// getClaims verifies asymmetric tokens locally against the project's JWKS and
// falls back to the Auth server for symmetric ones.
export function supabaseTokenVerifier(): TokenVerifier {
  const client = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return async (token) => {
    const { data, error } = await client.auth.getClaims(token);
    if (error || !data) return null;
    return data.claims as Record<string, unknown>;
  };
}
```

`supabase/functions/_shared/validate.ts`:

```ts
// Spec A §3.1 step 3: Zod-validate the body after stripping any
// client-supplied tenant (decision 4 — the tenant comes from the JWT only).
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";

const TENANT_KEYS = new Set(["tenantId", "tenant_id", "p_tenant_id"]);

export function stripTenantKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripTenantKeys);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).filter(([k]) => !TENANT_KEYS.has(k)).map(([k, v]) => [k, stripTenantKeys(v)]),
    );
  }
  return value;
}

export async function parseJsonBody<S extends z.ZodTypeAny>(req: Request, schema: S): Promise<z.infer<S>> {
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    throw new GatewayError(400, "INVALID_JSON", "Request body must be JSON.");
  }
  const result = schema.safeParse(stripTenantKeys(raw));
  if (!result.success) {
    throw new GatewayError(400, "VALIDATION_FAILED", "Request body is invalid.", result.error.flatten());
  }
  return result.data;
}

// generated by the client at enqueue time, not send time (§7.2)
export const idempotencyKey = z.string().uuid();
```

`supabase/functions/_shared/db.ts`:

```ts
// Spec A §3.1 step 6 / §3.2. A user RPC runs with the caller's own JWT, so
// the database derives actor and tenant itself; the service-role client exists
// only for system-flavoured functions (§3.4).
import { createClient, type SupabaseClient } from "./deps.ts";
import { requireEnv } from "./env.ts";
import { mapPostgresError } from "./errors.ts";

export type Rpc = <T = unknown>(fn: string, args: Record<string, unknown>) => Promise<T>;

const noSession = { persistSession: false, autoRefreshToken: false };

export function rpcFrom(client: SupabaseClient): Rpc {
  return async <T>(fn: string, args: Record<string, unknown>) => {
    const { data, error } = await client.rpc(fn, args);
    if (error) throw mapPostgresError(error);
    return data as T;
  };
}

export function userRpc(authorization: string): Rpc {
  return rpcFrom(createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authorization } },
    auth: noSession,
  }));
}

export function serviceRpc(): Rpc {
  return rpcFrom(createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: noSession,
  }));
}
```

`supabase/functions/_shared/gateway.ts`:

```ts
// The user-flavoured gateway pipeline (Spec A §3.1):
// POST only → verify JWT → validate body → handler (PIN, IO, one RPC) → §3.5 errors.
import type { z } from "./deps.ts";
import { authenticate, type Caller, supabaseTokenVerifier, type TokenVerifier } from "./auth.ts";
import { type Rpc, userRpc } from "./db.ts";
import { errorResponse, GatewayError } from "./errors.ts";
import { json } from "./http.ts";
import { parseJsonBody } from "./validate.ts";

export type UserGatewayDeps = {
  verifyToken: TokenVerifier;
  rpcFor: (authorization: string) => Rpc;
};

export type UserContext<B> = { caller: Caller; body: B; rpc: Rpc };

export function userGateway<S extends z.ZodTypeAny>(
  schema: S,
  handle: (ctx: UserContext<z.infer<S>>) => Promise<unknown>,
  deps: UserGatewayDeps,
): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");
      const caller = await authenticate(req, deps.verifyToken);
      const body = await parseJsonBody(req, schema);
      return json(200, await handle({ caller, body, rpc: deps.rpcFor(caller.authorization) }));
    } catch (e) {
      return errorResponse(e);
    }
  };
}

export function liveUserGatewayDeps(): UserGatewayDeps {
  return { verifyToken: supabaseTokenVerifier(), rpcFor: userRpc };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `deno test --allow-env supabase/functions/_shared/`
Expected: PASS (all `_shared` tests).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/auth.ts supabase/functions/_shared/validate.ts supabase/functions/_shared/db.ts supabase/functions/_shared/gateway.ts supabase/functions/_shared/auth.test.ts supabase/functions/_shared/validate.test.ts supabase/functions/_shared/gateway.test.ts
git commit -m "feat(functions): shared JWT, validation and user-gateway pipeline"
```

---

### Task 7: `_shared/pin.ts` — the PIN check utility

**Files:**
- Create: `supabase/functions/_shared/pin.ts`
- Test: `supabase/functions/_shared/pin.test.ts`

**Interfaces:**
- Consumes: `Rpc` (Task 6), `verify_pin` (Task 2), `GatewayError`, `z`.
- Produces: `pinSchema: z.ZodString` and `requirePin(rpc: Rpc, pin: string): Promise<void>`. On failure it throws `403 PIN_INVALID {attempts_left}` or `423 PIN_LOCKED {locked_until}`. Spec C/D gateways call it before their business RPC.

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { Rpc } from "./db.ts";
import { GatewayError } from "./errors.ts";
import { pinSchema, requirePin } from "./pin.ts";

const answering = (verdict: unknown, calls: unknown[] = []): Rpc => <T>(fn: string, args: Record<string, unknown>) => {
  calls.push([fn, args]);
  return Promise.resolve(verdict as T);
};

Deno.test("a passing PIN resolves, via verify_pin with the caller's own client", async () => {
  const calls: unknown[] = [];
  await requirePin(answering({ ok: true, attempts_left: 5, locked_until: null }, calls), "1234");
  assertEquals(calls, [["verify_pin", { p_pin: "1234" }]]);
});

Deno.test("a wrong PIN is 403 PIN_INVALID with attempts left", async () => {
  const e = await assertRejects(
    () => requirePin(answering({ ok: false, attempts_left: 3, locked_until: null }), "0000"),
    GatewayError,
  );
  assertEquals([e.status, e.code, e.details], [403, "PIN_INVALID", { attempts_left: 3 }]);
});

Deno.test("a locked membership is 423 PIN_LOCKED with the unlock time", async () => {
  const until = "2026-10-07T12:15:00+00:00";
  const e = await assertRejects(
    () => requirePin(answering({ ok: false, attempts_left: 0, locked_until: until }), "0000"),
    GatewayError,
  );
  assertEquals([e.status, e.code, e.details], [423, "PIN_LOCKED", { locked_until: until }]);
});

Deno.test("pinSchema accepts exactly four digits", () => {
  assertEquals(["1234", "123", "12345", "12a4"].map((p) => pinSchema.safeParse(p).success), [true, false, false, false]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `deno test --allow-env supabase/functions/_shared/pin.test.ts`
Expected: FAIL — `Module not found "…/_shared/pin.ts"`.

- [ ] **Step 3: Write the implementation**

```ts
// Spec A §3.1 step 4 / §5.5. The bcrypt comparison and the lockout counter
// live in public.verify_pin, called with the caller's own JWT: the gateway
// never sees pin_hash and never holds the service-role key.
import { z } from "./deps.ts";
import type { Rpc } from "./db.ts";
import { GatewayError } from "./errors.ts";

export const pinSchema = z.string().regex(/^\d{4}$/, "PIN must be 4 digits");

type PinCheck = { ok: boolean; attempts_left: number; locked_until: string | null };

export async function requirePin(rpc: Rpc, pin: string): Promise<void> {
  const check = await rpc<PinCheck>("verify_pin", { p_pin: pin });
  if (check.ok) return;
  if (check.locked_until) {
    throw new GatewayError(423, "PIN_LOCKED", "Too many wrong PINs. Try again later.", {
      locked_until: check.locked_until,
    });
  }
  throw new GatewayError(403, "PIN_INVALID", "Wrong PIN.", { attempts_left: check.attempts_left });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `deno test --allow-env supabase/functions/_shared/pin.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/pin.ts supabase/functions/_shared/pin.test.ts
git commit -m "feat(functions): shared PIN check backed by verify_pin"
```

---

### Task 8: `_shared` external clients — KudiSMS and the Paystack Verify API

**Files:**
- Create: `supabase/functions/_shared/sms.ts`, `supabase/functions/_shared/paystack.ts`
- Test: `supabase/functions/_shared/sms.test.ts`, `supabase/functions/_shared/paystack.test.ts`

**Interfaces:**
- Produces:
  - `type SmsSender = (to: string, message: string) => Promise<void>`
  - `kudiSmsSender(opts: { token: string; senderId: string; baseUrl?: string; fetchFn?: typeof fetch }): SmsSender`
  - `logSmsSender(): SmsSender`
  - `smsSenderFromEnv(): SmsSender`
  - `type VerifiedTransaction = { status: string; reference: string; amountMinor: number; currency: string; raw: Record<string, unknown> }`
  - `type VerifyTransaction = (reference: string) => Promise<VerifiedTransaction>`
  - `paystackVerifier(opts: { secretKey: string; baseUrl?: string; fetchFn?: typeof fetch }): VerifyTransaction`

- [ ] **Step 1: Check the KudiSMS contract.** In the KudiSMS dashboard's API section, confirm three things:
  - the plain-SMS endpoint is `POST https://my.kudisms.net/api/sms`;
  - the form fields are `token`, `senderID`, `recipients` and `message`;
  - a successful response carries `error_code: "000"`.

  If any of these differ, change `kudiSmsSender` and its test to match the dashboard before continuing. Also confirm the sender ID is approved, and record it for `KUDISMS_SENDER_ID`.

- [ ] **Step 2: Write the failing tests**

`supabase/functions/_shared/sms.test.ts`:

```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { kudiSmsSender, smsSenderFromEnv } from "./sms.ts";

function fakeFetch(response: unknown, status = 200, seen: Request[] = []): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(response), { status }));
  };
}

Deno.test("KudiSMS receives the token, sender, recipient without '+', and message as a form", async () => {
  const seen: Request[] = [];
  const send = kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({ error_code: "000" }, 200, seen) });
  await send("+2348000000005", "Your code is 123456");
  assertEquals(seen[0].method, "POST");
  assertEquals(seen[0].url, "https://my.kudisms.net/api/sms");
  const form = new URLSearchParams(await seen[0].text());
  assertEquals(
    [form.get("token"), form.get("senderID"), form.get("recipients"), form.get("message")],
    ["tok", "Teafair", "2348000000005", "Your code is 123456"],
  );
});

Deno.test("a KudiSMS error code is a failed send", async () => {
  const send = kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({ error_code: "100", msg: "Token provided is invalid" }) });
  await assertRejects(() => send("+2348000000005", "x"), Error, "Token provided is invalid");
});

Deno.test("an HTTP failure is a failed send", async () => {
  const send = kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({}, 500) });
  await assertRejects(() => send("+2348000000005", "x"));
});

Deno.test("there is no default SMS provider", () => {
  Deno.env.delete("SMS_PROVIDER");
  let threw = false;
  try {
    smsSenderFromEnv();
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});
```

`supabase/functions/_shared/paystack.test.ts`:

```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { paystackVerifier } from "./paystack.ts";

function fakeFetch(body: unknown, status = 200, seen: Request[] = []): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
}

const verified = {
  status: true,
  message: "Verification successful",
  data: { status: "success", reference: "ref/1", amount: 250000, currency: "NGN", paid_at: "2026-10-07T12:00:00.000Z" },
};

Deno.test("the Verify API is called with the secret key and an encoded reference", async () => {
  const seen: Request[] = [];
  const verify = paystackVerifier({ secretKey: "sk_test_x", fetchFn: fakeFetch(verified, 200, seen) });
  const tx = await verify("ref/1");
  assertEquals(seen[0].url, "https://api.paystack.co/transaction/verify/ref%2F1");
  assertEquals(seen[0].headers.get("Authorization"), "Bearer sk_test_x");
  assertEquals([tx.status, tx.reference, tx.amountMinor, tx.currency], ["success", "ref/1", 250000, "NGN"]);
  assertEquals(tx.raw, verified.data);
});

Deno.test("a base URL override is honoured (local fake Paystack)", async () => {
  const seen: Request[] = [];
  await paystackVerifier({ secretKey: "k", baseUrl: "http://host.docker.internal:54399", fetchFn: fakeFetch(verified, 200, seen) })("r");
  assertEquals(seen[0].url, "http://host.docker.internal:54399/transaction/verify/r");
});

Deno.test("status:false is an error, never a settlement", async () => {
  const verify = paystackVerifier({ secretKey: "k", fetchFn: fakeFetch({ status: false, message: "Transaction reference not found" }, 400) });
  await assertRejects(() => verify("r"), Error, "Transaction reference not found");
});

Deno.test("a malformed data block is an error", async () => {
  const verify = paystackVerifier({ secretKey: "k", fetchFn: fakeFetch({ status: true, data: { status: "success" } }) });
  await assertRejects(() => verify("r"));
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `deno test --allow-env supabase/functions/_shared/sms.test.ts supabase/functions/_shared/paystack.test.ts`
Expected: FAIL — `Module not found`.

- [ ] **Step 4: Write the implementation**

`supabase/functions/_shared/sms.ts`:

```ts
// SMS delivery for OTPs (Spec A §6.11). KudiSMS in every real environment;
// `log` only for the local stack. There is deliberately no default, so a
// misconfigured deployment fails loudly instead of logging codes.
import { requireEnv } from "./env.ts";

export type SmsSender = (to: string, message: string) => Promise<void>;

export function kudiSmsSender(opts: {
  token: string;
  senderId: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
}): SmsSender {
  const fetchFn = opts.fetchFn ?? fetch;
  const baseUrl = opts.baseUrl ?? "https://my.kudisms.net";
  return async (to, message) => {
    const res = await fetchFn(`${baseUrl}/api/sms`, {
      method: "POST",
      body: new URLSearchParams({
        token: opts.token,
        senderID: opts.senderId,
        recipients: to.replace(/^\+/, ""),
        message,
      }),
    });
    const payload = await res.json().catch(() => null) as { error_code?: string; msg?: string } | null;
    if (!res.ok || payload?.error_code !== "000") {
      throw new Error(`KudiSMS rejected the message: ${payload?.msg ?? `HTTP ${res.status}`}`);
    }
  };
}

export function logSmsSender(): SmsSender {
  return (to, message) => {
    console.log(`[sms:log] to ${to}: ${message}`);
    return Promise.resolve();
  };
}

export function smsSenderFromEnv(): SmsSender {
  const provider = requireEnv("SMS_PROVIDER");
  if (provider === "kudisms") {
    return kudiSmsSender({ token: requireEnv("KUDISMS_TOKEN"), senderId: requireEnv("KUDISMS_SENDER_ID") });
  }
  if (provider === "log") return logSmsSender();
  throw new Error(`unknown SMS_PROVIDER ${provider}`);
}
```

`supabase/functions/_shared/paystack.ts`:

```ts
// Spec A §3.6 check 3 / §6.11: amount, currency and status come from the
// Verify Transaction API, never from a webhook body or a client.
import { z } from "./deps.ts";

export type VerifiedTransaction = {
  status: string;
  reference: string;
  amountMinor: number;
  currency: string;
  raw: Record<string, unknown>;
};
export type VerifyTransaction = (reference: string) => Promise<VerifiedTransaction>;

const verifyResponse = z.object({
  status: z.literal(true),
  data: z.object({
    status: z.string(),
    reference: z.string(),
    amount: z.number().int(),
    currency: z.string(),
  }).passthrough(),
});

export function paystackVerifier(opts: {
  secretKey: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
}): VerifyTransaction {
  const fetchFn = opts.fetchFn ?? fetch;
  const baseUrl = opts.baseUrl ?? "https://api.paystack.co";
  return async (reference) => {
    const res = await fetchFn(`${baseUrl}/transaction/verify/${encodeURIComponent(reference)}`, {
      headers: { Authorization: `Bearer ${opts.secretKey}` },
    });
    const payload = await res.json().catch(() => null) as { message?: string } | null;
    const parsed = verifyResponse.safeParse(payload);
    if (!res.ok || !parsed.success) {
      throw new Error(`Paystack verify failed: ${payload?.message ?? `HTTP ${res.status}`}`);
    }
    const { data } = parsed.data;
    return {
      status: data.status,
      reference: data.reference,
      amountMinor: data.amount,
      currency: data.currency,
      raw: data,
    };
  };
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `deno test --allow-env supabase/functions/_shared/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/sms.ts supabase/functions/_shared/paystack.ts supabase/functions/_shared/sms.test.ts supabase/functions/_shared/paystack.test.ts
git commit -m "feat(functions): KudiSMS sender and Paystack Verify API client"
```

---

### Task 9: `auth-verify-claims` — the Custom Access Token Hook

**Files:**
- Create: `supabase/functions/auth-verify-claims/handler.ts`, `index.ts`, `handler.test.ts`
- Create: `supabase/.env.example`, `supabase/functions/.env.example`
- Modify: `supabase/config.toml` — replace the commented `# [auth.hook.custom_access_token]` block (lines 284–286) and add `[functions.*]` blocks after `[edge_runtime]`.

**Interfaces:**
- Consumes: `access_token_claims` (Task 1), `serviceRpc`, `json`, `requireEnv`, `Webhook`, `z`.
- Produces: `createAuthHookHandler(deps: { verifyHook: (payload: string, headers: Record<string, string>) => unknown; claimsFor: (userId: string) => Promise<Record<string, unknown>> })`.

- [ ] **Step 1: Write the failing test** — `supabase/functions/auth-verify-claims/handler.test.ts`

```ts
import { assertEquals } from "jsr:@std/assert@1";
import { createAuthHookHandler } from "./handler.ts";

const event = {
  user_id: "20000000-0000-0000-0000-000000000003",
  claims: { sub: "20000000-0000-0000-0000-000000000003", role: "authenticated", app_metadata: { provider: "email" } },
  authentication_method: "password",
};
const tenantClaims = {
  tenant_ids: ["10000000-0000-0000-0000-000000000001"],
  active_tenant_id: "10000000-0000-0000-0000-000000000001",
  tenant_role: "DSA",
  platform_role: null,
};
const post = (body: unknown) => new Request("http://x", { method: "POST", body: JSON.stringify(body) });

Deno.test("an unsigned or forged hook call is refused", async () => {
  const handler = createAuthHookHandler({
    verifyHook: () => {
      throw new Error("bad signature");
    },
    claimsFor: () => Promise.resolve(tenantClaims),
  });
  const res = await handler(post(event));
  assertEquals(res.status, 401);
});

Deno.test("tenant claims are merged into app_metadata, keeping every existing claim", async () => {
  const seen: string[] = [];
  const handler = createAuthHookHandler({
    verifyHook: (payload) => JSON.parse(payload),
    claimsFor: (id) => {
      seen.push(id);
      return Promise.resolve(tenantClaims);
    },
  });
  const res = await handler(post(event));
  assertEquals(res.status, 200);
  assertEquals(seen, [event.user_id]);
  assertEquals(await res.json(), {
    claims: { ...event.claims, app_metadata: { provider: "email", ...tenantClaims } },
  });
});

Deno.test("a signed payload of the wrong shape is 400", async () => {
  const handler = createAuthHookHandler({
    verifyHook: () => ({ nope: true }),
    claimsFor: () => Promise.resolve(tenantClaims),
  });
  assertEquals((await handler(post({}))).status, 400);
});

Deno.test("a database failure fails the sign-in closed, in the hook error shape", async () => {
  const handler = createAuthHookHandler({
    verifyHook: (payload) => JSON.parse(payload),
    claimsFor: () => Promise.reject(new Error("db down")),
  });
  const res = await handler(post(event));
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error.http_code, 500);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `deno test --allow-env supabase/functions/auth-verify-claims/`
Expected: FAIL — `Module not found "…/handler.ts"`.

- [ ] **Step 3: Write the implementation**

`supabase/functions/auth-verify-claims/handler.ts`:

```ts
// Spec A §4.4 — Custom Access Token Hook. Supabase Auth calls this, signed
// with Standard Webhooks, every time it mints an access token. The claim rules
// live in public.access_token_claims (pgTAP-tested); this is the HTTP shell.
// Claims PROPOSE; every RPC re-checks tenant_users live.
import { z } from "../_shared/deps.ts";
import { json } from "../_shared/http.ts";

export type AuthHookDeps = {
  verifyHook: (payload: string, headers: Record<string, string>) => unknown;
  claimsFor: (userId: string) => Promise<Record<string, unknown>>;
};

const hookEvent = z.object({
  user_id: z.string().uuid(),
  claims: z.record(z.unknown()),
}).passthrough();

const hookError = (status: number, message: string) => json(status, { error: { http_code: status, message } });

export function createAuthHookHandler(deps: AuthHookDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    const payload = await req.text();

    let signed: unknown;
    try {
      signed = deps.verifyHook(payload, Object.fromEntries(req.headers));
    } catch {
      return hookError(401, "invalid hook signature");
    }

    const event = hookEvent.safeParse(signed);
    if (!event.success) return hookError(400, "unexpected hook payload");

    try {
      const tenant = await deps.claimsFor(event.data.user_id);
      const appMetadata = { ...((event.data.claims.app_metadata as Record<string, unknown>) ?? {}), ...tenant };
      return json(200, { claims: { ...event.data.claims, app_metadata: appMetadata } });
    } catch (e) {
      console.error("access_token_claims failed", e);
      return hookError(500, "could not load tenant claims");
    }
  };
}
```

`supabase/functions/auth-verify-claims/index.ts`:

```ts
import { Webhook } from "../_shared/deps.ts";
import { serviceRpc } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { createAuthHookHandler } from "./handler.ts";

// system-flavoured (§3.4): no user JWT exists yet, so the claims are read
// with the service-role key — the only non-webhook place it appears.
const webhook = new Webhook(requireEnv("AUTH_HOOK_SECRET").replace("v1,whsec_", ""));
const rpc = serviceRpc();

Deno.serve(createAuthHookHandler({
  verifyHook: (payload, headers) => webhook.verify(payload, headers),
  claimsFor: (userId) => rpc<Record<string, unknown>>("access_token_claims", { p_user_id: userId }),
}));
```

- [ ] **Step 4: Run test to verify it passes**

Run: `deno test --allow-env supabase/functions/auth-verify-claims/`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire the hook and secrets**

In `supabase/config.toml`, replace:

```toml
# [auth.hook.custom_access_token]
# enabled = true
# uri = "pg-functions://<database>/<schema>/<hook_name>"
```

with:

```toml
# Spec A §4.4 — tenant claims, minted by the auth-verify-claims Edge Function.
[auth.hook.custom_access_token]
enabled = true
uri = "http://host.docker.internal:54321/functions/v1/auth-verify-claims"
secrets = "env(AUTH_HOOK_SECRET)"
```

After the `[edge_runtime]` block's `deno_version = 2` line, add:

```toml

# Every function verifies its own caller: the user gateways through
# auth.getClaims(), the hook through Standard Webhooks, the webhook through
# Paystack's HMAC. The platform's legacy JWT check is therefore off.
[functions.auth-verify-claims]
verify_jwt = false

[functions.process-payment]
verify_jwt = false

[functions.otp-issue]
verify_jwt = false

[functions.otp-verify]
verify_jwt = false
```

Create `supabase/.env.example`:

```ini
# Copy to supabase/.env (gitignored). Read by config.toml through env().
# Must be the same value as AUTH_HOOK_SECRET in supabase/functions/.env.
AUTH_HOOK_SECRET=v1,whsec_REPLACE_WITH_BASE64_SECRET
```

Create `supabase/functions/.env.example`:

```ini
# Copy to supabase/functions/.env (gitignored). Loaded by `supabase functions serve`.
AUTH_HOOK_SECRET=v1,whsec_REPLACE_WITH_BASE64_SECRET
PAYSTACK_SECRET_KEY=sk_test_REPLACE
# Omit in real environments (defaults to https://api.paystack.co).
# Local integration tests point it at their fake Paystack:
PAYSTACK_API_BASE=http://host.docker.internal:54399
# kudisms in real environments; log prints codes to the function log (local only)
SMS_PROVIDER=log
KUDISMS_TOKEN=
KUDISMS_SENDER_ID=
```

Generate the real local secret and write both gitignored files. Run each command separately; do not echo the secret anywhere else:

```bash
git check-ignore supabase/.env supabase/functions/.env   # must print both paths before creating them
SECRET="v1,whsec_$(openssl rand -base64 32)"
printf 'AUTH_HOOK_SECRET=%s\n' "$SECRET" > supabase/.env
printf 'AUTH_HOOK_SECRET=%s\nPAYSTACK_SECRET_KEY=sk_test_local_only\nPAYSTACK_API_BASE=http://host.docker.internal:54399\nSMS_PROVIDER=log\n' "$SECRET" > supabase/functions/.env
```

- [ ] **Step 6: Restart the stack with the hook enabled**

Run: `supabase stop` then `supabase start`
Expected: the stack starts. If it reports `AUTH_HOOK_SECRET` as unset, the CLI is not reading `supabase/.env` for `config.toml`. Copy the same line into a repo-root `.env` (also gitignored, confirm with `git check-ignore .env`) and retry.

Run: `supabase functions serve --env-file supabase/functions/.env` (in the background, leave it running)
Expected: `Serving functions on http://127.0.0.1:54321/functions/v1/<function-name>` with `auth-verify-claims` listed. The end-to-end sign-in check is in Task 12.

- [ ] **Step 7: Type-check and commit**

Run: `deno check supabase/functions/auth-verify-claims/index.ts`
Expected: no errors.

```bash
git status --short   # must NOT list supabase/.env or supabase/functions/.env
git add supabase/functions/auth-verify-claims supabase/config.toml supabase/.env.example supabase/functions/.env.example
git commit -m "feat(functions): auth-verify-claims access-token hook"
```

---

### Task 10: `process-payment` — the Paystack webhook

**Files:**
- Create: `supabase/functions/process-payment/signature.ts`, `replay-window.ts`, `handler.ts`, `index.ts`
- Test: `supabase/functions/process-payment/signature.test.ts`, `replay-window.test.ts`, `handler.test.ts`

**Interfaces:**
- Consumes: `settle_paystack_payment`, `record_stale_paystack_webhook` (Task 4), `VerifyTransaction`/`paystackVerifier` (Task 8), `Rpc`/`serviceRpc`, `GatewayError`, `errorResponse`, `json`, `z`.
- Produces:
  - `paystackSignatureValid(rawBody: string, signature: string | null, secretKey: string): Promise<boolean>`
  - `REPLAY_WINDOW_MS = 300_000`
  - `eventTime(data: { paid_at?: string | null; created_at?: string | null }): Date | null`
  - `withinReplayWindow(at: Date | null, now: Date): boolean`
  - `createProcessPaymentHandler(deps: { secretKey: string; verifyTransaction: VerifyTransaction; rpc: Rpc; now: () => Date })`

- [ ] **Step 1: Write the failing tests**

`supabase/functions/process-payment/signature.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import { paystackSignatureValid } from "./signature.ts";

// HMAC-SHA512('sk_test_secret', '{"event":"charge.success"}'), computed independently
const body = '{"event":"charge.success"}';
const expected =
  "d2c20958e71984927bee0613f77fa295c3fa82f681cebac2f292d603fbc0ec52d7302b91f7beb43b3e289b0cee9b9867daf70f7a5b1af70eb4d8da1909b5fd36";

Deno.test("a correct HMAC-SHA512 of the raw body is valid", async () => {
  assertEquals(await paystackSignatureValid(body, expected, "sk_test_secret"), true);
});

Deno.test("hex case does not matter", async () => {
  assertEquals(await paystackSignatureValid(body, expected.toUpperCase(), "sk_test_secret"), true);
});

Deno.test("a re-serialised body (whitespace changed) is invalid: hash the raw bytes", async () => {
  assertEquals(await paystackSignatureValid('{"event": "charge.success"}', expected, "sk_test_secret"), false);
});

Deno.test("a wrong key, missing header or truncated signature is invalid", async () => {
  assertEquals(await paystackSignatureValid(body, expected, "sk_test_other"), false);
  assertEquals(await paystackSignatureValid(body, null, "sk_test_secret"), false);
  assertEquals(await paystackSignatureValid(body, expected.slice(0, 64), "sk_test_secret"), false);
});
```

`supabase/functions/process-payment/replay-window.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import { eventTime, withinReplayWindow } from "./replay-window.ts";

const now = new Date("2026-10-07T12:00:00Z");
const at = (iso: string) => new Date(iso);

Deno.test("±300 s is inside; 301 s either way is outside (§3.6 check 2)", () => {
  assertEquals(withinReplayWindow(at("2026-10-07T11:55:00Z"), now), true);
  assertEquals(withinReplayWindow(at("2026-10-07T12:05:00Z"), now), true);
  assertEquals(withinReplayWindow(at("2026-10-07T11:54:59Z"), now), false);
  assertEquals(withinReplayWindow(at("2026-10-07T12:05:01Z"), now), false);
});

Deno.test("paid_at is preferred, created_at is the fallback", () => {
  assertEquals(eventTime({ paid_at: "2026-10-07T11:59:00Z", created_at: "2026-10-07T10:00:00Z" })?.toISOString(),
    "2026-10-07T11:59:00.000Z");
  assertEquals(eventTime({ paid_at: null, created_at: "2026-10-07T10:00:00Z" })?.toISOString(),
    "2026-10-07T10:00:00.000Z");
});

Deno.test("no usable time fails closed", () => {
  assertEquals(eventTime({}), null);
  assertEquals(eventTime({ paid_at: "not a date" }), null);
  assertEquals(withinReplayWindow(null, now), false);
});
```

`supabase/functions/process-payment/handler.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/db.ts";
import type { VerifiedTransaction, VerifyTransaction } from "../_shared/paystack.ts";
import { createProcessPaymentHandler } from "./handler.ts";

const SECRET = "sk_test_secret";
const NOW = new Date("2026-10-07T12:00:00Z");

async function sign(body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
}

function setup(opts: { verify?: VerifyTransaction; rpcResult?: unknown } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const verifyCalls: string[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve((opts.rpcResult ?? { outcome: "updated" }) as T);
  };
  const verified: VerifiedTransaction = { status: "success", reference: "ref_1", amountMinor: 250000, currency: "NGN", raw: { id: 9 } };
  const verifyTransaction: VerifyTransaction = opts.verify ?? ((ref) => {
    verifyCalls.push(ref);
    return Promise.resolve(verified);
  });
  const handler = createProcessPaymentHandler({ secretKey: SECRET, verifyTransaction, rpc, now: () => NOW });
  return { handler, rpcCalls, verifyCalls };
}

async function deliver(handler: (r: Request) => Promise<Response>, payload: unknown, signature?: string) {
  const body = JSON.stringify(payload);
  return handler(new Request("http://x", {
    method: "POST",
    body,
    headers: { "x-paystack-signature": signature ?? await sign(body) },
  }));
}

const fresh = { event: "charge.success", data: { reference: "ref_1", amount: 1, currency: "XXX", paid_at: "2026-10-07T11:59:00Z" } };

Deno.test("a bad signature is 401 and touches nothing", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await deliver(handler, fresh, "00");
  assertEquals(res.status, 401);
  assertEquals([rpcCalls.length, verifyCalls.length], [0, 0]);
});

Deno.test("events other than charge.success are acknowledged and ignored", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await deliver(handler, { event: "transfer.success", data: { reference: "t" } });
  assertEquals([res.status, (await res.json()).outcome], [200, "ignored"]);
  assertEquals([rpcCalls.length, verifyCalls.length], [0, 0]);
});

Deno.test("a stale event is acknowledged, audited, and never verified or applied", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const stale = { ...fresh, data: { ...fresh.data, paid_at: "2026-10-07T11:50:00Z" } };
  const res = await deliver(handler, stale);
  assertEquals([res.status, (await res.json()).outcome], [200, "stale"]);
  assertEquals(verifyCalls, []);
  assertEquals(rpcCalls, [["record_stale_paystack_webhook",
    { p_event: "charge.success", p_reference: "ref_1", p_event_time: "2026-10-07T11:50:00.000Z" }]]);
});

Deno.test("a fresh event settles with the Verify API's values, not the webhook's", async () => {
  const { handler, rpcCalls, verifyCalls } = setup();
  const res = await deliver(handler, fresh);
  assertEquals([res.status, (await res.json()).outcome], [200, "updated"]);
  assertEquals(verifyCalls, ["ref_1"]);
  assertEquals(rpcCalls, [["settle_paystack_payment", {
    p_event: "charge.success", p_reference: "ref_1", p_status: "success",
    p_amount_minor: 250000, p_currency: "NGN", p_verified: { id: 9 },
  }]]);
});

Deno.test("a Verify API outage is a 500, so Paystack retries", async () => {
  const { handler, rpcCalls } = setup({ verify: () => Promise.reject(new Error("timeout")) });
  const res = await deliver(handler, fresh);
  assertEquals(res.status, 500);
  assertEquals(rpcCalls.length, 0);
});

Deno.test("a Verify API answer for a different reference is refused", async () => {
  const { handler, rpcCalls } = setup({
    verify: () => Promise.resolve({ status: "success", reference: "other", amountMinor: 1, currency: "NGN", raw: {} }),
  });
  const res = await deliver(handler, fresh);
  assertEquals([res.status, (await res.json()).error.code], [502, "PAYSTACK_MISMATCH"]);
  assertEquals(rpcCalls.length, 0);
});

Deno.test("a signed body that is not JSON is acknowledged and ignored", async () => {
  const { handler, rpcCalls } = setup();
  const body = "not json";
  const res = await handler(new Request("http://x", { method: "POST", body, headers: { "x-paystack-signature": await sign(body) } }));
  assertEquals([res.status, rpcCalls.length], [200, 0]);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `deno test --allow-env supabase/functions/process-payment/`
Expected: FAIL — `Module not found`.

- [ ] **Step 3: Write the implementation**

`supabase/functions/process-payment/signature.ts`:

```ts
// Spec A §3.6 check 1: x-paystack-signature is the hex HMAC-SHA512 of the RAW
// body keyed with the secret key, compared in constant time.
export async function paystackSignatureValid(
  rawBody: string,
  signature: string | null,
  secretKey: string,
): Promise<boolean> {
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secretKey),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody)));
  const expected = Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
  return constantTimeEqual(expected, signature.toLowerCase());
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
```

`supabase/functions/process-payment/replay-window.ts`:

```ts
// Spec A §3.6 check 2. Paystack's signature carries no timestamp, so the window
// is measured against the event's own time: paid_at, else created_at. No
// usable time fails closed (treated as stale; the reconcile sweep settles it).
export const REPLAY_WINDOW_MS = 300_000;

export function eventTime(data: { paid_at?: string | null; created_at?: string | null }): Date | null {
  const raw = data.paid_at ?? data.created_at;
  if (!raw) return null;
  const at = new Date(raw);
  return Number.isNaN(at.getTime()) ? null : at;
}

export function withinReplayWindow(at: Date | null, now: Date): boolean {
  return at !== null && Math.abs(now.getTime() - at.getTime()) <= REPLAY_WINDOW_MS;
}
```

`supabase/functions/process-payment/handler.ts`:

```ts
// Spec A §3.6 — Paystack webhook. Four checks, in order, before any RPC:
// signature → replay window → Verify API → at-most-once (in the RPC).
// Non-2xx means "retry" to Paystack, so only real failures return one.
import { z } from "../_shared/deps.ts";
import type { Rpc } from "../_shared/db.ts";
import { errorResponse, GatewayError } from "../_shared/errors.ts";
import { json } from "../_shared/http.ts";
import type { VerifyTransaction } from "../_shared/paystack.ts";
import { eventTime, withinReplayWindow } from "./replay-window.ts";
import { paystackSignatureValid } from "./signature.ts";

export type ProcessPaymentDeps = {
  secretKey: string;
  verifyTransaction: VerifyTransaction;
  rpc: Rpc;
  now: () => Date;
};

const webhook = z.object({
  event: z.string().min(1),
  data: z.object({
    reference: z.string().min(1),
    paid_at: z.string().nullish(),
    created_at: z.string().nullish(),
  }).passthrough(),
});

const acknowledged = (outcome: string) => json(200, { received: true, outcome });

function parseWebhook(raw: string) {
  try {
    return webhook.safeParse(JSON.parse(raw));
  } catch {
    return null;
  }
}

export function createProcessPaymentHandler(deps: ProcessPaymentDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new GatewayError(405, "METHOD_NOT_ALLOWED", "Use POST.");

      // 1. signature over the raw bytes — parsing first would break it
      const raw = await req.text();
      if (!(await paystackSignatureValid(raw, req.headers.get("x-paystack-signature"), deps.secretKey))) {
        throw new GatewayError(401, "INVALID_SIGNATURE", "Invalid signature.");
      }

      const parsed = parseWebhook(raw);
      if (!parsed?.success || parsed.data.event !== "charge.success") return acknowledged("ignored");
      const { event, data } = parsed.data;

      // 2. replay window; stale events are recorded and left for the sweep
      const at = eventTime(data);
      if (!withinReplayWindow(at, deps.now())) {
        await deps.rpc("record_stale_paystack_webhook", {
          p_event: event,
          p_reference: data.reference,
          p_event_time: at?.toISOString() ?? null,
        });
        return acknowledged("stale");
      }

      // 3. source confirmation — the webhook body's amount is never trusted
      const tx = await deps.verifyTransaction(data.reference);
      if (tx.reference !== data.reference) {
        throw new GatewayError(502, "PAYSTACK_MISMATCH", "Paystack verified a different reference.");
      }

      // 4. at most once, inside the RPC
      const result = await deps.rpc<{ outcome: string }>("settle_paystack_payment", {
        p_event: event,
        p_reference: tx.reference,
        p_status: tx.status,
        p_amount_minor: tx.amountMinor,
        p_currency: tx.currency,
        p_verified: tx.raw,
      });
      return acknowledged(result.outcome);
    } catch (e) {
      return errorResponse(e);
    }
  };
}
```

`supabase/functions/process-payment/index.ts`:

```ts
import { serviceRpc } from "../_shared/db.ts";
import { requireEnv } from "../_shared/env.ts";
import { paystackVerifier } from "../_shared/paystack.ts";
import { createProcessPaymentHandler } from "./handler.ts";

// system-flavoured (§3.4): authenticated by Paystack's signature, runs as service_role
const secretKey = requireEnv("PAYSTACK_SECRET_KEY");

Deno.serve(createProcessPaymentHandler({
  secretKey,
  verifyTransaction: paystackVerifier({ secretKey, baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined }),
  rpc: serviceRpc(),
  now: () => new Date(),
}));
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `deno test --allow-env supabase/functions/process-payment/` then `deno check supabase/functions/process-payment/index.ts`
Expected: PASS (14 tests); no type errors.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/process-payment
git commit -m "feat(functions): process-payment Paystack webhook with the four §3.6 checks"
```

---

### Task 11: `otp-issue` and `otp-verify` — the OTP endpoints

**Files:**
- Create: `supabase/functions/otp-issue/code.ts`, `handler.ts`, `index.ts`
- Create: `supabase/functions/otp-verify/handler.ts`, `index.ts`
- Test: `supabase/functions/otp-issue/code.test.ts`, `supabase/functions/otp-issue/handler.test.ts`, `supabase/functions/otp-verify/handler.test.ts`

**Interfaces:**
- Consumes: `issue_otp`, `verify_otp` (Task 3); `userGateway`, `liveUserGatewayDeps`, `UserGatewayDeps` (Task 6); `idempotencyKey`; `SmsSender`, `smsSenderFromEnv` (Task 8); `GatewayError`; `z`.
- Produces:
  - `generateOtpCode(): string` and `maskPhone(phone: string): string`
  - `createOtpIssueHandler(deps: UserGatewayDeps & { sendSms: SmsSender; generateCode: () => string })`
  - `createOtpVerifyHandler(deps: UserGatewayDeps)`
  - HTTP contract:
    - `POST /otp-issue` takes `{idempotency_key, subject_id, purpose}` and returns `{challenge_id, expires_at, destination, sms_sent}`.
    - `POST /otp-verify` takes `{idempotency_key, challenge_id, code}` and returns `{verified: true, challenge_id}`, or `422 OTP_*`.

- [ ] **Step 1: Write the failing tests**

`supabase/functions/otp-issue/code.test.ts`:

```ts
import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { generateOtpCode, maskPhone } from "./code.ts";

Deno.test("codes are six digits, leading zeros kept", () => {
  for (let i = 0; i < 500; i++) assertMatch(generateOtpCode(), /^\d{6}$/);
});

Deno.test("codes vary", () => {
  assertEquals(new Set(Array.from({ length: 50 }, generateOtpCode)).size > 40, true);
});

Deno.test("the destination is masked for the agent's screen", () => {
  assertEquals(maskPhone("+2348012345678"), "+234******5678");
});
```

`supabase/functions/otp-issue/handler.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/db.ts";
import { createOtpIssueHandler } from "./handler.ts";

const KEY = "b0000000-0000-0000-0000-000000000001";
const SUBJECT = "20000000-0000-0000-0000-000000000005";

function setup(opts: { replayed?: boolean; smsFails?: boolean } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const sms: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve({
      challenge_id: "60000000-0000-0000-0000-000000000001",
      expires_at: "2026-10-07T12:05:00+00:00",
      destination_phone: "+2348000000005",
      replayed: opts.replayed ?? false,
    } as T);
  };
  const handler = createOtpIssueHandler({
    verifyToken: () => Promise.resolve({ sub: "u3", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    generateCode: () => "042917",
    sendSms: (to, message) => {
      if (opts.smsFails) return Promise.reject(new Error("KudiSMS down"));
      sms.push([to, message]);
      return Promise.resolve();
    },
  });
  return { handler, rpcCalls, sms };
}

const call = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer tok" } }));

Deno.test("a fresh challenge stores the code via the RPC and texts it to the owner's phone", async () => {
  const { handler, rpcCalls, sms } = setup();
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    challenge_id: "60000000-0000-0000-0000-000000000001",
    expires_at: "2026-10-07T12:05:00+00:00",
    destination: "+234******0005",
    sms_sent: true,
  });
  assertEquals(rpcCalls, [["issue_otp",
    { p_idempotency_key: KEY, p_subject_id: SUBJECT, p_purpose: "POS_SETTLEMENT", p_code: "042917" }]]);
  assertEquals(sms.length, 1);
  assertEquals(sms[0][0], "+2348000000005");
  assertEquals(sms[0][1].includes("042917"), true);
});

Deno.test("a replay never texts a code the database does not hold", async () => {
  const { handler, sms } = setup({ replayed: true });
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals((await res.json()).sms_sent, false);
  assertEquals(sms, []);
});

Deno.test("an SMS failure is 502 SMS_DELIVERY_FAILED", async () => {
  const { handler } = setup({ smsFails: true });
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT" });
  assertEquals([res.status, (await res.json()).error.code], [502, "SMS_DELIVERY_FAILED"]);
});

Deno.test("a client-supplied tenant never reaches the RPC", async () => {
  const { handler, rpcCalls } = setup();
  await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "POS_SETTLEMENT", tenant_id: "evil", tenantId: "evil" });
  assertEquals(Object.keys(rpcCalls[0][1]).some((k) => k.includes("tenant")), false);
});

Deno.test("an unknown purpose is rejected before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await call(handler, { idempotency_key: KEY, subject_id: SUBJECT, purpose: "ANYTHING" });
  assertEquals([res.status, rpcCalls.length], [400, 0]);
});
```

`supabase/functions/otp-verify/handler.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/db.ts";
import { createOtpVerifyHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const CHALLENGE = "60000000-0000-0000-0000-000000000001";

function setup(verdict: unknown) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve(verdict as T);
  };
  const handler = createOtpVerifyHandler({
    verifyToken: () => Promise.resolve({ sub: "u3", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
  });
  return { handler, rpcCalls };
}

const call = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer tok" } }));

Deno.test("a verified code is 200", async () => {
  const { handler, rpcCalls } = setup({ verified: true, challenge_id: CHALLENGE, purpose: "POS_SETTLEMENT" });
  const res = await call(handler, { idempotency_key: KEY, challenge_id: CHALLENGE, code: "123456" });
  assertEquals([res.status, await res.json()], [200, { verified: true, challenge_id: CHALLENGE }]);
  assertEquals(rpcCalls, [["verify_otp", { p_idempotency_key: KEY, p_challenge_id: CHALLENGE, p_code: "123456" }]]);
});

for (const reason of ["INVALID", "EXPIRED", "LOCKED", "CONSUMED"]) {
  Deno.test(`a ${reason} verdict is 422 OTP_${reason}`, async () => {
    const { handler } = setup({ verified: false, reason, attempts_left: reason === "INVALID" ? 3 : undefined });
    const res = await call(handler, { idempotency_key: KEY, challenge_id: CHALLENGE, code: "000000" });
    const body = await res.json();
    assertEquals([res.status, body.error.code], [422, `OTP_${reason}`]);
    assertEquals(body.error.details, { attempts_left: reason === "INVALID" ? 3 : null });
  });
}

Deno.test("a malformed code is 400 and never reaches the database", async () => {
  const { handler, rpcCalls } = setup({ verified: true });
  const res = await call(handler, { idempotency_key: KEY, challenge_id: CHALLENGE, code: "12ab" });
  assertEquals([res.status, rpcCalls.length], [400, 0]);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `deno test --allow-env supabase/functions/otp-issue/ supabase/functions/otp-verify/`
Expected: FAIL — `Module not found`.

- [ ] **Step 3: Write the implementation**

`supabase/functions/otp-issue/code.ts`:

```ts
// Uniform 6-digit codes: rejection sampling avoids the modulo bias of
// `random % 1_000_000` on a 32-bit draw.
const RANGE = 1_000_000;
const LIMIT = 2 ** 32 - (2 ** 32 % RANGE);

export function generateOtpCode(): string {
  const draw = new Uint32Array(1);
  do crypto.getRandomValues(draw); while (draw[0] >= LIMIT);
  return String(draw[0] % RANGE).padStart(6, "0");
}

// "+2348012345678" → "+234******5678"
export function maskPhone(phone: string): string {
  return phone.slice(0, 4) + "*".repeat(Math.max(phone.length - 8, 0)) + phone.slice(-4);
}
```

`supabase/functions/otp-issue/handler.ts`:

```ts
// Spec A §6.11 — issue the shop-owner OTP. The code is generated here, stored
// only as a bcrypt hash by issue_otp, and texted to the phone on the owner's
// profile (never a number from the request).
//
// A replayed key returns the original challenge, whose code this request does
// not know, so a replay never sends an SMS. If the SMS fails, the agent
// requests a fresh code with a new key.
import { z } from "../_shared/deps.ts";
import { GatewayError } from "../_shared/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/gateway.ts";
import type { SmsSender } from "../_shared/sms.ts";
import { idempotencyKey } from "../_shared/validate.ts";
import { maskPhone } from "./code.ts";

export type OtpIssueDeps = UserGatewayDeps & {
  sendSms: SmsSender;
  generateCode: () => string;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  subject_id: z.string().uuid(),
  purpose: z.enum(["PICKUP_CONFIRM", "POS_SETTLEMENT"]),
});

type Issued = { challenge_id: string; expires_at: string; destination_phone: string; replayed: boolean };

const message = (code: string) =>
  `Your Teafair code is ${code}. Give it to the agent only once you have your goods. It expires in 5 minutes.`;

export function createOtpIssueHandler(deps: OtpIssueDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const code = deps.generateCode();
    const issued = await rpc<Issued>("issue_otp", {
      p_idempotency_key: body.idempotency_key,
      p_subject_id: body.subject_id,
      p_purpose: body.purpose,
      p_code: code,
    });

    if (!issued.replayed) {
      try {
        await deps.sendSms(issued.destination_phone, message(code));
      } catch (e) {
        console.error("OTP SMS failed", e);
        throw new GatewayError(502, "SMS_DELIVERY_FAILED", "The code could not be sent. Request a new one.");
      }
    }

    return {
      challenge_id: issued.challenge_id,
      expires_at: issued.expires_at,
      destination: maskPhone(issued.destination_phone),
      sms_sent: !issued.replayed,
    };
  }, deps);
}
```

`supabase/functions/otp-issue/index.ts`:

```ts
import { liveUserGatewayDeps } from "../_shared/gateway.ts";
import { smsSenderFromEnv } from "../_shared/sms.ts";
import { generateOtpCode } from "./code.ts";
import { createOtpIssueHandler } from "./handler.ts";

Deno.serve(createOtpIssueHandler({
  ...liveUserGatewayDeps(),
  sendSms: smsSenderFromEnv(),
  generateCode: generateOtpCode,
}));
```

`supabase/functions/otp-verify/handler.ts`:

```ts
// Spec A §6.11 — verify the shop-owner OTP. verify_otp compares the hash,
// counts failures and consumes the challenge; it returns its verdict rather
// than raising, so a wrong code still counts. Each attempt needs a new
// idempotency key: a reused key replays the earlier verdict.
import { z } from "../_shared/deps.ts";
import { GatewayError } from "../_shared/errors.ts";
import { userGateway, type UserGatewayDeps } from "../_shared/gateway.ts";
import { idempotencyKey } from "../_shared/validate.ts";

const schema = z.object({
  idempotency_key: idempotencyKey,
  challenge_id: z.string().uuid(),
  code: z.string().regex(/^\d{6}$/, "code must be 6 digits"),
});

type Reason = "INVALID" | "EXPIRED" | "LOCKED" | "CONSUMED";
type Verdict = { verified: boolean; reason?: Reason; attempts_left?: number };

const MESSAGES: Record<Reason, string> = {
  INVALID: "That code is wrong.",
  EXPIRED: "That code has expired. Request a new one.",
  LOCKED: "Too many wrong codes. Request a new one.",
  CONSUMED: "That code has already been used.",
};

export function createOtpVerifyHandler(deps: UserGatewayDeps): (req: Request) => Promise<Response> {
  return userGateway(schema, async ({ body, rpc }) => {
    const verdict = await rpc<Verdict>("verify_otp", {
      p_idempotency_key: body.idempotency_key,
      p_challenge_id: body.challenge_id,
      p_code: body.code,
    });
    if (!verdict.verified) {
      const reason = verdict.reason ?? "INVALID";
      throw new GatewayError(422, `OTP_${reason}`, MESSAGES[reason], {
        attempts_left: verdict.attempts_left ?? null,
      });
    }
    return { verified: true, challenge_id: body.challenge_id };
  }, deps);
}
```

`supabase/functions/otp-verify/index.ts`:

```ts
import { liveUserGatewayDeps } from "../_shared/gateway.ts";
import { createOtpVerifyHandler } from "./handler.ts";

Deno.serve(createOtpVerifyHandler(liveUserGatewayDeps()));
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `deno test --allow-env supabase/functions/` then `deno check supabase/functions/*/index.ts`
Expected: every unit test passes; no type errors.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/otp-issue supabase/functions/otp-verify
git commit -m "feat(functions): otp-issue and otp-verify gateways"
```

---

### Task 12: End-to-end against the local stack, then docs

**Files:**
- Create: `supabase/functions/_tests/gateway.integration.ts`
- Modify: `supabase/CLAUDE.md` (status table, layout, a "Writing an Edge Function" section, commands); `CLAUDE.md` (repository state row and "Phase 3 … is next" line); spec §14 status paragraph.

**Interfaces:**
- Consumes: all four served functions, the hook, and the local database (service-role REST for fixtures).

- [ ] **Step 1: Write the integration test** — `supabase/functions/_tests/gateway.integration.ts`

```ts
// End-to-end against `supabase start` + `supabase functions serve`.
// Run: see supabase/CLAUDE.md → "Edge Functions". Needs API_URL, ANON_KEY,
// SERVICE_ROLE_KEY (from `supabase status -o env`) and PAYSTACK_SECRET_KEY.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "../_shared/deps.ts";

const API = Deno.env.get("API_URL")!;
const ANON = Deno.env.get("ANON_KEY")!;
const SERVICE = Deno.env.get("SERVICE_ROLE_KEY")!;
const PAYSTACK_SECRET = Deno.env.get("PAYSTACK_SECRET_KEY")!;
const FN = `${API}/functions/v1`;

const admin = createClient(API, SERVICE, { auth: { persistSession: false } });
const run = crypto.randomUUID().slice(0, 8);
const ids = {
  tenant: crypto.randomUUID(),
  zone: crypto.randomUUID(),
  territory: crypto.randomUUID(),
  tm: crypto.randomUUID(),
  dsm: crypto.randomUUID(),
  dsa: crypto.randomUUID(),
  owner: crypto.randomUUID(),
  order: crypto.randomUUID(),
};
const phone = (n: number) => `234${String(Date.now()).slice(-7)}${n}`;

async function must<T>(p: PromiseLike<{ data: T; error: unknown }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw error;
  return data;
}

async function createUser(n: number): Promise<{ id: string; email: string }> {
  const email = `it-${run}-${n}@teafair.test`;
  const { user } = await must(admin.auth.admin.createUser({
    email, password: "integration-pass-1", email_confirm: true,
    user_metadata: { phone: phone(n), full_name: `IT ${n}` },
  }));
  return { id: user!.id, email };
}

async function signIn(email: string): Promise<string> {
  const client = createClient(API, ANON, { auth: { persistSession: false } });
  const { session } = await must(client.auth.signInWithPassword({ email, password: "integration-pass-1" }));
  return session!.access_token;
}

const claimsOf = (jwt: string) =>
  JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));

async function sign(body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(PAYSTACK_SECRET), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  return Array.from(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))),
    (b) => b.toString(16).padStart(2, "0")).join("");
}

// a fake Paystack Verify API, reached from the edge runtime via host.docker.internal:54399
const paystackLedger = new Map<string, Record<string, unknown>>();
const fakePaystack = Deno.serve({ hostname: "0.0.0.0", port: 54399, onListen() {} }, (req) => {
  const reference = decodeURIComponent(new URL(req.url).pathname.split("/").pop()!);
  const data = paystackLedger.get(reference);
  return data
    ? Response.json({ status: true, message: "Verification successful", data })
    : Response.json({ status: false, message: "Transaction reference not found" }, { status: 400 });
});

let users: Record<"tm" | "dsm" | "dsa" | "owner", { id: string; email: string }>;

Deno.test({
  name: "fixtures",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    users = { tm: await createUser(1), dsm: await createUser(2), dsa: await createUser(3), owner: await createUser(4) };
    await must(admin.from("tenants").insert({ id: ids.tenant, name: `IT ${run}`, code: `IT_${run.toUpperCase().replace(/[^A-Z0-9]/g, "")}`.slice(0, 16) }));
    await must(admin.from("zones").insert({ id: ids.zone, tenant_id: ids.tenant, zone_name: "Lagos" }));
    await must(admin.from("territories").insert({ id: ids.territory, tenant_id: ids.tenant, zone_id: ids.zone, territory_name: "Ikeja" }));
    await must(admin.from("tenant_users").insert([
      { id: ids.tm, tenant_id: ids.tenant, profile_id: users.tm.id, role: "TM", territory_id: ids.territory, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("tenant_users").insert([
      { id: ids.dsm, tenant_id: ids.tenant, profile_id: users.dsm.id, role: "DSM", territory_id: ids.territory, reports_to_id: ids.tm, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("tenant_users").insert([
      { id: ids.dsa, tenant_id: ids.tenant, profile_id: users.dsa.id, role: "DSA", territory_id: ids.territory, reports_to_id: ids.dsm, status: "ACTIVE", is_primary: true },
      { id: ids.owner, tenant_id: ids.tenant, profile_id: users.owner.id, role: "RETAIL_SHOP_OWNER", status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("orders").insert({ id: ids.order, tenant_id: ids.tenant, channel: "FIELD_DSA", teafair_agent_id: users.dsa.id, total_amount: 2500 }));
  },
});

Deno.test({
  name: "auth-verify-claims: a signed-in DSA's token carries the tenant claims",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const app = claimsOf(await signIn(users.dsa.email)).app_metadata;
    assertEquals([app.active_tenant_id, app.tenant_role], [ids.tenant, "DSA"]);
    assertEquals(app.tenant_ids, [ids.tenant]);
  },
});

Deno.test({
  name: "otp-issue: no JWT is 401",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await fetch(`${FN}/otp-issue`, { method: "POST", body: "{}" });
    assertEquals(res.status, 401);
    await res.body?.cancel();
  },
});

Deno.test({
  name: "otp-issue → otp-verify: issue, then a wrong code counts",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const jwt = await signIn(users.dsa.email);
    const post = (fn: string, body: unknown) =>
      fetch(`${FN}/${fn}`, { method: "POST", headers: { Authorization: `Bearer ${jwt}` }, body: JSON.stringify(body) });

    const issued = await post("otp-issue", {
      idempotency_key: crypto.randomUUID(), subject_id: users.owner.id, purpose: "POS_SETTLEMENT",
      tenant_id: crypto.randomUUID(), // must be ignored
    });
    const issuedBody = await issued.json();
    assertEquals(issued.status, 200, JSON.stringify(issuedBody));
    assertEquals(issuedBody.sms_sent, true);

    // the probability that "000000" is the real code is one in a million
    const wrong = await post("otp-verify", { idempotency_key: crypto.randomUUID(), challenge_id: issuedBody.challenge_id, code: "000000" });
    const wrongBody = await wrong.json();
    assertEquals([wrong.status, wrongBody.error.code, wrongBody.error.details.attempts_left], [422, "OTP_INVALID", 4]);
  },
});

Deno.test({
  name: "process-payment: bad signature 401, stale 200 + audit, fresh settles once",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const reference = `it_${run}`;
    await must(admin.from("payments").insert({
      tenant_id: ids.tenant, order_id: ids.order, teafair_agent_id: users.dsa.id,
      amount: 2500, payment_status: "INITIATED", paystack_reference: reference,
    }));
    const deliver = async (payload: unknown, signature?: string) => {
      const body = JSON.stringify(payload);
      const res = await fetch(`${FN}/process-payment`, {
        method: "POST", body, headers: { "x-paystack-signature": signature ?? await sign(body) },
      });
      return { status: res.status, body: await res.json() };
    };

    const forged = await deliver({ event: "charge.success", data: { reference } }, "00");
    assertEquals(forged.status, 401);

    const stale = await deliver({ event: "charge.success", data: { reference, paid_at: new Date(Date.now() - 3_600_000).toISOString() } });
    assertEquals([stale.status, stale.body.outcome], [200, "stale"]);
    const audit = await must(admin.from("audit_logs").select("operation").eq("operation", "WEBHOOK_STALE").eq("tenant_id", ids.tenant));
    assertEquals(audit.length, 1);

    paystackLedger.set(reference, { status: "success", reference, amount: 250000, currency: "NGN", paid_at: new Date().toISOString() });
    const payload = { event: "charge.success", data: { reference, amount: 1, paid_at: new Date().toISOString() } };
    const first = await deliver(payload);
    assertEquals([first.status, first.body.outcome], [200, "updated"], JSON.stringify(first.body));
    const again = await deliver(payload);
    assertEquals(again.body.outcome, "updated");

    const [payment] = await must(admin.from("payments").select("payment_status").eq("paystack_reference", reference));
    assertEquals(payment.payment_status, "SUCCESS");
    const settled = await must(admin.from("audit_logs").select("id").eq("operation", "settle_paystack_payment").eq("tenant_id", ids.tenant));
    assert(settled.length === 1, "a redelivery settles nothing twice");
  },
});

Deno.test({
  name: "teardown",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    await fakePaystack.shutdown();
  },
});
```

- [ ] **Step 2: Run it against the local stack**

The stack from Task 9 must still be running, with `supabase functions serve --env-file supabase/functions/.env` in the background. Then:

```bash
supabase status -o env > supabase/.env.test.local     # gitignored by .env*.local; confirm: git check-ignore supabase/.env.test.local
deno test --allow-net --allow-env --env-file=supabase/.env.test.local --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts
```

Expected: 6 tests pass.
- If the hook test fails with an `app_metadata` lacking `tenant_role`, the hook is not wired. Check the `supabase start` output for `custom_access_token` and the functions log for `auth-verify-claims`.
- If `process-payment` returns 500 on the fresh delivery, the edge runtime cannot reach `host.docker.internal:54399`. Check Windows Firewall for Deno on port 54399.

- [ ] **Step 3: Run the full verification set**

Run: `supabase db reset`, then `supabase test db`, then `deno test --allow-env supabase/functions/`, then `deno check supabase/functions/*/index.ts`
Expected:
- `Result: PASS`, 282 assertions.
- All unit tests pass.
- No type errors.

- [ ] **Step 4: Update the docs**

In `supabase/CLAUDE.md`:
- Status table: phase 3 → `done`.
- Layout block: add `functions/  Edge Functions — _shared/ + one self-contained directory per function`.
- Add this section after "Writing an RPC":

````markdown
## Writing an Edge Function

Each function is a self-contained directory: `index.ts` only wires live
dependencies; `handler.ts` exports `create…Handler(deps)`; tests sit beside
it. Code used by two or more functions goes in `_shared/`, one
responsibility per file; third-party versions appear only in `_shared/deps.ts`.

- User gateways use `userGateway(schema, handle, liveUserGatewayDeps())`: POST
  only → JWT (`auth.getClaims`) → tenant keys stripped → Zod → handler →
  §3.5 error mapping. The handler's `rpc` forwards the caller's JWT. Never
  import `serviceRpc` into a user gateway.
- PIN-gated operations call `requirePin(rpc, body.pin)` before their RPC.
- System functions (`auth-verify-claims`, `process-payment`) authenticate by
  signature and use `serviceRpc()`.
- Every function has `verify_jwt = false` in `config.toml` and verifies its
  caller itself.

```bash
supabase functions serve --env-file supabase/functions/.env     # serve locally
deno test --allow-env supabase/functions/                       # unit tests
supabase status -o env > supabase/.env.test.local               # then:
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts
```

Secrets: copy `supabase/.env.example` and `supabase/functions/.env.example`;
`AUTH_HOOK_SECRET` must match in both. `SMS_PROVIDER=log` locally,
`kudisms` (with `KUDISMS_TOKEN`, `KUDISMS_SENDER_ID`) anywhere real.
````

In root `CLAUDE.md`:
- `supabase/` row: replace with `**Phases 1–3 done**: 20 migrations, 282 pgTAP assertions, 4 Edge Functions. See \`supabase/CLAUDE.md\``.
- Replace `Phase 3 (Edge Function gateway) is next; Phase 4 (client offline queue) needs the Spec B app shell.` with `Phase 4 (client offline queue) needs the Spec B app shell.`

In the spec, §14's status paragraph: replace `**Status (2026-10-06):** phases 1 and 2 are implemented …` with `**Status (2026-10-07):** phases 1–3 are implemented: \`supabase/migrations/\` (282 pgTAP assertions in \`supabase/tests/database/\`) and \`supabase/functions/\` (unit tests beside each function, plus \`_tests/gateway.integration.ts\`).`

- [ ] **Step 5: Commit**

```bash
git status --short   # must NOT list any .env file
git add supabase/functions/_tests supabase/CLAUDE.md CLAUDE.md docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md
git commit -m "test(functions): end-to-end gateway checks; docs: Phase 3 done"
```
