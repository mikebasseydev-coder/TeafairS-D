# Web Chat & Ticketing (Addendum A3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buyer opens a support ticket from the website, either about their order or as a pre-purchase question, and chats with the staff accountable for it. Staff work a tenant- and territory-scoped queue with Realtime. D1's payment exceptions raise SYSTEM tickets.

**Architecture:** Four tenant-owned tables:
- `support_tickets`: no personal data, readable by every member of the tenant.
- `support_ticket_contacts` and `support_messages`: restricted to the ticket's handlers.
- `support_ticket_secrets`: no API access at all.

Every write goes through a `SECURITY DEFINER` RPC. Three public Deno gateways serve the buyer: open, read (polled) and post. They are authenticated by a ticket secret whose sha256 is stored. D1's exceptions become tickets through triggers on `commission_records` and `audit_logs`, so D1's function bodies are not rewritten.

**Tech Stack:** Postgres 15 (Supabase local), pgTAP, `pg_cron`, Supabase Realtime publication, Deno Edge Functions, Zod (`_shared/core/deps.ts`), Cloudflare Turnstile.

**Spec:** `docs/superpowers/specs/2026-10-21-addendum-a3-chat-and-ticketing-design.md` (Addendum A3, approved 2026-10-21). Read §2 before any task. Spec A §9 and `supabase/CLAUDE.md` ("Writing a migration / an RPC / an Edge Function") apply to every task.

## Global Constraints

- Backend only. No `teafair-web` or app code. Leave the untracked `FIGMA.md` alone. Work on branch `docs/addendum-a3-chat-ticketing`.
- Never push to GitHub, never `supabase db push`, `functions deploy` or `config push`. Nothing touches the remote `vwmjyfjdwrohfizljxrq`.
- `authenticated` has `SELECT` only. RLS policies are `FOR SELECT` only, built from `(select auth.uid())` and set-returning `public.*` helpers (`x in (select public.f())`), never a per-row correlated subquery.
- Every `SECURITY DEFINER` function: `set search_path = public, pg_temp`. Every new function: `revoke execute … from public, anon, authenticated`, then grant only what the spec says. Internal helpers are also revoked from `service_role`.
- Staff RPCs take `p_idempotency_key uuid` first and use `assert_tenant_role` → `idempotency_begin` → writes → `write_audit` (source `USER`) → `idempotency_complete`. No `p_tenant_id` anywhere.
- Workflow values are `text` + `CHECK`, never enums. FKs are `ON DELETE RESTRICT`. Tenant rows reference each other through composite `(tenant_id, x)` FKs. People are `profiles(id)`.
- No contact details or message bodies in any audit row or notification payload.
- Errors: `P0001` → 422, `42501` → 403. Copy, exactly:
  - `This conversation is closed. Open a new ticket if you still need help.`
  - `Too many messages. Please wait a few minutes.`
- Body limit: 1–2000 characters after `btrim`, enforced in Zod and in the CHECK.
- Files: migrations `supabase/migrations/20261021<hhmmss>_support_<topic>.sql`; pgTAP `supabase/tests/database/0NN_support_<topic>.test.sql` (019 onward); shared Deno code `supabase/functions/_shared/support/`.
- Run `supabase test db` only after `supabase db reset`. Integration runs leave rows that break table-wide counts.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Decisions this plan makes where the spec is silent

1. **System tickets are raised by triggers, not by editing D1's functions.**
   - A row trigger on `commission_records` fires on transitions into `DISPUTED`: insert, or update of status.
   - A row trigger on `audit_logs` fires on inserts with operation `PAID_AFTER_CANCEL` or `LATE_SUCCESS`.
   - Both call `raise_system_ticket` in the same transaction as the D1 write. That is what spec §9 requires, and none of D1's four large functions is copied.
2. **The reference generator** becomes `public.new_crockford_reference(p_prefix text) returns text`: one random candidate. The uniqueness loop stays with each caller. `place_web_order` keeps its own inline copy, because rewriting that function only for this would copy its whole body.
3. **The buyer's secret travels in plain text only to the gateway and the read/post RPCs.** The RPCs hash it with `extensions.digest(p_secret, 'sha256')` and compare hex digests. Comparing digests of a 256-bit secret leaks nothing useful through timing; this satisfies spec §4.2's constant-time intent. `open_support_ticket` receives only the hash (spec §4.1).
4. **pgTAP is split into four files** (spec §11 allows "019 onward"):
   - `019_support_tickets` (schema, RLS)
   - `020_support_buyer`
   - `021_support_staff` (fallback handler, redaction, reopening)
   - `022_support_system` (system tickets, auto-close, grants)
5. **An ORDER ticket on an order with no `territory_id`** (an order from before D1) gets `territory_id` null and goes to the ZSM queue, with `accountable_id` set to the order's `teafair_agent_id`.

## Review Focus

