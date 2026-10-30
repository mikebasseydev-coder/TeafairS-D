# Monvelo Step 1c (tenant representation) and Step 2 (financing ledger and allocation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two things on `feat/monvelo-step1`:
- **Step 1c** (A6 §16.7): the CSM, `TENANT_ADMIN` and `LOGISTICS_MANAGER` roles, contact reports, CSM approvals that cite a decision, and decision-citing catalogue and stock-movement RPCs.
- **Step 2** (A6 plan row 2 plus the §16 additions): supply days, pledges, `place_trade_order`, the financing ledger, shop limits with history, request, TM approval, claim under the §7.1 allocation rule, the expiry sweep, the financing-status read, the staff proximity search, and the insert-only tenant ledger table.

**Architecture:**
- Two kinds of object live side by side in the existing Supabase backend:
  - **RTM-core objects** carry no prefix: contact reports, the catalogue and stock movements, `place_trade_order`.
  - **Monvelo objects** carry `monvelo_`.
- Spec A §9 holds everywhere:
  - every new table is SELECT-only under RLS;
  - every write is a SECURITY DEFINER RPC with `set search_path = public, pg_temp`, taking `p_idempotency_key uuid` first;
  - the tenant comes from `public.jwt_tenant_id()` and is re-checked live by `assert_tenant_role`.
- Step 1c and Step 2 add no Edge Function. Everything is pure database work, called through PostgREST with the caller's JWT, plus one pure-SQL `pg_cron` job.

**Tech Stack:**
- Postgres 17 hand-written migrations, pgTAP, PostGIS (`extensions.*`), `pg_cron`;
- the existing Deno suites are run, not changed, except one PostgREST integration test in Task 10.

**Spec:**
- `docs/superpowers/specs/2026-10-28-addendum-a6-monvelo-design.md`: §4.3, §4.4, §6.1, §6.2, §7.1, §7.2, §8, §15, and §16. The §16.2 rulings are binding, and the §16 "Claude's calls" were approved 2026-10-29.
- Read it with `docs/superpowers/plans/2026-10-28-monvelo-a6.md`, the parent plan; this plan details its Step 2.

## Prerequisite state

The rename plan `docs/superpowers/plans/2026-10-28-domain-separation-renames.md`, Tasks 5–7, is complete before Task 1 starts. Use the new names only:
- the tables `monvelo_agents` and `monvelo_agent_members`;
- the RPCs `request_monvelo_settlement_change` and `approve_monvelo_settlement_change`;
- `_shared/payments`, the `web_*` tables, and the role `POS_AGENT`.

Check before starting:
- `git log --oneline -5` shows the rename's docs commit;
- `ls supabase/tests/database` ends at `045_monvelo_agent_renames.test.sql`.

If either is not so, stop and report.

## Global Constraints

- **Spec A §9 rules.**
  - No direct client writes. New tables get `revoke all … from anon, authenticated`, then `grant select … to authenticated`. `anon` holds nothing; `003` asserts this.
  - Policies are `FOR SELECT` only. They use `(select auth.uid())` and the `public.my_*()` / `is_*()` helpers, never a per-row correlated subquery. An uncorrelated `(tenant_id, x) in (select … from <rls table>)` is allowed.
  - No `p_tenant_id` parameter. The one exception, as for `record_monvelo_fee_terms`, is a platform-role RPC acting on a named tenant: `appoint_client_service_manager` (Task 1).
- **Types.**
  - Money is `numeric(15,2)`, quantities `numeric(14,3)`, timestamps `timestamptz`, rates `integer` basis points (0–10000).
  - Workflow statuses are `text` + `CHECK`.
- **Tenant-scoped tables:**
  - `tenant_id uuid not null references public.tenants (id) on delete restrict` and `unique (tenant_id, id)`;
  - composite `(tenant_id, x)` FKs;
  - every FK column and every policy column indexed;
  - `on delete restrict` everywhere, never CASCADE.
- **Function grants.** New functions get no EXECUTE unless granted. Internal helpers get `revoke all … from public, anon, authenticated, service_role`.
- **Error codes:** `P0001` business 422, `42501` forbidden 403, `23505` 409, `TF001` insufficient stock 409 (with `detail` JSON text), `TF002` idempotency mismatch.
- **Audit.**
  - One `write_audit` row per effect.
  - Never a full phone number, an email address, an account number or a code.
  - Cron rows use `p_source => 'CRON'` and `p_teafair_agent_id =>` the financing's `raised_by`.
- **Domain boundary (A6 §15.3; the 045 guard).**
  - Every function whose body names `public.monvelo_` has `monvelo` in its name.
  - No function body names both a `public.web_` table and a `public.monvelo_` table.
  - No Monvelo function reads a `web_` table or a `web_*` column.
  - RTM-core functions (`place_trade_order`, the contact-report, catalogue and stock RPCs, `assert_citable_decision`) never name a `monvelo_` object.
- **Brand matching:** `lower(btrim(brand))`, as for brand terms.
- **Lagos dates:** `public.monvelo_today()` returns `(now() at time zone 'Africa/Lagos')::date` (Task 5). The end of a supply day is `((d + 1)::timestamp at time zone 'Africa/Lagos')`.
- **Records are never deleted** (§7.4). Insert-only tables refuse UPDATE, DELETE and TRUNCATE by trigger, and the API roles hold no write grant.
- **Sequencing:**
  - migrations are timestamped `20261029120000`… (Step 1c) and `20261029130000`… (Step 2);
  - pgTAP files are `046_`–`054_`;
  - applied migrations are never edited;
  - a recreated function starts from the live `pg_get_functiondef`, so no earlier change is lost.
- **Schema-shape tests:**
  - every task that adds a table adds it to `tables_are` in `001_schema_shape.test.sql`;
  - Task 1 updates the `tenant_role_enum` label lists in `001` and `042`.
- **Forbidden:**
  - pushing, deploying, or merging into `main`;
  - touching `FIGMA.md`, `monvelo.md` or any `.env`.

### The green gate (ends every task)

```bash
supabase db reset
psql -qAt -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "select vault.create_secret('local-gateway-secret', 'gateway_secret');"
supabase test db                                   # Result: PASS
deno test --allow-all supabase/functions/          # 0 failed
supabase functions serve --env-file supabase/functions/.env   # in the background
supabase status -o env > supabase/.env.test.local
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts   # 0 failed
```

- `GATEWAY_SECRET` in `supabase/functions/.env` must be `local-gateway-secret`.
- If the fake cannot bind (`os error 10013`), set `INTEGRATION_FAKE_PORT` as `supabase/CLAUDE.md` says.
- To run one pgTAP file: `psql -qAt -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/database/<file>`.

Each commit message ends with a blank line, then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A `TENANT_ADMIN` calling a write RPC.** The role is read-only, but it is an ACTIVE member, so every RPC that opens with `assert_tenant_role(null)` admits it at the door. Each such RPC must still refuse it with 42501.
   - Covered here: `invite_tenant_user`, `set_monvelo_tenant_settings`, `approve_monvelo_brand_terms`, `file_contact_report`, `upsert_catalogue_product`, `record_stock_receipt`, `place_trade_order`, `request_monvelo_financing`, `mark_order_dispatched` and `claim_ticket`.
   - Owned by Task 1 (the A5/A3 ones) and by each task for its own RPCs.
2. **Citing a superseded decision, or a decision of another tenant.** Either gets P0001 or 42501, never a silent approval.
   - A correction of a correction works: the chain is A → B → C, and only C's decisions are citable.
   - Owned by Tasks 2 and 3.
3. **Two agents claiming in the same second.** One wins; the other gets P0001 `'this request is no longer open'`. Neither leaves a second open claim row.
   - Also: a lapsed agent cannot reclaim, and a claim lapsing after midnight still ends EXPIRED, not OFFERED, by the next sweep.
   - Owned by Task 8.
4. **A request whose brands are only partly eligible.** For example, an order of Purerigin (terms approved) plus Tiger (no terms) is refused whole, with a message that names the brand that failed. It is never financed for the eligible part.
   - Owned by Task 7.
5. **Stock that would go negative.** A transfer or adjustment beyond the batch's quantity is TF001, with `detail` holding `sku_code`, `available` and `requested`. A transfer leaves both batches unchanged when it fails.
   - Owned by Task 4.

---

## File map

| File | Responsibility |
|---|---|
| `supabase/migrations/20261029120000_tenant_representation_enum.sql` | the three `tenant_role_enum` values only |
| `supabase/migrations/20261029120100_tenant_representation_roles.sql` | anchors, `is_platform_staff`, `appoint_client_service_manager`, `invite_tenant_user`, the fulfilment helpers, `my_monvelo_staff_tenant_ids` |
| `supabase/migrations/20261029120200_contact_reports.sql` | `contact_reports`, `contact_report_decisions`, `contact_report_recipients`, `contact_report_deliveries`, `file_contact_report`, `assert_citable_decision` |
| `supabase/migrations/20261029120300_monvelo_csm_approvals.sql` | `approval_decision_id`, `decision_id`, `max_limit`; `approve_monvelo_brand_terms`, `set_monvelo_tenant_settings` |
| `supabase/migrations/20261029120400_catalogue_stock_movements.sql` | `central_products.decision_id`, `upsert_catalogue_product`, `stock_movements`, the three stock RPCs |
| `supabase/migrations/20261029130000_monvelo_supply_pledges.sql` | `monvelo_platform_settings`, `monvelo_today`, `monvelo_supply_days`, `monvelo_pledges`, their RPCs, `monvelo_supply_days_near`, `monvelo_agents_near`, the agent location index |
| `supabase/migrations/20261029130100_trade_orders.sql` | `place_trade_order` |
| `supabase/migrations/20261029130200_monvelo_financings.sql` | financings, lines, limits, limit events, guards, request, approval, cancel |
| `supabase/migrations/20261029130300_monvelo_claims.sql` | claims, `claim_monvelo_financing`, `monvelo_open_offers`, `monvelo_sweep_offers`, the cron job |
| `supabase/migrations/20261029130400_monvelo_status_ledger.sql` | `monvelo_order_financing_status`, `monvelo_tenant_ledger_entries` |
| `supabase/tests/database/046_tenant_representation_roles.test.sql` … `054_monvelo_status_ledger.test.sql` | one pgTAP file per migration above (the enum migration is tested in 001/042/046) |
| `supabase/tests/database/001_schema_shape.test.sql`, `042_domain_separation_guard.test.sql` | enum labels, `tables_are` |
| `supabase/functions/_tests/gateway.integration.ts` | Task 10: one PostgREST flow |
| `supabase/CLAUDE.md`, `CLAUDE.md` | Task 10 |

---

## Step 1c: tenant representation

### Task 1: The three roles, CSM appointment, invites and fulfilment

**Files:**
- Create:
  - `supabase/migrations/20261029120000_tenant_representation_enum.sql`
  - `supabase/migrations/20261029120100_tenant_representation_roles.sql`
  - `supabase/tests/database/046_tenant_representation_roles.test.sql`
- Modify: `supabase/tests/database/001_schema_shape.test.sql` (`tenant_role_enum` labels), `042_domain_separation_guard.test.sql` (the same list)

