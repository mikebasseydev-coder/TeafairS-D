# Addendum A7: Tenant Support Tickets and Ticket Emails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tenant admins raise support tickets to their CSM (or the MONVELO_OPERATOR pool), and buyers and tenants receive ticket emails through a transactional outbox sent by Resend.

**Architecture:** Two migrations. `20261031121500` adds the outbox table, the internal `enqueue_email`, and the tenant ticket tables, RLS and RPCs. `20261031121600` makes the A3 buyer RPCs enqueue emails and adds the sender RPCs, the purge and the cron jobs. A new cron-invoked system Edge Function `email-outbox-send` drains the outbox through Resend.

**Tech Stack:** Postgres 15 (plpgsql, pgTAP, pg_cron, pg_net, Vault), Supabase Edge Functions (Deno, Zod), Resend.

**Spec:** `docs/superpowers/specs/2026-11-05-addendum-a7-tenant-support-and-ticket-emails-design.md`

## Global Constraints

- Every mutation is a `SECURITY DEFINER` RPC with `SET search_path = public, pg_temp`; `p_idempotency_key uuid` first; `idempotency_begin` / `idempotency_complete`; `write_audit` (`supabase/migrations/20261006130300_write_contract.sql`).
- `authenticated` gets SELECT only; RLS policies are `FOR SELECT`, use `(select auth.uid())` and `public.*` helpers, no per-row correlated subquery.
- Tenant from `public.jwt_tenant_id()`, verified live by `public.assert_tenant_role(...)`. Never a tenant parameter. Platform role through `public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[])`.
- Refusals: wrong role `42501`; ticket not in reach `P0002`; disallowed transition `P0001`.
- Workflow statuses `text` + `CHECK`; timestamps `timestamptz`.
- No email ever contains a message body or a ticket secret. The buyer link is exactly `${WEB_SUPPORT_TICKET_URL}?ref=TK-XXXXXX`.
- References: tenant `^TS-[0-9A-HJKMNP-TV-Z]{6}$` via `public.new_crockford_reference('TS-')` (check its exact argument shape in `20261021120000_support_schema.sql` / wherever it is defined and match how `TK-` calls it).
- Ruling 46: the sender reaches the secret key only through `serviceRpc()` / `_shared/core/keys.ts`, and is added to `SERVICE_RPC` in `supabase/functions/_tests/service-role-guard.test.ts` as `"system: x-cron-secret (constant time)"`.
- Spec correction (Claude's call): the from-address is a new required env `SUPPORT_EMAIL_FROM`, not "`RESEND_FROM`" (that variable does not exist; auth uses `AUTH_EMAIL_FROM`). `RESEND_API_KEY` and `RESEND_API_URL` are shared.
- Name: the directive's `outbox_emails` is the spec's `email_outbox`; the spec wins.
- Everything local. No `supabase db push`, no `functions deploy`, no `git push`.

## Review Focus

1. **Tenant-typed subject in an email** (`<script>`, `&`, quotes): HTML template must escape it; text template plain. Test in Task 3.
2. **Two operators/CSMs claiming the same ticket at once**: `claim_tenant_ticket` locks the row `FOR UPDATE`; the second gets `P0001`. Test in Task 1.
3. **Resend 4xx that will never succeed** (400/403/422): mark FAILED at once rather than retry 5 times; 429 and 5xx/network back off. Test in Tasks 2 and 3.
4. **A sender crash after claim** leaves rows SENDING: a row SENDING for more than 10 minutes is claimable again, and the Resend idempotency key (the outbox id) stops a double delivery. Test in Task 2.
5. **Buyer redacted between enqueue and send**: the PENDING row is gone, so nothing is sent. Test in Task 2.

---

### Task 1: Outbox table and tenant support tickets (migration 121500)

**Files:**
- Create: `supabase/migrations/20261031121500_tenant_support_tickets.sql`
- Test: `supabase/tests/database/070_tenant_support_tickets.test.sql`

**Interfaces:**
- Produces: table `public.email_outbox` (spec §5.1 columns exactly: `id uuid PK default gen_random_uuid()`, `template`, `to_email` nullable-after-redaction but `CHECK (status not in ('PENDING','SENDING') or to_email is not null)`, `payload jsonb not null`, `source_table text not null`, `source_id uuid not null`, `status text default 'PENDING' CHECK in ('PENDING','SENDING','SENT','FAILED')`, `attempts int not null default 0`, `next_attempt_at timestamptz not null default now()`, `sent_at`, `created_at`); index on `(status, next_attempt_at)` and `(source_table, source_id)`. RLS on, no policy, `revoke all from anon, authenticated`.
- Produces: `public.enqueue_email(p_template text, p_to_email text, p_payload jsonb, p_source_table text, p_source_id uuid) returns void`, lower-cases and trims the address and does nothing on null/empty; `revoke all from public, anon, authenticated, service_role`.
- Produces: tables `public.tenant_support_tickets`, `public.tenant_support_ticket_messages` (spec §4.1 exactly).
- Produces: `public.can_read_tenant_ticket(p_tenant_id uuid) returns boolean` stable SECURITY DEFINER: true when `p_tenant_id = jwt_tenant_id()` and the caller holds an ACTIVE `TENANT_ADMIN` or `CLIENT_SERVICE_MANAGER` membership there, or the caller's `profiles.platform_role = 'MONVELO_OPERATOR'`.
- Produces RPCs (all `returns jsonb`, granted to `authenticated`):
  - `open_tenant_ticket(p_idempotency_key uuid, p_category text, p_subject text, p_message text)` → `{ ticket_id, public_reference, status, assigned_csm_id }`
  - `reply_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_body text)` → `{ ticket_id, message_id, status }`
  - `claim_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid)` → `{ ticket_id, assigned_csm_id }`
  - `release_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid)` → `{ ticket_id, assigned_csm_id }` (null)
  - `assign_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_csm_profile_id uuid)` → `{ ticket_id, assigned_csm_id }`
  - `update_tenant_ticket_status(p_idempotency_key uuid, p_ticket_id uuid, p_status text)` → `{ ticket_id, status }`
- Produces: `public.close_resolved_tenant_tickets() returns integer` (revoked from everyone; cron `close-resolved-tenant-tickets` at `35 0 * * *`).
- Internal helpers (revoked from everyone): `tenant_ticket_lock(p_ticket_id uuid) returns tenant_support_tickets` (finds and `FOR UPDATE`-locks the ticket, `P0002` when it is not in the caller's tenant/reach); `tenant_ticket_live_csm(p_ticket tenant_support_tickets) returns uuid` (the assignee if ACTIVE CSM of the ticket's tenant, else null); `tenant_ticket_notify(...)`.

Caller resolution rule used by every RPC except `open_tenant_ticket`: if `assert_platform_role` succeeds the caller is an OPERATOR and the ticket is found by id alone; otherwise `assert_tenant_role(array['TENANT_ADMIN','CLIENT_SERVICE_MANAGER'])` and the ticket must have `tenant_id = jwt_tenant_id()`, else `P0002`. (Write a non-raising `is_monvelo_operator()` helper if `assert_platform_role` cannot be probed without an exception block; a `begin … exception when sqlstate '42501'` block is acceptable.)

Permission matrix (`42501` otherwise):

| RPC | TENANT_ADMIN | live assigned CSM | other CSM of tenant | OPERATOR |
|---|---|---|---|---|
| open | yes | – | – | – |
| reply | yes (side TENANT) | yes (TEAFAIR) | no | yes (TEAFAIR) |
| claim | no | no (already assigned → `P0001`) | only if live assignee is null | no |
| release | no | yes | no | no |
| assign | no | no | no | yes; target must be ACTIVE CSM of the ticket's tenant else `P0001`; null allowed |
| status | no | yes | no | yes |

Transitions: TEAFAIR reply on OPEN → IN_PROGRESS; TENANT reply on RESOLVED → OPEN (clear `resolved_at`); any reply or claim/assign/status on CLOSED → `P0001`; status as A3 (IN_PROGRESS→RESOLVED sets `resolved_at`; OPEN/IN_PROGRESS/RESOLVED→CLOSED).

Notifications (spec §4.4) and enqueued emails (§5.3), payload `{public_reference, category, subject}` plus `status` for STATUS:
- open → notify live CSM else every ACTIVE `MONVELO_OPERATOR` (`TENANT_TICKET_ACTIVITY`); email `TENANT_TICKET_OPENED` to `opened_by`'s `profiles.email`.
- TENANT reply → notify as open.
- TEAFAIR reply → notify `opened_by` (`TENANT_TICKET_UPDATE`); email `TENANT_TICKET_REPLY`.
- status → notify `opened_by`; RESOLVED/CLOSED (and auto-close) → email `TENANT_TICKET_STATUS`.

- [ ] **Step 1: Write the failing pgTAP file** `070_tenant_support_tickets.test.sql`, fixtures in the style of `069_monvelo_deferred_minors.test.sql` (tenants T1 = TEAFAIR `7eaf0000-…0001`, T2 = a second tenant; profiles with emails). Users: 08 TENANT_ADMIN T1, 09 TENANT_ADMIN T2, 12 CSM T1, 13 second CSM T1 (INVITED at first), 14 CSM T2, 15 MONVELO_OPERATOR (platform role, no membership), 01 ZSM T1, 03 TM T1, 16 LOGISTICS_MANAGER T1. Tests (names → assertions):
  - `schema`: `has_table` ×2; `col_not_null('tenant_support_tickets','tenant_id')`; `throws_ok` inserting category `'OTHER'` (23514); `TS-` reference CHECK.
  - `open auto-assigns the only CSM`: as 08, open → `assigned_csm_id = u(12)`, reference matches `^TS-`, first message side `TENANT`.
  - `open with two CSMs leaves it unassigned`: activate 13, open again → null; notification rows for 15 kind `TENANT_TICKET_ACTIVITY`.
  - `open with no CSM`: T2 after suspending 14 → null.
  - `open by non-admin refused`: as 12, 01, 03, 16 → `42501`.
  - `replay`: same key returns the same `ticket_id`; ticket and outbox counts unchanged.
  - `RLS isolation`: as 09 `select count(*)` of T1 tickets and messages = 0; as 01, 03, 16 = 0; as anon `42501`/0; as 15 sees both tenants; as 13 (ACTIVE CSM T1) sees T1.
  - `cross-tenant RPC`: as 09 reply on a T1 ticket → `P0002`; as 14 → `P0002`.
  - `CSM tenant context`: 12 with a JWT naming T2 (give 12 a T2 CSM membership) replying on a T1 ticket → `P0002`.
  - `reply rules`: 13 (not assigned) reply → `42501`; 12 reply → side TEAFAIR, status IN_PROGRESS, notification `TENANT_TICKET_UPDATE` for 08; 15 reply → side TEAFAIR.
  - `reopen`: 12 sets RESOLVED; 08 replies → OPEN, `resolved_at` null.
  - `closed refuses`: CLOSED then reply → `P0001`.
  - `claim/release/assign`: 13 claim on assigned → `P0001`; 12 release → null; 13 claim → u(13); concurrent second claim by 12 → `P0001`; 15 assign to u(14) (T2 CSM) → `P0001`; 15 assign null → null; 08 assign → `42501`.
  - `inactive assignee`: suspend 12 on a ticket assigned to 12 → 12 reply `42501`; 13 claim succeeds; a TENANT reply notifies 13 (or operators when none).
  - `status`: TENANT_ADMIN status → `42501`; OPEN→RESOLVED → `P0001`.
  - `auto-close`: set `resolved_at = now() - interval '8 days'`, `select close_resolved_tenant_tickets()` = 1, status CLOSED.
  - `outbox`: after open/TEAFAIR reply/RESOLVED/auto-close there are exactly 4 rows with templates `TENANT_TICKET_OPENED`, `_REPLY`, `_STATUS`, `_STATUS`, `to_email` = 08's email; `not exists (… where payload ? 'body' or payload::text like '%<the message text>%')`; a TENANT reply enqueues nothing; profile with null email enqueues nothing; `authenticated` select on `email_outbox` → `42501`.
  - `grants`: `function_privs_are` / `has_function_privilege` false for `authenticated` on `enqueue_email`, `close_resolved_tenant_tickets`.

- [ ] **Step 2: Run and see it fail**

Run: `npx supabase test db` (from `C:\Users\User\Teafair`)
Expected: `070_tenant_support_tickets` FAILs (relation does not exist).

- [ ] **Step 3: Write migration `20261031121500_tenant_support_tickets.sql`** with the Interfaces above, in that order: outbox + `enqueue_email`, tables + indexes (`(tenant_id, status, last_message_at desc)`, `(assigned_csm_id)`), RLS (`can_read_tenant_ticket(tenant_id)`), helpers, RPCs, auto-close + `cron.schedule`, grants (revoke from public/anon first, grant RPCs to `authenticated`).

- [ ] **Step 4: Apply and test**

Run: `npx supabase migration up` then `npx supabase test db`
Expected: migration applies; `Result: PASS` for the whole suite.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261031121500_tenant_support_tickets.sql supabase/tests/database/070_tenant_support_tickets.test.sql
git commit -m "feat(db): tenant support tickets and the email outbox (A7 §4, §5.1)"
```

### Task 2: Buyer email enqueue, sender RPCs, purge, cron (migration 121600)

**Files:**
- Create: `supabase/migrations/20261031121600_ticket_email_outbox.sql`
- Test: `supabase/tests/database/071_ticket_email_outbox.test.sql`

**Interfaces:**
- Consumes: `enqueue_email`, `email_outbox` (Task 1).
- Redefines (copy the **latest** body, add only the enqueue after `idempotency_begin` returned null and the write succeeded):
  - `open_support_ticket` from `20261023120400_a5_fulfilment.sql` → `BUYER_TICKET_OPENED` when the contact email is non-null.
  - `reply_ticket` from `20261023120300_a5_upload_slots.sql` → `BUYER_TICKET_REPLY` (non-SYSTEM, contact not redacted, email non-null).
  - `update_ticket_status` from `20261021120200_support_staff_rpcs.sql` → `BUYER_TICKET_STATUS` on RESOLVED/CLOSED.
  - `close_resolved_support_tickets` (same file) → `BUYER_TICKET_STATUS` per closed ticket with a contact email.
  - `redact_ticket_customer_data` from `20261023120300_a5_upload_slots.sql` → also `delete` PENDING/SENDING rows with `source_table = 'support_tickets' and source_id = ticket`, and `to_email = null` on its SENT/FAILED rows.
  - Buyer payload: `{ public_reference }` plus `status` for STATUS. `source_table = 'support_tickets'`.
- Produces (`service_role` only, `revoke` from public/anon/authenticated):
  - `claim_email_outbox(p_limit integer) returns setof email_outbox`: rows `status = 'PENDING' and next_attempt_at <= now()` or `status = 'SENDING' and next_attempt_at <= now() - interval '10 minutes'`; `order by next_attempt_at for update skip locked limit p_limit`; sets `status = 'SENDING', attempts = attempts + 1, next_attempt_at = now()`.
  - `complete_email_outbox(p_id uuid, p_result text) returns void`, `p_result in ('SENT','RETRY','PERMANENT')`: SENT → `status SENT, sent_at now()`; RETRY → PENDING with `next_attempt_at = now() + interval` of 1, 5, 15, 60 minutes for attempts 1–4, and FAILED when attempts ≥ 5; PERMANENT → FAILED. Only acts on a SENDING row (else no-op).
  - `purge_email_outbox() returns integer`: deletes SENT/FAILED rows with `created_at < now() - interval '30 days'`; cron `purge-email-outbox` at `45 0 * * *`.
- Cron `email-outbox-send` every minute: `select public.invoke_system_function('email-outbox-send', '{}'::jsonb)`.

- [ ] **Step 1: Write the failing pgTAP file** `071_ticket_email_outbox.test.sql` (fixtures modelled on `020_support_buyer.test.sql` / `021_support_staff.test.sql`; open tickets as `service_role` the way those tests do). Tests:
  - `opened with email` → one `BUYER_TICKET_OPENED` row, payload exactly `{"public_reference": …}`; `opened without email` → none.
  - `staff reply` → `BUYER_TICKET_REPLY`; `buyer message` (A3 buyer post RPC) → none.
  - `status RESOLVED`, `CLOSED`, and `close_resolved_support_tickets()` → `BUYER_TICKET_STATUS` with matching `status`; `set priority/claim/assign` → none.
  - `SYSTEM ticket` events → none.
  - `replay` of reply with the same key → still one row.
  - `no secret or body`: `payload::text` contains neither the message text nor anything matching `secret`.
  - `redaction`: PENDING row deleted; a SENT row keeps id but `to_email is null`; later reply → none (contact redacted).
  - `redacted between enqueue and send`: enqueue, redact, `claim_email_outbox(10)` returns 0 rows.
  - `claim`: two PENDING rows, `claim_email_outbox(1)` twice → two different ids; status SENDING, attempts 1; a future `next_attempt_at` row is not claimed.
  - `stale SENDING` reclaimed after `next_attempt_at` set 11 minutes back; not at 9 minutes.
  - `complete`: SENT sets `sent_at`; RETRY at attempt 1 → PENDING ≈ now()+1 min; at attempt 5 → FAILED; PERMANENT → FAILED; complete on a PENDING row → no-op.
  - `purge`: 31-day SENT and FAILED rows deleted, 29-day kept, PENDING never deleted.
  - `grants`: `authenticated` cannot execute `claim_email_outbox`, `complete_email_outbox`, `purge_email_outbox`; `service_role` can execute the first two.
  - `cron`: `select count(*) from cron.job where jobname in ('email-outbox-send','purge-email-outbox','close-resolved-tenant-tickets')` = 3.

- [ ] **Step 2: Run and see it fail** — `npx supabase test db`; expected `071` FAILs.
- [ ] **Step 3: Write migration `20261031121600_ticket_email_outbox.sql`** per Interfaces.
- [ ] **Step 4: Apply and test** — `npx supabase migration up`, `npx supabase test db`; expected `Result: PASS` (all of 001–071, existing A3/A5 support tests unchanged).
- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261031121600_ticket_email_outbox.sql supabase/tests/database/071_ticket_email_outbox.test.sql
git commit -m "feat(db): buyer ticket emails through the outbox; sender RPCs and purge (A7 §5)"
```

### Task 3: `email-outbox-send` Edge Function

**Files:**
- Move: `supabase/functions/send-auth-email/resend.ts` → `supabase/functions/_shared/messaging/resend.ts` (update the import in `send-auth-email/index.ts`, and in any test that imports it)
- Create: `supabase/functions/email-outbox-send/templates.ts`, `handler.ts`, `index.ts`
- Test: `supabase/functions/email-outbox-send/templates.test.ts`, `handler.test.ts`
- Modify: `supabase/functions/_tests/service-role-guard.test.ts` (`SERVICE_RPC` entry), `supabase/functions/.env.example` (`WEB_SUPPORT_TICKET_URL=http://localhost:3000/support/ticket`, `SUPPORT_EMAIL_FROM=`), `supabase/config.toml` only if functions are listed there (follow how `reconcile-funds` is configured, `verify_jwt = false`).

**Interfaces:**
- Consumes: `claim_email_outbox(p_limit)`, `complete_email_outbox(p_id, p_result)` (Task 2); `cronAuthorized` (`_shared/core/cron.ts`); `serviceRpc` (`_shared/core/db.ts`); `resendSender`, `EmailDeliveryError` (moved file).
- Produces: `renderEmail(row: { template: string; payload: Record<string, unknown> }, cfg: { ticketUrl?: string }): { subject: string; html: string; text: string }` in `templates.ts`; throws `MissingConfigError` for a buyer template when `ticketUrl` is unset.
- Produces: `createEmailOutboxSendHandler(deps: { cronSecret: string; rpc: Rpc; sendEmail: EmailSender; ticketUrl?: string; batchSize?: number })` in `handler.ts`; POST only; 401 without the cron secret; response `200 { claimed, sent, retried, failed }`. Default batch 50.
- Result mapping: success → `SENT`; `EmailDeliveryError` with status 400/403/422 → `PERMANENT`; 429, other statuses, network/timeout → `RETRY`; `MissingConfigError` → `RETRY` and `console.error` once per batch. One row's failure never stops the batch. Never log `to_email`.
- `sendEmail` is called with `idempotencyKey: row.id`.

Copy (spec §5.4, exact):
- `BUYER_TICKET_OPENED` subject `We've received your support request TK-XXXXXX`; `BUYER_TICKET_REPLY` `New update on your support ticket TK-XXXXXX`; `BUYER_TICKET_STATUS` `Your support ticket TK-XXXXXX is resolved` / `… is closed`. Body: the reference, a link to `${ticketUrl}?ref=${encodeURIComponent(ref)}`, and `To read the messages, enter the ticket code you were given when you opened the ticket.`
- Tenant templates: subjects `Support ticket TS-XXXXXX received` / `New reply on support ticket TS-XXXXXX` / `Support ticket TS-XXXXXX is resolved|closed` (Claude's wording); body: reference, subject, category, `Sign in to the Teafair app to read and reply.` No link.

- [ ] **Step 1: Write failing Deno tests**
  - `templates.test.ts`: `buyer reply link` — `html` and `text` contain `http://x/support/ticket?ref=TK-ABC123`; `no secret, no body` — rendering a payload that also carries `body` and `secret` keys outputs neither value; `escapes tenant subject` — subject `<script>&"` appears as `&lt;script&gt;&amp;&quot;` in `html`; `missing url` — buyer template without `ticketUrl` throws `MissingConfigError`; tenant template without it renders; each of the 6 template/status combinations produces the exact subject above.
  - `handler.test.ts` (fake `rpc` and `sendEmail`): `401 without x-cron-secret` and no rpc call; `sends with idempotency key = row id`; `422 → PERMANENT`, `429 → RETRY`, `500 → RETRY`, thrown TypeError → `RETRY`; `one failure doesn't stop the batch` (3 rows, middle fails, 2 SENT); `counts` in the response body; `no recipient in logs` (spy `console.error`, assert no call contains the address).
  - `service-role-guard.test.ts` passes with the new entry (it fails before the entry is added, because the new function calls `serviceRpc`).
- [ ] **Step 2: Run and see them fail** — `deno test --allow-read --allow-env supabase/functions/` → the new files fail (module not found) and the guard test flags `email-outbox-send`.
- [ ] **Step 3: Implement** the move, `templates.ts`, `handler.ts`, `index.ts` (`requireEnv("CRON_SECRET")`, `requireEnv("RESEND_API_KEY")`, `requireEnv("SUPPORT_EMAIL_FROM")`, optional `RESEND_API_URL`, optional `WEB_SUPPORT_TICKET_URL`, wrapped in `observe("email-outbox-send", …)` as `reconcile-funds/index.ts` does), the guard entry and `.env.example`.
- [ ] **Step 4: Run and pass** — `deno test --allow-read --allow-env supabase/functions/`; expected `ok` with 0 failed; `deno check supabase/functions/email-outbox-send/index.ts supabase/functions/send-auth-email/index.ts` clean.
- [ ] **Step 5: Commit**

```bash
git add supabase/functions
git commit -m "feat(functions): email-outbox-send drains the ticket email outbox via Resend (A7 §5.2)"
```

### Task 4: Documentation, reports and full verification

**Files:**
- Modify: `supabase/CLAUDE.md`, `CLAUDE.md` (root), `docs/superpowers/specs/2026-10-21-addendum-a3-chat-and-ticketing-design.md` (§12 line on buyer email: "lifted for email by A7"), regenerated files under `docs/reports/`.

- [ ] **Step 1: Full verification** from `C:\Users\User\Teafair`: `npx supabase db reset` (replays all 113 migrations), `npx supabase test db` → `Result: PASS`, record the file and assertion totals it prints; `deno test --allow-read --allow-env supabase/functions/` → 0 failed, record the count.
- [ ] **Step 2: Update counts and rows** using the recorded numbers: migrations 111 → 113 (the directive said 112; two migrations make 113), pgTAP files 67 → 69 and the new assertion total, Edge Functions 32 → 33; add the A7 row to the root `CLAUDE.md` table ("built locally, not pushed"), the new env vars and the outbox/cron to `supabase/CLAUDE.md`.
- [ ] **Step 3: Regenerate PDFs** — `cd docs/reports/generator && node generate-reports.mjs`; expected it exits 0. If its content sources (`docs/reports/generator/content/`) hold counts or a feature list, update them first so the PDFs carry A7.
- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md supabase/CLAUDE.md docs
git commit -m "docs: record addendum A7 (tenant support tickets, ticket emails); regenerate reports"
```