1. **A handler who is no longer ACTIVE.** A TM or default agent disabled after being stamped `accountable_id` must lose read access. `my_support_ticket_ids()` checks ACTIVE membership (Task 1 test).
2. **Replay of `open_support_ticket` with a different secret hash.** It returns the first reply, not TF002, and the stored hash is the first one (Task 2 test).
3. **The buyer after redaction.** The buyer can still read, sees `[redacted]` in place of their own messages, and can post again. New messages are not redacted (Task 3 test).
4. **Re-routing.** `assign_ticket` moves contacts and messages to the new territory, so the old TM loses them and the new TM gains them (Task 3 test).
5. **A SYSTEM ticket for a commission disputed twice.** It stays one ticket with two SYSTEM messages (Task 4 test).

---

## File structure

```
supabase/migrations/
  20261021120000_support_schema.sql         tables, RLS, grants, helpers, Realtime publication (T1)
  20261021120100_support_buyer_rpcs.sql     web_find_order_by_pair, web_order_status rewrite, open/read/add (T2)
  20261021120200_support_staff_rpcs.sql     claim/reply/status/priority/assign/redact, auto-close cron (T3)
  20261021120300_support_system_tickets.sql raise_system_ticket + two triggers (T4)
supabase/tests/database/
  019_support_tickets.test.sql   (T1)  020_support_buyer.test.sql (T2)
  021_support_staff.test.sql     (T3)  022_support_system.test.sql (T4)
  001_schema_shape.test.sql      table count/list (T1)
supabase/functions/
  _shared/support/secret.ts (+ test)                                 (T5)
  support-ticket-open/{index,handler,handler.test}.ts                (T5)
  support-ticket-read/{index,handler,handler.test}.ts                (T5)
  support-ticket-message/{index,handler,handler.test}.ts             (T5)
  _tests/gateway.integration.ts                                      (T6)
supabase/config.toml, supabase/CLAUDE.md, CLAUDE.md                  (T5, T6)
```

Commands (from `supabase/`):

```bash
supabase migration up
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qAt -f tests/database/<file>
supabase db reset && supabase test db          # expect "Result: PASS"
deno test --allow-env functions/               # from repo root: supabase/functions/
```

pgTAP files follow the style of `018_d1_security.test.sql`/`015_…`. Acting as a user: `set local role authenticated` plus `request.jwt.claims` with `sub` and `app_metadata.active_tenant_id` (see `011_commerce_web_management.test.sql`). Fixtures inserting ONLINE orders must satisfy D1's `orders_online_routed` and `payments_split_*` constraints.

---

### Task 1: Support schema, RLS and Realtime

**Files:**
- Create: `supabase/migrations/20261021120000_support_schema.sql`
- Create: `supabase/tests/database/019_support_tickets.test.sql`
- Modify: `supabase/tests/database/001_schema_shape.test.sql` (table count and list)

**Interfaces:**
- Produces the four tables exactly as spec §3.1–§3.3.
  - Extra columns in `support_messages`: `redacted_at timestamptz?`.
  - Extra columns in `support_ticket_contacts`: `redacted_at timestamptz?`.
  - `last_message_at timestamptz not null default now()`.
  - Each table has `tenant_id uuid not null references tenants on delete restrict`.
  - `support_tickets` has `unique (tenant_id, id)`. The others reference it through `(tenant_id, ticket_id)`.
- `support_ticket_secrets(ticket_id uuid primary key, tenant_id uuid not null, secret_hash text not null check (secret_hash ~ '^[0-9a-f]{64}$'), created_at)`. RLS on, no policy, no grant.
- `public.new_crockford_reference(p_prefix text) returns text`. `p_prefix || '-' || 6` uniform Crockford characters, copied from `place_web_order`'s loop body. Internal.
- `public.my_support_ticket_ids() returns setof uuid`. SECURITY DEFINER, STABLE. It returns ids of tickets whose `accountable_id` or `assigned_to` is `auth.uid()` **and** whose tenant has the caller as an ACTIVE `tenant_users` member. Granted to `authenticated`.
- Policies:
  - `support_tickets`: `tenant_id in (select public.my_tenant_ids())`.
  - contacts and messages: `tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])) or territory_id in (select public.my_tm_territory_ids()) or ticket_id in (select public.my_support_ticket_ids())`.
- Grants: `grant select` on the three readable tables to `authenticated`. Nothing to `anon`.
- `alter publication supabase_realtime add table public.support_tickets, public.support_messages;`
- Indexes:
  - every FK;
  - `support_tickets (tenant_id, status, last_message_at desc)`, `(accountable_id)`, `(assigned_to)`, `(tenant_id, order_id, status)`;
  - `support_ticket_contacts (customer_phone, created_at)`;
  - `support_messages (ticket_id, created_at, id)` and `(ticket_id, sender_type, created_at)`.
- `set_updated_at` triggers on tickets and contacts.