**Interfaces:**
- Consumes: `assert_tenant_role`, `assert_platform_role`, `idempotency_begin`/`_complete`, `write_audit`, and `invite_tenant_user` (live body after the rename).
- Produces:
  - **Enum values.** `tenant_role_enum` gains `'CLIENT_SERVICE_MANAGER'`, `'TENANT_ADMIN'`, `'LOGISTICS_MANAGER'`, appended in that order (`add value if not exists`).
  - **Constraints on `tenant_users`:**
    - `tenant_users_tenant_wide_roles`: `check (role not in ('CLIENT_SERVICE_MANAGER','TENANT_ADMIN','LOGISTICS_MANAGER') or (zone_id is null and territory_id is null and area_id is null))`;
    - `tenant_users_lm_reports`: `check (role <> 'LOGISTICS_MANAGER' or reports_to_id is not null)`.
  - **Helper** `is_platform_staff() returns boolean`:
    - `stable security definer`; true when `profiles.platform_role is not null` for `auth.uid()`;
    - granted to `authenticated` (used by policies).
  - **RPC** `appoint_client_service_manager(p_idempotency_key uuid, p_tenant_id uuid, p_phone_number text) returns jsonb`:
    - caller: `assert_platform_role(array['PLATFORM_SUPER_ADMIN'])`;
    - phone lookup as in `invite_tenant_user` (a confirmed phone only);
    - inserts `tenant_users (role 'CLIENT_SERVICE_MANAGER', status 'INVITED')` and a `TENANT_INVITE` notification;
    - an existing membership in that tenant is 23505 `'this person is already a member of the tenant'`;
    - returns `{tenant_user_id, status}`;
    - granted to `authenticated`.
  - **RPC** `invite_tenant_user` keeps its 6-argument signature and grant, but the caller becomes `assert_tenant_role(array['ZSM','CLIENT_SERVICE_MANAGER'])`.
    - **ZSM:** unchanged rules. Inviting `CLIENT_SERVICE_MANAGER` is 42501 `'only a platform administrator appoints a client service manager'`. Inviting `TENANT_ADMIN` or `LOGISTICS_MANAGER` is 42501 `'the client service manager invites tenant admins and logistics managers'`.
    - **CSM:** only `LOGISTICS_MANAGER` and `TENANT_ADMIN`; any other role is 42501 `'a client service manager invites tenant admins and logistics managers only'`.
      - `p_territory_id` and `p_area_id` must be null: P0001 `'tenant-wide roles have no territory or area'`.
      - LM: `reports_to_id` is forced to the CSM's own membership id (a different non-null `p_reports_to_id` is P0001 `'a logistics manager reports to the inviting client service manager'`).
      - TENANT_ADMIN: `reports_to_id` null.
  - **`fulfilment_can_dispatch(p_me, p_order)`**, recreated with the same signature and revokes: also true for an ACTIVE `LOGISTICS_MANAGER` of the order's tenant, for every warehouse.
  - **`fulfilment_delivery_path(p_me, p_order)`**, recreated: returns `'COURIER'` for an ACTIVE `LOGISTICS_MANAGER` of the order's tenant (the delivery-code path). The ZSM and field branches are unchanged.
  - **`my_monvelo_staff_tenant_ids()`**, recreated: its role list gains `'CLIENT_SERVICE_MANAGER','TENANT_ADMIN'`, so both read the tenant's enrolments.

- [ ] **Step 1: Write the failing tests.**
  - In `001` and `042`: `enum_has_labels('public','tenant_role_enum', array['ZSM','TM','ASM','DSM','DSA','POS_AGENT','RETAIL_SHOP_OWNER','ZSA','ASA','CLIENT_SERVICE_MANAGER','TENANT_ADMIN','LOGISTICS_MANAGER'])`.
  - In `046` (fixtures in the `039` style: auth users with `phone_confirmed_at`, a `PLATFORM_SUPER_ADMIN` profile, tenants A and B):
    - The platform admin appoints a CSM for tenant A: the row is INVITED with no anchors, and the same key replays.
    - A ZSM inviting a CSM gets 42501 with the message above; a `MONVELO_OPERATOR` calling `appoint_client_service_manager` gets 42501.
    - Appointing the same person twice in one tenant gets 23505.
    - The CSM (set ACTIVE as postgres) invites an LM, whose `reports_to_id` is the CSM's membership id. A CSM inviting a `TM` gets 42501. A CSM passing a territory gets P0001.
    - The CSM invites a `TENANT_ADMIN`. A ZSM inviting a `TENANT_ADMIN` gets 42501.
    - Insert-level: an LM row with a `territory_id` is 23514, and an LM row without `reports_to_id` is 23514.
    - `fulfilment_can_dispatch` is true for an ACTIVE LM row with an order of the same tenant (call it as postgres with rows selected from the tables), and false for tenant B's order.
    - `fulfilment_delivery_path` returns `'COURIER'` for the LM.
    - End to end: copy `030`'s paid ONLINE order fixture. The LM calls `mark_order_dispatched` with the gateway proof (create `gateway_secret` as `030` does) and the order becomes `IN_TRANSIT`. A `TENANT_ADMIN` calling the same RPC gets 42501 (Review Focus 1).
    - The `TENANT_ADMIN` gets 42501 from `invite_tenant_user` and from `claim_ticket` on a SYSTEM ticket.
    - The `TENANT_ADMIN` reads tenant A's `monvelo_shop_enrolments` rows and none of tenant B's.
    - `is_platform_staff()` is true for the platform admin and false for a ZSM.
- [ ] **Step 2: Run** `001`, `042` and `046`. Expected: FAIL (`invalid input value for enum tenant_role_enum: "CLIENT_SERVICE_MANAGER"`).
- [ ] **Step 3: Write the two migrations.**
  - The enum file holds only the three `alter type` statements.
  - The roles file recreates `invite_tenant_user` from the live `pg_get_functiondef`. The role branch comes before the existing ZSM-zone territory check, so a CSM's null territory never meets it.
