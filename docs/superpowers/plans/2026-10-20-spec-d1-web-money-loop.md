# Web Money Loop (Spec D1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the seven gaps in Spec D1 §1 — a paid web order becomes `PAID`, a terminal split becomes a `SPLIT` commission that is later `SETTLED`, lost webhooks and refunds are recovered by sweeps, refunds are applied, codeless visitors can buy TEAFAIR's house brands, and every web order is routed to a territory, warehouse and accountable person when it is placed.

**Architecture:** Hand-written migrations add the location reference, coverage and routing columns, then replace the public storefront RPCs and the settlement RPC, and add refund and commission-release RPCs. Three Deno system gateways (`reconcile-funds`, `fintech-commission-release`, and the extended `process-payment`) read Paystack and call those RPCs as `service_role`. Two new public gateways (`storefront-locations`, `web-order-status`) are read-only. `pg_cron` + `pg_net` trigger the system gateways with a Vault-held secret.

**Tech Stack:** Postgres 15 (Supabase local), pgTAP, `pg_cron`, `pg_net`, Supabase Vault, Deno Edge Functions, Zod (`_shared/core/deps.ts`), Paystack REST API.

**Spec:** `docs/superpowers/specs/2026-10-20-spec-d1-web-money-loop-design.md` (Spec D1). Read §2 (decisions) before any task. Spec A §9 rules and `supabase/CLAUDE.md` ("Writing a migration / an RPC / an Edge Function") apply to every task.

## Global Constraints