- [ ] **Step 1: Write the failing tests** in `019`.

  Fixtures:
  - Tenants T1 and T2.
  - In T1:
    - zone Lagos with a ZSM;
    - territories Ikeja (TM_A) and Epe (TM_B);
    - a DSA in Ikeja;
    - a DSM `DEF` used as a non-TM default agent;
    - a disabled member `GONE`.
  - In T2: a ZSM.

  Tickets are inserted directly as postgres:
  - `K1`: Ikeja, accountable TM_A, with a contact row and 2 messages.
  - `K2`: Epe.
  - `K3`: territory null, accountable `DEF`.
  - `K4`: territory null, accountable `GONE`.

  ```sql
  select throws_ok(<insert ticket kind 'ORDER' with order_id null>, '23514', null, 'ORDER needs an order');
  select throws_ok(<insert SYSTEM ticket with system_key null>, '23514', null, 'SYSTEM needs a system_key');
  select throws_ok(<insert ticket status RESOLVED, resolved_at null>, '23514', null, 'RESOLVED needs resolved_at');
  select throws_ok(<insert ticket public_reference 'TK-12'>, '23514', null, 'reference format');
  select throws_ok(<insert message body '   '>, '23514', null, 'empty body refused');
  select throws_ok(<insert message body repeat('x', 2001)>, '23514', null, 'over 2000 refused');
  select throws_ok(<insert STAFF message with sender_id null>, '23514', null, 'STAFF needs sender');
  select throws_ok(<contact row whose tenant differs from the ticket>, '23503', null, 'composite FK keeps tenants apart');
  select ok(public.new_crockford_reference('TK') ~ '^TK-[0-9A-HJKMNP-TV-Z]{6}$', 'reference generator');
  select ok(not has_table_privilege('authenticated', 'public.support_ticket_secrets', 'select'), 'secrets unreadable');
  select ok(not has_table_privilege('anon', 'public.support_messages', 'select'), 'anon reads no messages');
  select ok(not has_table_privilege('authenticated', 'public.support_tickets', 'insert'), 'no client writes');
  -- RLS
  select is(<count support_tickets as T1 DSA>, 4, 'every tenant member sees headers');
  select is(<count support_messages as T1 DSA>, 0, 'DSA reads no messages');
  select is(<count support_ticket_contacts as T1 DSA>, 0, 'DSA reads no contacts');
  select is(<count messages of K1 as TM_A>, 2, 'territory TM reads messages');
  select is(<count messages of K2 as TM_A>, 0, 'not another territory');
  select is(<count contacts as T1 ZSM>, <all T1 contacts>, 'ZSM reads all');
  select is(<count messages of K3 as DEF>, <K3 count>, 'non-TM default agent reads the ticket routed to them');
  select is(<count messages of K1 as DEF>, 0, 'and nothing else');
  select is(<count messages of K4 as GONE (status DISABLED)>, 0, 'disabled handler loses access');
  select is(<count support_tickets as T2 ZSM>, 0, 'other tenant sees nothing');
  select ok(exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'support_messages'), 'messages in Realtime');
  select ok(exists(<same for support_tickets>), 'tickets in Realtime');
  ```
- [ ] **Step 2: Run it.** Use the psql command on `019`. Expected: FAIL, because relation `support_tickets` does not exist.
- [ ] **Step 3: Write the migration.** Then update `001_schema_shape` for the 4 new tables.
- [ ] **Step 4: Run** `supabase migration up`, then `019`, then `supabase db reset && supabase test db`. Expected: all PASS.
- [ ] **Step 5: Commit.** `feat(db): support tickets schema, handler RLS, Realtime (A3 §3)`

---

### Task 2: Buyer RPCs: open, read, post

**Files:**
- Create: `supabase/migrations/20261021120100_support_buyer_rpcs.sql`
- Create: `supabase/tests/database/020_support_buyer.test.sql`

**Interfaces:**
- Consumes:
  - from Task 1: tables, `new_crockford_reference`;
  - from D1: `web_codeless_tenant()`, `web_route_try(uuid, agent_codes, uuid) returns web_route`, `notify_tenant_zsms(…)`, and `web_order_status` (in `20261020120300_commerce_web_storefront_codeless.sql`).
