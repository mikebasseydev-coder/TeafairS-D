# Domain separation and renames (A6 §15): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the web storefront and Monvelo their own names. These are the four web renames:
- `fintech_partners` → `web_pos_partners`;
- `fintech_terminals` → `web_pos_venues`;
- `agent_codes` → `web_referral_codes`;
- `commission_records` → `web_commissions`.

The changes also cover:
- the `FINTECH_AGENT` role becomes `POS_AGENT`;
- the ₦500 bounty is replaced by a tenant commission rate in basis points (0 everywhere);
- `fintech-commission-release` becomes `web-commission-release`;
- `_shared/fintech-liquidity/` becomes `_shared/payments/`;
- `monvelo_fintech_*` become `monvelo_agents` and `monvelo_agent_members`;
- `fintech_advances` is dropped.

The behaviour is unchanged except for the commission rule.

**Architecture:**
- Renames run in new migrations through `ALTER … RENAME`, so rows, grants, column privileges and RLS carry over. Applied migrations are never edited, because they are the remote's history.
- PL/pgSQL and plain SQL bodies are not dependency-tracked. Each body that names an old identifier is recreated in the same migration as its rename. Start from the live `pg_get_functiondef(...)` (the latest definition), not from an old migration file.
- A pgTAP guard scans `pg_proc.prosrc` and the catalog names for old identifiers. It grows with each task.
- Spec A §9 holds throughout.

**Tech Stack:** Postgres 17 migrations (hand-written), pgTAP, Deno Edge Functions. No Prisma.

**Spec:** `docs/superpowers/specs/2026-10-28-addendum-a6-monvelo-design.md` §15, which has the full mapping table. This plan replaces `2026-10-28-monvelo-step1b-fintech-replacement.md` (deleted; it is in git history). It also absorbs A6 Step 1 Task 7 (the Step 1 docs).

**Where this sits.** It runs on branch `feat/monvelo-step1`, on top of Step 1 Tasks 1–6 (local DB: 39 pgTAP files, 1893 PASS; deno 328 passed). Nothing merges into `main`, and nothing is pushed or deployed.

## Global Constraints

- **Names:** exactly as A6 §15.4. If a name is not in that table, do not rename it. If a body names an object the table does not list, stop and ask.
- **Migrations:** `20261028130000`–`20261028130500`. pgTAP files continue at `042_`. Never rename or edit a file under `supabase/migrations/` that already exists.
- **Recreated functions:** same signature, `security definer` as before, `set search_path = public, pg_temp`. Re-issue the grants the function had (`select proacl from pg_proc` before the change). Only `upsert_web_referral_code` and `set_web_pos_venue` are dropped and created; everything else is `create or replace`.
- **Drops never use CASCADE.**
- **Wire contract:**
  - the D1 split keys `subaccount_code`, `commission_bps` and `partner_share` are kept;
  - the Paystack metadata key `agent_code` is kept;
  - no public (teafairweb) response changes;
  - the one staff response change is `order-dispute-evidence` `order.agent_code_id` → `order.referral_code_id` (Task 3).
- **Monvelo boundary:** Monvelo objects change only in Task 5. No web function reads a `monvelo_` table, and no Monvelo function reads a `web_` table.
- **Settings are written by migration only:** `web_agent_commission_bps` is 0 for every tenant. Tests may set it as `postgres` or the service role.
- **After every `supabase db reset`**, recreate the Vault secret:
  `psql -qAt -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "select vault.create_secret('local-gateway-secret', 'gateway_secret');"`
- **Every task ends green:**
  - `supabase db reset`, the Vault secret, then `supabase test db`: `Result: PASS`;
  - `deno test --allow-all supabase/functions/`: 0 failed.

  Each task also updates `supabase/functions/_tests/gateway.integration.ts` for what it renames, but the integration suite is a gate only in Task 7.
- **Forbidden:**
  - `git push`, `supabase db push`, `supabase functions deploy` / `delete`, `supabase config push`;
  - remote secrets, merging into `main`;
  - touching `FIGMA.md` or any `.env` file. The tracked `supabase/functions/.env.example` may be edited.
