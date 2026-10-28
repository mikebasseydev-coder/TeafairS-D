# Monvelo Step 1b: Monvelo replaces fintech partners — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the legacy fintech-partner model. `fintech_partners`,
`fintech_terminals`, `fintech_advances`, the ₦500 web bounty and the
`FINTECH_AGENT` identity all go. The Monvelo registry takes their place: agents,
members, plus new tenant links and terminals. The web commission becomes a
per-tenant percentage, paid on POS-link orders only, at an interim 0%.

**Architecture:**
- `monvelo_fintech_agents` stays the one platform-level POS-agent registry.
- `monvelo_agent_tenants` (PK `(tenant_id, agent_id)`) is the tenant-scoped
  link. `payments`, `commission_records`, `agent_codes` and `orders` reference
  it by composite FK.
- `monvelo_agent_terminals` is platform-level. Tenant rows reference it as
  `(agent_id, terminal_id)`.
- POS staff are `monvelo_fintech_members`. Member RPCs take the tenant from the
  record and re-verify an ACTIVE link live.
- Spec A §9 holds:
  - `authenticated` has SELECT only;
  - writes are SECURITY DEFINER RPCs with `SET search_path = public, pg_temp`;
  - no client-supplied tenant;
  - policies are `FOR SELECT`;
  - `p_idempotency_key uuid` comes first.

**Tech Stack:**
- Postgres 17 hand-written migrations, pgTAP;
- Deno Edge Functions (no handler changes expected), the integration suite
  `supabase/functions/_tests/gateway.integration.ts`.

No Prisma.

**Spec:** `docs/superpowers/specs/2026-10-28-addendum-a6-monvelo-design.md` §15
(the amendment; the mapping table in §15.3 is the checklist), on top of A6 §4.1
and the Step 1 build (migrations `20261028120000`–`20261028120600`).

**Where this sits.**
- It runs on branch `feat/monvelo-step1`, after Step 1 Tasks 1–6 (built).
- If Step 1 Task 7 (docs) has not run, Task 6 here absorbs it.
- Nothing merges into `main`, and nothing is pushed or deployed.

## Global Constraints

- **Naming:** new tables are prefixed `monvelo_`. Persona codes as A6 §3; never "FSO".
- **Money and rates:** money `numeric(15,2)`; rates in basis points (`integer`, 0–10000); statuses `text` + `CHECK`.
- **Tenant-scoped rows:**
  - reference agents through `(tenant_id, monvelo_agent_id) → monvelo_agent_tenants (tenant_id, agent_id)`;
  - reference terminals through `(monvelo_agent_id, terminal_id) → monvelo_agent_terminals (agent_id, id)`;
  - every FK and policy column is indexed.
- **Grants:**
  - new functions get no EXECUTE for PUBLIC/anon/authenticated unless granted explicitly;
  - `monvelo_fintech_agents.paystack_subaccount_code` never gets a column grant.
- **Error codes:** P0001 business 422, 42501 forbidden 403, 23505 409, 23503 FK, 23514 check, TF002 idempotency mismatch.
- **No personal data or subaccount codes in audit rows.** `monvelo_agent_audit` strips them.
- **Keep the D1 wire contract.** The quote split keeps the keys `subaccount_code`, `commission_bps` and `partner_share`. Only the informational `fintech_partner_id` key becomes `monvelo_agent_id`.
- **Signatures unchanged** for every rewritten legacy RPC (`upsert_agent_code`, `set_terminal_venue`, `pos_order_lookup`, `place_web_order`, `settle_paystack_payment`, `issue_otp`, `verify_otp`, `invite_tenant_user`), so no Edge Function changes its calls.
- **Settings are written by migration only:** `web_agent_commission_bps` default 0 everywhere. Tests may set it as `postgres` or the service role.
- **Drops never use CASCADE.**
- **Sequencing:**
  - migrations `20261028130000`–`20261028130300`;
  - pgTAP files continue at `042_`;
  - after every `supabase db reset`, recreate the Vault secret:
    `psql -qAt -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "select vault.create_secret('local-gateway-secret', 'gateway_secret');"`
- **Every task ends green:**
  - `supabase db reset`, the Vault secret, then `supabase test db`: `Result: PASS`;
  - `deno test --allow-all supabase/functions/`: 0 failed.

  The integration suite is **not** a gate until Task 5. Its fixtures still
  write `fintech_partners` and a `FINTECH_AGENT` membership, so it is expected
  red after Task 2.
- **Forbidden:**
  - `git push`, `supabase db push`, `supabase functions deploy`, `supabase config push`;
  - remote secrets, merging into `main`;
  - touching `FIGMA.md` or any `.env` file.