- Produces. All are `service_role` only unless noted internal.
  - internal `public.web_find_order_by_pair(p_public_reference text, p_paystack_reference text) returns public.orders`:
    - the order whose `public_reference` equals `upper(btrim(p_public_reference))`;
    - and which has a payment with `lower(paystack_reference) = lower(btrim(p_paystack_reference))`;
    - any status; null when there is no match.
  - `web_order_status(text, text)` re-created with `create or replace` to call it. Its reply is byte-identical, and `014`/`018` stay green.
  - internal `public.support_notify_activity(p_ticket public.support_tickets) returns void`:
    - kind `SUPPORT_TICKET_ACTIVITY`, title `New support message`, body `Ticket <public_reference> needs a reply.`;
    - payload `{ticket_id, public_reference}`;
    - to `assigned_to`, else `accountable_id`, else every ZSM via `notify_tenant_zsms`.
  - `public.open_support_ticket(p_idempotency_key uuid, p_kind text, p_category text, p_message text, p_customer jsonb, p_order_public_reference text, p_order_paystack_reference text, p_lga_id uuid, p_secret_hash text) returns jsonb` → `{ticket_id, public_reference, status}`.
    - The idempotency request is everything except `p_secret_hash`.
    - `p_kind` is `ORDER | PRE_PURCHASE`. Exactly one of the order pair or `p_lga_id`, else P0001.
    - Customer validation is the same as `place_web_order`: name required, E.164 phone, optional lower-cased email.
    - Routing is spec §5 and plan Decision 5.
    - A pair mismatch raises `P0001` with message `NOT_FOUND`. The gateway maps it to 404.
    - Throttles: more than 3 contact rows for the phone in the last hour, or 3 tickets on the order with status `OPEN`/`IN_PROGRESS`, raise P0001 `Too many messages. Please wait a few minutes.`
    - In one statement order it writes the ticket, the secrets row, the contact row, the first CUSTOMER message and the notification.
    - Audit `open_support_ticket`, source `WEB`. The after-image is the ticket row plus `{phone_last4, has_email}`; the message is never included.
  - `public.read_support_ticket(p_public_reference text, p_secret text) returns jsonb`:
    - a match returns `{public_reference, status, category, order_public_reference, messages: [{sender: 'you'|'teafair', body, created_at}]}`, ordered by `created_at`, then `id`;
    - a miss returns **null**;
    - STABLE.
  - `public.add_ticket_message(p_idempotency_key uuid, p_public_reference text, p_secret text, p_message text) returns jsonb` → `{message_id, status}`.
    - Order of checks per spec §4.3: pair (miss → P0001 `NOT_FOUND`), then CLOSED (P0001 with the closed copy), then throttle (more than 30 CUSTOMER messages in the last hour).
    - RESOLVED → OPEN, and `resolved_at` is cleared.
    - It bumps `last_message_at` and notifies.
    - The idempotency request excludes `p_secret`.

- [ ] **Step 1: Write the failing tests** in `020`.

  Fixtures:
  - TEAFAIR (`7eaf0000-0000-4000-8000-000000000001`), with territory Ikeja, TM, ZSM, a REGIONAL warehouse and coverage `LA/Ikeja`.
  - A routed ONLINE order `TF-AAAAAA`, with payment `TFW-0000…01`, territory Ikeja and accountable TM.
  - A legacy-style CANCELLED order with null territory.
  - A non-TM `web_default_agent_id`.

  Hashes are computed as `encode(extensions.digest('s3cret', 'sha256'), 'hex')`.

  ```sql
  select is(<open ORDER with the right pair> ->> 'status', 'OPEN', 'order ticket opened');
  select is(<ticket row: (kind, tenant_id, territory_id, accountable_id, order_id)>, <(ORDER, TEAFAIR, Ikeja, TM, order)>, 'routed from the order');
  select is(<contact territory_id = ticket territory_id>, true, 'contacts copy the territory');
  select throws_ok(<open with pair TF-AAAAAA + another payment ref>, 'P0001', 'NOT_FOUND', 'mismatched pair');
  select is(<open with paystack ref upper-cased> ->> 'status', 'OPEN', 'pair is case-insensitive on the Paystack reference');
  select is(<open on the cancelled null-territory order: territory_id>, null, 'no territory → ZSM queue (Decision 5)');
  select is(<open PRE_PURCHASE LA/Ikeja: (tenant, territory, accountable)>, <(TEAFAIR, Ikeja, TM)>, 'pre-purchase routed');
  select is(<open PRE_PURCHASE KN/Fagge: (territory, accountable)>, <(null, DEFAULT_AGENT)>, 'unroutable → default agent');
  select is(<same with web_default_agent_id null: accountable>, null, 'else ZSM queue');
  select throws_ok(<open with both pair and lga>, 'P0001', null, 'exactly one of order or location');
  select is(<replay key1 with a different p_secret_hash> ->> 'ticket_id', <first ticket_id>, 'replay ignores a new secret hash');
  select is(<secret_hash stored for key1>, <first hash>, 'first secret is kept');
  select throws_ok(<4th ticket for one phone within the hour>, 'P0001', 'Too many messages. Please wait a few minutes.', 'phone throttle');
  select throws_ok(<4th open ticket on one order>, 'P0001', 'Too many messages. Please wait a few minutes.', 'order throttle');
  select ok(<audit after of open has no 'message' key and no full phone>, 'audit carries no text or phone');
  select is(<count SUPPORT_TICKET_ACTIVITY for the order ticket's TM>, 1, 'accountable notified');
  select ok(<notification payload keys = {ticket_id, public_reference}>, 'notification has no text');
  -- read
  select is(jsonb_array_length(public.read_support_ticket(<ref>, 's3cret') -> 'messages'), 1, 'buyer reads');
  select is(public.read_support_ticket(<ref>, 'wrong'), null, 'wrong secret is null');
  select is(public.read_support_ticket('TK-ZZZZZZ', 's3cret'), null, 'unknown ticket is null');
  select ok(position(<TM profile id> in public.read_support_ticket(<ref>, 's3cret')::text) = 0, 'no staff ids exposed');
  -- post
  select is(<add_ticket_message right secret> ->> 'status', 'OPEN', 'buyer posts');
  select throws_ok(<add with wrong secret>, 'P0001', 'NOT_FOUND', 'wrong secret refused');
  select ok(<last_message_at increased>, 'queue bumped');
  select is(<add on a RESOLVED ticket: status, resolved_at>, <(OPEN, null)>, 'RESOLVED reopens');
  select throws_ok(<add on CLOSED>, 'P0001', 'This conversation is closed. Open a new ticket if you still need help.', 'closed refuses');
  select is(<read on CLOSED> ->> 'status', 'CLOSED', 'closed stays readable');
  select throws_ok(<31st customer message in an hour>, 'P0001', 'Too many messages. Please wait a few minutes.', 'message throttle');
  select is(public.web_order_status(<ref>, <pref>) ->> 'public_reference', <ref>, 'web_order_status still answers via the shared lookup');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL, because the function does not exist.
- [ ] **Step 3: Write the migration.** Grants: the three buyer RPCs to `service_role` only. The two internal helpers are revoked from all API roles.
- [ ] **Step 4: Run** `020`, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): support buyer RPCs — open, read, post; shared order-pair lookup (A3 §4–5)`