- [ ] **Step 4: Run the three files, then the green gate.** Expected: PASS; 0 failed; integration 0 failed (`004`'s invite tests pass unchanged).
- [ ] **Step 5: Commit.** `feat(db): CSM, TENANT_ADMIN and LOGISTICS_MANAGER roles; CSM appointment and invites (A6 §16.3)`

### Task 2: Contact reports

**Files:**
- Create: `supabase/migrations/20261029120200_contact_reports.sql`, `supabase/tests/database/047_contact_reports.test.sql`
- Modify: `001_schema_shape.test.sql` (`tables_are` gains the four tables)

**Interfaces:**
- Consumes: Task 1 roles and `is_platform_staff()`.
- Produces:
  - **table `contact_reports`:**
    - `id`, `tenant_id`;
    - `reference text unique check (reference ~ '^CR-[A-Z2-7]{8}$')`;
    - `met_at timestamptz not null`;
    - `channel text check in ('MEETING','CALL','VIDEO','MESSAGE')`;
    - `attendees jsonb not null`: an array of 1–30 `{name, side}`, with `side` in `TEAFAIR`/`TENANT`; checked in the RPC, plus `jsonb_typeof = 'array'` in a CHECK;
    - `summary text check (length(btrim(summary)) between 1 and 4000)`;
    - `filed_by → profiles`, `filed_at default now()`, `check (met_at <= filed_at)`;
    - `supersedes_id uuid null`, with FK `(tenant_id, supersedes_id) → contact_reports (tenant_id, id)` and `unique (supersedes_id)` (a report is corrected at most once).
  - **table `contact_report_decisions`:**
    - `id`, `tenant_id`, `report_id`, `seq integer`;
    - `subject text check in ('BRAND_TERMS','MONVELO_SETTINGS','FEES','CATALOGUE','STOCK','OTHER')` (`FEES` added 2026-10-29 for Teafair's fee terms);
    - `decision_text text check (length(btrim(decision_text)) between 1 and 2000)`;
    - `created_at`;
    - FK `(tenant_id, report_id)`; `unique (report_id, seq)`; `unique (tenant_id, id)`.
  - **table `contact_report_recipients`:**
    - `id`, `tenant_id`, `report_id`;
    - `name text`;
    - `channel text check in ('WHATSAPP','EMAIL')`;
    - `address text not null`: E.164 `^\+[1-9][0-9]{7,14}$` for WhatsApp, `^[^@\s]+@[^@\s]+\.[^@\s]+$` for email;
    - `address_hint text not null`: `…` plus the last 4 digits, or the first character + `***@` + the domain;
    - `created_at`.
    - **No column grant on `address`.**
  - **table `contact_report_deliveries`** (the send log):
    - `id`, `tenant_id`, `report_id`, `recipient_id`;
    - `channel`;
    - `status text default 'PENDING' check in ('PENDING','SENT','FAILED')`;
    - `attempts integer default 0`, `last_attempt_at`, `sent_at`, `error_code text`;
    - `created_at`, `updated_at`.
    - One row per recipient, written PENDING by `file_contact_report`.
    - Only Step 6's sender moves it, and only its status columns may change (trigger). It is never deleted.
  - **Insert-only.** `contact_reports`, `contact_report_decisions` and `contact_report_recipients` get the trigger function `contact_reports_insert_only()` on BEFORE UPDATE/DELETE (row) and TRUNCATE (statement): P0001 `'contact reports are insert-only; file a correction that supersedes the report'`. UPDATE, DELETE and TRUNCATE are revoked from `authenticated`, `anon` and `service_role`.
  - **Policy helper** `my_contact_report_tenant_ids()` = `my_tenant_ids_with_role(array['TENANT_ADMIN','CLIENT_SERVICE_MANAGER','ZSM'])`.
    - The policy on all four tables: `tenant_id in (select public.my_contact_report_tenant_ids()) or (select public.is_platform_staff())`.
  - **RPC** `file_contact_report(p_idempotency_key uuid, p_report jsonb) returns jsonb`:
    - caller: `assert_tenant_role(array['CLIENT_SERVICE_MANAGER'])`;
    - `p_report` keys: `met_at`, `channel`, `attendees`, `summary`, `supersedes_id` (optional), `decisions: [{subject, text}]` (0–50, `seq` = array position from 1), `recipients: [{name, channel, address}]` (1–20; a phone is normalised to `+` digits);
    - `supersedes_id` must be a report of the caller's tenant that nobody has superseded yet: P0001 `'only the current version of a report can be corrected'`;
    - the reference is drawn like `monvelo_assign_shop_code` (internal `contact_report_draw_reference()`, 8 base32 characters, retry on collision);
    - writes one PENDING delivery per recipient;
    - the audit `after` holds the reference, channel, decision subjects and recipient hints, never an address;
    - the stored idempotency request is the report with each `address` replaced by its hint;
    - returns `{report_id, reference, decision_ids: [uuid…] in seq order, deliveries_pending: n}`;
    - granted to `authenticated`.
  - **Internal** `assert_citable_decision(p_tenant_id uuid, p_decision_id uuid, p_subject text) returns public.contact_report_decisions`:
    - not found in that tenant: 42501 `'decision not found'`;
    - wrong subject: P0001 `'cite a decision on <subject>'`;
    - its report is superseded: P0001 `'this contact report has been superseded; cite the decision in its correction'`;
    - no grant.

- [ ] **Step 1: Write the failing tests** in `047`:
  - The CSM files a report with 2 decisions and 2 recipients (one WhatsApp, one email): a `CR-` reference, 2 PENDING deliveries, and the same key replays.
  - A ZSM filing gets 42501, and so does a `TENANT_ADMIN`.
  - The stored `idempotency_logs.request` and the audit `after` contain neither address (`not like '%@%'`, no 10-digit run).
  - `has_column_privilege('authenticated','public.contact_report_recipients','address','SELECT')` is false; `address_hint` is true.
  - As postgres: `update contact_reports set summary = 'x'` raises P0001, `delete` raises P0001, and `truncate` raises P0001.
  - A correction B supersedes A. A second correction of A gets P0001. C supersedes B.
  - `assert_citable_decision` on A's decision gets P0001 (superseded). On B's it also gets P0001. On C's, with the matching subject, it returns the row. With the wrong subject it gets P0001. With another tenant's decision it gets 42501 (Review Focus 2).
  - Readers: the `TENANT_ADMIN`, the CSM, a ZSM and a `MONVELO_FINANCE` profile read tenant A's report. A TM, a DSA and tenant B's ZSM read none.
  - Zero recipients gets P0001 `'a contact report copies at least one tenant contact'`; a bad phone gets P0001.
- [ ] **Step 2: Run the file.** Expected: FAIL (`relation "public.contact_reports" does not exist`).
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file, then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): contact reports, decisions, recipients and the send log (A6 §16.4)`

### Task 2b: ZSM review and the signed hard copy of a contact report (user, 2026-10-29)

**Rules (user):**
- Every contact report has a hard copy, and it is uploaded.
- **A ZSM of the tenant reviews the report before the hard copy is uploaded.**

A report's decisions cannot be cited until it has a ZSM approval **and** an
attached signed hard copy.

**The ZSM review:**
- **Table `contact_report_reviews`** (insert-only, the same trigger and revokes as the report tables):
  - `id`, `tenant_id`, `report_id`;
  - `outcome text check in ('APPROVED','REJECTED')`;
  - `note text`, required for REJECTED, `check (length(btrim(note)) <= 2000)`;
  - `reviewed_by → profiles`, `reviewed_at default now()`;
  - composite FK `(tenant_id, report_id) → contact_reports`, `unique (tenant_id, id)`;
  - **one review per report:** `unique (report_id)`. A rejected report is corrected by a superseding report, which gets its own review.
  - SELECT policy: as for the report tables.
- **RPC** `review_contact_report(p_idempotency_key uuid, p_report_id uuid, p_outcome text, p_note text default null) returns jsonb`:
  - **callers:**
    - an ACTIVE ZSM of the report's tenant. Another tenant's report is 42501 `'contact report not found'`;
    - **operator fallback (user, 2026-10-29):** a `MONVELO_OPERATOR` (platform role, via `assert_platform_role`) may review **only when the report's tenant has no ACTIVE ZSM membership**. Otherwise it gets 42501 `'this tenant has an active ZSM; the ZSM reviews'`. The tenant is taken from the report, never from a parameter. `reviewed_by` is the operator, and the audit row records `reviewer_kind = 'OPERATOR_FALLBACK'`;
  - a superseded report is P0001 `'only the current version of a report can be reviewed'`;
  - a second review is 23505 `'this contact report has already been reviewed'`;
  - REJECTED without a note is P0001 `'say what must be corrected'`;
  - audit row with the reference and outcome (the note is kept in the table, not the audit row);
  - returns `{review_id, report_id, outcome}`;
  - granted to `authenticated`.
- The CSM (who filed it), a `TENANT_ADMIN` or a TM calling it gets 42501. Other platform roles get 42501.
- Claude's call (open to change): any ACTIVE ZSM of the tenant may review.

The hard-copy upload below requires an APPROVED review.
The upload follows the A5 photo pattern:
1. an RPC registers a pending slot;
2. a user gateway signs a one-time upload URL;
3. the client uploads to a private bucket;
4. a claim RPC checks that the object is really there.

Paths and URLs never reach an audit row.

**Files:**
- Create:
  - `supabase/migrations/20261029120250_contact_report_review_hard_copy.sql`
  - `supabase/tests/database/055_contact_report_hard_copy.test.sql`
  - `supabase/functions/contact-report-upload/{index,handler,handler.test}.ts`
- Modify:
  - `001_schema_shape.test.sql` (`tables_are`);
  - `supabase/config.toml` (only if the user-gateway pattern needs a section; the A5 staff gateway shows what is needed);
  - `supabase/functions/_shared/storage/` (a bucket constant and the field schema for PDF and images, alongside `attachment.ts`).

**Interfaces:**
- Consumes: Task 2's tables and `assert_citable_decision`; the A5 pattern in `20261023120300_a5_upload_slots.sql` (slot RPC, `my_support_attachment_paths()` and the `support_attachments_select` policy on `storage.objects`, `storage_purge_queue`) and in `supabase/functions/support-staff-attachment/`.
- Produces:
  - **Bucket** `contact-reports`: private, `file_size_limit` 10485760, `allowed_mime_types` `application/pdf`, `image/jpeg`, `image/png`.
  - **Table `contact_report_hard_copies`:**
    - `id`, `tenant_id`, `report_id`;
    - `storage_path text not null unique`, matching `^contact-reports/<report_id>/<id>\.(pdf|jpg|png)$`;
    - `mime_type` (the three types), `size_bytes bigint check (between 1 and 10485760)`;
    - `uploaded_by → profiles`, `created_at`, `attached_at timestamptz null`;
    - composite FK `(tenant_id, report_id) → contact_reports`;
    - **one attached copy per report:** a unique partial index on `(report_id) where attached_at is not null`;
    - **never deleted:** a trigger refuses DELETE and TRUNCATE. It allows only one UPDATE, `attached_at` from null to a value, and refuses every other change with P0001 `'a hard copy is never changed; file a correction'`. UPDATE and DELETE are revoked from the API roles.
    - SELECT policy: the same as the contact-report tables (§ Task 2).
  - **RPC** `request_contact_report_hard_copy(p_idempotency_key uuid, p_report_id uuid, p_mime_type text, p_size_bytes bigint) returns jsonb`:
    - caller: the tenant's `CLIENT_SERVICE_MANAGER`;
    - the report must be of the caller's tenant (else 42501 `'contact report not found'`) and have no attached copy (else P0001 `'this contact report already has its hard copy'`);
    - the report must have an APPROVED ZSM review, else P0001 `'a ZSM must approve this contact report before its hard copy is uploaded'`. A REJECTED review gives P0001 `'this contact report was rejected; file a correction'`;
    - inserts a pending row;
    - returns `{hard_copy_id, storage_path}` (the path goes only to the gateway, which keeps it server-side);
    - granted to `authenticated`.
  - **RPC** `attach_contact_report_hard_copy(p_idempotency_key uuid, p_hard_copy_id uuid) returns jsonb`:
    - caller: the CSM;
    - the object must exist in `storage.objects` (bucket `contact-reports`, that path), else P0001 `'the hard copy has not been uploaded yet'`;
    - sets `attached_at`;
    - audit row with the report reference, mime type and size, never the path;
    - returns `{report_id, reference, attached_at}`;
    - granted to `authenticated`.
  - **Download:** a policy on `storage.objects` for bucket `contact-reports` lets a reader of the report read the **attached** copy's path only, through a helper `my_contact_report_hard_copy_paths()` in the `my_support_attachment_paths()` style.
  - **Cleanup:** a pending row older than 24 h is left in place, since rows are never deleted. Its object, if one was uploaded, is queued in `storage_purge_queue` by extending the existing nightly `cleanup_pending_upload_slots()`, recreated from its live body.
  - **`assert_citable_decision`**, recreated. After the supersede check, in this order:
    - a decision whose report has no APPROVED review is P0001 `'a ZSM must approve this contact report before it is cited'`;
    - one with no attached hard copy is P0001 `'upload the signed hard copy of this contact report before citing it'`.
  - **Gateway** `contact-report-upload`:
    - a user gateway, the caller's JWT forwarded;
    - Zod body `{idempotency_key, report_id, mime_type, size_bytes}`;
    - calls `request_contact_report_hard_copy`, then `signUpload('contact-reports', path)`;
    - returns `{hard_copy_id, upload_url}`;
    - uses `observe("contact-report-upload", …)`;
    - handler tests mirror `support-staff-attachment`.
  - **The deliveries of Task 2** are sent (Step 6) only once the hard copy is attached. Step 1c sends nothing.

- [ ] **Step 1: Write the failing tests.**
  - In `055`:
    - **Review:**
      - requesting a slot before any review gets P0001 (ZSM approval message);
      - the CSM, a `TENANT_ADMIN` and a TM calling `review_contact_report` get 42501, and tenant B's ZSM gets 42501;
      - **operator fallback:**
        - a `MONVELO_OPERATOR` reviewing a report of tenant A (which has an ACTIVE ZSM) gets 42501;
        - for tenant C, which has no ACTIVE ZSM, the operator's APPROVED review is stored with `reviewed_by` = the operator, and its decisions become citable once the hard copy is attached;
        - a `MONVELO_FINANCE` profile gets 42501;
      - REJECTED without a note gets P0001; REJECTED with a note is stored, and a slot request then gets P0001 (rejected message);
      - a correction of the rejected report is reviewed APPROVED;
      - a second review of the same report gets 23505;
      - reviewing a superseded report gets P0001;
      - as postgres, `update contact_report_reviews` raises P0001;
      - citing an approved report's decision before the hard copy gets P0001 (hard-copy message), and citing an unreviewed report's decision gets P0001 (review message).
    - After an APPROVED review, the CSM requests a slot for a PDF of 200 KB and gets a path under `contact-reports/<report_id>/`.
    - Attaching before any object exists gets P0001.
    - Insert a `storage.objects` row as postgres (bucket, name) to stand in for the upload, then attach: `attached_at` is set and the same key replays.
    - A second request for the same report gets P0001.
    - Citing the report's decision before the attach gets P0001 with the hard-copy message; after the attach the citation passes (re-check via `assert_citable_decision` as postgres).
    - As postgres: changing `storage_path` raises P0001, and deleting raises P0001.
    - A ZSM or a `TENANT_ADMIN` requesting a slot gets 42501; tenant B's CSM gets 42501.
    - Storage read: the `TENANT_ADMIN` of tenant A can SELECT the attached object's row in `storage.objects`; a TM cannot; nobody can read a pending (unattached) object.
    - A 20 MB size or a `text/plain` type gets rejected (23514 or P0001).
  - In `handler.test.ts`: a valid body returns `{hard_copy_id, upload_url}`; a bad mime type is 400; the RPC gets the caller's JWT; nothing in the response holds the storage path.
- [ ] **Step 2: Run** `055` and the handler test. Expected: FAIL.
- [ ] **Step 3: Write the migration, the shared storage constant and the gateway.**
- [ ] **Step 4: Run** `047`, `055`, `deno check supabase/functions/contact-report-upload/index.ts`, then the green gate. Expected: PASS.
  - Task 3's `048` and Task 4's `049` fixtures must have a ZSM approve the report and attach a hard copy (insert the `storage.objects` row as postgres) before citing. Their briefs carry this.
- [ ] **Step 5: Commit.** `feat: ZSM review and signed hard copy of a contact report, both required before citing (A6 §16.4)`

### Task 3: CSM approval of brand terms and settings

**Files:**
- Create: `supabase/migrations/20261029120300_monvelo_csm_approvals.sql`, `supabase/tests/database/048_monvelo_csm_approvals.test.sql`

**Interfaces:**
- Consumes: `assert_citable_decision` (Task 2), `monvelo_brand_terms_guard` (live body), `set_monvelo_tenant_settings` and `approve_monvelo_brand_terms` (live bodies).
- Produces:
  - **Columns:**
    - `monvelo_brand_terms.approval_decision_id uuid`, FK `(tenant_id, approval_decision_id) → contact_report_decisions (tenant_id, id)`, indexed;
    - `monvelo_tenant_settings.decision_id uuid`, with the same FK, indexed;
    - `monvelo_tenant_settings.max_limit numeric(15,2) null`, `check (max_limit is null or max_limit >= opening_limit)`. This is the tenant's cap on limit growth (§7.2); Step 4 reads it.
  - **`monvelo_brand_terms_guard()`**, recreated: the PROPOSED branch also lets `approval_decision_id` change with the approval.
  - **Helper** `monvelo_tenant_has_csm(p_tenant_id uuid) returns boolean`: an ACTIVE `CLIENT_SERVICE_MANAGER` membership exists. Internal, no grant.
  - **RPC** `approve_monvelo_brand_terms(p_idempotency_key uuid, p_terms_id uuid, p_decision_id uuid default null)`. Drop the 2-argument version; the grant follows.
    - Caller: `assert_tenant_role(array['ZSM','CLIENT_SERVICE_MANAGER'])`.
    - **With an active CSM:**
      - a ZSM gets 42501 `'brand terms are approved by the client service manager'`;
      - the CSM must pass `p_decision_id`, checked by `assert_citable_decision(…, 'BRAND_TERMS')`, else P0001 `'cite the contact report decision that agreed these terms'`.
    - **Without one (the bridging rule):**
      - a ZSM other than `proposed_by` approves, else 42501 `'terms are approved by a second ZSM'`;
      - **the decision is mandatory here too (user, A6 §17.3).** `p_decision_id` is checked by `assert_citable_decision(…, 'BRAND_TERMS')`, so the report must be ZSM-approved with its hard copy attached. Without it: P0001 `'cite the contact report decision that agreed these terms'`.
    - `p_decision_id` goes into the idempotency request; the result keys are unchanged.
  - **RPC** `set_monvelo_tenant_settings(p_idempotency_key uuid, p_enabled boolean, p_opening_limit numeric, p_approval_cap numeric, p_max_limit numeric default null, p_decision_id uuid default null)`. Drop the 4-argument version.
    - Caller: `ZSM` or `CLIENT_SERVICE_MANAGER`.
    - With an active CSM: only the CSM. A ZSM gets 42501 `'Monvelo settings are set by the client service manager'`.
    - Without one (bridging): a ZSM.
    - **Either way, the decision is mandatory (user, 2026-10-29).** It must be a current `MONVELO_SETTINGS` decision whose report is ZSM-approved with a hard copy attached. Without it: P0001 `'cite the contact report decision that agreed these settings'`.
    - Stores `decision_id` and `max_limit`.

  - **RPC** `withdraw_monvelo_brand_terms(p_idempotency_key uuid, p_terms_id uuid, p_decision_id uuid)`:
    - drop the 2-argument version;
    - same callers and rules as approval (the CSM, or a second ZSM while bridging);
    - **cites a current `BRAND_TERMS` decision**, which is mandatory.
  - **RPC** `record_monvelo_fee_terms(p_idempotency_key uuid, p_tenant_id uuid, p_fee_bps integer, p_valid_from date, p_valid_to date, p_decision_id uuid)`:
    - drop the 5-argument version;
    - caller unchanged (`MONVELO_OPERATOR`);
    - **cites a current `FEES` decision of `p_tenant_id`** (Teafair's fee is agreed with the brand and recorded in a contact report), which is mandatory;
    - stores `monvelo_tenant_fee_terms.decision_id` (new column, composite FK to `contact_report_decisions`, indexed).
  - **Zero unaudited backdoors (user, 2026-10-29).** No risk, financial or commercial setting of a tenant changes without a cited decision:
    - brand terms (rebate, interest-free days, late charge): approval and withdrawal;
    - Monvelo settings (enabled, opening limit, maximum limit, approval cap);
    - Teafair's fee terms;
    - the catalogue and stock movements (Task 4).

    Exempt, with reasons, recorded in A6 §16.4:
    - `propose_monvelo_brand_terms` is a draft with no effect until approved;
    - `set_web_defaults` is routing only (warehouse, default agent);
    - `web_transport_fare` and `web_agent_commission_bps` change by migration only;
    - the platform agent controls (`register_`, `approve_`, `suspend_monvelo_agent`, `set_monvelo_agent_caps`, the settlement-change RPCs) concern lenders, not a tenant's agreement. They stay `MONVELO_OPERATOR` decisions, audited.

    Task 4 adds the catalog guard that keeps this true.

- [ ] **Step 1: Write the failing tests** in `048`:
  - **Bridging:** no CSM.
    - Two ZSMs propose and approve, citing a current, ZSM-approved `BRAND_TERMS` decision with a hard copy, and the result is APPROVED.
    - Approval without a decision gets P0001.
    - `039`'s approval calls are updated to cite a decision. Its fixtures file, review and attach a contact report as postgres. This is the one permitted change to `039`.
  - **With the CSM ACTIVE:**
    - the second ZSM's approval gets 42501;
    - the CSM's approval without a decision gets P0001;
    - with a `CATALOGUE` decision it gets P0001;
    - with a current `BRAND_TERMS` decision it is APPROVED, with `approval_decision_id` set;
    - with a superseded report's decision it gets P0001 (Review Focus 2).
  - **Settings:**
    - the CSM sets them citing a `MONVELO_SETTINGS` decision, and `decision_id` is stored;
    - a ZSM gets 42501;
    - `p_max_limit` below `p_opening_limit` gets 23514 from the CHECK (assert `throws_ok … '23514'`);
    - a `TENANT_ADMIN` gets 42501 from both RPCs;
    - **bridging:** a ZSM setting them without a decision gets P0001, and with a current `MONVELO_SETTINGS` decision succeeds.
  - **Withdrawal** without a decision gets P0001; with one, the terms are WITHDRAWN and the decision is recorded in the audit row.
  - **Fee terms:** the operator recording them without a decision gets P0001. With a `FEES` decision of another tenant it gets 42501. With a current `FEES` decision of the named tenant, `decision_id` is stored. The existing fee-terms tests in `039` are updated to cite a decision; this is a permitted change.
  - **Immutability:** on an APPROVED row, `update … set approval_decision_id = <another>` raises P0001 `'approved terms are immutable'`.
- [ ] **Step 2: Run the file.** Expected: FAIL (`function public.approve_monvelo_brand_terms(uuid, uuid, uuid) does not exist`).
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `039` (updated as above), `048`, then the green gate. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): the CSM approves brand terms and settings citing a decision; two-ZSM bridging (A6 §16.3)`

### Task 4: Catalogue and stock movements

**Files:**
- Create: `supabase/migrations/20261029120400_catalogue_stock_movements.sql`, `supabase/tests/database/049_catalogue_stock_movements.test.sql`
- Modify: `001_schema_shape.test.sql` (`stock_movements`)

**Interfaces:**
- Consumes: `assert_citable_decision` (subjects `CATALOGUE` and `STOCK`), and the existing `central_products` triggers (category guard, NAFDAC CHECK, `order_items_wholesale_pack`).
- Produces:
  - **Column** `central_products.decision_id uuid`, FK `(tenant_id, decision_id) → contact_report_decisions`, indexed. It holds the decision behind the latest RPC change; seeded rows stay null.
  - **RPC** `upsert_catalogue_product(p_idempotency_key uuid, p_decision_id uuid, p_product jsonb) returns jsonb`:
    - caller: `CLIENT_SERVICE_MANAGER` only;
    - keys: `sku_code` (identity; immutable), `product_name`, `brand`, `category`, `sale_category`, `unit_price`, `wholesale_price`, `description`, `nafdac_number`, `carton_units`, `break_bulk_units`, `is_active`;
    - insert when the SKU is new in the tenant, otherwise update the given keys;
    - existing CHECKs and triggers do the validation, and their errors pass through unchanged;
    - the audit row holds the before and after rows;
    - returns `{product_id, sku_code, created}`.
  - **table `stock_movements`:**
    - `id`, `tenant_id`;
    - `kind text check in ('RECEIPT','TRANSFER','ADJUSTMENT')`;
    - `warehouse_id` (the receipt's destination, the transfer's source, the adjustment's warehouse) and `to_warehouse_id` (TRANSFER only, `<> warehouse_id`);
    - `sku_code`, `batch_number`;
    - `quantity numeric(14,3)`: `> 0` for RECEIPT and TRANSFER, `<> 0` for ADJUSTMENT;
    - `reason text` (required for ADJUSTMENT);
    - `decision_id uuid not null`;
    - `recorded_by`, `created_at`.
    - Composite FKs to `warehouses` (both), `central_products (tenant_id, sku_code)` and `contact_report_decisions`.
    - Insert-only (trigger `stock_movements_insert_only()` plus revokes).
    - SELECT policy `tenant_id in (select public.my_tenant_ids())`.
  - **RPCs** (callers `CLIENT_SERVICE_MANAGER` or `LOGISTICS_MANAGER`; decision subject `STOCK`; each returns `{movement_id, batch_id, quantity}` with the batch's new quantity):
    - `record_stock_receipt(p_idempotency_key uuid, p_decision_id uuid, p_warehouse_id uuid, p_sku_code text, p_batch_number text, p_quantity numeric, p_expires_at timestamptz)`:
      - upserts the batch `(warehouse, sku, batch)` and adds the quantity;
      - a different non-null `expires_at` on an existing batch is P0001 `'this batch already has a different expiry'`.
    - `record_stock_transfer(p_idempotency_key uuid, p_decision_id uuid, p_from_warehouse_id uuid, p_to_warehouse_id uuid, p_sku_code text, p_batch_number text, p_quantity numeric)`:
      - locks both batch rows in id order;
      - TF001 `'insufficient stock'` with `detail` = `{"sku_code","available","requested"}` (jsonb text);
      - creates the destination batch with the source's `expires_at`.
    - `record_stock_adjustment(p_idempotency_key uuid, p_decision_id uuid, p_warehouse_id uuid, p_sku_code text, p_batch_number text, p_quantity_delta numeric, p_reason text)`: a result below 0 is TF001.

- [ ] **Step 1: Write the failing tests** in `049`:
  - **Catalogue:**
    - the CSM creates a COSMETICS product with a NAFDAC number, and `created` is true;
    - an update of `wholesale_price` gives `created` false, with `decision_id` set;
    - a COSMETICS product without NAFDAC gets 23514;
    - TELECOM for a non-Sureach tenant gets the existing P0001;
    - a ZSM and an LM get 42501;
    - a `STOCK` decision gets P0001.
  - **Stock:**
    - the LM receives 24 units into batch B1, and the batch quantity is 24;
    - receiving again adds to 48;
    - transferring 12 to the regional warehouse leaves 36 and 12, with the same expiry;
    - transferring 100 gets TF001, with `detail::jsonb ->> 'available' = '36'`, and both batches are unchanged (Review Focus 5);
    - an adjustment of −40 gets TF001;
    - an adjustment without a reason gets P0001;
    - a warehouse of tenant B gets 42501 (`'warehouse not found in this tenant'`);
    - a `TENANT_ADMIN` gets 42501.
  - **Zero-backdoor catalog guard (user, 2026-10-29):**
    - every `public` function whose body inserts, updates or deletes `monvelo_brand_terms`, `monvelo_tenant_settings`, `monvelo_tenant_fee_terms`, `central_products`, `inventory_batches` or `stock_movements` either takes a `p_decision_id uuid` argument and calls `assert_citable_decision`, or is in the named allowlist: `propose_monvelo_brand_terms`, plus trigger and guard functions that do not mutate those tables;
    - a positive control proves the scan finds `set_monvelo_tenant_settings`.
  - **Movement records:**
    - one row per call;
    - as postgres, `update stock_movements` raises P0001;
    - a DSA of the tenant reads the movements, and tenant B's ZSM reads none.
- [ ] **Step 2: Run the file.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file, then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): catalogue and stock-movement RPCs citing a contact report decision (A6 §16.3)`

Step 1c is complete when Task 4 is green.

### Task 1d: Teafair field structure: zones are states, multi-zone ZSMs (A6 §17)

Runs after Task 4 and before Task 5. The user approved the rulings on 2026-10-29.

**Files:**
- Create:
  - `supabase/migrations/20261029125000_teafair_field_structure.sql`
  - `supabase/tests/database/056_teafair_field_structure.test.sql`
- Modify:
  - every pgTAP fixture that inserts into `public.zones` (about 40 inserts) so it gives a `state_code`, and every fixture that gives a ZSM `tenant_users` row a `zone_id`;
  - `supabase/seed.sql` or the migrations' TEAFAIR seed, if they create zones or ZSMs;
  - `gateway.integration.ts` fixtures, the same way.

**Interfaces:**
- **Zones are states.**
  - Add `zones.state_code text not null`, with FK `→ ng_states (code)` and `unique (tenant_id, state_code)`, indexed.
  - Backfill existing rows by matching `lower(zone_name)` to `lower(ng_states.name)`. If a row cannot be matched, the migration fails and names it; it never guesses.
  - `zone_name` stays as a display name.
- **One ZSM, many zones.**
  - `zones.zsm_id` is the source of truth for a ZSM's coverage. A ZSM covers every zone in a tenant where `zsm_id` is them, and in every tenant where they hold an ACTIVE ZSM membership.
  - **`tenant_users` for a ZSM:**
    - drop the CHECK `role <> 'ZSM' or zone_id is not null`;
    - add `tenant_users_zsm_no_zone`: `check (role <> 'ZSM' or zone_id is null)`;
    - the backfill first sets each ZSM's old `zone_id` zone's `zsm_id` to that ZSM where it is null, then sets `zone_id` null.
  - **New helper** `zsm_zone_ids(p_tenant_id uuid, p_profile_id uuid) returns setof uuid`: the zones of that tenant whose `zsm_id` is the profile, given an ACTIVE ZSM membership. It is stable, security definer and internal. `my_zsm_zone_ids()` returns the caller's zones in their active tenant and is granted to `authenticated` for policies.
  - The `zones` trigger that checks `zsm_id` has a ZSM membership (`20261006120400`, about line 97) stays.
- **Every function and policy that scopes a ZSM by `tenant_users.zone_id` is recreated from its live `pg_get_functiondef`**, so that "the ZSM's zone" becomes "one of `zsm_zone_ids`".
  - **Inventory first, live:** `select proname from pg_proc where pronamespace = 'public'::regnamespace and prosrc ~ 'zone_id'`, and `pg_policies` whose `qual` names `zone_id`. Read each one.
  - Known today: `invite_tenant_user`, `upsert_zone`, `upsert_territory`, `upsert_area`, `assign_ticket`, `chat_staff_zone`, `chat_is_available`, `my_chat_channel_ids`, `hide_chat_message`, `monvelo_assign_shop_code` and `web_route_try`, plus any RLS helper that joins a ZSM's zone.
  - Where a function picks *one* zone for a ZSM (for example `chat_staff_zone`, or routing to "the ZSM"), it uses the zone of the object in hand: the territory's zone, or the order's zone. It never takes an arbitrary one of the ZSM's zones.
  - Grants and signatures are unchanged.
  - **Chat:** a multi-zone ZSM is a member of every ZONE channel of their zones.
- **The field force is Teafair staff** (§17.2).
  - No new code: only a platform administrator appoints a ZSM (already enforced), and ZSMs invite TM, ASM, ZSA and ASA within their zones.
  - `invite_tenant_user`'s zone check becomes "the territory is in one of my zones".
- **Docs:** `supabase/CLAUDE.md` gets a "Teafair field structure (A6 §17)" section. Task 10 folds the counts.

- [ ] **Step 1: Write the failing tests** in `056`:
  - `zones.state_code` exists, is NOT NULL and references `ng_states`. A second Lagos zone in the same tenant gets 23505.
  - One ZSM is `zsm_id` on Lagos and Ogun in tenant A and on Lagos in tenant B, with no `zone_id` on the memberships. A ZSM row with a `zone_id` gets 23514.
  - That ZSM:
    - invites a TM into an Ogun territory, and into a Lagos territory;
    - gets 42501 inviting into a territory of a zone they don't cover (Oyo, whose `zsm_id` is another ZSM);
    - does the same in tenant B, scoped to B's zones only.
  - `upsert_territory` and `upsert_area` work in both of the ZSM's zones and refuse elsewhere.
  - Chat: the ZSM is in both ZONE channels of tenant A.
  - `assign_ticket` and `web_route_try` behave as before for a single-zone ZSM, and route by the object's zone for a multi-zone ZSM. Mirror their existing tests in `011`/`021`/`022` (find them).
  - Monvelo: `monvelo_assign_shop_code` and `enrol_monvelo_shop` accept a ZSM in either covered zone.
  - The backfill migration fails clearly on a zone name that matches no state. Test this with a savepoint and a temp copy, or document it if it cannot be tested in pgTAP.
- [ ] **Step 2: Run** `056`. Expected: FAIL.
- [ ] **Step 3: Write the migration and update every fixture.** The whole suite must pass, not only `056`.
- [ ] **Step 4: The green gate.** Expected: PASS, deno 0 failed, integration 0 failed.
- [ ] **Step 5: Commit.** `feat(db): zones are states; a Teafair ZSM covers many zones across tenants (A6 §17)`

---

## Step 2: the financing ledger and allocation

### Task 5: Platform settings, supply days, pledges and proximity

**Files:**
- Create: `supabase/migrations/20261029130000_monvelo_supply_pledges.sql`, `supabase/tests/database/050_monvelo_supply_pledges.test.sql`
- Modify: `001_schema_shape.test.sql`

**Interfaces:**
- Consumes: `monvelo_agents`, `monvelo_agent_members`, `my_monvelo_agent_ids()`, `is_monvelo_staff()`, `areas`, and `monvelo_shop_enrolments`.
- Produces:
  - **table `monvelo_platform_settings`:**
    - one row, `id boolean primary key default true check (id)`;
    - `offer_radius_m integer not null default 1000 check (offer_radius_m between 100 and 50000)`;
    - `preferred_window_minutes integer not null default 10`;
    - `claim_minutes integer not null default 15`;
    - the row is seeded; there is no RPC (a migration changes it);
    - SELECT policy `using (true)` for `authenticated`;
    - internal getter `monvelo_settings() returns public.monvelo_platform_settings`.
  - **Function** `monvelo_today() returns date`: stable; granted to `authenticated`.
  - **Index** `idx_monvelo_agents_location on public.monvelo_agents using gist (location)`.
  - **table `monvelo_supply_days`:**
    - `tenant_id`, `area_id`;
    - `day_of_week integer check between 1 and 7` (ISO: 1 = Monday);
    - `active boolean not null default true`;
    - `set_by`, `created_at`, `updated_at`;
    - pk `(tenant_id, area_id, day_of_week)`; FK `(tenant_id, area_id) → areas`;
    - never deleted (a day off is `active = false`);
    - policy: `tenant_id in (select public.my_tenant_ids()) or (select public.is_monvelo_staff())`.
  - **table `monvelo_pledges`:**
    - `id`, `tenant_id`, `agent_id → monvelo_agents`, `area_id`, `supply_date date`;
    - `amount numeric(15,2) check (amount > 0)`, `remaining numeric(15,2) check (remaining >= 0 and remaining <= amount)`;
    - `pledged_by → profiles`, `created_at`, `updated_at`;
    - `unique (tenant_id, id)`, `unique (agent_id, tenant_id, area_id, supply_date)`; FK `(tenant_id, area_id) → areas`;
    - policy: `agent_id in (select public.my_monvelo_agent_ids()) or (select public.is_monvelo_staff())`;
    - `remaining` drops only at funding (Step 3).
  - **RPC** `set_monvelo_supply_day(p_idempotency_key uuid, p_area_id uuid, p_day_of_week integer, p_active boolean) returns jsonb`:
    - caller: the TM of the area's territory (else 42501 `'supply days are set by the TM of the area's territory'`);
    - upsert;
    - returns `{area_id, day_of_week, active}`.
  - **RPC** `pledge_monvelo_funds(p_idempotency_key uuid, p_agent_id uuid, p_area_id uuid, p_supply_date date, p_amount numeric) returns jsonb`:
    - the caller is an ACTIVE member of `p_agent_id` (else 42501), and the agent is ACTIVE (P0001 `'the agent is not active'`);
    - the area's tenant has Monvelo enabled;
    - `p_supply_date >= monvelo_today()`, and an active supply day exists for its ISO weekday (P0001 `'that date is not a supply day for this area'`);
    - **the first pledge** inserts with `remaining = amount`;
    - **a repeat** sets `amount = p_amount` and `remaining = remaining + (p_amount − amount)`, refused below 0 with P0001 `'a pledge cannot drop below what is already funded'`;
    - the audit row goes to the area's tenant;
    - returns `{pledge_id, amount, remaining}`.
  - **Read RPC** `monvelo_supply_days_near(p_agent_id uuid, p_days integer default 7) returns table (area_id uuid, area_name text, supply_date date, shop_count integer)`:
    - member of the agent only;
    - the agent's upcoming supply days in the next `p_days` (max 14) for areas of enabled tenants;
    - counts only shops that are ACTIVE-enrolled within `offer_radius_m` of the agent;
    - totals only: no shop rows;
    - `stable security definer`; granted to `authenticated`.
  - **Read RPC** `monvelo_agents_near(p_shop_id uuid, p_radius_m integer default null) returns table (agent_id uuid, pos_network public.pos_network_enum, distance_m integer)`:
    - `is_monvelo_staff()` only (else 42501);
    - ACTIVE agents;
    - `extensions.st_dwithin(a.location, s.location::extensions.geography, radius)`;
    - radius defaults to `offer_radius_m`, maximum 50000;
    - ordered by distance; limit 200;
    - no phone, name or account column (§16.6).

- [ ] **Step 1: Write the failing tests** in `050`:
  - Defaults: `monvelo_platform_settings` holds 1000 / 10 / 15 / 3 / 42.
  - The TM sets Thursday active for area A1. Another territory's TM gets 42501. A ZSA gets 42501.
  - **Pledges:**
    - a member of an ACTIVE agent pledges 150000 for the next Thursday: `remaining` is 150000;
    - re-pledging 200000 gives `remaining` 200000;
    - after setting `remaining` to 0 as postgres, pledging 100000 gets P0001;
    - a Wednesday date gets P0001; yesterday gets P0001;
    - a PENDING agent's member gets P0001; a non-member gets 42501.
  - **`monvelo_supply_days_near`:**
    - returns A1 with `shop_count` 1 for an agent 400 m from an enrolled shop;
    - returns nothing for an agent 5 km away;
    - a WITHDRAWN enrolment is not counted.
  - **`monvelo_agents_near`:**
    - the operator gets the 400 m agent and not the 5 km one, with an integer distance near 400;
    - a ZSM gets 42501;
    - `pg_get_function_result('public.monvelo_agents_near(uuid,integer)'::regprocedure) !~* 'phone|name|account'`.
  - `has_index('public','monvelo_agents','idx_monvelo_agents_location')`.
  - Pledge rows: the member reads their own; another agent's member and a tenant ZSM read none.
- [ ] **Step 2: Run the file.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file, then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): Monvelo supply days, pledges and the staff proximity search (A6 §4.3, §16.6)`

### Task 6: `place_trade_order`

**Files:**
- Create: `supabase/migrations/20261029130100_trade_orders.sql`, `supabase/tests/database/051_trade_orders.test.sql`

**Interfaces:**
- Consumes: `orders`, `order_items` (the `order_items_wholesale_pack` trigger), `central_products`, `warehouses`, `areas` and `tenant_users` anchors.
- Produces: **RPC** `place_trade_order(p_idempotency_key uuid, p_shop_id uuid, p_lines jsonb, p_territory_id uuid default null) returns jsonb`. This is RTM core; it names no `monvelo_` object.
  - **Callers:** `ZSA`, `ASA`, `TM`.
  - **Territory:**
    - ASA and TM: their own `territory_id` (a different `p_territory_id` is 42501 `'you sell in your own territory'`);
    - ZSA: `p_territory_id` is required (P0001 `'choose the territory for this order'`) and must lie in the ZSA's zone (42501).
  - **Shop:** must exist (P0001 `'shop not found'`).
  - **Lines:** `p_lines` is `[{sku_code, qty}]`, 1–50 items, no repeated SKU (P0001).
    - Each SKU must be an active product of the caller's tenant (P0001 `'<sku> is not an active product'`).
    - `qty` is numeric(14,3) > 0.
    - Items are inserted at `unit_price = wholesale_price`. The whole-pack rule is the existing trigger's P0001, passed through.
  - **Warehouse:** the territory's REGIONAL warehouse.
    - None: P0001 `'the territory has no regional warehouse'`.
    - Several: the oldest (`order by created_at, id`).
  - **The order:**
    - `channel 'FIELD_SALES'`, `status 'PENDING'`, `retail_shop_id`;
    - `agent_id` and `teafair_agent_id` = the caller;
    - `territory_id`, `fulfilment_warehouse_id`;
    - `total_amount` = Σ `round(qty × wholesale_price, 2)`.
  - **Result:** `{order_id, total_amount, territory_id, warehouse_id}`.
  - The audit row holds the order without the shop's contact details.

- [ ] **Step 1: Write the failing tests** in `051`:
  - An ASA orders 1 carton (12 units) of Purerigin 200 ml: total 48000.00 and `FIELD_SALES`; the item's `unit_price` is 4000; the same key replays.
  - 5 units gets the existing whole-pack P0001; an inactive SKU gets P0001; a repeated SKU gets P0001.
  - A ZSA without a territory gets P0001; with a territory outside the zone, 42501; with one inside, it lives.
  - A DSA gets 42501; a `TENANT_ADMIN` gets 42501.
  - A territory with no REGIONAL warehouse gets P0001; with two, the older is chosen.
  - `042` and `045` still pass (no `monvelo_` or `web_` table in the body).
- [ ] **Step 2: Run the file.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file, then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): place_trade_order for ZSA, ASA and TM at wholesale in whole packs (A6 §6.1)`

### Task 7: Financings, lines, shop limits, request, TM approval and cancel

**Files:**
- Create: `supabase/migrations/20261029130200_monvelo_financings.sql`, `supabase/tests/database/052_monvelo_financings.test.sql`
- Modify: `001_schema_shape.test.sql`

**Interfaces:**
- Consumes:
  - Task 5: settings, supply days, pledges, `monvelo_today`;
  - Task 6: trade orders;
  - Step 1: `monvelo_terms_at`, enrolments and `my_owned_shop_ids`;
  - Task 3: `monvelo_tenant_settings.max_limit` (not used yet).
- Produces:
  - **table `monvelo_financings`** (§4.4, every column now, so Steps 3–4 add no columns):
    - **identity:** `id`, `tenant_id`, `reference text unique check (reference ~ '^MV-[A-Z2-7]{8}$')`;
    - **links:** `shop_id`, `order_id`, `area_id`, `territory_id`, `raised_by`;
    - **amount and dates:** `principal numeric(15,2) check (> 0)`, `supply_date date`;
    - **status:** `status text check in ('REQUESTED','AWAITING_APPROVAL','OFFERED','CLAIMED','FUNDED','DELIVERED','REPAID_WITHIN_WINDOW','DEFAULTED_WITH_LATE_CHARGE','REPAID_LATE','EXPIRED','CANCELLED','REFUND_DUE')`;
    - **approval:** `approval_required boolean not null`, `approved_by`, `approved_at`;
    - **offer:** `offered_at`, `preferred_agent_id → monvelo_agents`, `preferred_window_ends_at`;
    - **claim:** `claimed_by_agent_id → monvelo_agents`, `claimed_by → profiles`, `claim_expires_at`, `pledge_id`;
    - **funding (Step 3):** `funder_agent_id → monvelo_agents`, `paystack_reference`, `funded_at`;
    - **delivery and repayment (Step 4):** `delivered_at`, `due_at`, `late_charge_amount numeric(15,2) not null default 0`, `outstanding numeric(15,2)`, `closed_at`;
    - **cancellation:** `cancelled_by`, `cancelled_at`, `cancel_reason`;
    - `created_at`, `updated_at`.
  - **Its constraints:**
    - FKs: `(tenant_id, order_id) → orders`, `(tenant_id, shop_id) → monvelo_shop_enrolments`, `(tenant_id, area_id) → areas`, `(tenant_id, territory_id) → territories`, `(tenant_id, pledge_id) → monvelo_pledges (tenant_id, id)`;
    - `check (status <> 'CLAIMED' or num_nulls(claimed_by_agent_id, claimed_by, claim_expires_at, pledge_id) = 0)`;
    - `check ((status = 'CANCELLED') = (cancelled_at is not null))`;
    - partial unique index `monvelo_financings_one_live_per_order on (tenant_id, order_id) where status not in ('CANCELLED','EXPIRED')`;
    - indexes on every FK, plus `(status, claim_expires_at)` and `(status, supply_date)`.
  - **Its guard trigger `monvelo_financings_guard()`:**
    - insert only as `REQUESTED`;
    - the identity columns are immutable: `tenant_id`, `reference`, `shop_id`, `order_id`, `area_id`, `territory_id`, `raised_by`, `principal`, `supply_date`, `created_at`;
    - status moves only along this whitelist (a self-update keeping the status is allowed):
      - `REQUESTED → OFFERED | AWAITING_APPROVAL | CANCELLED`;
      - `AWAITING_APPROVAL → OFFERED | CANCELLED | EXPIRED`;
      - `OFFERED → CLAIMED | CANCELLED | EXPIRED`;
      - `CLAIMED → OFFERED | FUNDED`;
      - `FUNDED → DELIVERED | REFUND_DUE`;
      - `DELIVERED → REPAID_WITHIN_WINDOW | DEFAULTED_WITH_LATE_CHARGE`;
      - `DEFAULTED_WITH_LATE_CHARGE → REPAID_LATE`;
    - anything else is P0001 `'a financing cannot move from <old> to <new>'`;
    - plus a new trigger function `monvelo_no_delete()` (P0001 `'Monvelo records are never deleted'`) on DELETE (row) and TRUNCATE (statement). Tasks 7–8 reuse it for lines, limit events and claims.
  - **table `monvelo_financing_lines`:**
    - `tenant_id`, `financing_id`;
    - `brand text`, `brand_key text not null check (brand_key = lower(btrim(brand)))`;
    - `amount numeric(15,2) check (> 0)`;
    - the terms columns `terms_id → monvelo_brand_terms`, `rebate_bps`, `interest_free_days`, `late_charge_bps`, `terms_locked_at`, all null until funding: `check (num_nulls(terms_id, rebate_bps, interest_free_days, late_charge_bps, terms_locked_at) in (0, 5))`;
    - pk `(financing_id, brand_key)`; FK `(tenant_id, financing_id) → monvelo_financings (tenant_id, id)`;
    - a trigger allows only that one null-to-set lock (Step 3) and refuses every other update, and every delete.
  - **table `monvelo_shop_limits`:**
    - `tenant_id`, `shop_id`, `brand_key`;
    - `limit_amount numeric(15,2) check (>= 0)`;
    - `status text check in ('ACTIVE','FROZEN')`;
    - `updated_at`;
    - pk `(tenant_id, shop_id, brand_key)`; FK `(tenant_id, shop_id) → monvelo_shop_enrolments`.
    - This is the per-brand current limit hanging off the enrolment (§16.6).
  - **table `monvelo_shop_limit_events`:**
    - `id`, `tenant_id`, `shop_id`, `brand_key`;
    - `kind text check in ('OPENED','GROWN','FROZEN','RESET')`;
    - `old_limit`, `new_limit`, `financing_id null`, `created_at`;
    - insert-only: the history.
  - **Internal helpers** (no grants):
    - `monvelo_shop_limit_for(p_tenant_id uuid, p_shop_id uuid, p_brand_key text) returns public.monvelo_shop_limits`: creates the row at `opening_limit` with an `OPENED` event on first use.
    - `monvelo_brand_exposure(p_tenant_id uuid, p_shop_id uuid, p_brand_key text, p_exclude uuid) returns numeric`: Σ line `amount` over the shop's financings in `AWAITING_APPROVAL, OFFERED, CLAIMED, FUNDED, DELIVERED, DEFAULTED_WITH_LATE_CHARGE`. Step 4 replaces it with outstanding-based exposure.
    - `monvelo_draw_reference() returns text`.
    - `monvelo_offer(p_id uuid) returns public.monvelo_financings`: moves the row to OFFERED and sets `offered_at`. It sets `preferred_agent_id` and `preferred_window_ends_at = now() + preferred_window_minutes` only when all of these hold; otherwise both stay null:
      - the shop's `preferred_agent_id` is ACTIVE;
      - it has a pledge for `(tenant, area, supply_date)`;
      - that pledge's `remaining` minus the principal of its other CLAIMED financings is ≥ `principal`.
  - **RPC** `request_monvelo_financing(p_idempotency_key uuid, p_order_id uuid) returns jsonb`. The caller is a `ZSA`, `ASA` or `TM`, and the checks run in this order, with these messages:
    1. The tenant is enabled: P0001 `'Monvelo is not switched on for this tenant'`.
    2. The order is in the tenant, `FIELD_SALES` and `PENDING`: P0001 `'only a pending trade order can be financed'`.
    3. `teafair_agent_id` is the caller: 42501 `'only the order's raiser requests its financing'`.
    4. There is no live financing: P0001 `'this order already has a Monvelo financing'`.
    5. The enrolment is ACTIVE: P0001 `'the shop is not enrolled in Monvelo'`.
    6. The shop is on the caller's beat: the ASA's `area_id` equals the enrolment's; a ZSA's zone contains the area's territory; the TM's territory is the area's. Else 42501 `'the shop is not on your beat'`.
    7. `order.territory_id` is the area's territory: P0001 `'the order was placed in another territory'`.
    8. The owner has a profile phone confirmed in `auth.users`: P0001 `'the shop owner has no verified phone'`.
    9. Today's ISO weekday is an active supply day for the area: P0001 `'today is not a supply day for this area'`.
    10. For each brand in the order, in `brand_key` order:
        - `monvelo_terms_at(tenant, brand, today)` exists, else P0001 `'<Brand> has no approved Monvelo terms'`;
        - no DEFAULTED financing of the shop carries the brand, and its limit is not FROZEN, else P0001 `'the shop cannot get new <Brand> credit until its overdue financing is cleared'`.

    Then, in one transaction:
    - insert the financing (`REQUESTED`, `principal = order.total_amount`, `supply_date = today`, `approval_required` = whether any brand's exposure + amount > `limit_amount`);
    - insert one line per brand, `amount` = Σ `line_total`;
    - move to `AWAITING_APPROVAL` (if approval is required) or call `monvelo_offer`;
    - audit.

    Returns `{financing_id, reference, status, principal, approval_required}`.
  - **RPC** `approve_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid) returns jsonb`:
    - the TM whose `territory_id` is the financing's, else 42501;
    - `AWAITING_APPROVAL` only (P0001 `'only a financing awaiting approval can be approved'`);
    - sets `approved_by` and `approved_at`, then `monvelo_offer`;
    - returns `{financing_id, status}`.
  - **RPC** `cancel_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_reason text) returns jsonb`:
    - the raiser or the territory's TM;
    - from `REQUESTED`, `AWAITING_APPROVAL` or `OFFERED` (else P0001 `'this financing can no longer be cancelled'`);
    - a reason is required.
  - **Policies** (`FOR SELECT`), with the helper `my_monvelo_territory_ids()` = the `territory_id` of the caller's ACTIVE `TM`/`ASM` memberships:
    - **`monvelo_financings`** is readable by:
      - the shop owner: `shop_id in (select my_owned_shop_ids())`;
      - fintech members: `claimed_by_agent_id in (select my_monvelo_agent_ids()) or funder_agent_id in (…)`;
      - the raiser: `raised_by = (select auth.uid())`;
      - the territory: `territory_id in (select my_monvelo_territory_ids())`;
      - the tenant book: `tenant_id in (select my_tenant_ids_with_role(array['ZSM','TENANT_ADMIN','CLIENT_SERVICE_MANAGER']))`;
      - logistics: `(status = 'FUNDED' and tenant_id in (select my_tenant_ids_with_role(array['LOGISTICS_MANAGER'])))`;
      - `(select is_monvelo_staff())`.
    - **Lines:** `(tenant_id, financing_id) in (select tenant_id, id from public.monvelo_financings)`.
    - **Limits and events:**
      - the shop owner;
      - `tenant_id in (select my_tenant_ids_with_role(array['ZSM','TM','ASM','ZSA','ASA','TENANT_ADMIN','CLIENT_SERVICE_MANAGER']))`;
      - Monvelo staff.

- **Credit rules are the tenant's (user, 2026-10-30; binding; A6 §7.2).**
  - Teafair is the platform provider and imposes no cash-order or trading-history threshold. There is no `min_cash_orders` and no `monvelo_cash_orders`.
  - A shop's credit is governed by the tenant's own configured settings: `opening_limit`, `max_limit`, `approval_cap`, and the new `limit_growth_bps`.
  - `limit_growth_bps` is a new `monvelo_tenant_settings` column: `integer not null default 0`, `check (0..10000)`. It is the rise after a financing is repaid within the window, capped by `max_limit`. Task 7 adds it to `set_monvelo_tenant_settings` as `p_limit_growth_bps integer default null` (null keeps the current value). As with every setting, it cites a `MONVELO_SETTINGS` decision.
  - The platform keeps only integrity checks: enrolment with consent, a verified owner phone, a GPS pin, approved brand terms, a supply day, and the freeze after a default.

- [ ] **Step 1: Write the failing tests** in `052`.
  - **Fixtures:**
    - tenant TEAFAIR-like `T1`, enabled, `opening_limit` 50000;
    - Purerigin and Tiger products;
    - Purerigin terms APPROVED today; Tiger has none;
    - area A1 with Thursday active; to make "today" a supply day, set the active day to `extract(isodow from monvelo_today())`;
    - an enrolled shop whose owner's phone is confirmed;
    - 3 PAID `FIELD_SALES` Purerigin orders in the last 6 weeks, inserted as postgres;
    - an ASA in A1 and the TM.
  - **The happy path:**
    - the ASA places 12 × Purerigin 200 ml (48000) and requests: `OFFERED`, `MV-` reference, `approval_required` false;
    - one line, Purerigin, 48000;
    - a `monvelo_shop_limits` row at 50000 with an OPENED event;
    - the same key replays.
  - **Above the limit:** a second order of 24 units (96000) gives `AWAITING_APPROVAL` (exposure 48000 + 96000 > 50000).
    - The TM approves, and it becomes OFFERED.
    - Another territory's TM gets 42501; an ASA approving gets 42501.
  - **Refusals, one each:**
    - the tenant is disabled;
    - a non-PENDING order;
    - another person's order (42501);
    - a second request for the same order;
    - a WITHDRAWN enrolment;
    - an ASA of another area (42501);
    - an owner with no verified phone;
    - not a supply day;
    - an order with Purerigin + Tiger, refused naming `Tiger` and writing no financing row (Review Focus 4);
    - a DEFAULTED Purerigin financing, inserted as postgres via the whitelist path.
  - **The preferred window:**
    - with the shop's preferred agent ACTIVE and pledged 150000 for today: `preferred_window_ends_at` ≈ now() + 10 min;
    - with no pledge: null.
  - **Cancel:** the raiser cancels an OFFERED financing, and the order can be requested again (the partial unique index).
  - **The guard, as postgres:**
    - `update monvelo_financings set principal = 1` gives P0001;
    - `OFFERED → FUNDED` gives P0001;
    - deleting a line gives P0001;
    - inserting as `OFFERED` gives P0001.
  - **Readers:**
    - the owner reads it;
    - the TENANT_ADMIN reads it;
    - an LM reads none (nothing is FUNDED);
    - a DSA reads none;
    - tenant B's ZSM reads none;
    - a fintech member with no claim reads none.
- [ ] **Step 2: Run the file.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file, then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): Monvelo financings, lines, shop limits with history, request, TM approval and cancel (A6 §4.4, §7.2)`

### Task 8: Claim, open offers and the expiry sweep

**Files:**
- Create: `supabase/migrations/20261029130300_monvelo_claims.sql`, `supabase/tests/database/053_monvelo_claims.test.sql`
- Modify: `001_schema_shape.test.sql`

**Interfaces:**
- Consumes: Task 7's `monvelo_financings` and `monvelo_offer`; Task 5's pledges, settings and agent location index.
- Produces:
  - **table `monvelo_financing_claims`:**
    - `id`, `tenant_id`, `financing_id`, `agent_id → monvelo_agents`, `claimed_by → profiles`, `pledge_id`;
    - `claimed_at`, `expires_at`;
    - `outcome text null check in ('LAPSED','FUNDED','EXPIRED')`, `ended_at`;
    - FK `(tenant_id, financing_id)`;
    - partial unique `on (financing_id) where outcome is null` (one open claim);
    - index `(financing_id, agent_id)`;
    - the trigger allows only `outcome`/`ended_at` to be set once, and refuses deletes;
    - policy: the agent's members, the financing's readers (`(tenant_id, financing_id) in (select tenant_id, id from public.monvelo_financings)`), and Monvelo staff.
  - **RPC** `claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid) returns jsonb`. The caller must be an ACTIVE member of `p_agent_id` (42501). Lock the financing with `for update`, then check in this order:
    1. Status is `OFFERED`: P0001 `'this request is no longer open'`.
    2. The agent is ACTIVE: P0001 `'the agent is not active'`.
    3. The enrolment is ACTIVE: P0001 `'the shop is no longer enrolled'`.
    4. There is no LAPSED claim by this agent on this financing: P0001 `'your claim on this request lapsed; another agent may claim it'`.
    5. During the preferred window, only `preferred_agent_id`: P0001 `'the shop's preferred agent has first claim until <HH24:MI Lagos>'`.
    6. Distance: the preferred agent is exempt; others need `st_dwithin(agent.location, shop.location::geography, offer_radius_m)`, else P0001 `'this shop is outside your area'`.
    7. Pledge: the agent's pledge for `(tenant, area, supply_date)`, locked, with `remaining` − Σ principal of the agent's other CLAIMED financings on that pledge ≥ principal. Else P0001 `'pledge enough funds for this area and day first'`.
    8. Caps: `principal <= per_financing_cap`, else P0001 `'this request is above your per-financing cap'`. Σ principal of the agent's CLAIMED financings plus those it funded today (Lagos), plus this one, `<= daily_cap`, else P0001 `'this request would pass your daily cap'`.

    Then:
    - set `CLAIMED`, `claimed_by_agent_id`, `claimed_by`, `claim_expires_at = now() + claim_minutes`, `pledge_id`;
    - clear `preferred_window_ends_at`;
    - insert the claim row;
    - audit to the financing's tenant.

    Returns `{financing_id, reference, status, claim_expires_at, principal}`.
  - **Read RPC** `monvelo_open_offers(p_agent_id uuid) returns table (financing_id uuid, reference text, shop_name text, shop_code text, area_name text, principal numeric, distance_m integer, supply_date date, preferred_until timestamptz)`:
    - members only;
    - shows `OFFERED` financings of today whose enrolment is ACTIVE, which the agent could claim now by rules 4–7, or which are in this agent's own preferred window;
    - never the owner's name or phone;
    - `stable security definer`; granted to `authenticated`.
  - **Function** `monvelo_sweep_offers() returns jsonb`, with no grant. Two passes, in this order:
    1. CLAIMED with `claim_expires_at <= now()` → OFFERED (claim `outcome 'LAPSED'`; claim fields cleared; no new preferred window).
    2. OFFERED or AWAITING_APPROVAL with `now() >= end of supply_date (Lagos)` → EXPIRED.

    It audits each change as `CRON` and returns `{lapsed, expired}`. The trade order is left PENDING.
  - **Cron** `select cron.schedule('monvelo-offer-sweep', '* * * * *', $$select public.monvelo_sweep_offers()$$);`: pure SQL, no Vault.