- **Commits:** every commit message ends with a blank line, then `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Cross-tenant binding.** These must be refused by FK (23503), not by RPC logic alone:
   - a code, payment, commission or order of tenant A naming an agent linked only to tenant B;
   - a terminal of agent X under agent Y.

   A SUSPENDED link or a SUSPENDED agent makes the code resolve as "This link is no longer valid". Owned by Tasks 1 and 2.
2. **Commission on the wrong orders.** These have `split` null, no `payments.split_*` and no commission row, even at a non-zero tenant rate:
   - codeless orders;
   - staff (DSA) links;
   - POS links whose agent has no subaccount;
   - any order at rate 0.

   The share is on goods only, never the fare. A share that rounds to 0 is no split. Owned by Task 2.
3. **Subaccount secrecy.** `authenticated` cannot select `paystack_subaccount_code` (`has_column_privilege` false). It never appears in audit rows, catalogue output or any `authenticated` RPC response. Only the service-role quote carries it. Owned by Tasks 1 and 2.
4. **Stale function bodies.** PL/pgSQL is not dependency-tracked: a body still naming `fintech_terminals` passes the migration and fails at call time. A guard assertion scans `pg_proc.prosrc`. Owned by Task 4, with an early version in Task 2.
5. **Members acting without a tenant.** No member path calls `assert_tenant_role`; the tenant comes from the order and the link is re-checked live. A member of agent X cannot look up agent Y's order or set Y's venue (42501). A REVOKED member, or a member after the link is SUSPENDED, gets nothing. Members can still sign in (`auth_sms_allowed`). Owned by Tasks 2 and 3.

---

## File map

| File | Responsibility |
|---|---|
| `supabase/migrations/20261028130000_monvelo_agent_links.sql` | `monvelo_agent_tenants`, `monvelo_agent_terminals`, subaccount columns, helpers, the four link/terminal/subaccount RPCs, agent policy update, `monvelo_agent_audit` update |
| `supabase/migrations/20261028130100_monvelo_web_cutover.sql` | FK repoint and renames on `payments`, `commission_records`, `agent_codes`, `orders`; `web_agent_commission_bps` in, `web_agent_bounty` out; rewrites of `web_price_cart`, `web_resolve_code`, `web_route_try`, `storefront_catalogue`, `place_web_order`, `upsert_agent_code`, `set_terminal_venue`, `pos_order_lookup`, `settle_paystack_payment` |
| `supabase/migrations/20261028130200_monvelo_retire_fintech_agent.sql` | `tenant_users_no_fintech_agent`, `invite_tenant_user` refusal, `issue_otp` / `verify_otp` DSA-only, `auth_sms_allowed` with members |
| `supabase/migrations/20261028130300_drop_fintech_partners.sql` | drop `fintech_advances`, `fintech_terminals`, `fintech_partners` |
| `supabase/tests/database/042_monvelo_agent_links.test.sql` | Task 1 |
| `supabase/tests/database/043_monvelo_web_commission.test.sql` | Task 2 (the commission rule and member paths) |
| `supabase/tests/database/044_monvelo_fintech_agent_retired.test.sql` | Task 3 |
| `supabase/tests/database/001`, `002`, `010`–`017`, `020`, `022`–`026`, `034`, `040` | fixture and assertion updates (per task below) |
| `supabase/functions/web-checkout/handler.test.ts` | fixture key rename; null-split test |
| `supabase/functions/_tests/gateway.integration.ts` | Monvelo fixtures and new flows |
| `supabase/CLAUDE.md`, `CLAUDE.md` | docs, counts, pre-push checks |

**Shared pgTAP fixture** (Tasks 2–4 use it wherever a file used `fintech_partners` / `fintech_terminals` / a FINTECH_AGENT membership; run as `postgres`, ids per file):

```sql
insert into public.monvelo_fintech_agents (id, business_name, pos_network, network_agent_id, contact_phone, location,
  address_text, settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name,
  network_kyc_reference, recruited_by, status, approved_by, approved_at, paystack_subaccount_code)
values ('<agent>', 'Grace POS', 'MONIEPOINT', 'MP-GRACE', '+2348000000000',
  extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'Allen Ave',
  '0123456789', '6789', '058', 'Grace POS', 'KYC-1', '<any profile>', 'ACTIVE', '<any profile>', now(), 'ACCT_grace01');