---

### Task 3: Staff RPCs, redaction and auto-close

**Files:**
- Create: `supabase/migrations/20261021120200_support_staff_rpcs.sql`
- Create: `supabase/tests/database/021_support_staff.test.sql`

**Interfaces:**
- Consumes: Task 1 tables and `my_support_ticket_ids`; Task 2 `support_notify_activity` is not used for staff writes.
- Produces. All are `authenticated` with the standard write contract, and each returns `{ticket_id, status, priority, assigned_to}`:
  - internal `public.support_lock_ticket(p_ticket_id uuid, p_me public.tenant_users, p_zsm_only boolean) returns public.support_tickets`.
    - It locks the ticket `FOR UPDATE`.
    - The ticket must be in `p_me.tenant_id`, else `P0001` `ticket not found`.
    - Allowed: a ZSM; a TM with `territory_id = p_me.territory_id`; or `p_me.profile_id` in (`accountable_id`, `assigned_to`) when `not p_zsm_only`. Anyone else raises `42501`.
  - `claim_ticket(p_idempotency_key, p_ticket_id)`. Behaviour per spec §6:
    - a TM claiming a ticket held by someone else is `42501`;
    - a ZSM takeover writes audit operation `claim_ticket` with `before.assigned_to`.
  - `reply_ticket(p_idempotency_key, p_ticket_id, p_body)`: a STAFF message.
    - Claims the ticket if it is unassigned.
    - `OPEN`/`RESOLVED` → `IN_PROGRESS`, and `resolved_at` is cleared.
    - A CLOSED ticket raises P0001 with the closed copy.
    - Bumps `last_message_at`.
  - `update_ticket_status(p_idempotency_key, p_ticket_id, p_status)`:
    - allowed: `IN_PROGRESS → RESOLVED` (sets `resolved_at = now()`), `RESOLVED → CLOSED`, any non-CLOSED → `CLOSED`;
    - anything else is P0001 `that status change is not allowed`.
  - `set_ticket_priority(p_idempotency_key, p_ticket_id, p_priority)`.
  - `assign_ticket(p_idempotency_key, p_ticket_id, p_territory_id)`. ZSM only. Applies to `kind = 'PRE_PURCHASE'` only, else P0001 `only pre-purchase tickets can be re-routed`.
    - `accountable_id` follows the chain: the territory's TM, else the zone's ZSM, else `web_default_agent_id`, each only if ACTIVE.
    - Clears `assigned_to`.
    - Updates `territory_id` on the ticket, contacts and messages.
  - `redact_ticket_customer_data(p_idempotency_key, p_ticket_id)`. ZSM only.
    - Nulls the contact name, phone and email, and sets `redacted_at`.
    - Sets every `CUSTOMER` message `body = '[redacted]'` and its `redacted_at`.
    - Audit `TICKET_DATA_REDACTED` with after `{ticket_id, had_email, messages_redacted}`.
  - `public.close_resolved_support_tickets() returns integer`:
    - RESOLVED with `resolved_at < now() - 7 days` → CLOSED, audit source `CRON`;
    - revoked from all roles;
    - scheduled with `cron.schedule('close-resolved-support-tickets', '30 0 * * *', $$select public.close_resolved_support_tickets()$$)`.
- No audit row carries `p_body`.