- **Commits:** every message ends with a blank line, then `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Stale bodies.** Every body that named an old identifier is recreated, and the guard (042) proves it.
   - `terminal_id` is tested after stripping `network_terminal_id`.
   - `commission_bps` is banned only as a column access (`\.commission_bps`), because the wire key stays.

   Owned by every task; the guard is complete after Task 6.
2. **Nothing but names changes**, apart from the commission rule.
   - Task 3 is a pure rename: every pre-existing assertion passes with names substituted and no expected value changed.
   - Task 4 alone changes amounts, and only where the old fixtures used `commission_bps` or the bounty.
3. **Commission on the wrong orders** (Task 4). Even at a non-zero tenant rate, these get `split` null, no `payments.split_*` and no `web_commissions` row:
   - codeless orders;
   - DSA/DSM links;
   - a SUSPENDED partner;
   - a share that rounds to 0.

   A rate of 0 has the same result. The share never includes the fare.
4. **Grants survive.**
   - `authenticated` can still SELECT `payments.web_pos_partner_id` and `web_pos_venue_id`, and still cannot SELECT `monvelo_agents.settlement_account_number`.
   - The renamed RPCs keep exactly their old EXECUTE grants.

   Owned by Tasks 3 and 5.
5. **The boundary** (Task 5, file 045):
   - no body names both a `public.web_` and a `public.monvelo_` table;
   - no FK joins the two domains.
6. **The Edge Function rename** (Task 6). Every `index.ts` type-checks (`deno check`). The cron job calls `web-commission-release`, and nothing names `fintech-liquidity` or `fintech-commission-release` outside historical migrations and docs history.

---

## File map

| File | Responsibility |
|---|---|
| `supabase/migrations/20261028130000_pos_agent_role.sql` | `FINTECH_AGENT` → `POS_AGENT`; recreate `issue_otp`, `verify_otp`, `invite_tenant_user`, `set_terminal_venue` |
| `supabase/migrations/20261028130100_drop_fintech_advances.sql` | drop `fintech_advances` |
| `supabase/migrations/20261028130200_web_domain_renames.sql` | the four web tables and the `payments`/`orders` columns: tables, columns, constraints, indexes, policies, triggers; recreate the web and D1 bodies; replace `upsert_agent_code` and `set_terminal_venue` |
| `supabase/migrations/20261028130300_web_agent_commission.sql` | `web_agent_commission_bps` in, `web_agent_bounty` and `web_pos_partners.commission_bps` out; `web_price_cart` |
| `supabase/migrations/20261028130400_monvelo_agent_renames.sql` | `monvelo_agents`, `monvelo_agent_members` and their objects; the nine Monvelo bodies |
| `supabase/migrations/20261028130500_web_commission_release_cron.sql` | unschedule `fintech-commission-release`, schedule `web-commission-release` |
| `supabase/tests/database/042_domain_separation_guard.test.sql` | the guard (A6 §15.7), grown by Tasks 1–6 |
| `supabase/tests/database/043_web_domain_renames.test.sql` | Task 3 shape, grants and rename smoke tests |
| `supabase/tests/database/044_web_agent_commission.test.sql` | Task 4: the commission rule |
| `supabase/tests/database/045_monvelo_agent_renames.test.sql` | Task 5: shape, grants, boundary |
| `supabase/tests/database/040_monvelo_fintech_agents.test.sql` | `git mv` to `040_monvelo_agents.test.sql` (Task 5) |
| `supabase/tests/database/001`–`027`, `034`, `041` | fixture and assertion updates, per task |
| `supabase/functions/_shared/fintech-liquidity/` → `_shared/payments/` | `git mv` (Task 6) |
| `supabase/functions/fintech-commission-release/` → `web-commission-release/` | `git mv` (Task 6) |
| `supabase/functions/{process-payment,reconcile-funds,web-checkout}/*`, `_shared/monvelo/paystack-resolve.ts` | import paths (Task 6); `web-checkout/handler.test.ts` fixture key (Task 3) |
| `supabase/functions/_tests/gateway.integration.ts` | fixtures per task |
| `supabase/config.toml`, `supabase/functions/.env.example` | function name (Task 6) |
| `supabase/CLAUDE.md`, `CLAUDE.md` | Task 7 |

**Fixture substitutions.** Tasks 3–5 apply these to test files. They are not a blind `sed`: `terminal_id` means two different things.

| In | Old | New |
|---|---|---|
| any | `fintech_partners` / `fintech_terminals` / `agent_codes` / `commission_records` | `web_pos_partners` / `web_pos_venues` / `web_referral_codes` / `web_commissions` |
| any | `fintech_partner_id` / `fintech_terminal_id` | `web_pos_partner_id` / `web_pos_venue_id` |
| `orders` | `agent_code_id` / `attributed_terminal_id` | `referral_code_id` / `attributed_venue_id` |
| `agent_codes` rows and `upsert_agent_code` calls | `terminal_id` / `p_terminal_id` | `venue_id` / `p_venue_id` |
| `fintech_terminals` rows | `terminal_id` (the device id) | `network_terminal_id` |
| `set_terminal_venue` calls | `p_terminal_id` | `p_venue_id` |
| RPC names | `upsert_agent_code` / `set_terminal_venue` | `upsert_web_referral_code` / `set_web_pos_venue` |
| Task 5 | `monvelo_fintech_agents` / `monvelo_fintech_members` | `monvelo_agents` / `monvelo_agent_members` |

---

### Task 1: `FINTECH_AGENT` becomes `POS_AGENT`

**Files:**
- Create: `supabase/migrations/20261028130000_pos_agent_role.sql`, `supabase/tests/database/042_domain_separation_guard.test.sql`
- Modify: every `'FINTECH_AGENT'` literal in tests `001`, `010`–`014`, `020`, `023`–`026`, and in `gateway.integration.ts` (the IT membership)

**Interfaces:**
- Produces:
  - `tenant_role_enum` labels `ZSM, TM, ASM, DSM, DSA, POS_AGENT, RETAIL_SHOP_OWNER, ZSA, ASA`;
  - the bodies of `issue_otp`, `verify_otp`, `invite_tenant_user` and `set_terminal_venue` name `'POS_AGENT'`, with signatures and grants unchanged;
  - the guard file with its scan helper.
- Guard helper (in the test file): `pg_temp.bodies_matching(p_pattern text) returns text[]`, the sorted `proname`s in `public` whose `regexp_replace(prosrc, 'network_terminal_id', '', 'g') ~ p_pattern`. Each guard assertion is `is(pg_temp.bodies_matching('<pattern>'), null::text[], 'no body names <pattern>')`.

- [ ] **Step 1: Write the failing tests.**
  - In 042, add the guard for `FINTECH_AGENT`, plus `enum_has_labels('public','tenant_role_enum', array[…POS_AGENT…])`.
  - In 001, change the role-enum assertion to `POS_AGENT`.
  - Replace the literal in the listed tests and the integration fixture.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL. 042 lists the four functions, and the fixtures fail with `invalid input value for enum tenant_role_enum: "POS_AGENT"`.
- [ ] **Step 3: Write the migration.**
  - `alter type public.tenant_role_enum rename value 'FINTECH_AGENT' to 'POS_AGENT';`
  - Then `create or replace` the four functions, from `pg_get_functiondef` with only the literal changed.
  - `tenant_users_territory_roles_have_territory` follows by itself.
  - Also grep `supabase/functions` for `FINTECH_AGENT`. Expected: only the integration fixture, already changed.
- [ ] **Step 4: Run** the reset, the Vault secret, `supabase test db`, then `deno test --allow-all supabase/functions/`. Expected: PASS; 0 failed.
- [ ] **Step 5: Commit.** `feat(db): FINTECH_AGENT renamed POS_AGENT (A6 §15)`

### Task 2: Drop `fintech_advances`

**Files:**
- Create: `supabase/migrations/20261028130100_drop_fintech_advances.sql`
- Modify: `042`; `001_schema_shape.test.sql` and `002_invariants.test.sql` (remove the `fintech_advances` assertions and lower each `plan(n)` by the number removed)

**Interfaces:**
- Produces: no `fintech_advances` table, policy, index or trigger. The `pos_network_enum` stays: `web_pos_partners` and `monvelo_agents` use it.

- [ ] **Step 1: Write the failing tests.** In 042, add `hasnt_table('public','fintech_advances')` and the body guard for `fintech_advances`. Remove the advance assertions from 001 and 002.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL at the `hasnt_table`.
- [ ] **Step 3: Write the migration:** `drop table public.fintech_advances;` (no CASCADE). Before writing it, confirm that no FK and no body names the table:
  ```sql
  select conname from pg_constraint where confrelid = 'public.fintech_advances'::regclass;
  ```
- [ ] **Step 4: Run** the reset, the Vault secret, `supabase test db` and `deno test`. Expected: PASS; 0 failed.
- [ ] **Step 5: Commit.** `feat(db): drop fintech_advances; Monvelo financing replaces it (A6 §15.6)`

### Task 3: Web domain renames

**Files:**
- Create: `supabase/migrations/20261028130200_web_domain_renames.sql`, `supabase/tests/database/043_web_domain_renames.test.sql`
- Modify:
  - `042`;
  - tests `001`, `002`, `010`–`017`, `022`, `027`, `034` (per the substitution table);
  - `supabase/functions/web-checkout/handler.test.ts` (the quote fixture key `fintech_partner_id` → `web_pos_partner_id`);
  - `gateway.integration.ts`: the `from("…")` table names, the `rpc("upsert_web_referral_code", { …, p_venue_id })` call, and `attributed_venue_id` in the POS checkout test.

**Interfaces:**
- Consumes: Task 1's bodies, as the current `pg_get_functiondef`.
- Produces: every web row of A6 §15.4 (tables, columns, constraints, indexes, policies, triggers):
  - **Tables and columns.** `alter table … rename to`, then `rename column`:
    - `payments`: `web_pos_partner_id`, `web_pos_venue_id`;
    - `web_commissions.web_pos_partner_id`;
    - `web_referral_codes.venue_id`;
    - `web_pos_venues.network_terminal_id`;
    - `orders`: `referral_code_id`, `attributed_venue_id`.
  - **Constraints, indexes, policies, triggers:** `alter table … rename constraint`, `alter index … rename to`, `alter policy … on … rename to`, `alter trigger … on … rename to`.
  - **Function** `web_referral_codes_no_discount()`, by `alter function public.agent_codes_no_discount() rename to …`.
  - **RPC** `upsert_web_referral_code(p_idempotency_key uuid, p_code text, p_agent_id uuid, p_venue_id uuid, p_discount_type text, p_discount_value numeric, p_max_redemptions integer, p_expires_at timestamptz, p_is_active boolean) returns jsonb`:
    - replaces `upsert_agent_code` (drop, then create) with the same rules, idempotency op `upsert_web_referral_code`, and audit entity `web_referral_codes`;
    - grant execute to `authenticated` and `service_role`.
  - **RPC** `set_web_pos_venue(p_idempotency_key uuid, p_venue_id uuid, p_venue_channel venue_channel_enum, p_venue_name text, p_address_text text, p_state text, p_lga text, p_latitude double precision, p_longitude double precision, p_operating_hours jsonb) returns jsonb`:
    - replaces `set_terminal_venue` with the same rules (ZSM, TM, or the venue's own `POS_AGENT`) and the same grants.
  - **`create or replace`** with the new names and the same signatures (rowtype parameters are written `public.web_referral_codes`):
    - `web_price_cart`: still the per-partner rate and bounty, now read from `web_pos_partners`; the split key becomes `web_pos_partner_id`;
    - `web_resolve_code`, `web_route_try`, `web_storefront_code`, `storefront_catalogue`, `storefront_locations`, `quote_web_order`;
    - `place_web_order`;
    - `get_order_dispute_evidence`: the output key becomes `referral_code_id`;
    - `settle_paystack_payment`, `apply_paystack_refund`, `release_commission`, `list_unsettled_subaccounts`, `expire_unsettled_commissions`.
  - **Comments** on the renamed tables and columns are rewritten wherever they name the old objects.

- [ ] **Step 1: Write the failing tests.**
  - **042:** add the body guards for `fintech_partners`, `fintech_terminals`, `agent_codes`, `commission_records`, `fintech_partner_id`, `fintech_terminal_id`, `agent_code_id`, `attributed_terminal_id`, `upsert_agent_code`, `set_terminal_venue`, and `terminal_id` (stripped). Add the catalog-name guard for constraints, indexes, policies and triggers in `public` matching `(^|_)fintech_(partner|terminal|advance)|agent_code|commission_records`. The narrower `fintech` pattern spares `monvelo_fintech_*` until Task 5, which widens the guard to the final `fintech|agent_code|commission_records|monvelo_fintech` (A6 §15.7).
  - **043, shape:**
    - `has_table` for the four new tables; `hasnt_table` for the three old ones still present;
    - `has_column` / `hasnt_column` for each renamed column;
    - `policies_are` on each of the four tables;
    - `has_trigger` for `web_referral_codes_no_discount`, `web_commissions_support_ticket_ins` and `…_upd`;
    - `fk_ok('public','orders',array['tenant_id','attributed_venue_id'],'public','web_pos_venues',array['tenant_id','id'])`, the same for `orders.referral_code_id`, `payments.web_pos_partner_id`, `payments.web_pos_venue_id`, `web_commissions.web_pos_partner_id` and `web_referral_codes.venue_id`.
  - **043, grants:**
    - `has_column_privilege('authenticated','public.payments','web_pos_partner_id','SELECT')`, and the same for `web_pos_venue_id`, are true;
    - `has_function('public','upsert_web_referral_code', …)` and `has_function('public','set_web_pos_venue', …)` with their arg types; `hasnt_function` for the two old names;
    - `function_privs_are('public','upsert_web_referral_code', …, 'authenticated', array['EXECUTE'])`, and the same for `set_web_pos_venue`; `anon` gets none.
  - **043, smoke (one tenant, TM, POS_AGENT member, partner and venue, as `postgres` fixtures):**
    - the TM issues a code through `upsert_web_referral_code` with `p_venue_id`; the same key replays;
    - a TM of another territory gets 42501, as in 011;
    - the POS_AGENT sets the venue through `set_web_pos_venue`;
    - `storefront_catalogue(code)` returns the venue `{name, channel}`;
    - a POS_AGENT-route `place_web_order` writes `orders.attributed_venue_id` and `payments.web_pos_venue_id` / `web_pos_partner_id`;
    - `get_order_dispute_evidence` returns `order ? 'referral_code_id'` and not `order ? 'agent_code_id'`;
    - the audit row of the code write has `entity_type = 'web_referral_codes'`.
  - **Fixtures:** apply the substitution table to the listed tests, `web-checkout/handler.test.ts` and the integration suite. No expected value changes.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL (`relation "public.web_pos_partners" does not exist`, and the guard lists the bodies).
- [ ] **Step 3: Write the migration.**
  1. Snapshot the bodies: `select pg_get_functiondef('public.<fn>'::regproc)` for each function listed under Produces.
  2. Do the renames.
  3. Recreate the bodies, changing identifiers only. Audit `entity_type`s become the new table names, and the op names change for the two replaced RPCs.
  4. Re-issue the grants.
  5. Then run this, which must return nothing (before the guard runs):
     ```sql
     select proname from pg_proc where pronamespace='public'::regnamespace and prosrc ~ '(fintech_|agent_code|commission_records|attributed_terminal_id)';
     ```
- [ ] **Step 4: Run** the reset, the Vault secret, `supabase test db` and `deno test --allow-all supabase/functions/`. Expected: PASS; 0 failed. Confirm that no assertion's expected value changed: `git diff -U0 supabase/tests | grep '^[-+]' | grep -v -E 'web_|venue|referral|network_terminal_id|plan\('` should show only the renamed names.
- [ ] **Step 5: Commit.** `feat(db): web domain renames: web_pos_partners, web_pos_venues, web_referral_codes, web_commissions (A6 §15.4)`

### Task 4: The tenant commission rate replaces the bounty

**Files:**
- Create: `supabase/migrations/20261028130300_web_agent_commission.sql`, `supabase/tests/database/044_web_agent_commission.test.sql`
- Modify:
  - `042`;
  - every fixture that inserts `web_pos_partners.commission_bps` (tests `002`, `010`–`017`, `022`, `034`): drop the column from the insert, and where a split is under test add `update public.tenant_settings set web_agent_commission_bps = 150 where tenant_id = …`;
  - `034_web_retail_pricing.test.sql`: its bounty assertions become rate assertions, with TEAFAIR at 0 and so no split;
  - `gateway.integration.ts`: drop `commission_bps` from the partner insert, and set the IT tenant's rate to 150 with the admin client before "terminal checkout → SPLIT → release → SETTLED".

**Interfaces:**
- Produces:
  - `tenant_settings.web_agent_commission_bps integer not null default 0`, CHECK `tenant_settings_web_agent_commission_bps_check (web_agent_commission_bps between 0 and 10000)`, with a comment: "set by migration only; 0 until rates are agreed (A6 §15.5)";
  - `tenant_settings.web_agent_bounty` and `web_pos_partners.commission_bps` are dropped, and their checks go with them;
  - `web_price_cart`: same signature; split = `{web_pos_partner_id, subaccount_code, commission_bps: <rate>, partner_share: round(goods_total * rate / 10000, 2)}`, only when:
    - `p_code.venue_id` is set;
    - the venue's partner is ACTIVE;
    - `0 < share < goods_total`.

    Otherwise the split is null. The fare is never included.
- Consumes, unchanged:
  - `place_web_order`, which compares and snapshots the three wire keys;
  - `settle_paystack_payment`, which copies `split_bps` to `bps_applied`.

- [ ] **Step 1: Write the failing tests** in 044 (one tenant with a fare of 750, a POS partner and venue, a DSA, as `postgres`):
  - `col_not_null` and `col_default_is(…, 0)` on the new column; every seeded tenant has 0, TEAFAIR included;
  - updating the rate to 10001 or to −1 gives 23514;
  - `hasnt_column` for `tenant_settings.web_agent_bounty` and `web_pos_partners.commission_bps`;
  - at rate 0, a POS-link quote has `split` null;
  - at rate 150, goods 6200 plus fare 750 gives a POS-link split `{commission_bps: 150, partner_share: 93.00, subaccount_code: 'ACCT_…'}`, exactly those three keys plus `web_pos_partner_id`;
  - at rate 150, a codeless quote has `split` null;
  - at rate 150, a DSA-link quote has `split` null;
  - at rate 150 with the partner SUSPENDED: `split` null;
  - at rate 1 with goods 3.00 (the share rounds to 0.00): `split` null;
  - a PAYSTACK_WEB `place_web_order` with the split writes `payments.split_bps = 150`, `split_amount = 93.00` and the subaccount. The `settle_paystack_payment` that follows writes one `web_commissions` row with `bps_applied = 150` and `amount = 93.00`;
  - with no split, settlement writes no `web_commissions` row.

  Also add the guards `web_agent_bounty` and `\.commission_bps` to 042.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL (`column "web_agent_commission_bps" does not exist`, and the guard names `web_price_cart`).
- [ ] **Step 3: Write the migration.** Add the column, recreate `web_price_cart` from its Task 3 definition with the bounty and per-partner branches removed, then drop the two columns.
- [ ] **Step 4: Run** the reset, the Vault secret, `supabase test db` and `deno test`. Expected: PASS; 0 failed. The D1 tests 015–017 keep their amounts (93.00 at 150 bps), because the fixtures now set the tenant rate.
- [ ] **Step 5: Commit.** `feat(db): web POS commission is a tenant rate in bps, 0 until agreed; bounty removed (A6 §15.5)`

### Task 5: Monvelo agent renames

**Files:**
- Create: `supabase/migrations/20261028130400_monvelo_agent_renames.sql`, `supabase/tests/database/045_monvelo_agent_renames.test.sql`
- Modify:
  - `042`;
  - `git mv supabase/tests/database/040_monvelo_fintech_agents.test.sql supabase/tests/database/040_monvelo_agents.test.sql`, then apply the substitutions;
  - `041_monvelo_shop_enrolment.test.sql`, `001_schema_shape.test.sql`;
  - `gateway.integration.ts` (the two `monvelo_fintech_agents` reads).

**Interfaces:**
- Produces:
  - the tables `monvelo_agents` and `monvelo_agent_members`, with their constraints, indexes, policies and trigger renamed per A6 §15.4;
  - the column grants on `monvelo_agents`, carried over unchanged;
  - `create or replace` with the same signatures and grants: `add_monvelo_member`, `approve_monvelo_agent`, `suspend_monvelo_agent`, `set_monvelo_agent_caps`, `register_monvelo_agent` (its 23505 handler now matches `monvelo_agents_pos_network_network_agent_id_key`), `request_settlement_change`, `approve_settlement_change`, `close_monvelo_nomination`, `my_monvelo_agent_ids` (SQL language);
  - **No edits** to web objects or to `monvelo-agent-register` / `monvelo-shop-consent`: they call RPCs by name, and the names are unchanged.

- [ ] **Step 1: Write the failing tests.**
  - **045, shape:** `has_table` and `hasnt_table`; `policies_are('public','monvelo_agents', array['monvelo_agents_select'])` and the same for members; `fk_ok('public','retail_shops','preferred_agent_id','public','monvelo_agents','id')`; the same for `monvelo_agent_nominations.recruited_agent_id`.
  - **045, grants:** `has_column_privilege('authenticated','public.monvelo_agents','settlement_account_number','SELECT')` is false and `…'business_name'…` is true.
  - **045, behaviour:** a ZSA registering the same `(pos_network, network_agent_id)` twice gets 23505 with `'this agent is already registered with Monvelo'`.
  - **045, boundary:**
    - no `public` body matches both `public\.(web_pos_partners|web_pos_venues|web_referral_codes|web_commissions)` and `public\.monvelo_`;
    - no FK has one side `monvelo_%` and the other side `web_%`;
    - the bodies naming `public\.monvelo_` in functions without `monvelo` in the name are exactly `{approve_settlement_change, request_settlement_change}`.
  - **042:** add the `monvelo_fintech_` body guard, and widen the catalog-name guard to `fintech|agent_code|commission_records|monvelo_fintech`.
  - **040 (renamed) and 041:** apply the substitutions.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL (`relation "public.monvelo_agents" does not exist`).
- [ ] **Step 3: Write the migration:** renames, then the nine bodies from `pg_get_functiondef` with the table and constraint names changed. Also update the table comments.
- [ ] **Step 4: Run** the reset, the Vault secret, `supabase test db` and `deno test`. Expected: PASS; 0 failed.
- [ ] **Step 5: Commit.** `feat(db): monvelo_agents and monvelo_agent_members (A6 §15.4)`

### Task 6: Edge Functions: `_shared/payments` and `web-commission-release`

**Files:**
- Create: `supabase/migrations/20261028130500_web_commission_release_cron.sql`
- Move:
  - `git mv supabase/functions/_shared/fintech-liquidity supabase/functions/_shared/payments`;
  - `git mv supabase/functions/fintech-commission-release supabase/functions/web-commission-release`.
- Modify:
  - the imports in `process-payment/{handler,index,handler.test}.ts`, `reconcile-funds/{handler,index,handler.test}.ts`, `web-checkout/{handler,index,handler.test}.ts`, `web-commission-release/{handler,index,handler.test}.ts` and `_shared/monvelo/paystack-resolve.ts`;
  - `web-commission-release/index.ts` (`observe("web-commission-release", …)`);
  - `supabase/config.toml` (`[functions.web-commission-release] verify_jwt = false`, replacing the old section);
  - `supabase/functions/.env.example` (the `CRON_SECRET` comment);
  - `018_d1_security.test.sql` (the job names and schedule assertion);
  - `042`;
  - `gateway.integration.ts` (`cron("web-commission-release", …)` and the loop at the cron-auth test).

**Interfaces:**
- Produces:
  - the cron job `web-commission-release`, `0 6 * * *`, `select public.invoke_system_function('web-commission-release', '{}'::jsonb)`;
  - no job named `fintech-commission-release`;
  - the module paths `../_shared/payments/{paystack,paystack-client,paystack-refunds,paystack-settlements,settle}.ts`, with exported names unchanged;
  - no handler logic change.
- The migration: `select cron.unschedule('fintech-commission-release');`, then `select cron.schedule('web-commission-release', '0 6 * * *', $$…$$);`.

- [ ] **Step 1: Write the failing tests.**
  - In 018, expect `('reconcile-funds-sweep','reconcile-funds-refunds','web-commission-release')`, and `web-commission-release` at `0 6 * * *`.
  - In 042, add these checks:
    ```sql
    select is((select count(*)::int from cron.job where jobname = 'fintech-commission-release' or command like '%fintech-commission-release%'), 0, 'no job calls the old function');
    select is((select command from cron.job where jobname = 'web-commission-release'), $$select public.invoke_system_function('web-commission-release', '{}'::jsonb)$$, 'the release job calls web-commission-release');
    ```
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL in 018 and 042.
- [ ] **Step 3: Implement.** Write the migration, do the two `git mv`s, then fix the imports and the config.
- [ ] **Step 4: Run all of these:**
  - the reset, the Vault secret and `supabase test db`. Expected: PASS.
  - `deno test --allow-all supabase/functions/`. Expected: 0 failed.
  - `deno check supabase/functions/*/index.ts`. Expected: no errors, because index files are not reached by the unit tests.
  - `git grep -n -E "fintech-liquidity|fintech-commission-release" -- supabase ':!supabase/migrations'`. Expected: hits only in `supabase/CLAUDE.md`, which Task 7 fixes.
- [ ] **Step 5: Commit.** `refactor(functions): _shared/payments and web-commission-release (A6 §15.4)`

### Task 7: Docs, Monvelo Step 1 docs, and full verification

**Files:**
- Modify: `supabase/CLAUDE.md`, `CLAUDE.md`

- [ ] **Step 1: Run everything:**
  - `supabase db reset`, the Vault secret, then `supabase test db`. Expected: `Result: PASS`, 43 files.
  - `deno test --allow-all supabase/functions/`. Expected: 0 failed.
  - `deno check supabase/functions/*/index.ts`. Expected: clean.
  - Serve the functions (`supabase functions serve --env-file supabase/functions/.env`), then run the integration suite as in `supabase/CLAUDE.md`, with `INTEGRATION_FAKE_PORT` if the port is reserved. Expected: 0 failed. "terminal checkout → SPLIT → release → SETTLED" settles 93.00 at 150 bps through `web-commission-release`.
  - Re-run this; the only hits must be the `fintech_liquidity` file names and docs history:
    ```sh
    git grep -n -E "fintech_partners|fintech_terminals|fintech_advances|agent_codes|commission_records|FINTECH_AGENT|web_agent_bounty|monvelo_fintech_" -- supabase ':!supabase/migrations'
    ```
- [ ] **Step 2: Update `supabase/CLAUDE.md`:**
  - **Status table:** a row "Domain separation and renames (A6 §15) | done (local)", and a row "Monvelo (A6) Step 1 | done (local)".
  - **A new "Monvelo (A6), Step 1" section** (the absorbed Step 1 Task 7):
    - the tables: `areas`, `monvelo_agents`, `monvelo_agent_members`, enrolments, challenges, nominations, settings, brand terms, fee terms;
    - the RPCs, and the gateways `monvelo-agent-register` and `monvelo-shop-consent`;
    - no new secrets: both need `GATEWAY_SECRET`, and `monvelo-agent-register` needs the Paystack key;
    - the ZSA/ASA role anchors and the `FIELD_SALES` rename.

    Keep the existing consent section beneath it, with "registered Monvelo agents".
  - **A new "Domain separation (A6 §15)" section:**
    - the boundary table;
    - the naming note: "the `fintech_liquidity_*` migration files keep their historical names; they hold OTP, the Paystack webhook and D1 money; the domains are `web_*` and `monvelo_*`";
    - the commission rule;
    - the guard file 042.
  - **"Teafairweb retail pricing":** replace the bounty bullet with the rate rule. Fix the evidence bullet (`referral_code_id`) and the trigger name (`web_referral_codes`, `upsert_web_referral_code`).
  - **Everywhere:**
    - `fintech-commission-release` → `web-commission-release` (the D1 deploy list, the system functions, secrets, the cron jobs, Paystack test mode);
    - `_shared/fintech-liquidity/` → `_shared/payments/` and the domain list (Layout).
  - **Deploy notes, as user actions for later** (A6 §15.8):
    - the three pre-push checks;
    - the redeploy list for `_shared/payments` importers;
    - deploy `web-commission-release` immediately after the migrations;
    - `supabase functions delete fintech-commission-release` only if it was deployed by then (the 2026-10-15 record says it was not);
    - never `config push`.
- [ ] **Step 3: Update `CLAUDE.md`:**
  - the repository-state row: the real counts from Step 1 (migrations, pgTAP assertions and files, Edge Functions), and "A6 Monvelo Step 1 and the A6 §15 domain separation built locally, not pushed";
  - the rule `teafair_agent_id` is `NOT NULL` on `orders`, `payments`, `web_commissions`;
  - the naming note.
- [ ] **Step 4: Commit** `docs: domain separation and Monvelo Step 1`. **Do not merge into `main`.** Do not push.