- [ ] **Step 1: Write the failing tests** in `053`. Fixtures as in `052`, plus:
  - agent P (preferred, 400 m, pledged 150000);
  - agent N (600 m, pledged 100000);
  - agent F (5 km, pledged 100000);
  - caps of 500000 / 200000.

  Cases:
  - **The preferred window:**
    - N claims during the window: P0001 naming the time;
    - P claims: CLAIMED, `claim_expires_at` ≈ now() + 15 min, one open claim row;
    - P's replay returns the same response.
  - **One at a time:**
    - after P's claim, N's claim is P0001 `'this request is no longer open'`;
    - `select count(*) from monvelo_financing_claims where outcome is null` is 1 (Review Focus 3).
  - **Lapse:**
    - as postgres, set `claim_expires_at = now() - interval '1 second'`, then `monvelo_sweep_offers()` gives `{lapsed:1}`, OFFERED, and claim outcome LAPSED;
    - P re-claims: P0001 (lapsed);
    - N claims: CLAIMED (the window is gone).
  - **Distance and money:**
    - F (5 km) on a new financing after the window: P0001 `'this shop is outside your area'`;
    - an agent with no pledge: P0001;
    - an agent whose pledge is committed to another CLAIMED financing: P0001;
    - a `per_financing_cap` of 10000: P0001.
  - **Open offers:**
    - for N, the new financing appears, with `shop_code` and `distance_m`, and no owner column;
    - `pg_get_function_result` holds no `owner` or `phone`;
    - for F, it does not appear.
  - **Expiry:**
    - as postgres, set `supply_date = monvelo_today() - 1` on an OFFERED and an AWAITING_APPROVAL financing; the sweep makes both EXPIRED;
    - a CLAIMED financing of yesterday whose claim has lapsed ends EXPIRED in one sweep (Review Focus 3).
  - **Cron:** `select schedule from cron.job where jobname = 'monvelo-offer-sweep'` is `* * * * *`, and its command names `monvelo_sweep_offers`.
  - **Security:**
    - a non-member claiming for agent P: 42501;
    - a ZSM calling `monvelo_sweep_offers`: 42501 (`has_function_privilege('authenticated', …, 'execute')` is false).
  - **Audit:** sweep rows have `source = 'CRON'` and a non-null `teafair_agent_id`.