- [ ] **Step 1: Write the failing tests** in `021`. Use Task 1's fixture shape, plus a buyer-opened PRE_PURCHASE ticket `P1` routed to the non-TM default agent `DEF`, holding two CUSTOMER messages and one STAFF reply.

  ```sql
  select is(<claim K1 as TM_A> ->> 'status', 'IN_PROGRESS', 'TM claims own territory');
  select throws_ok(<claim K1 as TM_B>, '42501', null, 'other territory refused');
  select throws_ok(<claim K1 (held by TM_A) as another Ikeja TM>, '42501', null, 'TM cannot take a held ticket');
  select is(<claim K1 as ZSM> ->> 'assigned_to', <ZSM>, 'ZSM takeover');
  select ok(<audit claim_ticket before.assigned_to = TM_A>, 'takeover audited');
  select is(<reply P1 as DEF> ->> 'status', 'IN_PROGRESS', 'non-TM default agent replies to the ticket routed to them');
  select throws_ok(<reply K1 as DEF>, '42501', null, 'but not to others');
  select throws_ok(<reply as DSA>, '42501', null, 'DSA refused');
  select is(<reply on unassigned ticket: assigned_to>, <replier>, 'reply auto-claims');
  select is(<RESOLVED ticket, staff reply: (status, resolved_at)>, <(IN_PROGRESS, null)>, 'reply reopens');
  select is(<update_ticket_status IN_PROGRESS→RESOLVED: resolved_at is not null>, true, 'resolve stamps time');
  select throws_ok(<CLOSED → OPEN>, 'P0001', 'that status change is not allowed', 'CLOSED is final');
  select throws_ok(<reply on CLOSED>, 'P0001', 'This conversation is closed. Open a new ticket if you still need help.', 'no replies on closed');
  select is(<set_ticket_priority URGENT> ->> 'priority', 'URGENT', 'priority');
  select throws_ok(<assign_ticket as TM>, '42501', null, 'assign is ZSM only');
  select throws_ok(<assign_ticket on an ORDER ticket>, 'P0001', 'only pre-purchase tickets can be re-routed', 'order tickets follow the order');
  select is(<assign P1 to Ikeja: (territory, accountable, assigned_to)>, <(Ikeja, TM_A, null)>, 'assign re-routes');
  select is(<count P1 messages as TM_A>, <n>, 'Ikeja TM gains access');
  select lives_ok(<assign P1 to Epe>, 're-route again');
  select is(<territory_id on P1 contacts and messages>, <Epe>, 'copies moved');
  select is(<count P1 messages as TM_B>, <n>, 'new TM gains access');
  select is(<count P1 messages as TM_A>, 0, 'old territory loses access');
  -- redaction
  select throws_ok(<redact as TM>, '42501', null, 'redact is ZSM only');
  select lives_ok(<redact P1 as ZSM>, 'redact');
  select is(<P1 contact (name, phone, email)>, <(null, null, null)>, 'contacts blanked');
  select is(<P1 CUSTOMER bodies>, <all '[redacted]'>, 'buyer bodies redacted');
  select is(<P1 STAFF body>, <original reply>, 'staff reply untouched');
  select ok(<TICKET_DATA_REDACTED after = {ticket_id, had_email, messages_redacted}>, 'audit summary only');
  select is(<read_support_ticket(P1 ref, secret) messages from 'you'>, <all '[redacted]'>, 'buyer sees redacted history');
  select is(<add_ticket_message on P1 after redaction> ->> 'status', <status>, 'buyer can still post');
  select ok(<the new message body is not '[redacted]'>, 'new messages are not redacted');
  select ok(<no audit row from these RPCs contains a reply body>, 'no bodies in audit');
  -- auto-close
  select is(public.close_resolved_support_tickets(), 1, 'one RESOLVED ticket older than 7 days closes');
  select ok(exists(select 1 from cron.job where jobname = 'close-resolved-support-tickets'), 'auto-close scheduled');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.** Grant the six RPCs to `authenticated`. Revoke the two internals from every API role.
- [ ] **Step 4: Run** `021`, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): support staff RPCs, redaction, auto-close (A3 §6)`

---

### Task 4: System tickets from D1 exceptions

**Files:**
- Create: `supabase/migrations/20261021120300_support_system_tickets.sql`
- Create: `supabase/tests/database/022_support_system.test.sql`

**Interfaces:**
- Consumes: Task 1 tables and `new_crockford_reference`; D1's `settle_paystack_payment`, `apply_paystack_refund`, `release_commission` and `expire_unsettled_commissions` (unchanged).
- Produces:
  - internal `public.raise_system_ticket(p_system_key text, p_order_id uuid, p_body text, p_priority text) returns uuid`.
    - Reads the order for `tenant_id` and `territory_id`.
    - Inserts a `SYSTEM` ticket with `category 'SYSTEM'`, `accountable_id` null, the `system_key`, and a SYSTEM message `p_body`, with `on conflict (system_key) do nothing`.
    - On conflict it adds a SYSTEM message to the existing ticket instead.
    - Returns the ticket id.
  - trigger function `support_ticket_on_commission_disputed()`: `AFTER INSERT OR UPDATE OF status ON commission_records`, firing when `new.status = 'DISPUTED' and (tg_op = 'INSERT' or old.status <> 'DISPUTED')`.
    - Key `COMMISSION_DISPUTED:<commission id>`. Priority `HIGH`.
    - Body: `Commission <id> disputed (<dispute_reason>): <amount> on payment <payment_id>.`
  - trigger function `support_ticket_on_payment_exception()`: `AFTER INSERT ON audit_logs` `WHEN (new.operation in ('PAID_AFTER_CANCEL','LATE_SUCCESS'))`.
    - `entity_id` is the payment id. The order comes from `payments.order_id`.
    - Key `<operation>:<payment id>`. Priority `URGENT` for `PAID_AFTER_CANCEL`, `HIGH` for `LATE_SUCCESS`.
    - Body: `<operation> on payment <payment_id> for order <public_reference>.`
  - Both trigger functions are SECURITY DEFINER with the search_path pinned and revoked from every API role.