- Backend only. No `teafair-web` or app code. Leave the untracked `FIGMA.md` alone.
- Nothing is pushed to remote project `vwmjyfjdwrohfizljxrq`; no `supabase db push`, no `functions deploy`, no `config push`.
- Every `SECURITY DEFINER` function: `set search_path = public, pg_temp`. Every new function: `revoke execute … from public, anon, authenticated`, then grant only what the spec says.
- §5.2 and §5.3 RPCs: execute for `service_role` only. §5.1 RPCs: execute for `authenticated`, role `ZSM`, standard write contract (`p_idempotency_key` first, `assert_tenant_role`, `idempotency_begin`/`write_audit`/`idempotency_complete`).
- No `p_tenant_id` on any client-callable RPC. The codeless tenant comes from `web_codeless_tenant()` only.
- Money `numeric(15,2)`; Paystack amounts are integer minor units; compare as `(x * 100)::bigint`.
- Errors: `P0001` business (422), `42501` forbidden. Refusal copy, exactly: `We don't deliver to this area yet.` and A1's `This link is not active yet`.
- No contact details (name, phone, email, address) in any audit row, notification payload or public response.
- Old RPC signatures are dropped, not overloaded (§5.2).
- Migration files `supabase/migrations/20261020<hhmmss>_<domain>_<topic>.sql`; pgTAP files `supabase/tests/database/0NN_<domain>_<topic>.test.sql`.
- Paystack base URL env var is the existing **`PAYSTACK_API_BASE`** (the spec's `PAYSTACK_BASE_URL` is a slip; see Paystack facts F5).
- Commit after each task with a conventional message ending in the attribution line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Paystack facts (Spec D1 §12), checked 2026-10-20

These were checked against Paystack's API reference (docs-v2.paystack.com API pages, PaystackOSS/openapi, and PaystackOSS/doc-code-snippets). The fixtures in Tasks 9–12 use these shapes.

- **F1 Verify Transaction** (`GET /transaction/verify/:reference`). `data.id` is an integer (Paystack says to treat it as unsigned 64-bit, so we store it as text). `data.status` is one of `success`, `failed`, `abandoned`, `ongoing`, `pending`, `processing`, `queued`, `reversed`. On a single-subaccount split, `data.subaccount.subaccount_code` is set and `data.fees_split` is `{ paystack, integration, subaccount, params: { bearer, transaction_charge, percentage_charge } }` in minor units. Without a split, `data.subaccount` is `{}` and `data.fees_split` is `null`. **As the spec assumed. No narrowing.**
- **F2 List Settlements** (`GET /settlement`). The documented query parameters are `perPage`, `page`, `status` (`success|processing|pending|failed`), `subaccount` ("a subaccount **ID**"; `none` means the main account only), `from` and `to`. Each item has `id` (integer), `status`, `settlement_date`, `total_amount`, …, and pagination is in `meta.pageCount`. **Narrowing:** the docs ask for the subaccount *ID*, but we store the *code*. The release job therefore resolves the id once per run with `GET /subaccount/:id_or_code` (`data.id`). It lists `status=success` settlements only.
- **F3 Settlement Transactions** (`GET /settlement/:id/transactions`, query `perPage`, `page`, `from`, `to`, with `meta.pageCount`). Items are full transaction objects: `reference`, `amount`, `subaccount`, `fees_split`. The subaccount's share is `fees_split.subaccount`. The documented sample is an unsplit transaction with `fees_split: null`, so we can't confirm the field is always present on a subaccount's settlement. **Narrowing:** when the share is missing, inclusion in the subaccount's `success` settlement is the proof of payment. The row becomes `SETTLED`, with `share_verified: false` in its audit row. When the share is present, the spec's equality check applies (`SETTLEMENT_MISMATCH`).
- **F4 Refunds.** The `refund.*` webhook `data` carries `status`, `transaction_reference`, `refund_reference` (may be null), `amount` (a **string**), `currency` and `customer`. It has **no refund id and no event timestamp**. List Refunds (`GET /refund`, query `reference` = the transaction reference, `currency`, `from`, `to` as dates, `perPage`, `page`, with `meta.pageCount`) returns items with `id` (integer), `amount` (integer minor units), `currency`, `status` (`pending|processing|processed|failed`) and `transaction` (an integer id). The OpenAPI schema also has `transaction_reference`; the older guide sample does not. The Fetch Refund path is documented inconsistently (`/refund/:reference` vs an integer id). **Narrowing:** (a) `refund.processed` skips the ±300 s replay window because the payload carries no time. This is safe because the gateway re-reads from Paystack and the writer is at-most-once per refund id. (b) Instead of Fetch Refund, the webhook re-reads with **List Refunds `?reference=<transaction_reference>`**, then applies every `processed` item. (c) In the daily pass, an item without `transaction_reference` is logged and counted as `unreadable`. It is never guessed.
- **F5 Env.** The existing code reads `PAYSTACK_API_BASE` (`supabase/functions/process-payment/index.ts`, `web-checkout/index.ts`). New functions read the same variable.
- **F6 Test mode.** The user's Paystack account is in test mode. Test-mode transactions, Verify and refunds behave as in live mode. Test mode is not expected to produce real subaccount settlements, so the release path (F2/F3) is proven against the integration fake only. Its first real check is after go-live. Record this in `supabase/CLAUDE.md` (Task 14).

## Decisions this plan makes where the spec is silent

The hand-off reports these to the user.

1. **`reversed` from Verify on a payment that is still `INITIATED`/`PROCESSING` (or `FAILED`).** The gateway calls only `apply_paystack_refund` (refund id `'reversal:' || reference`, reason `REVERSAL`, the verified amount and currency). In one transaction it moves the payment straight to `REFUNDED`, audited with the prior status, and takes the key; the order stays `PENDING`, is never marked `PAID`, and no `WEB_ORDER_PAID` notification is sent. The amount must equal the payment amount, else `REFUND_CONFLICT` (`amount_mismatch`). (Final review: the earlier settle-then-refund was two transactions and told the warehouse to ship a reversed order.)
2. **Refund conflicts while the payment is not yet `SUCCESS`** (refund webhook before the charge settles) do **not** take the at-most-once key. The daily refund pass then re-applies the refund once the charge has settled. Every other outcome takes the key.
3. **The sweep skips payments it has already decided.** `list_unconfirmed_payments` excludes any payment whose `(sweep, reference)` key is `COMPLETED` (for example a mismatch). Otherwise, fifty such rows would fill every batch.
4. **No split when the partner's share would be 0 or the whole total** (`commission_bps` 0, or 10000, or a total too small). `web_price_cart` returns `split: null`, so the `payments_split_*` constraints can never make checkout fail with a 500.
5. **The split snapshot is the quote's.** `web-checkout` passes the quote's split inside `p_checkout.split`. `place_web_order` recomputes it and refuses `Prices changed — refresh and try again` on any difference (spec §8.2: Initialize and the snapshot come from the same quote).
6. **LGA ids are deterministic:** `md5('ng_lga:' || state_code || ':' || name)::uuid`, so every environment has the same id for the same LGA.
7. **Cron authentication header** is `x-cron-secret`.

## Review Focus

1. **A partner with `commission_bps` of 0 or 10000.** Checkout must still work, with no split (Task 4, `place_web_order` with a 0-bps partner).
2. **Sweep starvation.** Fifty `mismatch` payments must not stop newer payments from being swept (Task 5, `list_unconfirmed_payments` excludes decided rows).
3. **A refund that arrives before its charge settles.** The refund must still land later (Task 6, conflict-then-retry test).
4. **A bad `lga_id`.** An unknown uuid, or an LGA from a state with no coverage, must give the clean `P0001` refusal, never an FK 500 (Task 3, Task 4).
5. **A `reversed` status from the sweep on an unconfirmed payment.** One `apply_paystack_refund` call: the payment ends `REFUNDED` and drops out of the sweep, the order stays `PENDING` (never `PAID`) and no `WEB_ORDER_PAID` notification is sent (Task 10, `settleVerified` reversed branch; `017` reversal tests).

---

## File structure

```
supabase/migrations/
  20261020120000_commerce_ng_locations.sql             ng_states, ng_lgas + seed (T1)
  20261020120100_commerce_web_routing_schema.sql       territory_coverage, columns, triggers, constraints, legacy cancel (T2)
  20261020120200_commerce_web_routing.sql              web_route type, routing fns, §5.1 RPCs (T3)
  20261020120300_commerce_web_storefront_codeless.sql  §5.2 RPCs replaced/added (T4)
  20261020130000_fintech_liquidity_settlement.sql      notify helper, settle_paystack_payment v2, list_unconfirmed_payments (T5)
  20261020130100_fintech_liquidity_refunds.sql         apply_paystack_refund (T6)
  20261020130200_fintech_liquidity_commission_release.sql  list_unsettled_subaccounts, release_commission, expire_unsettled_commissions (T7)
  20261020130300_fintech_liquidity_cron.sql            pg_net, invoke_system_function, 3 cron jobs (T8)
supabase/tests/database/
  014_commerce_web_locations_routing.test.sql  (T1–T4)
  015_fintech_liquidity_web_settlement.test.sql (T5)
  016_fintech_liquidity_commission_release.test.sql (T7)
  017_fintech_liquidity_refunds.test.sql (T6)
  018_d1_security.test.sql (T8)
  009, 012, 013 — updated for the new signatures (T4, T5)
supabase/functions/
  _shared/core/cron.ts (+ .test.ts)                       x-cron-secret check (T9)
  _shared/fintech-liquidity/paystack.ts (+ test)          Verify gains id + split (T9)
  _shared/fintech-liquidity/paystack-client.ts (+ test)   GET + pagination (T9)
  _shared/fintech-liquidity/paystack-refunds.ts (+ test)  List Refunds (T9)
  _shared/fintech-liquidity/paystack-settlements.ts (+ test)  subaccount id, settlements, settlement txns (T9)
  _shared/fintech-liquidity/settle.ts (+ test)            settleVerified, applyRefunds (T10)
  process-payment/handler.ts, index.ts (+ test)           refund.processed (T10)
  reconcile-funds/{index,handler,handler.test}.ts         (T11)
  fintech-commission-release/{index,handler,handler.test}.ts (T12)
  storefront-catalogue/handler.ts (+ test)                code optional (T13)
  web-checkout/handler.ts (+ test)                        code optional, lga_id, split in p_checkout (T13)
  storefront-locations/{index,handler,handler.test}.ts    (T13)
  web-order-status/{index,handler,handler.test}.ts        (T13)
  _tests/gateway.integration.ts                           D1 flows (T14)
supabase/config.toml, supabase/functions/.env.example, supabase/CLAUDE.md, CLAUDE.md (T8, T14)
```

Commands used throughout (from `supabase/`):

```bash
supabase migration up                                   # apply new migrations
supabase test db                                        # all pgTAP; expect "Result: PASS"
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qAt -f tests/database/<file>   # one file
deno test --allow-env functions/                        # all Deno unit tests
```

---

### Task 1: Nigerian states and LGAs

**Files:**
- Create: `supabase/migrations/20261020120000_commerce_ng_locations.sql`
- Test: `supabase/tests/database/014_commerce_web_locations_routing.test.sql` (new; Tasks 2–4 append to it)

**Interfaces:**
- Produces: `public.ng_states(code text pk, name text unique)`; `public.ng_lgas(id uuid pk, state_code text → ng_states, name text, unique(state_code, name))`, with `id = md5('ng_lga:'||state_code||':'||name)::uuid`.

The state codes are ISO 3166-2:NG. Here they are with the INEC LGA count for each; the migration asserts every count:

`AB` Abia 17 · `AD` Adamawa 21 · `AK` Akwa Ibom 31 · `AN` Anambra 21 · `BA` Bauchi 20 · `BY` Bayelsa 8 · `BE` Benue 23 · `BO` Borno 27 · `CR` Cross River 18 · `DE` Delta 25 · `EB` Ebonyi 13 · `ED` Edo 18 · `EK` Ekiti 16 · `EN` Enugu 17 · `FC` Federal Capital Territory 6 · `GO` Gombe 11 · `IM` Imo 27 · `JI` Jigawa 27 · `KD` Kaduna 23 · `KN` Kano 44 · `KT` Katsina 34 · `KE` Kebbi 21 · `KO` Kogi 21 · `KW` Kwara 16 · `LA` Lagos 20 · `NA` Nasarawa 13 · `NI` Niger 25 · `OG` Ogun 20 · `ON` Ondo 18 · `OS` Osun 30 · `OY` Oyo 33 · `PL` Plateau 17 · `RI` Rivers 23 · `SO` Sokoto 23 · `TA` Taraba 16 · `YO` Yobe 17 · `ZA` Zamfara 14 (total 774).

LGA names come from INEC's published list of 774 LGAs. Spell names as INEC does, including Lagos's `Eti-Osa`, `Ibeju-Lekki`, `Ikeja`, `Ikorodu`, `Lagos Island`, `Lagos Mainland`. The per-state counts are the check that the transcription is complete.

- [ ] **Step 1: Write the failing test** in `014_…test.sql` (pgTAP file header as in `012`):

```sql
select is((select count(*)::int from public.ng_states), 37, 'exactly 37 states (FCT included)');
select is((select count(*)::int from public.ng_lgas), 774, 'exactly 774 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'LA'), 20, 'Lagos has 20 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'FC'), 6, 'FCT has 6 area councils');
select is((select id from public.ng_lgas where state_code = 'LA' and name = 'Ikeja'),
          md5('ng_lga:LA:Ikeja')::uuid, 'LGA ids are deterministic');
select ok(has_table_privilege('authenticated', 'public.ng_lgas', 'select'), 'authenticated reads LGAs');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'insert'), 'no write grant on LGAs');
select throws_ok($$insert into public.ng_states values ('lagos', 'X')$$, '23514', null, 'state code is two capitals');
```

- [ ] **Step 2: Run it.** `psql … -f tests/database/014_commerce_web_locations_routing.test.sql`. Expected: FAIL, relation `public.ng_states` does not exist.
- [ ] **Step 3: Write the migration.** Create both tables as in spec §3.1, with `enable row level security`, a `FOR SELECT to authenticated using (true)` policy on each, and `grant select … to authenticated`. Seed with `insert … select`. Then a `do $$` block raises an exception unless there are 37 states, 774 LGAs and each state's count matches the table above.
- [ ] **Step 4: Run it.** `supabase migration up`, then the file. Expected: all pass.
- [ ] **Step 5: Commit.** `feat(db): Nigerian states and LGAs reference (D1 §3.1)`

---

### Task 2: Coverage, routing columns and constraints

**Files:**
- Create: `supabase/migrations/20261020120100_commerce_web_routing_schema.sql`
- Test: append to `014_…test.sql`

**Interfaces:**
- Produces: `public.territory_coverage` (spec §3.2); the columns in spec §3.3; the constraints `orders_online_routed`, `orders_codeless_pays_online`, `payments_split_snapshot_complete` and `payments_split_within_amount`; the triggers `territory_coverage_lga_in_state`, `territories_web_warehouse_check` and `tenant_settings_web_defaults_check`.

- [ ] **Step 1: Write the failing tests.** Fixtures: tenant `T1`, with a zone, territories `Ikeja` and `Epe`, warehouses `REG-IKEJA` (REGIONAL, territory Ikeja), `REG-EPE` (REGIONAL, territory Epe) and `CENTRAL-1` (CENTRAL), plus tenant `T2` with its own warehouse. Assertions:

```sql
-- coverage
select lives_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
                  values (:T1, 'LA', md5('ng_lga:LA:Ikeja')::uuid, :IKEJA)$$, 'LGA row');
select lives_ok($$… values (:T1, 'LA', null, :EPE)$$, 'state fallback row');
select throws_ok($$… values (:T1, 'LA', null, :IKEJA)$$, '23505', null, 'a second state fallback is rejected (NULLS NOT DISTINCT)');
select throws_ok($$… values (:T1, 'OG', md5('ng_lga:LA:Ikeja')::uuid, :IKEJA)$$, 'P0001', null, 'LGA must belong to the state');
-- warehouse pointers
select throws_ok($$update public.territories set web_fulfilment_warehouse_id = :CENTRAL1 where id = :IKEJA$$, 'P0001', null, 'territory pointer must be REGIONAL');
select throws_ok($$update public.territories set web_fulfilment_warehouse_id = :REG_EPE where id = :IKEJA$$, 'P0001', null, 'regional warehouse must belong to this territory');
select lives_ok($$update public.territories set web_fulfilment_warehouse_id = :REG_IKEJA where id = :IKEJA$$, 'own regional warehouse');
select throws_ok($$update public.tenant_settings set web_default_warehouse_id = :REG_IKEJA where tenant_id = :T1$$, 'P0001', null, 'default must be CENTRAL');
select throws_ok($$update public.tenant_settings set web_default_warehouse_id = :T2_WAREHOUSE where tenant_id = :T1$$, '23503', null, 'default must be same tenant');
-- orders / payments constraints
select throws_ok(<insert ONLINE PENDING order with delivery_lga_id null>, '23514', null, 'orders_online_routed');
select lives_ok(<insert ONLINE CANCELLED order with no routing>, 'cancelled orders need no routing');
select throws_ok(<insert routed ONLINE order, agent_code_id null, payment_route POS_AGENT>, '23514', null, 'orders_codeless_pays_online');
select throws_ok(<insert payment with split_bps set, split_amount null>, '23514', null, 'split snapshot all-or-none');
select throws_ok(<insert payment amount 100, split_amount 100 (+code, bps)>, '23514', null, 'split below amount');
```

Use literal uuids in the file, as `012` does. The `:NAME` placeholders above are for reading only.

- [ ] **Step 2: Run it.** Expected: FAIL, relation `territory_coverage` does not exist.
- [ ] **Step 3: Write the migration**, in this order:
  1. `territory_coverage` per spec §3.2. Composite FK `(tenant_id, territory_id) → territories(tenant_id, id)`, `unique nulls not distinct (tenant_id, state_code, lga_id)`, RLS `FOR SELECT to authenticated using (tenant_id in (select public.my_tenant_ids()))`, `grant select`, indexes on `(tenant_id, territory_id)` and `lga_id`, and the `set_updated_at` trigger. Add a `before insert or update` trigger that raises `P0001` `the LGA is not in that state` when `lga_id` is not in `state_code`.
  2. Columns from spec §3.3. `territories.web_fulfilment_warehouse_id` gets a composite FK `(tenant_id, …) → warehouses`. `tenant_settings.web_default_warehouse_id` gets a composite FK `(tenant_id, …) → warehouses(tenant_id, id)`, and `web_default_agent_id` an FK to `profiles`. `orders.delivery_lga_id` references `ng_lgas`. `orders.territory_id` and `orders.fulfilment_warehouse_id` get composite FKs. Add the three `payments.split_*` columns with their checks, and `commission_records.paystack_settlement_id text`.
  3. Trigger functions. Territory pointer: the warehouse must have `kind = 'REGIONAL'` and `territory_id = new.id`, else `P0001` `a territory ships web orders from its own regional warehouse`. Default warehouse: `kind = 'CENTRAL'`, else `P0001` `the default web warehouse must be a CENTRAL warehouse`. Default agent: must be an `ACTIVE` member of the tenant, else `P0001` `the default web agent must be an active member of this tenant`.
  4. Legacy cancel (spec §3.4). For each `ONLINE` `PENDING` order with `delivery_lga_id is null`, set it to `CANCELLED` and `perform write_audit(tenant_id, 'D1_LEGACY_CANCEL', 'orders', id::text, '{"status":"PENDING"}', '{"status":"CANCELLED"}', null, 'SYSTEM', teafair_agent_id)`.
  5. Add the four constraints, validated, and the three indexes from spec §3.4.
  6. Re-issue the `payments` column grant to `authenticated`: the existing list plus `split_subaccount_code, split_bps, split_amount`.
- [ ] **Step 4: Run** `supabase migration up`, then `014`. Expected: PASS. Run `supabase test db`. Expected: `012` and `013` FAIL where they insert routed-less web orders through `place_web_order`. Task 4 fixes them; note the count.
- [ ] **Step 5: Commit.** `feat(db): territory coverage, web routing columns and constraints (D1 §3.2–3.4)`

---

### Task 3: Routing and the management RPCs

**Files:**
- Create: `supabase/migrations/20261020120200_commerce_web_routing.sql`
- Test: append to `014_…test.sql`

**Interfaces:**
- Consumes: Task 2 schema; existing `public.agent_codes`, `public.assert_tenant_role`.
- Produces:
  - `create type public.web_route as (territory_id uuid, warehouse_id uuid, accountable_id uuid)`
  - `public.web_codeless_tenant() returns uuid`. The `ACTIVE` tenant with `code = 'TEAFAIR'`; none → `P0001` `This shop is not open yet`.
  - `public.web_route_try(p_tenant_id uuid, p_code public.agent_codes, p_lga_id uuid) returns public.web_route`. `STABLE`, never raises; a field is null where its step found nothing. `p_code` is null for codeless.
  - `public.web_route_order(p_tenant_id uuid, p_code public.agent_codes, p_lga_id uuid) returns public.web_route`. Calls `web_route_try`. An unknown `p_lga_id` raises `P0001` `choose a delivery area from the list`. Coded with null accountable → `This link is not active yet`. Any other null (territory, warehouse, codeless accountable) → `We don't deliver to this area yet.`
  - `public.set_territory_coverage(p_idempotency_key uuid, p_state_code text, p_lga_id uuid, p_territory_id uuid) returns jsonb` → `{coverage_id}` (null when deleted)
  - `public.set_territory_web_warehouse(p_idempotency_key uuid, p_territory_id uuid, p_warehouse_id uuid) returns jsonb` → `{territory_id, warehouse_id}`
  - `public.set_web_defaults(p_idempotency_key uuid, p_warehouse_id uuid, p_agent_id uuid) returns jsonb` → `{warehouse_id, agent_id}` (upserts `tenant_settings`)

The algorithm is spec §4, steps 1–3, verbatim. Coded territory = `coalesce(terminal.territory_id, holder.territory_id)`, falling back to coverage when both are null. Accountable candidates (TM, ZSM, default agent) count only when they hold an `ACTIVE` `tenant_users` row in the tenant.

- [ ] **Step 1: Write the failing tests.** Reuse Task 2's fixtures. Add a TM on Ikeja, a ZSM on the zone, a DSA code holder, a FINTECH_AGENT with a terminal in Ikeja, a FINTECH_AGENT with a terminal with no territory whose holder also has no territory (`tenant_users.territory_id` is required for FINTECH_AGENT, so give the holder the territory `Epe` with no TM, and test the "coded, no TM" path there), and coverage `LA/Ikeja → Ikeja` and `LA/null → Epe`. Assertions (`(r).territory_id` etc.):

```sql
-- codeless
select is((public.web_route_try(:T1, null, md5('ng_lga:LA:Ikeja')::uuid)).territory_id, :IKEJA, 'LGA hit');
select is((public.web_route_try(:T1, null, md5('ng_lga:LA:Epe')::uuid)).territory_id, :EPE, 'state fallback');
select is((public.web_route_try(:T1, null, md5('ng_lga:LA:Epe')::uuid)).warehouse_id, :CENTRAL1, 'CENTRAL fallback when the territory has no regional warehouse');
select throws_ok($$select public.web_route_order(:T1, null, md5('ng_lga:KN:Fagge')::uuid)$$, 'P0001', 'We don''t deliver to this area yet.', 'uncovered state refused');
select throws_ok($$select public.web_route_order(:T1, null, gen_random_uuid())$$, 'P0001', 'choose a delivery area from the list', 'unknown LGA is a clean refusal');
select is((public.web_route_try(:T1, null, <Ikeja lga>)).accountable_id, :TM, 'codeless → territory TM');
-- after disabling the TM: ZSM; after also clearing zsm: default agent; then refusal
select is(<…>, :ZSM, 'inactive TM skipped → ZSM');
select is(<…>, :DEFAULT_AGENT, 'no ZSM → web_default_agent_id');
select throws_ok(<default agent DISABLED>, 'P0001', 'We don''t deliver to this area yet.', 'no accountable person refused');
-- coded
select is((public.web_route_order(:T1, <DSA code row>, <Kano lga>)).accountable_id, :DSA, 'staff holder accountable for own sale, LGA ignored for territory');
select is((public.web_route_order(:T1, <POS code row>, <Ikeja lga>)).accountable_id, :TM, 'FINTECH_AGENT code → TM of terminal territory');
select throws_ok(<POS code in Epe (no TM)>, 'P0001', 'This link is not active yet', 'coded, no TM');
-- territory set but no warehouse at all (clear CENTRAL default)
select throws_ok(<…>, 'P0001', 'We don''t deliver to this area yet.', 'no warehouse refused');
-- management RPCs (act as ZSM through request.jwt.claims, as 011 does)
select lives_ok(<set_territory_coverage as ZSM>, 'ZSM sets coverage');
select is(<set_territory_coverage(key, 'LA', ikeja_lga, null) ->> 'coverage_id'>, null, 'null territory deletes the row');
select throws_ok(<set_territory_coverage as TM>, '42501', null, 'TM cannot set coverage');
select throws_ok(<set_web_defaults as TM>, '42501', null, 'TM cannot set defaults');
select throws_ok(<set_territory_web_warehouse as DSA>, '42501', null, 'DSA cannot set warehouse');
select ok(not has_function_privilege('authenticated', 'public.web_route_order(uuid,public.agent_codes,uuid)', 'execute'), 'routing is internal');
```

- [ ] **Step 2: Run it.** Expected: FAIL, function `web_route_try` does not exist.
- [ ] **Step 3: Write the migration.** Follow spec §4 and the write-RPC skeleton in `supabase/CLAUDE.md`. Revoke `web_codeless_tenant`, `web_route_try` and `web_route_order` from `public, anon, authenticated, service_role`. Grant the three management RPCs to `authenticated`.
- [ ] **Step 4: Run it.** Expected: the `014` assertions so far PASS.
- [ ] **Step 5: Commit.** `feat(db): web order routing and coverage management RPCs (D1 §4, §5.1)`

---

### Task 4: Public storefront RPCs — codeless, routed, split snapshot, locations, status

**Files:**
- Create: `supabase/migrations/20261020120300_commerce_web_storefront_codeless.sql`
- Modify: `supabase/tests/database/012_commerce_web_public.test.sql`, `013_commerce_buyer_privacy.test.sql`. Give their fixtures a REGIONAL warehouse per used territory, plus coverage. Pass `p_lga_id` and `p_checkout.split`. Update the `has_function_privilege` signatures.
- Test: append to `014_…test.sql`

**Interfaces:**
- Consumes: Task 3 routing functions; existing `web_resolve_code(text)` and `web_price_cart(agent_codes, jsonb)`.
- Produces (all `service_role` only):
  - internal `public.web_storefront_code(p_code text) returns public.agent_codes`. A null or blank code → a row with only `tenant_id := web_codeless_tenant()`. Otherwise `web_resolve_code(p_code)`.
  - `web_price_cart` change: `split` is non-null only when `0 < partner_share < total` (Decision 4). Its shape stays `{fintech_partner_id, subaccount_code, commission_bps, partner_share}`.
  - `public.storefront_catalogue(p_code text default null) returns jsonb`. Same body, through `web_storefront_code`. `code` is null when codeless.
  - `public.quote_web_order(p_code text, p_items jsonb, p_lga_id uuid) returns jsonb`. Same reply as A1, after `web_route_order` succeeds. Drop `quote_web_order(text, jsonb)`.
  - `public.place_web_order(p_idempotency_key uuid, p_code text, p_items jsonb, p_customer jsonb, p_utm jsonb, p_payment_route text, p_expected_total numeric, p_checkout jsonb, p_lga_id uuid) returns jsonb`. Same reply as A2. Drop the 8-argument version.
  - `public.storefront_locations(p_code text default null) returns jsonb` → `{states: [{code, name, lgas: [{id, name, deliverable}]}]}`, ordered by state name, then LGA name.
  - `public.web_order_status(p_public_reference text, p_paystack_reference text) returns jsonb`. Returns `{public_reference, order_status, payment_status, total, currency, lines: [{name, qty, unit_price}]}`, or **null** when the pair doesn't match one order and its payment.

`place_web_order` changes to the A2 body (`20261015130100_…`):
1. Add `'lga_id', p_lga_id` to the idempotency request jsonb.
2. Replace the accountable/territory block with `v_route := web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id)`.
3. For `PAYSTACK_WEB`, `p_checkout -> 'split'` must equal `jsonb_build_object('subaccount_code', …, 'commission_bps', …, 'partner_share', …)` of `v_cart -> 'split'`, or both must be JSON null. Otherwise raise `Prices changed — refresh and try again`.
4. Stamp `orders.delivery_lga_id`, `territory_id`, `fulfilment_warehouse_id` and `teafair_agent_id = v_route.accountable_id`, and set `order_contacts.territory_id = v_route.territory_id`. Fill `payments.split_*` from the cart split.

The existing "paying at an agent needs a link from a POS agent" check already refuses codeless + `POS_AGENT`, because the synthetic code has no terminal.

`storefront_locations`: `deliverable` is true when `web_route_try` returns no null fields. For coded links, also require `accountable_id`.

- [ ] **Step 1: Write the failing tests** in `014`. Fixtures: TEAFAIR (`7eaf0000-0000-4000-8000-000000000001`) gets a zone, a territory with a TM, a REGIONAL warehouse, coverage `LA/Ikeja` and an active product. Tenant T1 gets a partner with `commission_bps = 0` and a code on its terminal.

```sql
select is(public.storefront_catalogue(null) -> 'tenant' ->> 'name', 'Teafair', 'codeless catalogue is TEAFAIR');
select is(public.storefront_catalogue('  ') -> 'tenant' ->> 'name', 'Teafair', 'blank code is codeless');
select throws_ok($$select public.quote_web_order(null, '[{"sku_code":"TF-TEA-50","qty":1}]', md5('ng_lga:KN:Fagge')::uuid)$$,
                 'P0001', 'We don''t deliver to this area yet.', 'quote refuses before Paystack');
select is(public.quote_web_order(null, '[…]', <Ikeja>) -> 'split', 'null'::jsonb, 'codeless has no split');
select is(public.quote_web_order('ZERO-BPS', '[…]', <Ikeja>) -> 'split', 'null'::jsonb, 'a 0-bps partner gets no split');
-- codeless PAYSTACK_WEB order
select lives_ok(<place_web_order(key1, null, items, customer, '{}', 'PAYSTACK_WEB', total, '{"reference":"TFW-…","authorization_url":"https://x","split":null}', <Ikeja>)>, 'codeless order placed');
select is(<orders row of key1: (agent_code_id, territory_id, fulfilment_warehouse_id, teafair_agent_id)>, <(null, TF territory, TF warehouse, TF TM)>, 'codeless order routed and stamped');
select is(<order_contacts.territory_id of key1>, <TF territory>, 'contacts territory = orders territory');
select throws_ok(<codeless with 'POS_AGENT'>, 'P0001', 'paying at an agent needs a link from a POS agent', 'codeless must pay online');
select throws_ok(<GRACE-01 order with p_checkout.split = null though quote has a split>, 'P0001', 'Prices changed — refresh and try again', 'split snapshot must match the quote');
select is(<payments.split_amount, split_bps, split_subaccount_code of a GRACE-01 order>, <quote's split>, 'payment carries the split snapshot');
select throws_ok(<replay key1 with a different p_lga_id>, 'TF002', null, 'lga_id is in the idempotency hash');
-- locations
select is(jsonb_array_length(public.storefront_locations(null) -> 'states'), 37, '37 states');
select is(<deliverable of LA/Ikeja in storefront_locations(null)>, true, 'covered LGA deliverable');
select is(<deliverable of KN/Fagge>, false, 'uncovered LGA not deliverable');
select ok(position(<TF territory id> in public.storefront_locations(null)::text) = 0, 'no territory ids exposed');
-- status
select is(public.web_order_status(<ref of key1>, 'TFW-…') ->> 'order_status', 'PENDING', 'status read by the pair');
select is(public.web_order_status(<ref of key1>, 'TFW-other'), null, 'mismatched pair is null');
select ok(position('+234' in public.web_order_status(<ref>, <pref>)::text) = 0, 'no contact details in status');
select ok(not has_function_privilege('anon', 'public.web_order_status(text,text)', 'execute'), 'status is service_role only');
```

- [ ] **Step 2: Run it.** Expected: FAIL, function `quote_web_order(unknown, unknown, uuid)` does not exist.
- [ ] **Step 3: Write the migration** as described above. Copy A2's `place_web_order` body and apply only the four listed changes. Grant `storefront_catalogue(text)`, `quote_web_order(text,jsonb,uuid)`, `place_web_order(…9 args…)`, `storefront_locations(text)` and `web_order_status(text,text)` to `service_role` only.
- [ ] **Step 4: Update `012` and `013`.** Add fixtures: a REGIONAL warehouse on each used territory with `web_fulfilment_warehouse_id` set. Change every `quote_web_order` / `place_web_order` call to the new signatures (`p_lga_id` = Lagos/Ikeja; `p_checkout.split` = the quote's split). Every existing assertion keeps its meaning. Adjust `plan(n)`.
- [ ] **Step 5: Run** `supabase test db`. Expected: everything PASS except `009` (Task 5).
- [ ] **Step 6: Commit.** `feat(db): codeless storefront, routed web orders, split snapshot, locations and status reads (D1 §5.2)`

---

### Task 5: Collection settlement

**Files:**
- Create: `supabase/migrations/20261020130000_fintech_liquidity_settlement.sql`
- Modify: `supabase/tests/database/009_fintech_liquidity_paystack_webhook.test.sql` (new signature; its order fixtures become routed `FIELD_DSA` orders, which `orders_online_routed` does not constrain)
- Test: `supabase/tests/database/015_fintech_liquidity_web_settlement.test.sql`

**Interfaces:**
- Produces:
  - internal `public.notify_tenant_zsms(p_tenant_id uuid, p_kind text, p_title text, p_body text, p_payload jsonb) returns integer`. One `notifications` row per `ACTIVE` ZSM.
  - `public.settle_paystack_payment(p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb, p_transaction_id text, p_split_subaccount text, p_split_share_minor bigint) returns jsonb`. `outcome` ∈ `unknown_reference | ambiguous_reference | not_final | mismatch | unchanged | conflict | updated`. On `updated` the reply also carries `payment_status`, `order_status` and `commission_status` (each may be null). Drop the 6-argument version.
  - `public.list_unconfirmed_payments(p_limit integer) returns table(paystack_reference text, created_at timestamptz)`. `INITIATED`/`PROCESSING` payments older than 5 minutes, oldest first, excluding any payment whose key `md5('paystack:sweep:' || paystack_reference)::uuid` is `COMPLETED` in `idempotency_logs` (Decision 3).

Behaviour is spec §6.1–6.2 exactly. Age = `now() - payments.created_at`. `p_status = 'reversed'` raises `P0001` `reversed is applied by apply_paystack_refund`. Audit source: `case when p_event = 'sweep' then 'CRON' else 'WEBHOOK' end`. Audit operations: `settle_paystack_payment`, `PAYSTACK_MISMATCH`, `LATE_SUCCESS`, `PAID_AFTER_CANCEL`, `SWEEP_EXPIRED`, `SPLIT_MISMATCH`. Notification kinds and copy:
- `WEB_ORDER_PAID` — title `Web order paid`, body `Order <public_reference> is paid and ready to ship.`, payload `{order_id, public_reference}`.
- `WEB_ORDER_PAID_AFTER_CANCEL` (ZSMs) — title `Paid order was cancelled`, body `Order <public_reference> was paid after it was cancelled. Refund or reinstate it.`
- `COMMISSION_DISPUTED` (ZSMs) — title `Commission disputed`, body `A partner commission needs review (<reason>).`, payload `{commission_id, order_id, reason}`.

- [ ] **Step 1: Write the failing tests** in `015`. Fixtures: a tenant with a territory, TM, a REGIONAL warehouse with a `manager_id`, a ZSM and an ACTIVE partner `ACCT_grace01`. Routed ONLINE orders and payments are inserted directly as postgres, with `created_at` set per case. One payment carries a split snapshot (`split_amount 37.50`, `split_bps 150`, `split_subaccount_code 'ACCT_grace01'`, amount 2500).

```sql
select is(<settle('charge.success', 'r_ok', 'success', 250000, 'NGN', '{}', '9001', null, null) ->> 'order_status'>, 'PAID', 'PENDING → PAID');
select is(<count commission_records for r_ok>, 0, 'no snapshot, no commission row');
select is(<count notifications kind WEB_ORDER_PAID for r_ok>, 2, 'warehouse manager and TM notified');
select is(<… manager = TM case>, 1, 'recipients deduplicated');
select is(<settle(…'r_split'…, '9002', 'ACCT_grace01', 3750) ->> 'commission_status'>, 'SPLIT', 'matching split → SPLIT');
select is(<commission_records r_split: (amount, bps_applied, paystack_split_reference)>, <(37.50, 150, '9002')>, 'row copies the snapshot');
select is(<settle(…'r_split_bad'…, 'ACCT_other', 3750) ->> 'commission_status'>, 'DISPUTED', 'wrong subaccount → DISPUTED');
select is(<dispute_reason>, 'SPLIT_MISMATCH', 'reason SPLIT_MISMATCH');
select is(<count COMMISSION_DISPUTED notifications>, <ZSM count>, 'ZSMs told about the dispute');
select is(<settle(…'r_aband_new' (created 1 h ago), 'abandoned'…) ->> 'outcome'>, 'not_final', 'abandoned under 2 h is not final');
select is(<settle(…'r_aband_old' (3 h)…) ->> 'outcome'>, 'updated', 'abandoned over 2 h fails');
select is(<settle(…'r_pend_old' (73 h), 'ongoing'…) payment_status>, 'FAILED', 'non-final over 72 h fails');
select is(<count audit SWEEP_EXPIRED>, 1, 'audited SWEEP_EXPIRED');
select is(<settle success on a FAILED payment; count audit LATE_SUCCESS>, 1, 'LATE_SUCCESS');
select is(<settle success on a CANCELLED order: order status>, 'CANCELLED', 'order left as it is');
select is(<count audit PAID_AFTER_CANCEL + notifications WEB_ORDER_PAID_AFTER_CANCEL>, <1, ZSM count>, 'escalated');
select is(<settle('sweep', 'r_ok', 'success', …) ->> 'outcome'>, 'unchanged', 'webhook then sweep: unchanged');
select is(<settle(… amount 1 …) ->> 'outcome'>, 'mismatch', 'amount mismatch');
select is(<payment and order status after mismatch>, <INITIATED, PENDING>, 'mismatch changes nothing');
select is(<'r_mismatch' in list_unconfirmed_payments(50)> after a sweep mismatch, false, 'a decided payment leaves the sweep');
select is(<oldest-first order of list_unconfirmed_payments(50)>, <expected refs>, 'oldest first, >5 min only');
select throws_ok(<settle(…'reversed'…)>, 'P0001', null, 'reversed is not settled here');
select is(<web_resolve_code for a max_redemptions=1 code with one PAID order>, <raises>, 'PAID orders count toward max_redemptions');
select is(<audit_logs.teafair_agent_id of the settle row>, <payment teafair_agent_id>, 'audit carries the accountable agent');
```

- [ ] **Step 2: Run it.** Expected: FAIL, settle function with 9 arguments does not exist.
- [ ] **Step 3: Write the migration.** Start from `settle_paystack_payment` in `20261007120300_…`. Keep the reference lookup and the at-most-once key. Remove `abandoned → FAILED` and `reversed → REFUNDED` from the immediate map, and add spec §6.1's age rules before `idempotency_begin`. Lock the payment `FOR UPDATE`, then the order `FOR UPDATE`. Add spec §6.2 steps 3–5. `drop function public.settle_paystack_payment(text,text,text,bigint,text,jsonb)`. Grant the new functions to `service_role` only.
- [ ] **Step 4: Update `009`** to the 9-argument call (`p_transaction_id` = `'1'`, no split). Update its signatures, then its expectations: `abandoned` on a fresh payment is now `not_final`, and `reversed` now raises.
- [ ] **Step 5: Run** `supabase test db`. Expected: `Result: PASS`.
- [ ] **Step 6: Commit.** `feat(db): web settlement — PAID, commission rows, sweep rules (D1 §6)`

---

### Task 6: Refunds and reversals

**Files:**
- Create: `supabase/migrations/20261020130100_fintech_liquidity_refunds.sql`
- Test: `supabase/tests/database/017_fintech_liquidity_refunds.test.sql`

**Interfaces:**
- Consumes: `notify_tenant_zsms` (Task 5).
- Produces: `public.apply_paystack_refund(p_source text, p_refund_id text, p_transaction_reference text, p_amount_minor bigint, p_currency text, p_reason text, p_verified jsonb) returns jsonb`, `service_role` only.
  - `p_source` ∈ `webhook | sweep` (audit `WEBHOOK | CRON`); `p_reason` ∈ `REFUND | REVERSAL`.
  - Key: `md5('paystack-refund:' || p_refund_id)::uuid`.
  - `outcome` ∈ `refunded | partial | conflict`, with `payment_id` when known.

The cases are spec §9's table. Conflict audit operation: `REFUND_CONFLICT`, with `{reason: 'payment_not_success' | 'unknown_reference' | 'currency_mismatch' | 'over_refund'}`. Per Decision 2, a `payment_not_success` conflict returns **before** `idempotency_begin` (the key is not taken); every other path takes it. On a full refund, every `SPLIT`/`SETTLED` commission row on the payment becomes `DISPUTED` / `ORDER_REFUNDED`, with a `COMMISSION_DISPUTED` notification. Partial refunds send kind `PAYMENT_PARTIALLY_REFUNDED`, title `Partial refund`, body `Order <public_reference> was partly refunded (<amount> <currency>).`

- [ ] **Step 1: Write the failing tests** in `017`. Fixtures: three SUCCESS payments with PAID orders, one with a `SETTLED` commission; one INITIATED payment.

```sql
select is(<apply('webhook','5001','r_full',250000,'NGN','REFUND','{}') ->> 'outcome'>, 'refunded', 'full refund');
select is(<payment, order status r_full>, <REFUNDED, REFUNDED>, 'payment and order REFUNDED');
select is(<commission r_full: status, dispute_reason>, <DISPUTED, ORDER_REFUNDED>, 'commission disputed on refund');
select is(<apply('webhook','5001',…) again ->> 'outcome'>, 'refunded', 'replay of one refund id returns the first reply');
select is(<count audit rows for refund 5001>, 1, 'replay writes nothing');
select is(<apply(…'5002','r_part',100000…) ->> 'outcome'>, 'partial', 'partial refund');
select is(<payment status r_part; count PAYMENT_PARTIALLY_REFUNDED>, <SUCCESS, ZSMs>, 'no status change, ZSMs told');
select is(<apply('sweep','reversal:r_rev','r_rev',…,'REVERSAL',…) ->> 'outcome'>, 'refunded', 'reversal');
select is(<audit after for r_rev ->> 'reason'>, 'REVERSAL', 'reason REVERSAL');
select is(<apply(…'5003','r_unknown'…) ->> 'outcome'>, 'conflict', 'unknown reference');
select is(<apply(… currency 'GHS' …) ->> 'outcome'>, 'conflict', 'currency mismatch');
-- Decision 2: early refund then late success
select is(<apply('webhook','5004','r_init',…) ->> 'outcome'>, 'conflict', 'refund before settle conflicts');
select lives_ok(<settle_paystack_payment('charge.success','r_init','success',…)>, 'charge then settles');
select is(<apply('sweep','5004','r_init',…) ->> 'outcome'>, 'refunded', 'refund pass re-applies once the charge is SUCCESS');
select ok(not has_function_privilege('authenticated', 'public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)', 'execute'), 'service_role only');
```

- [ ] **Step 2: Run it.** Expected: FAIL, function does not exist.
- [ ] **Step 3: Write the migration.** Lock the payment, then the order, `FOR UPDATE`.
- [ ] **Step 4: Run** `017`, then `supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): apply_paystack_refund — refunds and reversals (D1 §9)`

---

### Task 7: Commission release RPCs

**Files:**
- Create: `supabase/migrations/20261020130200_fintech_liquidity_commission_release.sql`
- Test: `supabase/tests/database/016_fintech_liquidity_commission_release.test.sql`

**Interfaces:**
- Produces (`service_role` only):
  - `public.list_unsettled_subaccounts() returns table(subaccount_code text, oldest_at timestamptz, references text[])`. `SPLIT` rows older than 24 h, grouped by `paystack_subaccount_code`; `references` are the payments' `paystack_reference`s.
  - `public.release_commission(p_settlement_id text, p_settled_at timestamptz, p_reference text, p_subaccount_share_minor bigint) returns jsonb`. `outcome` ∈ `settled | mismatch | no_match`. Key `md5('paystack-settlement:' || p_settlement_id || ':' || p_reference)::uuid`, taken only once a `SPLIT` row matches; `no_match` (unknown reference, or the row is not `SPLIT`) takes no key. A null share settles, with audit `share_verified: false` (Paystack fact F3). A share ≠ `(amount * 100)::bigint` gives `DISPUTED` / `SETTLEMENT_MISMATCH`, with both values in the audit row and a ZSM notification.
  - `public.expire_unsettled_commissions() returns integer`. `SPLIT` rows older than 7 days → `DISPUTED` / `NOT_SETTLED`, each audited (source `CRON`) and notified.

- [ ] **Step 1: Write the failing tests** in `016`. Fixtures: commission rows at 2 h, 30 h and 8 days old on two subaccounts.

```sql
select is(<subaccounts returned by list_unsettled_subaccounts()>, <only the >24 h ones>, 'only rows older than 24 h');
select is(<release('S1', now(), 'r_c1', 3750) ->> 'outcome'>, 'settled', 'matching share settles');
select is(<row r_c1: status, paystack_settlement_id, settled_at is not null>, <SETTLED, 'S1', true>, 'settlement recorded');
select is(<release('S1', now(), 'r_c1', 3750) ->> 'outcome'>, 'settled', 'replay of one settlement is the first reply');
select is(<count audit release rows r_c1>, 1, 'replay writes nothing');
select is(<release('S1', now(), 'r_c2', 1) ->> 'outcome'>, 'mismatch', 'wrong share');
select is(<row r_c2 dispute_reason>, 'SETTLEMENT_MISMATCH', 'reason SETTLEMENT_MISMATCH');
select is(<release('S1', now(), 'r_c3', null) ->> 'outcome'>, 'settled', 'missing share settles on inclusion (F3)');
select is(<release('S1', now(), 'nope', 1) ->> 'outcome'>, 'no_match', 'unknown reference');
select is(public.expire_unsettled_commissions(), 1, 'one row older than 7 days expires');
select is(<that row: status, dispute_reason>, <DISPUTED, NOT_SETTLED>, 'NOT_SETTLED');
```

- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(db): commission release and expiry RPCs (D1 §8.1)`

---

### Task 8: Cron jobs and the D1 security suite

**Files:**
- Create: `supabase/migrations/20261020130300_fintech_liquidity_cron.sql`
- Test: `supabase/tests/database/018_d1_security.test.sql`

**Interfaces:**
- Produces: `create extension if not exists pg_net`; internal `public.invoke_system_function(p_function text, p_body jsonb) returns bigint`. It reads `functions_base_url` and `cron_secret` from `vault.decrypted_secrets` and calls `net.http_post(url => base || '/' || p_function, body => p_body, headers => {'content-type': 'application/json', 'x-cron-secret': secret})`. It returns the request id, or `raise log` and null when either secret is missing. It is revoked from every API role. Three `cron.schedule` jobs, exactly as spec §10: `reconcile-funds-sweep` `*/5 * * * *` → `select public.invoke_system_function('reconcile-funds', '{"mode":"sweep"}')`; `reconcile-funds-refunds` `0 5 * * *` → `{"mode":"refunds"}`; `fintech-commission-release` `0 6 * * *` → `'{}'`.

- [ ] **Step 1: Write the failing tests** in `018`:

```sql
select is((select count(*)::int from cron.job where jobname in ('reconcile-funds-sweep','reconcile-funds-refunds','fintech-commission-release')), 3, 'three D1 cron jobs');
select is((select schedule from cron.job where jobname = 'reconcile-funds-refunds'), '0 5 * * *', '06:00 Lagos');
select is(public.invoke_system_function('reconcile-funds', '{}'), null, 'no Vault secrets → posts nothing');
-- for each §5.2/§5.3 function: anon and authenticated cannot execute
select ok(not has_function_privilege(r, f, 'execute'), …) from (values ('anon'), ('authenticated')) roles(r)
  cross join (values ('public.storefront_catalogue(text)'), ('public.quote_web_order(text,jsonb,uuid)'),
                     ('public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid)'),
                     ('public.storefront_locations(text)'), ('public.web_order_status(text,text)'),
                     ('public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)'),
                     ('public.record_stale_paystack_webhook(text,text,timestamptz)'),
                     ('public.list_unconfirmed_payments(integer)'),
                     ('public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)'),
                     ('public.list_unsettled_subaccounts()'),
                     ('public.release_commission(text,timestamptz,text,bigint)'),
                     ('public.expire_unsettled_commissions()'),
                     ('public.invoke_system_function(text,jsonb)')) fns(f);
select ok(not has_function_privilege('service_role', 'public.invoke_system_function(text,jsonb)', 'execute'), 'cron helper is not an API');
-- territory_coverage RLS: member of T1 sees T1 rows only; non-member sees none
select is(<count as T1 TM>, <T1 rows>, 'member reads own tenant coverage');
select is(<count as T2 ZSM of T1 rows>, 0, 'other tenant reads nothing');
```

Write the "for each" block as individual `select ok(...)` lines: pgTAP's `plan` counts calls, so a set-returning form is fine only if `plan` matches its row count.

- [ ] **Step 2: Run it.** Expected: FAIL, no cron rows.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `supabase test db`. Expected: `Result: PASS`, with every file listed.
- [ ] **Step 5: Commit.** `feat(db): pg_net cron jobs for reconcile-funds and commission release; D1 security suite (D1 §10, §11)`

---

### Task 9: Paystack client additions and the cron secret check

**Files:**
- Modify: `supabase/functions/_shared/fintech-liquidity/paystack.ts`, `paystack.test.ts`
- Create: `_shared/fintech-liquidity/paystack-client.ts`, `paystack-refunds.ts`, `paystack-settlements.ts` (each with `.test.ts`); `_shared/core/cron.ts`, `cron.test.ts`

**Interfaces:**
- Produces:
  - `VerifiedTransaction` gains `transactionId: string` (`String(data.id)`) and `split: { subaccountCode: string; shareMinor: number | null } | null` (null when `data.subaccount` has no `subaccount_code`).
  - `paystack-client.ts`: `type PaystackOpts = { secretKey: string; baseUrl?: string; fetchFn?: typeof fetch }`; `paystackGet<T>(opts, path: string, query: Record<string, string | number | undefined>, schema: z.ZodType<T>): Promise<T>` (throws `Error("Paystack <path> failed: …")` on non-2xx or bad shape); `paystackPages<T>(opts, path, query, item: z.ZodType<T>): Promise<T[]>` (pages 1…`meta.pageCount`, `perPage=100`, at most 50 pages).
  - `paystack-refunds.ts`: `type PaystackRefund = { id: string; transactionReference: string | null; amountMinor: number; currency: string; status: string; raw: Record<string, unknown> }`; `type ListRefunds = (q: { reference?: string; from?: string; to?: string }) => Promise<PaystackRefund[]>` (dates `YYYY-MM-DD`); `paystackRefundLister(opts: PaystackOpts): ListRefunds`.
  - `paystack-settlements.ts`: `type PaystackSettlement = { id: string; settledAt: string }` (`settlement_date`); `type SettlementTransaction = { reference: string; shareMinor: number | null }` (`fees_split?.subaccount ?? null`); `FetchSubaccountId = (code: string) => Promise<string>` (`GET /subaccount/:code` → `String(data.id)`); `ListSettlements = (q: { subaccountId: string; from: Date }) => Promise<PaystackSettlement[]>` (always `status=success`, `from` ISO); `ListSettlementTransactions = (settlementId: string) => Promise<SettlementTransaction[]>`; factories `paystackSubaccountFetcher`, `paystackSettlementLister` and `paystackSettlementTransactionLister`, each taking `PaystackOpts`.
  - `cron.ts`: `cronAuthorized(req: Request, secret: string): boolean`. Constant-time comparison of the `x-cron-secret` header with `secret`; false when either is empty.

Fixtures are the F1–F4 shapes, trimmed to the fields used, plus one field each of `customer`/`authorization` so tests catch accidental pass-through.

- [ ] **Step 1: Write the failing tests:**
  - `paystack.test.ts` — `"verify returns the transaction id and split"`: fetch fake returns F1 with `id: 2009945086`, `subaccount: { subaccount_code: "ACCT_grace01" }` and `fees_split: { paystack: 100, integration: 0, subaccount: 3750, params: {...} }`; assert `transactionId === "2009945086"` and `split` deep-equals `{ subaccountCode: "ACCT_grace01", shareMinor: 3750 }`. `"verify without a split has split null"`: `subaccount: {}`, `fees_split: null` → `split === null`.
  - `paystack-client.test.ts` — `"paystackPages follows pageCount"`: fake pages 1–3 with `meta.pageCount: 3`; assert 3 fetches with `page=1..3&perPage=100`, and the items concatenated. `"paystackGet throws on status false"`.
  - `paystack-refunds.test.ts` — `"lists refunds for a reference"`: assert the URL is `/refund?reference=TFW-1&perPage=100&page=1`, and the item `{ id: "747680", amountMinor: 10000, status: "processed", transactionReference: "TFW-1" }`. `"missing transaction_reference is null"`.
  - `paystack-settlements.test.ts` — `"subaccount code resolves to id"` (`/subaccount/ACCT_grace01` → `"55"`); `"settlements are filtered by subaccount id and success"` (URL has `subaccount=55&status=success&from=…`); `"settlement transaction share comes from fees_split.subaccount"`; `"null fees_split gives shareMinor null"`.
  - `cron.test.ts` — right secret true; wrong secret false; missing header false; empty configured secret false.
- [ ] **Step 2: Run** `deno test --allow-env functions/_shared/`. Expected: FAIL (missing modules / properties).
- [ ] **Step 3: Implement.** Use the `zod` from `_shared/core/deps.ts`. Use `.passthrough()` on objects only where `raw` is kept.
- [ ] **Step 4: Run** the same command. Expected: PASS. Then run `deno test --allow-env functions/`; existing tests that build `VerifiedTransaction` literals need the two new fields.
- [ ] **Step 5: Commit.** `feat(functions): Paystack verify split, refunds, settlements clients; cron secret check (D1 §12)`

---

### Task 10: `process-payment` handles `refund.processed`; shared settle helpers

**Files:**
- Create: `supabase/functions/_shared/fintech-liquidity/settle.ts`, `settle.test.ts`
- Modify: `supabase/functions/process-payment/handler.ts`, `index.ts`, `handler.test.ts`

**Interfaces:**
- Consumes: Task 9 types; RPCs from Tasks 5 and 6.
- Produces:
  - `settleVerified(rpc: Rpc, event: string, tx: VerifiedTransaction): Promise<{ outcome: string }>`. For `tx.status !== "reversed"`, one `settle_paystack_payment` call with all 9 arguments (`p_split_subaccount: tx.split?.subaccountCode ?? null`, `p_split_share_minor: tx.split?.shareMinor ?? null`). For `"reversed"` (Decision 1), first `settle_paystack_payment` with `p_status: "success"`, then `apply_paystack_refund` with `p_source: event === "sweep" ? "sweep" : "webhook"`, `p_refund_id: "reversal:" + tx.reference`, `p_reason: "REVERSAL"` and the verified amount and currency; it returns the refund's outcome.
  - `applyRefunds(rpc: Rpc, source: "webhook" | "sweep", refunds: PaystackRefund[], reference?: string): Promise<Record<string, number>>`. For each refund with `status === "processed"`, it calls `apply_paystack_refund` with `p_transaction_reference: refund.transactionReference ?? reference`. A refund with neither is counted as `unreadable` and skipped. It returns the outcome counts.
  - `ProcessPaymentDeps` gains `listRefunds: ListRefunds`.

Webhook flow (F4): the signature check comes first, unchanged. Then the event is parsed as a union:
- `charge.success`: the current path (replay window, Verify, reference check), then `settleVerified(rpc, "charge.success", tx)`.
- `refund.processed`: needs `data.transaction_reference`. There is **no** replay window. Call `listRefunds({ reference })`, then `applyRefunds(rpc, "webhook", refunds, reference)`. Acknowledge `refunded` if any refund was refunded, else `none_processed`.
- Anything else: `ignored`.

- [ ] **Step 1: Write the failing tests:**
  - `settle.test.ts`: `"success passes the split through"` (asserts the args of the one `settle_paystack_payment` call); `"reversed settles then applies a reversal"` (the two calls, in order, with `p_refund_id: "reversal:ref_1"`); `"applyRefunds skips non-processed and unreadable"` (input: processed with ref, pending, processed without ref and no fallback → counts `{ refunded: 1, unreadable: 1 }`).
  - `handler.test.ts`: `"refund.processed re-reads refunds by reference and applies them"` (fake `listRefunds` records `{reference: "TFW-1"}`; rpc gets `apply_paystack_refund` with `p_refund_id "747680"`); `"refund.processed has no replay window"` (an event with no timestamp is still applied); `"refund.processed with a bad signature is 401"`; and update the existing `"charge.success …"` tests for the 9-argument call.
- [ ] **Step 2: Run** `deno test --allow-env functions/process-payment functions/_shared/fintech-liquidity`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `index.ts`, wire `listRefunds: paystackRefundLister({ secretKey, baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined })`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(functions): process-payment applies refund.processed; shared settle helpers (D1 §9)`

---

### Task 11: `reconcile-funds`

**Files:**
- Create: `supabase/functions/reconcile-funds/index.ts`, `handler.ts`, `handler.test.ts`
- Modify: `supabase/config.toml` (`[functions.reconcile-funds] verify_jwt = false`)

**Interfaces:**
- Consumes: `cronAuthorized`, `settleVerified`, `applyRefunds`, `VerifyTransaction`, `ListRefunds`; RPC `list_unconfirmed_payments`.
- Produces: `createReconcileFundsHandler(deps: { cronSecret: string; rpc: Rpc; verifyTransaction: VerifyTransaction; listRefunds: ListRefunds; now: () => Date }): (req: Request) => Promise<Response>`.
  - POST only (405). `cronAuthorized` false → 401 `UNAUTHORIZED`. Body `{ mode: "sweep" | "refunds" }` (Zod; anything else is a 400).
  - `sweep`: `list_unconfirmed_payments({ p_limit: 50 })`, then for each one `verifyTransaction` and `settleVerified(rpc, "sweep", tx)`. Errors are caught per item, `console.error`'d and counted.
  - `refunds`: `listRefunds({ from: <now − 3 days, YYYY-MM-DD>, to: <now + 1 day, YYYY-MM-DD> })`, then `applyRefunds(rpc, "sweep", refunds)`.
  - Reply: 200 `{ mode, seen: number, outcomes: Record<string, number>, errors: number }`.

- [ ] **Step 1: Write the failing tests:** `"wrong secret is 401 and touches nothing"`; `"GET is 405"`; `"sweep verifies and settles each payment"` (2 references → 2 verify calls and 2 settle calls with `p_event: "sweep"`); `"one payment's error does not stop the batch"` (verify throws for the first reference → `errors: 1`, and the second is still settled); `"refunds mode lists the last 3 days"` (with `now = 2026-10-20T05:00Z`, asserts `{from: "2026-10-17", to: "2026-10-21"}` and the applyRefunds counts); `"unknown mode is 400"`.
- [ ] **Step 2: Run** `deno test --allow-env functions/reconcile-funds`. Expected: FAIL (module missing).
- [ ] **Step 3: Implement** the handler and `index.ts`. It requires `CRON_SECRET` and `PAYSTACK_SECRET_KEY` (`requireEnv`), uses `serviceRpc()`, and passes `PAYSTACK_API_BASE` to both clients.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(functions): reconcile-funds sweep and refund pass (D1 §7)`

---

### Task 12: `fintech-commission-release`

**Files:**
- Create: `supabase/functions/fintech-commission-release/index.ts`, `handler.ts`, `handler.test.ts`
- Modify: `supabase/config.toml`

**Interfaces:**
- Consumes: Task 9 settlement clients; RPCs from Task 7.
- Produces: `createCommissionReleaseHandler(deps: { cronSecret: string; rpc: Rpc; fetchSubaccountId: FetchSubaccountId; listSettlements: ListSettlements; listSettlementTransactions: ListSettlementTransactions }): (req: Request) => Promise<Response>`.
  - POST only, cron secret as in Task 11.
  - `list_unsettled_subaccounts()`. For each row: `fetchSubaccountId(code)`, then `listSettlements({ subaccountId, from: oldest_at − 1 day })`, then for each settlement `listSettlementTransactions(id)`. For each transaction whose `reference` is in the row's `references`: `release_commission({ p_settlement_id, p_settled_at: settledAt, p_reference, p_subaccount_share_minor: shareMinor })`. A subaccount's error is logged and counted, and the rest continue.
  - Then `expire_unsettled_commissions()` once.
  - Reply: 200 `{ subaccounts, outcomes: Record<string, number>, expired, errors }`.

- [ ] **Step 1: Write the failing tests:** `"wrong secret is 401"`; `"matches settlement transactions to SPLIT references"` (two settlements; three transactions, one with an unrelated reference → exactly 2 `release_commission` calls with the right args); `"a subaccount's error does not stop the others"`; `"expiry runs once after release"` (the last rpc call is `expire_unsettled_commissions`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(functions): fintech-commission-release (D1 §8.1)`

---

### Task 13: Public gateways — optional code, `lga_id`, locations, order status

**Files:**
- Modify: `supabase/functions/storefront-catalogue/handler.ts`, `handler.test.ts`; `web-checkout/handler.ts`, `handler.test.ts`
- Create: `supabase/functions/storefront-locations/{index,handler,handler.test}.ts`, `supabase/functions/web-order-status/{index,handler,handler.test}.ts`
- Modify: `supabase/config.toml` (two new `verify_jwt = false` blocks)

**Interfaces:**
- Consumes: `publicGateway`; RPCs from Task 4.
- Produces:
  - `storefront-catalogue`: schema `code` becomes `.optional()`; call `p_code: body.code ?? null`.
  - `web-checkout`: `code` becomes optional; `lga_id: z.string().uuid()` is required. A `.refine`: no code ⇒ `payment_route === "PAYSTACK_WEB"` (400 `VALIDATION_FAILED`). `quote_web_order` gets `p_lga_id`. The Initialize `metadata.agent_code` becomes `body.code?.toUpperCase() ?? null`. `p_checkout` gains `split: quote.split ? { subaccount_code, commission_bps, partner_share } : null`, copied from the quote unchanged (the `Quote` type gains `commission_bps`). `place_web_order` gets `p_lga_id`.
  - `createStorefrontLocationsHandler(deps: PublicGatewayDeps)`: POST, schema `{ code?: string(4..32) }`, `cacheControl: "public, max-age=3600"`, rpc `storefront_locations`.
  - `createWebOrderStatusHandler(deps: PublicGatewayDeps)`: POST, schema `{ public_reference: /^TF-[0-9A-HJKMNP-TV-Z]{6}$/ (trimmed, upper-cased), paystack_reference: /^TFW-[0-9a-f-]{36}$/i (trimmed) }`, rpc `web_order_status`; a null reply raises `GatewayError(404, "NOT_FOUND", "We couldn't find that order.")`. A malformed reference is a 400 (Zod). `cache-control: no-store` (the default).

- [ ] **Step 1: Write the failing tests:**
  - `storefront-catalogue/handler.test.ts`: `"no code is the codeless catalogue"` (rpc args `{ p_code: null }`).
  - `web-checkout/handler.test.ts`: `"codeless checkout initialises without a split"` (`metadata.agent_code === null`, no `subaccount`, and `p_checkout.split === null`); `"lga_id is required"` → 400; `"codeless POS_AGENT is 400"`; `"the quote's split travels to place_web_order"` (`p_checkout.split` deep-equals the quote split); update the existing tests to send `lga_id`.
  - `storefront-locations/handler.test.ts`: `"returns the RPC reply with an hour's public cache"` (header `public, max-age=3600`); `"code is optional"`.
  - `web-order-status/handler.test.ts`: `"a mismatched pair is 404 NOT_FOUND"` (rpc returns null); `"a missing order is the same 404"`; `"a malformed public reference is 400"`; `"returns the status payload as is"`.
- [ ] **Step 2: Run** `deno test --allow-env functions/`. Expected: FAIL.
- [ ] **Step 3: Implement** the handlers and each `index.ts` (wired like `storefront-catalogue/index.ts`: `serviceRpc()`, `allowedOriginsFromEnv()`).
- [ ] **Step 4: Run** `deno test --allow-env functions/`. Expected: PASS, every file.
- [ ] **Step 5: Commit.** `feat(functions): codeless storefront and checkout, storefront-locations, web-order-status (D1 §8.2–8.4)`

---

### Task 14: Integration flows and documentation

**Files:**
- Modify: `supabase/functions/_tests/gateway.integration.ts`, `supabase/functions/.env.example`, `supabase/CLAUDE.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above, through HTTP.

Fake Paystack additions (port 54399): `GET /refund?reference=…` from a `refundLedger`; `GET /subaccount/:code` → `{ data: { id: 55 } }`; `GET /settlement?subaccount=55…` and `GET /settlement/:id/transactions` from a `settlementLedger`; Verify ledger entries now carry `id`, `subaccount` and `fees_split`. All replies use the F1–F4 shapes and `meta.pageCount: 1`.

Fixtures: the existing tenant gets a REGIONAL warehouse on its territory and `web_fulfilment_warehouse_id`, plus coverage. TEAFAIR gets a per-run zone and territory with a TM and a REGIONAL warehouse, a per-run product, and **upserted** coverage for `LA/Ikeja`. Use `upsert(..., { onConflict: "tenant_id,state_code,lga_id" })`: the local database persists between runs and the row is unique.

- [ ] **Step 1: Write the failing integration tests:**
  - `"codeless checkout → charge.success → PAID → status read"`: `web-checkout` with no code and `lga_id` Ikeja → signed `charge.success` (ledger `success`, `fees_split: null`) → `web-order-status` returns `order_status: "PAID"`; with a wrong `paystack_reference` it is a 404.
  - `"terminal checkout → SPLIT → release → SETTLED"`: code checkout (ledger with `subaccount_code ACCT_it01` and `fees_split.subaccount` = the partner share) → webhook → commission `SPLIT`. Set the commission's `created_at` to now − 25 h (admin) and seed the settlement ledger. POST `fintech-commission-release` with `x-cron-secret` → commission `SETTLED` with `paystack_settlement_id`.
  - `"a dropped webhook is recovered by the sweep"`: checkout; set the payment's `created_at` to `2000-01-01T00:00:00Z` plus a per-run offset, so it is first in the oldest-first batch; ledger `success`; POST `reconcile-funds {mode:"sweep"}` → order `PAID`.
  - `"refund.processed → REFUNDED"`: a paid order; refund ledger `{ id: 900001, status: "processed", amount: <full>, transaction_reference }`; signed `refund.processed` with no timestamp → payment and order `REFUNDED`.
  - `"cron functions reject a wrong secret"`: both return 401.
- [ ] **Step 2: Run** (from repo root, stack up, `supabase functions serve --env-file supabase/functions/.env` in another shell): the integration command in `supabase/CLAUDE.md`. Expected: the new tests FAIL until `.env` has `CRON_SECRET`.
- [ ] **Step 3:** Add `CRON_SECRET=local-cron-secret` to `supabase/functions/.env.example`, with a comment that it must equal the Vault secret `cron_secret` (and copy it into the local `.env`). Re-run the command. Expected: PASS, all tests, old and new.
- [ ] **Step 4: Docs.**
  - `supabase/CLAUDE.md`: a status row `D1. Web money loop — routing, settlement, sweeps, refunds, commission release | done (local)`. List the four new functions under system and public gateways. Document the Vault setup per environment: `select vault.create_secret('<url>', 'functions_base_url'); select vault.create_secret('<secret>', 'cron_secret');` (locally `http://host.docker.internal:54321/functions/v1`). Add the F6 test-mode note, and "D1 never deploys without A1 and A2".
  - Root `CLAUDE.md`: update the repository-state row (migration, assertion and function counts; take the counts from `ls supabase/migrations | wc -l`, the `supabase test db` output and `ls supabase/functions`).
- [ ] **Step 5: Full verification.** Run `supabase db reset && supabase test db` (expected `Result: PASS`), then `deno test --allow-env supabase/functions/` (expected `ok`, 0 failed), then the integration command (expected all `ok`).
- [ ] **Step 6: Commit.** `test(functions): D1 integration flows; docs: D1 status, Vault cron setup`