- [ ] **Step 2: Run the file.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file and `018`** (D1's job list must still be 3 named jobs), **then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): Monvelo claims with the allocation rule, open offers and the minute sweep (A6 §7.1)`

### Task 9: Financing-status read and the tenant ledger table

**Files:**
- Create: `supabase/migrations/20261029130400_monvelo_status_ledger.sql`, `supabase/tests/database/054_monvelo_status_ledger.test.sql`
- Modify: `001_schema_shape.test.sql`

**Interfaces:**
- Consumes: Task 7's financings; `my_owned_shop_ids`.
- Produces:
  - **Read RPC** `monvelo_order_financing_status(p_order_ids uuid[]) returns table (order_id uuid, financing_state text, financing_id uuid, reference text, principal numeric)`:
    - `stable security definer`;
    - caller: `assert_tenant_role(null)`;
    - at most 200 ids (P0001);
    - only orders of the caller's active tenant are returned. A `RETAIL_SHOP_OWNER` gets only orders of shops they own, and a `POS_AGENT` gets none;
    - `financing_state` is the live financing's `status`, else `'NONE'`;
    - granted to `authenticated` (§16.6).
  - **table `monvelo_tenant_ledger_entries`** (§16.5):
    - `id`, `tenant_id`;
    - `business_date date not null`;
    - `entry_type text check in ('FUNDED_GROSS','REBATE','FEE','REFUND','REMITTANCE')`;
    - `financing_id uuid null`, FK `(tenant_id, financing_id) → monvelo_financings`;
    - `amount numeric(15,2) not null`, `created_at`;
    - CHECK `monvelo_tenant_ledger_entries_sign`: `(entry_type = 'FUNDED_GROSS' and amount > 0) or (entry_type <> 'FUNDED_GROSS' and amount < 0)`;
    - indexes `(tenant_id, business_date)` and `(financing_id)`;
    - trigger function `monvelo_ledger_insert_only()` on BEFORE UPDATE/DELETE (row) and TRUNCATE (statement): P0001 `'ledger entries are insert-only'`;
    - `revoke all on … from anon, authenticated, service_role`, then `grant select … to authenticated`;
    - policy: `tenant_id in (select my_tenant_ids_with_role(array['TENANT_ADMIN','CLIENT_SERVICE_MANAGER','ZSM'])) or (select is_monvelo_staff())`.
    - **No writer in Step 2.** Steps 3 and 5 add the writers (funding, rebate, fee, refund, remittance), and Step 5 adds `rebate_payable_id` with its FK.

- [ ] **Step 1: Write the failing tests** in `054`:
  - **Status:**
    - for a cash `FIELD_SALES` order and an OFFERED-financed one, the ZSM gets `NONE` and `OFFERED`;
    - an order id of tenant B is omitted;
    - 201 ids gives P0001;
    - the shop owner gets their own order only.
  - **Ledger, as postgres:**
    - insert `FUNDED_GROSS 48000` (lives);
    - `REBATE −4800` (lives);
    - `REBATE 4800` gives 23514;
    - `FUNDED_GROSS −1` gives 23514;
    - `FEE 0` gives 23514;
    - `update … set amount = 1` gives P0001;
    - `delete` gives P0001;
    - `truncate` gives P0001.
  - **Ledger grants:** `has_table_privilege('service_role', 'public.monvelo_tenant_ledger_entries', 'UPDATE')` is false, and the same for DELETE; `authenticated` INSERT is false.
  - **Ledger readers:**
    - the TENANT_ADMIN, the CSM, a ZSM and MONVELO_FINANCE read the rows;
    - a TM, an ASA and tenant B's ZSM read none.
- [ ] **Step 2: Run the file.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run the file, then the green gate.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): order financing status read and the insert-only tenant ledger (A6 §16.5, §16.6)`

### Task 10: PostgREST integration, docs and full verification

**Files:**
- Modify:
  - `supabase/functions/_tests/gateway.integration.ts`: one test, after the existing Monvelo tests;
  - `supabase/CLAUDE.md`, `CLAUDE.md`.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the integration test** `"monvelo step 2 over PostgREST: a ZSA's trade order is requested, offered and claimed"`.
  - **Admin inserts:**
    - settings enabled;
    - Purerigin terms APPROVED;
    - a supply day for today's ISO weekday;
    - an ACTIVE agent with a member profile, caps and a pledge;
    - reuse the shop enrolled by the `monvelo-shop-consent` test.
  - **As the users:**
    - the ZSA calls `rpc("place_trade_order", {p_idempotency_key, p_shop_id, p_lines, p_territory_id})`, then `rpc("request_monvelo_financing", …)`, and gets OFFERED;
    - the member calls `rpc("monvelo_open_offers", {p_agent_id})`, sees it, then `rpc("claim_monvelo_financing", …)`, and gets CLAIMED.
  - **The CSM over PostgREST:** `rpc("approve_monvelo_brand_terms", {p_idempotency_key, p_terms_id, p_decision_id})` resolves the 3-argument function, which proves no overload remains.
- [ ] **Step 2: Run the green gate.** Expected: `Result: PASS` (54 files), 0 failed, and integration 0 failed. Note the assertion and migration counts.
- [ ] **Step 3: Update the docs.**
  - **`supabase/CLAUDE.md`:**
    - status rows for "Monvelo (A6) Step 1c: tenant representation" and "Monvelo (A6) Step 2: financing ledger and allocation", both "done (local)";
    - a section listing the tables, RPCs, the `monvelo-offer-sweep` cron job, the bridging rule, the contact-report send deferral (deliveries stay PENDING until Step 6), the tenant-governed credit rule (A6 §7.2, 2026-10-30) and the decision subjects.
  - **`CLAUDE.md`:** the counts, plus "Step 1c and Step 2 built locally, not pushed".
- [ ] **Step 4: Commit.** `docs: Monvelo Step 1c and Step 2`. Do not merge into `main`. Do not push.

---

## Calls made in this plan

Each call says what it costs if it is wrong.

1. **Contact-report sending is deferred to Step 6.** Step 1c records recipients and writes one PENDING `contact_report_deliveries` row each, which is the send log, but it sends nothing.
   - **Why:** the A5 router sends only Meta-approved WhatsApp templates and has no email path, and a contact report needs a new utility template (Meta approval, §10) plus Resend for email. Step 6 owns templates and adds a service-role drain that sends through the router and moves deliveries to SENT or FAILED.
   - **Cost if wrong:** tenants' contacts get no copy until Step 6; reports are still readable in the app by the TENANT_ADMIN. Moving the send earlier is one gateway plus a template name.
2. **The CSM is appointed by a new `appoint_client_service_manager(p_idempotency_key, p_tenant_id, p_phone_number)`, `PLATFORM_SUPER_ADMIN` only.** It takes a tenant id, under the platform-role exception documented for `record_monvelo_fee_terms`, because ZSMs are appointed by service-role tooling today and there is no platform RPC to extend.
   - **Cost if wrong:** one RPC to drop, if the user prefers service-role tooling.
3. **Decisions carry a `subject` (`BRAND_TERMS`, `MONVELO_SETTINGS`, `CATALOGUE`, `STOCK`, `OTHER`), and a citation must match it.**
   - **Cost if wrong:** a CSM cannot cite an `OTHER` decision for terms and must file a correction with the right subject. Relaxing it means dropping one comparison.
4. **Recipient addresses have no column grant;** readers see `address_hint`.
   - **Cost if wrong:** the TENANT_ADMIN cannot see full contact addresses in the app; a column grant fixes it.
5. **"Platform staff" who read contact reports** means any profile with a `platform_role` (`is_platform_staff()`), including `MONVELO_FINANCE`.
   - **Cost if wrong:** finance can read client meeting notes; narrowing the role list is one function.
6. **The §7.2 thresholds live in a migration-only `monvelo_platform_settings` row:** radius 1000 m, windows of 10 and 15 minutes. (The cash-order threshold was removed by the user on 2026-10-30.) The cash-order count needs `FIELD_SALES`/`RETAIL` orders that are `PAID`, `IN_TRANSIT` or `DELIVERED`, and nothing marks a trade order PAID until Spec C.
   - **Superseded (user, 2026-10-30):** no cash-order threshold; credit follows the tenant's own settings (A6 §7.2).
7. **`max_limit` (the tenant's cap on limit growth) is added to `monvelo_tenant_settings` in Task 3,** so the settings RPC is recreated once; Step 4 reads it.
   - **Cost if wrong:** one unused column until Step 4.
8. **Per-brand limits are rows keyed to the enrolment (`monvelo_shop_limits`), with an insert-only `monvelo_shop_limit_events` history,** not columns on the enrolment. §4.1 makes limits per brand, and §16.6 asks for history.
   - **Cost if wrong:** low; it is a reshaping before any data exists.
9. **Exposure for the limit check** is Σ line amounts of the shop's financings from AWAITING_APPROVAL through DEFAULTED. Step 4 swaps in outstanding-based exposure.
   - **Cost if wrong:** shops repaying in part look more exposed until Step 4, so more requests go to the TM.
10. **`place_trade_order` takes an optional `p_territory_id`** (required for a ZSA). It derives ASA and TM territories from their anchors, because it is RTM core and may not read the enrolment (the 045 guard), and `tenant_shop_coverage` has no writer.
    - **Cost if wrong:** one extra parameter beyond §6.1. Spec C may move the derivation to coverage.
11. **The trade order's warehouse is the territory's REGIONAL warehouse, the oldest if several,** not `territories.web_fulfilment_warehouse_id`, which belongs to the web domain (§15.3).
    - **Cost if wrong:** in a territory with two regional warehouses, a trade order ships from the wrong one. A trade-warehouse column (Spec C) fixes it.
12. **A request on a day that is not an active supply day for the area is refused,** rather than offered and left to expire unpledged.
    - **Cost if wrong:** ad hoc requests are impossible; the TM sets a supply day first.
13. **A request is all-or-nothing across brands:** one ineligible brand refuses the whole order.
    - **Cost if wrong:** the field must split mixed orders by hand.
14. **Rows are inserted as REQUESTED and moved in the same transaction;** nothing rests in REQUESTED in Step 2.
    - **Cost if wrong:** none beyond one extra update.
15. **AWAITING_APPROVAL also expires at the end of the supply day** (the status machine names only OFFERED), because supply is same day.
    - **Cost if wrong:** a TM cannot approve yesterday's request; the raiser requests again.
16. **The claim names its agent (`p_agent_id`), checked against membership,** because a profile may belong to more than one agent.
    - **Cost if wrong:** one parameter.
17. **The preferred agent is exempt from the radius,** inside and after the window, because the shop chose them.
    - **Cost if wrong:** a distant preferred agent can win against nearer ones; adding the radius check is one line.
18. **A pledge is debited at funding (Step 3), as §5 says,** but a claim must fit within `remaining` minus the agent's other open claims on that pledge.
    - **Cost if wrong:** none for money, because funding still debits once.
19. **The daily cap counts open claims plus today's fundings.**
    - **Cost if wrong:** an agent with many lapsing claims is briefly capped early.
20. **An expired or cancelled financing leaves its trade order PENDING,** because Monvelo writes only Monvelo tables plus the order it created, and Spec C owns order cancellation.
    - **Cost if wrong:** stale PENDING trade orders accumulate until Spec C adds a cancel; a request can reuse them.
21. **The financing-status read is an RPC, not a `security_invoker` view.** A view would show a financed order as `NONE` to a caller who can read `orders` but not `monvelo_financings` (a DSA).
    - **Cost if wrong:** clients call an RPC instead of selecting from a view.
22. **Fintech agents learn about supply days through `monvelo_supply_days_near`** (totals only, within the radius), so they have area ids to pledge against before Step 6's notices.
    - **Cost if wrong:** one read RPC that Step 6 may reuse or replace.
23. **The tenant ledger has no `rebate_payable_id` until Step 5,** which creates the payables table it points at.
    - **Cost if wrong:** Step 5 adds a column, which it would do anyway.
24. **The LOGISTICS_MANAGER reads only FUNDED financings, and the TENANT_ADMIN reads what any tenant member reads** (orders, catalogue, areas), plus the book, the reports and the ledger.
    - **Cost if wrong:** if the TENANT_ADMIN should see less (for example, orders), existing `my_tenant_ids()` policies need narrowing, which is wider than this plan.
25. **No `monvelo_` table is readable by the CSM, LM or TENANT_ADMIN** beyond what is listed: never agents, pledges or claims, because tenants never see or steer lenders (§16.2.2).
    - **Cost if wrong:** small; an added policy branch.
26. **The `orders.agent_id` of a trade order is the raiser,** as Spec A's selling agent, and so is `teafair_agent_id`.
    - **Cost if wrong:** a data fix on PENDING orders only.