- Bodies use only ids, amounts, reasons and references, never `p_verified` or contact data.

- [ ] **Step 1: Write the failing tests** in `022`. Reuse the fixtures of `015_fintech_liquidity_web_settlement.test.sql`: a routed ONLINE order with a split-snapshot payment, a CANCELLED-order payment, and a FAILED payment.

  ```sql
  select lives_ok(<settle_paystack_payment success on the cancelled order's payment>, 'PAID_AFTER_CANCEL path');
  select is(<count SYSTEM tickets key 'PAID_AFTER_CANCEL:<pid>'>, 1, 'one urgent ticket');
  select is(<that ticket: (priority, territory_id, order_id, accountable_id)>, <(URGENT, order territory, order, null)>, 'routed to the ZSM queue with the order');
  select is(<settle success on a FAILED payment → count key 'LATE_SUCCESS:<pid>'>, 1, 'late success ticket');
  select is(<settle with a wrong split share → count key 'COMMISSION_DISPUTED:<cid>'>, 1, 'split mismatch ticket');
  select is(<replay the same settle → count SYSTEM tickets>, <unchanged>, 'replay raises none');
  select is(<refund the SETTLED-commission payment fully → count tickets for that commission>, 1, 'ORDER_REFUNDED dispute ticket');
  select is(<force a second DISPUTED transition on one commission (DISPUTED → SPLIT by postgres, then expire)> -> <count tickets, count SYSTEM messages>, <(1, 2)>, 'second dispute adds a message, not a ticket');
  select ok(<no SYSTEM message body contains '@' or '+234'>, 'no contact data in system bodies');
  select is(<count support_ticket_contacts for SYSTEM tickets>, 0, 'SYSTEM tickets have no contact row');
  select is(<count support_ticket_secrets for SYSTEM tickets>, 0, 'and no secret');
  -- grants across A3
  select ok(not has_function_privilege(r, f, 'execute'), …) -- one line per (anon, authenticated) ×
  --   open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text), read_support_ticket(text,text),
  --   add_ticket_message(uuid,text,text,text), raise_system_ticket(text,uuid,text,text),
  --   web_find_order_by_pair(text,text), support_notify_activity(public.support_tickets),
  --   close_resolved_support_tickets(), new_crockford_reference(text)
  select ok(not has_function_privilege('anon', 'public.claim_ticket(uuid,uuid)', 'execute'), 'staff RPCs not for anon');
  ```

  Write each privilege check as its own `select ok(...)`, guarded with `to_regprocedure(...) is not null`, as `018` does.
- [ ] **Step 2: Run it.** Expected: FAIL, because no SYSTEM tickets are raised.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `022`, then `supabase db reset && supabase test db`. Expected: PASS; `015`–`017` unchanged.
- [ ] **Step 5: Commit.** `feat(db): system support tickets from D1 payment exceptions (A3 §9)`

---

### Task 5: Buyer gateways

**Files:**
- Create: `supabase/functions/_shared/support/secret.ts`, `secret.test.ts`
- Create: `supabase/functions/support-ticket-open/{index,handler,handler.test}.ts`
- Create: `supabase/functions/support-ticket-read/{index,handler,handler.test}.ts`
- Create: `supabase/functions/support-ticket-message/{index,handler,handler.test}.ts`
- Modify: `supabase/config.toml` (three `verify_jwt = false` blocks)

**Interfaces:**
- Consumes:
  - `publicGateway`, `PublicGatewayDeps` and `allowedOriginsFromEnv` (`_shared/core/public-gateway.ts`);
  - `GatewayError` (`_shared/core/errors.ts`);
  - `idempotencyKey` (`_shared/core/validate.ts`);
  - `normalizePhone` (`_shared/commerce/phone.ts`);
  - `VerifyTurnstile` and `turnstileVerifier` (`_shared/commerce/turnstile.ts`);
  - the Task 2 RPCs.