insert into public.monvelo_fintech_members (agent_id, profile_id) values ('<agent>', '<pos staff profile>');
insert into public.monvelo_agent_tenants (tenant_id, agent_id, territory_id, linked_by) values ('<tenant>', '<agent>', '<territory>', '<zsm>');
insert into public.monvelo_agent_terminals (id, agent_id, network_terminal_id, operator_profile_id) values ('<terminal>', '<agent>', 'T-GRACE-1', '<pos staff profile>');
update public.tenant_settings set web_agent_commission_bps = 150 where tenant_id = '<tenant>';  -- only where a split is under test
```

---

### Task 1: Agent–tenant links, terminals and subaccounts (additive)

**Files:**
- Create: `supabase/migrations/20261028130000_monvelo_agent_links.sql`, `supabase/tests/database/042_monvelo_agent_links.test.sql`
- Modify: `supabase/tests/database/040_monvelo_fintech_agents.test.sql` (one more `has_column_privilege` assertion; raise `plan`)

**Interfaces:**
- Consumes:
  - `assert_platform_role`, `is_monvelo_staff()`, `my_monvelo_agent_ids()`, `assert_tenant_role`, `my_tenant_ids()`;
  - `write_audit`, `idempotency_begin` / `idempotency_complete`, `monvelo_agent_audit`.
- Produces:
  - **columns on `monvelo_fintech_agents`:**
    - `paystack_subaccount_code text null check (paystack_subaccount_code ~ '^ACCT_[A-Za-z0-9]+$')`, with no column grant;
    - `has_paystack_subaccount boolean generated always as (paystack_subaccount_code is not null) stored`, granted SELECT to `authenticated`.
  - **`monvelo_agent_audit`** recreated: also strips `paystack_subaccount_code`.
  - **table** `monvelo_agent_tenants`:
    - `tenant_id uuid not null → tenants`;
    - `agent_id uuid not null → monvelo_fintech_agents`;
    - `territory_id uuid not null`;
    - `status text not null default 'ACTIVE' check in ('ACTIVE','SUSPENDED')`;
    - `linked_by uuid not null → profiles`;
    - `created_at`, `updated_at` (`set_updated_at` trigger);
    - `primary key (tenant_id, agent_id)`;
    - FK `(tenant_id, territory_id) → territories (tenant_id, id)`, all `on delete restrict`;
    - indexes `(agent_id)`, `(tenant_id, territory_id)`, `(linked_by)`;
    - SELECT policy: `tenant_id in (select my_tenant_ids())`, or `(select is_monvelo_staff())`, or `agent_id in (select my_monvelo_agent_ids())`.
  - **table** `monvelo_agent_terminals`:
    - `id uuid pk`;
    - `agent_id uuid not null → monvelo_fintech_agents`;
    - `network_terminal_id text not null check (network_terminal_id = upper(btrim(network_terminal_id)) and length(network_terminal_id) > 0)`;
    - `operator_profile_id uuid null`;
    - the venue fields, with the same types as `fintech_terminals`: `venue_channel venue_channel_enum`, `venue_name text`, `address_text text`, `state text`, `lga text`, `location extensions.geometry(Point,4326)`, `operating_hours jsonb`;
    - `is_active boolean not null default true`, `created_at`, `updated_at`;
    - `unique (agent_id, id)`, `unique (agent_id, network_terminal_id)`;
    - FK `(agent_id, operator_profile_id) → monvelo_fintech_members (agent_id, profile_id)`;
    - index `(operator_profile_id)`;
    - SELECT policy: staff, own members (`agent_id in my_monvelo_agent_ids()`), or `agent_id in (select my_linked_monvelo_agent_ids())`.
  - **Agent SELECT policy** replaced to add `or id in (select public.my_linked_monvelo_agent_ids())`.
  - **Helpers:**
    - `my_linked_monvelo_agent_ids() returns setof uuid`: stable security definer, granted to `authenticated`; the agents with a link (any status) to a tenant in `my_tenant_ids()`.
    - `assert_monvelo_member(p_agent_id uuid) returns uuid`: `auth.uid()` if they are an ACTIVE member of an ACTIVE agent `p_agent_id`, else 42501 `'not a member of this Monvelo agent'`. No grant.
    - `monvelo_agent_link_active(p_tenant_id uuid, p_agent_id uuid) returns boolean`: the link is ACTIVE and the agent is ACTIVE. Stable, no grant.
  - **RPC** `set_monvelo_agent_subaccount(p_idempotency_key uuid, p_agent_id uuid, p_subaccount_code text) returns jsonb`:
    - MONVELO_OPERATOR; null clears;
    - a bad format raises P0001 `'a Paystack subaccount code looks like ACCT_…'`;
    - returns `{agent_id, has_paystack_subaccount}`;
    - audit `{has_paystack_subaccount, by}` only, tenant null.
  - **RPC** `upsert_monvelo_terminal(p_idempotency_key uuid, p_terminal_id uuid, p_agent_id uuid, p_network_terminal_id text, p_operator_profile_id uuid, p_is_active boolean) returns jsonb`:
    - MONVELO_OPERATOR; `p_terminal_id` null creates;
    - the agent never changes: P0001 `'a terminal''s agent never changes'`;
    - the operator must be an ACTIVE member of the agent: P0001 `'the operator must be an active member of the agent'`;
    - a duplicate network terminal id for the agent raises 23505 `'this terminal is already registered for the agent'`;
    - returns `{terminal_id}`.
  - **RPC** `link_monvelo_agent(p_idempotency_key uuid, p_pos_network pos_network_enum, p_network_agent_id text, p_territory_id uuid) returns jsonb`:
    - tenant ZSM (`assert_tenant_role(array['ZSM'])`); the tenant comes from the JWT;
    - the agent is matched on `(pos_network, upper(btrim(network_agent_id)))` and must be ACTIVE: P0001 `'no active Monvelo agent has that network id'` (the same text for unknown and PENDING);
    - the territory must be the caller's tenant's: 42501;
    - an existing link is updated (territory, ACTIVE);
    - refused if an active terminal of the agent has a venue outside the territory boundary: P0001 `'the agent''s venue lies outside that territory'`;
    - returns `{agent_id, status}`.
  - **RPC** `set_monvelo_agent_link_status(p_idempotency_key uuid, p_agent_id uuid, p_status text) returns jsonb`:
    - tenant ZSM; `p_status` in `('ACTIVE','SUSPENDED')`, else P0001;
    - an unknown link raises P0001 `'this agent is not linked to your tenant'`;
    - reactivating needs the agent ACTIVE;
    - returns `{agent_id, status}`.
  - All four RPCs are granted to `authenticated` and audited with `write_audit`. The link RPCs carry the tenant id; the operator RPCs carry a null tenant.

- [ ] **Step 1: Write the failing tests** in `042_monvelo_agent_links.test.sql` (fixtures: two tenants A and B with a ZSM each, a territory each with a boundary on A's, an operator profile, an ACTIVE agent X with member M, a PENDING agent P):
  - the operator sets X's subaccount: `has_paystack_subaccount` true; a ZSM gets 42501; `'ACCT 1'` gets P0001;
  - `has_column_privilege('authenticated','public.monvelo_fintech_agents','paystack_subaccount_code','select')` is false, and `has_paystack_subaccount` is true;
  - no `audit_logs` row's text contains `ACCT_`;
  - the operator registers terminal T for X with operator M; a non-member operator profile gets P0001; registering the same network id twice gets 23505; changing T's agent gets P0001;
  - ZSM A links X into A's territory: ACTIVE; the same key replays;
  - linking P gets P0001 with the "no active" text; linking with B's territory gets 42501; a TM gets 42501;
  - a link row naming B's territory under tenant A, inserted directly, gets 23503 (composite FK);
  - ZSM A suspends the link, then reactivates it; ZSM B cannot (P0001, not linked);
  - visibility:
    - A's TM reads the link, the terminal and X's public columns;
    - B's ZSM reads none of them;
    - M reads its link and terminal;
    - a stranger reads nothing;
  - `assert_monvelo_member(X)` as M returns M; as a stranger it raises 42501; as M after X is suspended it raises 42501.
- [ ] **Step 2: Run** `psql -qAt -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/database/042_monvelo_agent_links.test.sql`. Expected: FAIL (`relation "public.monvelo_agent_tenants" does not exist`).
- [ ] **Step 3: Write the migration** with the interfaces above, following the `20261028120500` skeleton (operator RPCs) and `20261006130300` (tenant RPCs). Add the `has_column_privilege` assertion for `paystack_subaccount_code` to `040`.
- [ ] **Step 4: Run** `supabase db reset`, recreate the Vault secret, `supabase test db`, then `deno test --allow-all supabase/functions/`. Expected: `Result: PASS`; 0 failed.
- [ ] **Step 5: Commit.** `feat(db): Monvelo agent–tenant links, terminals and Paystack subaccounts (A6 §15)`

### Task 2: Web cutover onto Monvelo (codes, attribution, routing, commission, settlement)

The cutover is one migration: the FKs form one graph. `web_price_cart`
reads a code's terminal, `place_web_order` writes the payment's agent, and
`settle_paystack_payment` writes the commission's agent. None can move alone.
The legacy tables stay (orphaned) until Task 4.

**Files:**
- Create: `supabase/migrations/20261028130100_monvelo_web_cutover.sql`, `supabase/tests/database/043_monvelo_web_commission.test.sql`
- Modify (fixtures to the shared Monvelo fixture; assertions as listed in Step 1): `010_commerce_web_schema`, `011_commerce_web_management`, `012_commerce_web_public`, `013_commerce_buyer_privacy`, `014_commerce_web_locations_routing`, `015_fintech_liquidity_web_settlement`, `016_fintech_liquidity_commission_release`, `017_fintech_liquidity_refunds`, `022_support_system`, `034_web_retail_pricing`

**Interfaces:**
- Consumes: Task 1 tables and helpers (`monvelo_agent_link_active`, `assert_monvelo_member`, `is_monvelo_staff`).
- Produces (schema):
  - **Drop FKs:** `payments_tenant_id_fintech_partner_id_fkey`, `payments_tenant_id_fintech_terminal_id_fkey`, `commission_records_tenant_id_fintech_partner_id_fkey`, `agent_codes_tenant_id_terminal_id_fkey`, `orders_attributed_terminal_fk`.
  - **`payments`:**
    - rename `fintech_partner_id → monvelo_agent_id` and `fintech_terminal_id → monvelo_terminal_id` (column grants follow);
    - rename constraint `payments_split_has_partner → payments_split_has_agent`;
    - rename indexes `idx_payments_partner → idx_payments_monvelo_agent` and `idx_payments_terminal → idx_payments_monvelo_terminal` (now `(monvelo_agent_id, monvelo_terminal_id)`);
    - FK `payments_monvelo_agent_fk (tenant_id, monvelo_agent_id) → monvelo_agent_tenants`;
    - FK `payments_monvelo_terminal_fk (monvelo_agent_id, monvelo_terminal_id) → monvelo_agent_terminals (agent_id, id)`;
    - CHECK `payments_terminal_has_agent (monvelo_terminal_id is null or monvelo_agent_id is not null)`.
  - **`commission_records`:**
    - rename `fintech_partner_id → monvelo_agent_id`;
    - rename index `idx_commission_records_partner → idx_commission_records_monvelo_agent`;
    - FK `commission_records_monvelo_agent_fk (tenant_id, monvelo_agent_id) → monvelo_agent_tenants`.
  - **`agent_codes`:**
    - `agent_id` drops NOT NULL; add `monvelo_agent_id uuid`;
    - FK `agent_codes_monvelo_agent_fk (tenant_id, monvelo_agent_id) → monvelo_agent_tenants`;
    - FK `agent_codes_terminal_fk (monvelo_agent_id, terminal_id) → monvelo_agent_terminals (agent_id, id)`;
    - CHECK `agent_codes_one_holder (num_nonnulls(agent_id, monvelo_agent_id) = 1)`;
    - CHECK `agent_codes_terminal_iff_monvelo ((terminal_id is null) = (monvelo_agent_id is null))`;
    - indexes `(tenant_id, monvelo_agent_id)` and `(monvelo_agent_id, terminal_id)`;
    - SELECT policy gains `or monvelo_agent_id in (select public.my_monvelo_agent_ids())`.
  - **`orders`:**
    - add `attributed_monvelo_agent_id uuid`;
    - FK `orders_attributed_monvelo_agent_fk (tenant_id, attributed_monvelo_agent_id) → monvelo_agent_tenants`;
    - FK `orders_attributed_terminal_fk (attributed_monvelo_agent_id, attributed_terminal_id) → monvelo_agent_terminals (agent_id, id)`;
    - CHECK `orders_attributed_terminal_has_agent (attributed_terminal_id is null or attributed_monvelo_agent_id is not null)`;
    - replace `orders_web_attribution_complete` with: `channel <> 'ONLINE' or agent_code_id is null or (num_nulls(payment_route, public_reference) = 0 and num_nonnulls(attributed_agent_id, attributed_monvelo_agent_id) = 1)`;
    - indexes `(tenant_id, attributed_monvelo_agent_id)` and `(attributed_monvelo_agent_id, attributed_terminal_id)`.
  - **`tenant_settings`:**
    - add `web_agent_commission_bps integer not null default 0 check (web_agent_commission_bps between 0 and 10000)`;
    - drop `web_agent_bounty`.
- Produces (functions; every signature unchanged):
  - **`web_price_cart(p_code agent_codes, p_items jsonb)`:**
    - `split` is `{monvelo_agent_id, subaccount_code, commission_bps, partner_share}` only when:
      - `p_code.monvelo_agent_id` is not null;
      - `monvelo_agent_link_active(p_code.tenant_id, p_code.monvelo_agent_id)`;
      - the agent has a subaccount;
      - the rate is above 0;
      - `0 < share < total`;
    - `partner_share = round(goods_total * bps / 10000, 2)`;
    - otherwise `split` is null.
  - **`web_resolve_code(p_code text)`:**
    - a staff code needs an ACTIVE `tenant_users` holder (as today);
    - a POS code needs `monvelo_agent_link_active` and the terminal `is_active`;
    - otherwise P0001 `'This link is no longer valid'`.
  - **`web_route_try(p_tenant_id, p_code, p_lga_id)`:**
    - for a POS code, the territory is the link's `territory_id`, and the accountable person is that territory's ACTIVE TM;
    - staff and codeless branches are unchanged.
  - **`storefront_catalogue(p_code)`:** the venue comes from `monvelo_agent_terminals` by `(v_code.monvelo_agent_id, v_code.terminal_id)`.
  - **`place_web_order(…13 args…)`:**
    - `POS_AGENT` needs `v_code.terminal_id` (as today);
    - writes `attributed_agent_id = v_code.agent_id`, `attributed_monvelo_agent_id = v_code.monvelo_agent_id`, `attributed_terminal_id = v_code.terminal_id`;
    - writes `payments.monvelo_agent_id` and `monvelo_terminal_id` from the code.
  - **`upsert_agent_code(p_idempotency_key, p_code, p_agent_id, p_terminal_id, p_discount_type, p_discount_value, p_max_redemptions, p_expires_at, p_is_active)`:**
    - exactly one of `p_agent_id` (staff link) and `p_terminal_id` (POS link) is given: P0001 `'a link names either a staff member or a POS terminal'`;
    - for a POS link:
      - the agent is the terminal's;
      - the link must exist for the caller's tenant: P0001 `'this agent is not linked to your tenant'`;
      - it must be ACTIVE when the code is active;
      - a TM may issue only when the link's territory is theirs (42501);
    - a code's holder never changes: the existing P0001 text, for both kinds;
    - the terminal may change only within the same agent.
  - **`set_terminal_venue(p_idempotency_key, p_terminal_id, p_venue_channel, p_venue_name, p_address_text, p_state, p_lga, p_latitude, p_longitude, p_operating_hours)`:**
    - the caller is MONVELO_OPERATOR or passes `assert_monvelo_member(terminal.agent_id)`; ZSM and TM callers get 42501;
    - the boundary check runs against every ACTIVE link territory with a boundary: P0001 `'the venue lies outside a territory this agent serves'`;
    - the audit has a null tenant;
    - the validation copy is otherwise unchanged.
  - **`pos_order_lookup(p_public_reference text)`:**
    - no `assert_tenant_role`;
    - finds the order by `public_reference`, `payment_route = 'POS_AGENT'` and `attributed_monvelo_agent_id in my_monvelo_agent_ids()`, with `monvelo_agent_link_active(order.tenant_id, order.attributed_monvelo_agent_id)`;
    - otherwise P0001 `'Order not found'`;
    - the output is unchanged (A2 till fields).
  - **`settle_paystack_payment(…9 args…)`:** inserts `commission_records.monvelo_agent_id = v_payment.monvelo_agent_id`; the rest is unchanged.

- [ ] **Step 1: Write the failing tests.**
  - **New file `043_monvelo_web_commission.test.sql`.** Fixture: tenant A at 150 bps; agent X linked to A with a subaccount and terminal T; agent Y linked to A without a subaccount; a DSA; TEAFAIR codeless. Assertions:
    - the POS code on X: a cart of 6,200 goods gives `split.partner_share` 93.00 and `commission_bps` 150, on goods only (a non-zero fare is excluded);
    - the same code at rate 0: `split` is null;
    - a POS code on Y (no subaccount): `split` is null;
    - a DSA staff code at 150 bps: `split` is null;
    - codeless (TEAFAIR): `split` is null and `transport_fare` is 750;
    - a share that rounds to 0 (1 bps on ₦10): `split` is null;
    - suspend X's link: `web_resolve_code` raises "This link is no longer valid"; the same after the operator suspends X; the same when T is inactive;
    - placing a PAYSTACK_WEB order on X's code:
      - `payments.monvelo_agent_id = X`, `monvelo_terminal_id = T`, `split_bps = 150`, `split_amount = 93`;
      - after `settle_paystack_payment` success with a matching split, there is a `commission_records` row with `monvelo_agent_id = X`, `bps_applied = 150`, `status = 'SPLIT'`;
    - placing a POS_AGENT order: `attributed_monvelo_agent_id = X`, `attributed_terminal_id = T`, `attributed_agent_id` null;
    - FK checks:
      - a code of tenant B naming X (linked only to A), inserted directly: 23503;
      - a code naming X with Y's terminal: 23503;
      - a code with both `agent_id` and `monvelo_agent_id`: 23514;
    - `pos_order_lookup` with an order created by direct insert:
      - as X's member: the till fields;
      - as Y's member: P0001 "Order not found";
      - after X's link is suspended: P0001;
    - `set_terminal_venue` on T:
      - X's member succeeds;
      - Y's member gets 42501;
      - A's ZSM gets 42501;
      - the operator succeeds;
      - a point outside A's territory boundary gets P0001;
    - `has_column_privilege('authenticated','public.tenant_settings','web_agent_commission_bps','select')` is true, and `web_agent_bounty` no longer exists (`hasnt_column`);
    - an early guard: no `public` function body matches `web_agent_bounty|fintech_partners|fintech_terminals` (Task 4 widens it).
  - **Existing files.** Move each fixture to the shared Monvelo fixture, keeping each assertion's intent:
    - **010:** the column and FK shape assertions name `monvelo_agent_tenants` / `monvelo_agent_terminals`; add `col_is_null` for `agent_codes.agent_id`.
    - **011:** venue tests become member/operator tests (ZSM and TM now 42501). Code tests issue a POS link with `p_agent_id` null and `p_terminal_id`. A TM outside the link's territory gets 42501. The departed-agent tests stay for staff codes.
    - **012:** the public resolve/catalogue tests use a POS code; the catalogue venue is read from the Monvelo terminal.
    - **013:** the till lookup is called by the Monvelo member with no tenant claim, not a FINTECH_AGENT membership.
    - **014:** a POS code's territory and accountable person come from the link.
    - **015, 016, 017, 022:** payments and commissions use `monvelo_agent_id`; the tenant rate is set to the bps each file expects.
    - **034:**
      - drop the bounty assertions ("TEAFAIR 500", the `commission_bps 0 / partner_share 500` split);
      - replace them with "TEAFAIR `web_agent_commission_bps` is 0" and "a TEAFAIR POS link yields no split at the interim rate";
      - keep the fare and no-discount assertions.

    Adjust each `plan(n)`.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL (043 cannot find `attributed_monvelo_agent_id`; the updated files fail on the missing columns).
- [ ] **Step 3: Write the migration.**
  - Each function body starts from its latest definition. `web_price_cart`, `place_web_order` and `storefront_catalogue` come from `20261024140000`; take the rest from `pg_get_functiondef` on the local DB.
  - Change only what the interfaces list.
  - Re-issue `grant execute` exactly as before (`upsert_agent_code`, `set_terminal_venue` and `pos_order_lookup` to `authenticated`; the web functions to `service_role`).
- [ ] **Step 4: Run** `supabase db reset`, the Vault secret, `supabase test db`, then `deno test --allow-all supabase/functions/`. Expected: PASS; 0 failed. The integration suite is not run (see Global Constraints).
- [ ] **Step 5: Commit.** `feat(db): web links, routing, commission and settlement move onto Monvelo agents; bounty removed (A6 §15)`

### Task 3: Retire FINTECH_AGENT

**Files:**
- Create: `supabase/migrations/20261028130200_monvelo_retire_fintech_agent.sql`, `supabase/tests/database/044_monvelo_fintech_agent_retired.test.sql`
- Modify:
  - `020_support_buyer`, `023_chat_schema`, `024_chat_direct`, `025_chat_post`, `026_chat_moderation`: every `'FINTECH_AGENT'` fixture or update becomes `'RETAIL_SHOP_OWNER'`, the non-staff role the tests mean. Reword the descriptions ("a staff member turned shop owner sees nothing"). Checked 2026-10-28: a `RETAIL_SHOP_OWNER` row with a territory passes every `tenant_users` CHECK, and `tenant_settings_web_defaults_check` accepts any ACTIVE member as `web_default_agent_id` (020).

**Interfaces:**
- Consumes: Task 2 (no function still uses the role).
- Produces:
  - **CHECK** `tenant_users_no_fintech_agent (role <> 'FINTECH_AGENT')`, validated (not `NOT VALID`).
  - **`invite_tenant_user(p_idempotency_key, p_phone_number, p_role, p_territory_id, p_reports_to_id, p_area_id)`:** same body as `20261028120100`, plus an early refusal P0001 `'FINTECH_AGENT is retired: POS staff join through Monvelo (add_monvelo_member)'`. Remove `FINTECH_AGENT` from its territory-role list.
  - **`issue_otp(p_idempotency_key, p_subject_id, p_purpose, p_gateway_proof)`** and **`verify_otp(p_idempotency_key, p_challenge_id, p_code)`:** `assert_tenant_role(array['DSA'])`; otherwise unchanged from `20261024160000` / `20261007120200`.
  - **`auth_sms_allowed(p_user_id, p_phone)`:** adds `or exists (select 1 from public.monvelo_fintech_members m where m.profile_id = p.id and m.status = 'ACTIVE')`.
  - `tenant_role_enum` keeps the label (`001`'s enum assertion is unchanged).

- [ ] **Step 1: Write the failing tests** in `044`:
  - inserting a `tenant_users` row with role FINTECH_AGENT gives 23514;
  - updating a DSA row to FINTECH_AGENT gives 23514;
  - a ZSM inviting FINTECH_AGENT gets P0001 with the text above;
  - `issue_otp` by a Monvelo member (no tenant claim) gets 42501; a DSA still issues (with the proof);
  - `auth_sms_allowed` is true for an ACTIVE member with no membership or platform role, and false once that member is REVOKED;
  - the guard: the only `public` function whose body contains `FINTECH_AGENT` is `invite_tenant_user`.
- [ ] **Step 2: Run** the file. Expected: FAIL (the insert succeeds; the invite returns a row).
- [ ] **Step 3: Write the migration, and update the chat and support fixtures.**
- [ ] **Step 4: Run** `supabase db reset`, the Vault secret, `supabase test db`, then `deno test --allow-all supabase/functions/`. Expected: PASS; 0 failed (`otp-issue` / `otp-verify` unit tests already use the DSA).
- [ ] **Step 5: Commit.** `feat(db): retire FINTECH_AGENT; POS staff are Monvelo members and can sign in (A6 §15)`

### Task 4: Drop the legacy tables

**Files:**
- Create: `supabase/migrations/20261028130300_drop_fintech_partners.sql`
- Modify:
  - `supabase/tests/database/001_schema_shape.test.sql`: in the tables list, `fintech_partners`, `fintech_terminals` and `fintech_advances` become `monvelo_agent_tenants` and `monvelo_agent_terminals` (or wherever the Monvelo tables are listed); drop the `fintech_advances.requested_amount` type assertion;
  - `supabase/tests/database/002_invariants.test.sql`: replace the partner and advance invariants.

**Interfaces:**
- Consumes: Tasks 2–3 (no FK, policy or function body still references the tables).
- Produces:
  - `drop table public.fintech_advances; drop table public.fintech_terminals; drop table public.fintech_partners;` in that order, **without CASCADE**.
  - Nothing else. `pos_network_enum`, `venue_channel_enum`, `commission_status_enum` and `otp_purpose_enum` stay; they are still used.

- [ ] **Step 1: Write the failing tests.**
  - **001:**
    - `hasnt_table` for each of the three;
    - `hasnt_column('public','tenant_settings','web_agent_bounty')`;
    - the widened guard: no `public` function body matches `fintech_partners|fintech_terminals|fintech_advances|web_agent_bounty|fintech_partner_id|fintech_terminal_id` (expect the empty set and list offenders in the description).
  - **002:**
    - `tenant_settings.web_agent_commission_bps = 10001` gives 23514;
    - a subaccount `'BAD'` on an agent gives 23514;
    - a link naming another tenant's territory gives 23503;
    - a terminal network id `'abc'` (not upper-case) gives 23514.

  Adjust both `plan(n)`.
- [ ] **Step 2: Run** `supabase test db`. Expected: FAIL (the tables still exist).
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `supabase db reset`, the Vault secret, `supabase test db`, then `deno test --allow-all supabase/functions/`. Expected: PASS; 0 failed. Also run `grep -rn "fintech_partners\|fintech_terminals\|fintech_advances\|web_agent_bounty" supabase/functions supabase/tests`. Expected: no hits except historical migrations, which are never edited.
- [ ] **Step 5: Commit.** `feat(db): drop fintech_partners, fintech_terminals and fintech_advances (A6 §15)`

### Task 5: Edge Functions and the integration suite

**Files:**
- Modify: `supabase/functions/web-checkout/handler.test.ts`, `supabase/functions/_tests/gateway.integration.ts`

**Interfaces:**
- Consumes: Tasks 1–4. The handler code is unchanged (§15.3).
- Produces:
  - **The unit fixture's quote split:** `{ monvelo_agent_id, subaccount_code, commission_bps, partner_share }`.
  - **Integration fixtures:**
    - `ids.partner` becomes `ids.monveloAgent`;
    - `users.agent` is a Monvelo member, not a tenant member;
    - an ACTIVE Monvelo agent, with subaccount `ACCT_it01` set by the operator RPC or directly by admin;
    - terminal `ids.terminal` with `operator_profile_id = users.agent.id`;
    - a link `(IT tenant, agent, ids.territory)`;
    - `tenant_settings.web_agent_commission_bps = 150` for the IT tenant (admin upsert).
  - **`upsert_agent_code`** is called with `p_agent_id: null, p_terminal_id: ids.terminal`.
  - **The POS_AGENT assertion** reads `attributed_monvelo_agent_id, attributed_terminal_id`.

- [ ] **Step 1: Write the failing tests.**
  - **Unit, `web-checkout`:** rename the fixture key. Add "a quote with `split: null` initialises Paystack without a subaccount and sends `split: null` to `place_web_order`" if no existing test covers it.
  - **Integration:** update the fixtures and assertions as above. Add these tests:
    - `pos_order_lookup: the Monvelo member finds their POS order through PostgREST`: sign in as `users.agent`; there is no tenant claim; 200 with `phone_last4`;
    - `pos_order_lookup: a member of another agent gets 422 "Order not found"`;
    - `codeless TEAFAIR checkout carries no split at the interim rate`: the payment's `split_subaccount_code` is null, and the fake Paystack Initialize received no `subaccount`;
    - `a suspended agent link invalidates the code`: ZSM `set_monvelo_agent_link_status` SUSPENDED, after which `storefront-catalogue?code=…` refuses as "This link is no longer valid". Then reactivate it, so later tests keep the link.
- [ ] **Step 2: Run** `deno test --allow-env supabase/functions/web-checkout`. Then serve the functions and run the integration suite (`INTEGRATION_FAKE_PORT` if needed). Expected: the unit test FAILs until renamed; the integration suite FAILs at the fixtures until updated.
- [ ] **Step 3: Implement** the fixture and test changes. Change no handler unless a test proves it necessary; if one does, record why in the commit.
- [ ] **Step 4: Run** `deno test --allow-all supabase/functions/`. Expected: 0 failed. Run the integration suite: 0 failed. Confirm "terminal checkout → SPLIT → release → SETTLED" still settles 93.00 at 150 bps.
- [ ] **Step 5: Commit.** `test(functions): Monvelo agents replace fintech partners in the web and integration suites (A6 §15)`

### Task 6: Docs and full verification

**Files:**
- Modify: `supabase/CLAUDE.md`, `CLAUDE.md`

- [ ] **Step 1: Run all of these:**
  - `supabase db reset`, the Vault secret, then `supabase test db`. Expected: `Result: PASS`, 42 files.
  - `deno test --allow-all supabase/functions/`. Expected: 0 failed.
  - Serve the functions, then run the integration suite. Expected: 0 failed.
  - Record the migration count, file count and assertion count.
- [ ] **Step 2: Update `supabase/CLAUDE.md`.**
  - **New section "Monvelo replaces fintech partners (A6 §15, Step 1b)":**
    - the four migrations;
    - the new tables, helpers and RPCs;
    - the commission rule (per-tenant bps, POS links only, interim 0, set by migration);
    - the member platform-actor rule;
    - ZSM linking;
    - venues by members or the operator;
    - FINTECH_AGENT retired (label kept, CHECK);
    - `issue_otp` / `verify_otp` DSA-only;
    - members can sign in.
  - **"Teafairweb retail pricing":** mark the POS agent bounty bullet as superseded by §15 (keep the fare and no-discount text).
  - **Status table:** add a row.
  - **Layout and "Writing an Edge Function":** no table names change.
  - **Deploy notes.** The remote push **drops `fintech_partners`, `fintech_terminals` and `fintech_advances`** (which the remote has) and never creates `web_agent_bounty`. It deploys with the rest of D1–A6, in order. **Pre-push checks on the remote** (each must return 0, otherwise stop and ask the user):
    - `select count(*) from public.fintech_partners;`
    - `select count(*) from public.fintech_terminals;`
    - `select count(*) from public.fintech_advances;`
    - `select count(*) from public.commission_records;`
    - `select count(*) from public.payments where fintech_partner_id is not null or fintech_terminal_id is not null;`
    - `select count(*) from public.agent_codes where terminal_id is not null;`
    - `select count(*) from public.orders where attributed_terminal_id is not null;`
    - `select count(*) from public.tenant_users where role = 'FINTECH_AGENT';`
  - **Post-deploy:**
    - the operator sets each agent's subaccount;
    - ZSMs link agents;
    - the commission rate stays 0 until the user agrees one (open question 1).
- [ ] **Step 3: Update `CLAUDE.md`:**
  - the repository-state row: migration, pgTAP and function counts, and "Monvelo replaces fintech partners (Step 1b), built locally, not pushed";
  - the project paragraph: POS agents are the Monvelo registry, linked per tenant;
  - the remote note: the push will drop the legacy tables.
- [ ] **Step 4: Commit** `docs: Monvelo replaces fintech partners (Step 1b)`. **Do not merge into `main`.** Do not push.