- Produces:
  - `secret.ts`:
    - `newTicketSecret(): string`: 32 bytes from `crypto.getRandomValues`, base64url without padding (43 characters);
    - `sha256Hex(s: string): Promise<string>`.
  - `createSupportTicketOpenHandler(deps: PublicGatewayDeps & { verifyTurnstile: VerifyTurnstile; newSecret: () => string })`.
    - POST, schema `{ idempotency_key, turnstile_token, category: enum(PAYMENT, DELIVERY, ORDER_CHANGE, PRODUCT, OTHER), message: trim 1..2000, customer: {name 2..120, phone 7..24, email?}, order?: {public_reference regex TF-, paystack_reference regex TFW-uuid /i}, location?: {lga_id uuid} }`, refined to exactly one of `order` or `location`.
    - Turnstile and phone handling are copied from `web-checkout/handler.ts`, including the 503 and 403 codes.
    - Calls `open_support_ticket` with `p_kind` `ORDER` or `PRE_PURCHASE` and `p_secret_hash: await sha256Hex(secret)`.
    - Replies `{ public_reference, secret, status }`, with `cache-control: no-store`.
    - A `P0001` with message `NOT_FOUND` becomes `GatewayError(404, "NOT_FOUND", "We couldn't find that order.")`.
  - `createSupportTicketReadHandler(deps: PublicGatewayDeps)`.
    - POST `{ public_reference: /^TK-[0-9A-HJKMNP-TV-Z]{6}$/ (trim, upper), secret: string 43 }`.
    - A null reply becomes `GatewayError(404, "NOT_FOUND", "We couldn't find that conversation.")`. Otherwise the reply is passed through as is.
  - `createSupportTicketMessageHandler(deps: PublicGatewayDeps)`.
    - POST `{ idempotency_key, public_reference, secret, message }`.
    - A `NOT_FOUND` P0001 becomes 404, as in the read handler. Other P0001s keep the default 422 mapping, which carries the closed and throttle copy.
  - Each `index.ts` is wired like `storefront-catalogue/index.ts`. The open handler also gets `turnstileVerifier` (env `TURNSTILE_SECRET_KEY` and the optional `TURNSTILE_VERIFY_URL`) and `newSecret: newTicketSecret`.

- [ ] **Step 1: Write the failing tests:**
  - `secret.test.ts`:
    - `"newTicketSecret is 43 url-safe characters and differs each call"`;
    - `"sha256Hex matches a known vector"`: `sha256("abc")` = `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
  - `support-ticket-open/handler.test.ts`:
    - `"a failed bot check is 403 and calls nothing"`;
    - `"order ticket sends the pair and only the secret's hash"`: rpc args include `p_secret_hash === sha256Hex(fixed secret)`, and no arg contains the secret;
    - `"reply includes the secret once"`;
    - `"both order and location is 400"`;
    - `"NOT_FOUND from the RPC is 404"`;
    - `"message over 2000 characters is 400"`.
  - `support-ticket-read/handler.test.ts`:
    - `"null is 404 NOT_FOUND"`;
    - `"malformed reference is 400"`;
    - `"reply passes through and is no-store"`.
  - `support-ticket-message/handler.test.ts`:
    - `"NOT_FOUND is 404"`;
    - `"closed copy is 422"` (rpc rejects with P0001 and the closed message);
    - `"throttle copy is 422"`.
- [ ] **Step 2: Run** `deno test --allow-env supabase/functions/`. Expected: FAIL, because the modules are missing.
- [ ] **Step 3: Implement.** Add the config.toml blocks.
- [ ] **Step 4: Run** `deno test --allow-env supabase/functions/` and `deno check supabase/functions/*/index.ts`. Expected: PASS, with the 172 existing tests and the new ones all green.
- [ ] **Step 5: Commit.** `feat(functions): support ticket gateways — open, read, message (A3 §4)`

---

### Task 6: Integration flow and docs

**Files:**
- Modify: `supabase/functions/_tests/gateway.integration.ts`
- Modify: `supabase/CLAUDE.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above, over HTTP and PostgREST.

- [ ] **Step 1: Write the failing integration test** `"support: open → staff reply → buyer read → buyer message → resolve → close"`:
  1. POST `support-ticket-open` with a pre-purchase `location` for the TEAFAIR fixtures the D1 tests already upsert. Keep the secret.
  2. Sign in as the territory's TM. Call `reply_ticket` through PostgREST.
  3. POST `support-ticket-read` and assert the staff reply appears as `sender: "teafair"`.
  4. POST `support-ticket-message`.
  5. Call `update_ticket_status` to RESOLVED, then CLOSED, as the TM.
  6. POST `support-ticket-message` and assert a 422 with the closed copy.
  7. POST `support-ticket-read` with a wrong secret and assert 404.
  
  Use per-run idempotency keys and phones, because the local database persists between runs.
- [ ] **Step 2: Run** the integration command in `supabase/CLAUDE.md`, with `supabase functions serve --env-file supabase/functions/.env` running. Expected: the new test FAILS until the functions are served with the new code. Then all PASS. Stop the serve process afterwards.
- [ ] **Step 3: Docs.**
  - `supabase/CLAUDE.md`:
    - status row `A3. Web chat & ticketing — support tables, buyer gateways, staff RPCs, system tickets | done (local)`;
    - list the three public gateways and the staff RPCs;
    - note the handler RLS rule (ZSM, territory TM, accountable or assigned person);
    - note that A3 deploys after D1 (it depends on D1's routing and its triggers watch D1's tables).
  - Root `CLAUDE.md`: update the repository-state row counts from real commands, and add the A3 spec row.
- [ ] **Step 4: Full verification.** Run `supabase db reset && supabase test db` (expect `Result: PASS`), then `deno test --allow-env supabase/functions/` (0 failed), then the integration command (all ok).
- [ ] **Step 5: Commit.** `test(functions): support ticket integration flow; docs: A3 status`
