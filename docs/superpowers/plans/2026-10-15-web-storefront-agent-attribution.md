# Web storefront and agent attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give POS agents attributable links (agent codes) at their venues, and give the `teafairweb.com` storefront two public gateways — a cached catalogue read and a checkout that starts a Paystack payment or a pay-at-agent order.

**Architecture:** Three migrations of schema (venue enum, terminal venue columns, `agent_codes`, order attribution columns), four of RPCs (two `authenticated` management RPCs, three `service_role`-only public RPCs on two internal helpers), a new `public` gateway kernel in `_shared/core/`, two Edge Functions, and an extended local integration test. Everything is test-first against the local stack.

**Tech Stack:** Postgres 17 + PostGIS (Supabase CLI migrations), pgTAP, Deno 2 Edge Functions, Zod 3, supabase-js 2, Paystack Initialize/Verify APIs, Cloudflare Turnstile.

**Spec:** `docs/superpowers/specs/2026-10-15-web-storefront-agent-attribution-design.md` (addendum A1 to Spec A, `docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`). Read both before starting. `supabase/CLAUDE.md` is the working guide for migrations, RPCs and functions.

## Global Constraints

- Local stack only. Never `supabase db push`, `supabase functions deploy` or `supabase config push`.
- Every tenant FK is `on delete restrict`; tenant-scoped tables carry `unique (tenant_id, id)` and reference tenant rows through composite `(tenant_id, x)` FKs.
- RLS policies are `FOR SELECT` only. No `anon` policy, no `INSERT/UPDATE/DELETE/ALL` policy, anywhere.
- Every `SECURITY DEFINER` function has `set search_path = public, pg_temp`. PostGIS calls are written `extensions.st_*` / `extensions.geometry(...)`.
- Write RPCs take `p_idempotency_key uuid` first, never a tenant parameter, and write one `audit_logs` row per effect via `public.write_audit`.
- Public RPCs (`storefront_catalogue`, `quote_web_order`, `place_web_order`) are executable by `service_role` only.
- Error codes: `P0001` business 422 · `42501` forbidden 403 · `23505` 409 · `TF002` idempotency mismatch 409 · `40001`/`55P03` retry 503. Never `P0002`.
- Money `numeric(15,2)`, quantities `numeric(14,3)`, timestamps `timestamptz`.
- Venue types: `CHURCH, MOSQUE, HOSPITAL, OFFICE_COMPLEX, RESIDENTIAL_ESTATE, EDUCATIONAL_INSTITUTION, EVENT_CENTER, TRANSIT_HUB, OPEN_MARKET, OTHER` in `public.venue_channel_enum`.
- Agent code format `^[A-Z0-9][A-Z0-9-]{3,31}$`, stored upper-case, unique across all tenants. Invalid code message, always: `This link is no longer valid`.
- Public reference format `^TF-[0-9A-HJKMNP-TV-Z]{6}$`.
- Third-party versions appear only in `supabase/functions/_shared/core/deps.ts`.
- `.env` files stay gitignored; only `.env.example` files are edited.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

- A buyer types or shares the code in lower case or with stray spaces (` grace-01 `) → it resolves as `GRACE-01` (Task 4, test "a lower-case, padded code resolves").
- A buyer enters a Nigerian number as `0803 123 4567` or `+234 803-123-4567` → normalised to `+2348031234567`, not rejected (Task 7, phone tests).
- Cloudflare is unreachable during checkout → 503 `RETRY` (the browser retries), never a 500, and no order is written (Task 9, "a Turnstile outage is 503").
- Paystack Initialize fails → 502 and no order row, so the buyer can simply retry (Task 9, "a Paystack failure writes no order").
- An error from the catalogue (expired link, 503) is never cached by the CDN → `cache-control: no-store` on every error response (Task 6, "errors are never cached").

---

## File structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20261015120000_commerce_web_enums.sql` | `venue_channel_enum`; `audit_source_enum` + `WEB` |
| `supabase/migrations/20261015120100_commerce_web_storefront_schema.sql` | terminal venue columns, `agent_codes`, order attribution columns, indexes, RLS policy |
| `supabase/migrations/20261015120200_commerce_terminal_venue.sql` | `set_terminal_venue` RPC |
| `supabase/migrations/20261015120300_commerce_agent_codes.sql` | `upsert_agent_code` RPC |
| `supabase/migrations/20261015120400_commerce_web_storefront_reads.sql` | `web_resolve_code`, `web_price_cart` (internal); `storefront_catalogue`, `quote_web_order` (service_role) |
| `supabase/migrations/20261015120500_commerce_place_web_order.sql` | `place_web_order` (service_role) |
| `supabase/tests/database/001_schema_shape.test.sql` | modified: 34 tables, new enum labels |
| `supabase/tests/database/010_commerce_web_schema.test.sql` | schema constraints, RLS, privileges |
| `supabase/tests/database/011_commerce_web_management.test.sql` | `set_terminal_venue`, `upsert_agent_code` |
| `supabase/tests/database/012_commerce_web_public.test.sql` | catalogue, quote, place |
| `supabase/functions/_shared/core/public-gateway.ts` (+ `.test.ts`) | public gateway kernel: CORS, method, query/body validation, error mapping, cache headers |
| `supabase/functions/_shared/commerce/phone.ts` (+ `.test.ts`) | Nigerian phone normalisation |
| `supabase/functions/_shared/commerce/turnstile.ts` (+ `.test.ts`) | Turnstile siteverify client |
| `supabase/functions/_shared/fintech-liquidity/paystack.ts` (+ `.test.ts`) | modified: add `paystackInitializer` |
| `supabase/functions/storefront-catalogue/{handler,handler.test,index}.ts` | catalogue gateway |
| `supabase/functions/web-checkout/{handler,handler.test,index}.ts` | checkout gateway |
| `supabase/functions/_tests/gateway.integration.ts` | modified: fake Initialize + Turnstile, storefront tests |
| `supabase/config.toml`, `supabase/functions/.env.example` | function entries, new env vars |
| `supabase/CLAUDE.md`, `CLAUDE.md` | docs |

Test UUID scheme used throughout (same as existing tests): tenants `1000…`, users `2000…`, zones `3000…`, territories `4000…`, memberships `5000…`, partners `6000…`, terminals `6100…`, codes `6200…`, products are keyed by SKU, orders `7000…`, idempotency keys `aaaa…`/`bbbb…`.

---

### Task 1: Schema — enums, terminal venue, `agent_codes`, order attribution

**Files:**
- Create: `supabase/migrations/20261015120000_commerce_web_enums.sql`
- Create: `supabase/migrations/20261015120100_commerce_web_storefront_schema.sql`
- Create: `supabase/tests/database/010_commerce_web_schema.test.sql`
- Modify: `supabase/tests/database/001_schema_shape.test.sql` (lines 5, 12–38, 56)

**Interfaces:**
- Produces: `public.venue_channel_enum`; `audit_source_enum` label `WEB`; `fintech_terminals.(venue_channel, venue_name, address_text, state, lga, location, operating_hours)`; table `public.agent_codes(id, tenant_id, code, agent_id, terminal_id, discount_type, discount_value, max_redemptions, expires_at, is_active, created_by, created_at, updated_at)`; `orders.(agent_code_id, attributed_agent_id, attributed_terminal_id, utm_source, utm_medium, utm_campaign, payment_route, discount_amount, customer_email, delivery_address, public_reference)`.

- [ ] **Step 1: Start the stack**

Run: `supabase start` (Docker Desktop must be running). Then `supabase test db` and confirm the baseline: `Result: PASS`.

- [ ] **Step 2: Update `001_schema_shape.test.sql` (failing)**

Change `select plan(65);` to `select plan(66);`. Replace the table block (lines 12–31) with:

```sql
-- the 33 Spec A tables (§6.1) + agent_codes (addendum A1)
select tables_are('public', array[
  -- tenancy and identity (6)
  'tenants', 'tenant_settings', 'tenant_users', 'profiles',
  'user_secure_profiles', 'devices',
  -- geography and shared network (7)
  'zones', 'territories', 'retail_shops', 'tenant_shop_coverage',
  'routes', 'route_waypoints', 'field_check_ins',
  -- catalogue and inventory (4)
  'warehouses', 'brand_approval_policies', 'central_products',
  'inventory_batches',
  -- commerce (6) + web storefront (1, addendum A1)
  'requisitions', 'requisition_items', 'orders', 'order_items',
  'retail_stock_pickups', 'retail_stock_pickup_items', 'agent_codes',
  -- money and the liquidity engine (6)
  'fintech_partners', 'payments', 'commission_records', 'fintech_terminals',
  'fintech_advances', 'cash_audit_batches',
  -- platform (4)
  'otp_challenges', 'idempotency_logs', 'audit_logs', 'notifications'
], 'public holds exactly the 34 tables');
```

Change the RLS count assertion to `34, 'RLS is enabled on all 34 tables');`. Replace the `audit_source_enum` line and add the venue enum after it:

```sql
select enum_has_labels('public', 'audit_source_enum', array['USER','SYSTEM','WEBHOOK','CRON','WEB']);
select enum_has_labels('public', 'venue_channel_enum',
  array['CHURCH','MOSQUE','HOSPITAL','OFFICE_COMPLEX','RESIDENTIAL_ESTATE',
        'EDUCATIONAL_INSTITUTION','EVENT_CENTER','TRANSIT_HUB','OPEN_MARKET','OTHER']);
```

- [ ] **Step 3: Write `010_commerce_web_schema.test.sql` (failing)**

```sql
-- Addendum A1 §3 — terminal venues, agent codes and web attribution on
-- orders. Constraints run as postgres; RLS runs as authenticated.
begin;
create extension if not exists pgtap with schema extensions;

select plan(20);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');

-- 1 ZSM Nestle · 4 POS agent Nestle · 9 ZSM Unilever
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, 'ACTIVE', true);

insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now()),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Uni OPay', 'OPAY',
   150, '+2348000000009', 'ACCT_uni01', 'ACTIVE', '20000000-0000-0000-0000-000000000009', now());
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0001', '40000000-0000-0000-0000-000000000001'),
  ('61000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002',
   null, 'OP-0001', '40000000-0000-0000-0000-000000000002');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── shape ───────────────────────────────────────────────────────────────
select has_table('public', 'agent_codes', 'agent_codes exists');
select has_column('public', 'fintech_terminals', 'venue_channel', 'terminals carry a venue type');
select has_column('public', 'orders', 'public_reference', 'orders carry a public reference');

-- ── terminal venue: all or nothing ──────────────────────────────────────
select throws_ok(
  $$update public.fintech_terminals set venue_name = 'RCCG Grace Parish'
     where id = '61000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a venue name without the rest of the venue is refused');
select lives_ok(
  $$update public.fintech_terminals
       set venue_channel = 'CHURCH', venue_name = 'RCCG Grace Parish',
           address_text = '12 Allen Avenue, Ikeja', state = 'Lagos', lga = 'Ikeja',
           location = extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)
     where id = '61000000-0000-0000-0000-000000000001'$$,
  'a complete venue is accepted');
select throws_ok(
  $$update public.fintech_terminals set operating_hours = '[]'::jsonb
     where id = '61000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'operating_hours must be an object');

-- ── agent_codes ─────────────────────────────────────────────────────────
select lives_ok(
  $$insert into public.agent_codes (id, tenant_id, code, agent_id, terminal_id, discount_type, discount_value, created_by)
    values ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GRACE-01',
            '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001',
            'PERCENT', 10, '20000000-0000-0000-0000-000000000001')$$,
  'a valid code is accepted');
select throws_ok(
  $$insert into public.agent_codes (tenant_id, code, agent_id, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'grace-02',
            '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'codes are stored upper-case');
select throws_ok(
  $$insert into public.agent_codes (tenant_id, code, agent_id, created_by)
    values ('10000000-0000-0000-0000-000000000002', 'GRACE-01',
            '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000009')$$,
  '23505', null, 'a code is unique across all tenants');
select throws_ok(
  $$insert into public.agent_codes (tenant_id, code, agent_id, discount_type, discount_value, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'GRACE-03', '20000000-0000-0000-0000-000000000004',
            'PERCENT', 150, '20000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'a percentage discount is at most 100');
select throws_ok(
  $$insert into public.agent_codes (tenant_id, code, agent_id, discount_type, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'GRACE-04', '20000000-0000-0000-0000-000000000004',
            'FIXED', '20000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'a discount type needs a value');
select throws_ok(
  $$insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, created_by)
    values ('10000000-0000-0000-0000-000000000001', 'CROSS-01', '20000000-0000-0000-0000-000000000004',
            '61000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001')$$,
  '23503', null, 'a code cannot point at another tenant''s terminal');

-- ── orders: web attribution ─────────────────────────────────────────────
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, agent_code_id,
                               attributed_agent_id, payment_route, delivery_address)
    values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100,
            '62000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
            'POS_AGENT', '5 Opebi Road')$$,
  '23514', null, 'an attributed web order needs a public reference');
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, agent_code_id,
                               attributed_agent_id, payment_route, delivery_address, public_reference)
    values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100,
            '62000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
            'POS_AGENT', '5 Opebi Road', 'TF-OOOOOO')$$,
  '23514', null, 'a public reference uses Crockford base-32 (no O)');
select lives_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, agent_code_id,
                               attributed_agent_id, payment_route, delivery_address, public_reference)
    values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100,
            '62000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
            'POS_AGENT', '5 Opebi Road', 'TF-7K3Q9X')$$,
  'a complete attributed web order is accepted');
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount)
    values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, -1)$$,
  '23514', null, 'a discount is never negative');

-- ── RLS and privileges ──────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.agent_codes), 1, 'a member reads their tenant''s codes');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.agent_codes), 0, 'another tenant''s codes are invisible');
reset role;
select ok(not has_table_privilege('anon', 'public.agent_codes', 'select'), 'anon cannot read agent_codes');
select ok(not has_table_privilege('authenticated', 'public.agent_codes', 'insert'), 'authenticated cannot write agent_codes');

select * from finish();
rollback;
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `supabase test db`
Expected: FAIL — `001` reports a missing `agent_codes` / unknown `venue_channel_enum`; `010` fails on `has_table` and every statement touching the new columns.

- [ ] **Step 5: Write `20261015120000_commerce_web_enums.sql`**

```sql
-- Addendum A1 §3.1. Kept apart from the schema migration: a label added with
-- ALTER TYPE … ADD VALUE cannot be used in the transaction that adds it.

-- where a POS terminal physically sits; a different axis from
-- order_channel_enum, which says how a sale was made (A1 decision 5)
create type public.venue_channel_enum as enum (
  'CHURCH', 'MOSQUE', 'HOSPITAL', 'OFFICE_COMPLEX', 'RESIDENTIAL_ESTATE',
  'EDUCATIONAL_INSTITUTION', 'EVENT_CENTER', 'TRANSIT_HUB', 'OPEN_MARKET', 'OTHER'
);

-- rows written through a public gateway: no actor, like WEBHOOK
alter type public.audit_source_enum add value 'WEB';
```

- [ ] **Step 6: Write `20261015120100_commerce_web_storefront_schema.sql`**

```sql
-- Addendum A1 §3 — terminal venues, agent codes, web attribution on orders.

-- ── fintech_terminals: the venue a terminal sits in ─────────────────────
-- All-or-nothing: a venue is either fully described or absent. lga and
-- operating_hours are optional extras.
alter table public.fintech_terminals
  add column venue_channel    public.venue_channel_enum,
  add column venue_name       text check (venue_name is null or length(btrim(venue_name)) > 0),
  add column address_text     text check (address_text is null or length(btrim(address_text)) > 0),
  add column state            text check (state is null or length(btrim(state)) > 0),
  add column lga              text,
  add column location         extensions.geometry(Point, 4326),
  add column operating_hours  jsonb check (operating_hours is null or jsonb_typeof(operating_hours) = 'object'),
  add constraint fintech_terminals_venue_complete
    check (num_nulls(venue_channel, venue_name, address_text, state, location) in (0, 5));
create index idx_fintech_terminals_location on public.fintech_terminals using gist (location);

-- ── agent_codes (class A) ───────────────────────────────────────────────
-- The shareable link and the optional promo code are one thing (A1
-- decision 6). code is unique across tenants because the link alone must
-- resolve the tenant (decision 2). Membership and terminal ownership are
-- checked by upsert_agent_code, which is the only writer.
create table public.agent_codes (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  code             text not null unique check (code ~ '^[A-Z0-9][A-Z0-9-]{3,31}$'),
  agent_id         uuid not null references public.profiles (id) on delete restrict,
  terminal_id      uuid,
  discount_type    text check (discount_type in ('PERCENT', 'FIXED')),
  discount_value   numeric(15,2),
  max_redemptions  integer check (max_redemptions > 0),
  expires_at       timestamptz,
  is_active        boolean not null default true,
  created_by       uuid not null references public.profiles (id) on delete restrict,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, terminal_id) references public.fintech_terminals (tenant_id, id) on delete restrict,
  constraint agent_codes_discount_pair
    check ((discount_type is null) = (discount_value is null)),
  constraint agent_codes_percent_range
    check (discount_type is distinct from 'PERCENT' or (discount_value > 0 and discount_value <= 100)),
  constraint agent_codes_fixed_positive
    check (discount_type is distinct from 'FIXED' or discount_value > 0)
);
alter table public.agent_codes enable row level security;
create index idx_agent_codes_agent on public.agent_codes (tenant_id, agent_id);
create index idx_agent_codes_terminal on public.agent_codes (tenant_id, terminal_id);
create index idx_agent_codes_created_by on public.agent_codes (created_by);
create trigger agent_codes_set_updated_at before update on public.agent_codes
  for each row execute function public.set_updated_at();

create policy agent_codes_select_tenant_member on public.agent_codes
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── orders: attribution and web checkout ────────────────────────────────
-- attributed_* are snapshots taken at checkout, so history survives a code
-- being rebound or deactivated.
alter table public.orders
  add column agent_code_id           uuid,
  add column attributed_agent_id     uuid references public.profiles (id) on delete restrict,
  add column attributed_terminal_id  uuid,
  add column utm_source              text check (length(utm_source) <= 100),
  add column utm_medium              text check (length(utm_medium) <= 100),
  add column utm_campaign            text check (length(utm_campaign) <= 100),
  add column payment_route           text check (payment_route in ('PAYSTACK_WEB', 'POS_AGENT')),
  add column discount_amount         numeric(15,2) not null default 0 check (discount_amount >= 0),
  add column customer_email          text check (customer_email = lower(customer_email)),
  add column delivery_address        text check (delivery_address is null or length(btrim(delivery_address)) > 0),
  add column public_reference        text unique check (public_reference ~ '^TF-[0-9A-HJKMNP-TV-Z]{6}$'),
  add constraint orders_agent_code_fk
    foreign key (tenant_id, agent_code_id) references public.agent_codes (tenant_id, id) on delete restrict,
  add constraint orders_attributed_terminal_fk
    foreign key (tenant_id, attributed_terminal_id) references public.fintech_terminals (tenant_id, id) on delete restrict,
  add constraint orders_web_attribution_complete
    check (channel <> 'ONLINE' or agent_code_id is null
           or num_nulls(payment_route, attributed_agent_id, delivery_address, public_reference) = 0);
create index idx_orders_agent_code on public.orders (tenant_id, agent_code_id);
create index idx_orders_attributed_agent on public.orders (attributed_agent_id);
create index idx_orders_attributed_terminal on public.orders (tenant_id, attributed_terminal_id);
-- the place_web_order throttle: pending web orders per phone, last hour
create index idx_orders_web_pending_phone on public.orders (customer_phone, created_at)
  where channel = 'ONLINE' and status = 'PENDING';
```

- [ ] **Step 7: Apply and run the tests**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS` (001: 66, 010: 20, others unchanged).

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20261015120000_commerce_web_enums.sql \
        supabase/migrations/20261015120100_commerce_web_storefront_schema.sql \
        supabase/tests/database/001_schema_shape.test.sql \
        supabase/tests/database/010_commerce_web_schema.test.sql
git commit -m "feat(commerce): venue, agent code and web attribution schema (A1 §3)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `set_terminal_venue` RPC

**Files:**
- Create: `supabase/migrations/20261015120200_commerce_terminal_venue.sql`
- Create: `supabase/tests/database/011_commerce_web_management.test.sql`

**Interfaces:**
- Consumes: Task 1 columns on `fintech_terminals`.
- Produces: `public.set_terminal_venue(p_idempotency_key uuid, p_terminal_id uuid, p_venue_channel public.venue_channel_enum, p_venue_name text, p_address_text text, p_state text, p_lga text, p_latitude double precision, p_longitude double precision, p_operating_hours jsonb) returns jsonb` → `{"terminal_id": uuid}`. Executable by `authenticated`.

- [ ] **Step 1: Write `011_commerce_web_management.test.sql` (failing)**

Task 3 appends to this file, so keep the fixture block complete.

```sql
-- Addendum A1 §4.1 — the management RPCs: set_terminal_venue and
-- upsert_agent_code. Called as authenticated, exactly as PostgREST does.
begin;
create extension if not exists pgtap with schema extensions;

select plan(13);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');

-- 1 ZSM · 2 TM Ikeja · 4 POS agent Ikeja · 5 POS agent Fagge · 6 DSA Ikeja · 9 ZSM Unilever
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', 'Kano'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
-- Ikeja has a boundary (a box around 3.30–3.40 E, 6.55–6.65 N); Fagge has none
insert into public.territories (id, tenant_id, zone_id, territory_name, boundary) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja',
   extensions.st_multi(extensions.st_makeenvelope(3.30, 6.55, 3.40, 6.65, 4326))),
  ('40000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000009', 'Fagge', null),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja', null);

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000009', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';

insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0001', '40000000-0000-0000-0000-000000000001'),
  ('61000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'MP-0005', '40000000-0000-0000-0000-000000000009');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── set_terminal_venue ──────────────────────────────────────────────────
select ok(has_function_privilege('authenticated',
  'public.set_terminal_venue(uuid,uuid,public.venue_channel_enum,text,text,text,text,double precision,double precision,jsonb)', 'execute'),
  'the app may call set_terminal_venue');
select ok(not has_function_privilege('anon',
  'public.set_terminal_venue(uuid,uuid,public.venue_channel_enum,text,text,text,text,double precision,double precision,jsonb)', 'execute'),
  'anon may not');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000001',
      '61000000-0000-0000-0000-000000000001', 'CHURCH', 'RCCG Grace Parish',
      '12 Allen Avenue, Ikeja', 'Lagos', 'Ikeja', 6.60, 3.35,
      '{"mon":"08:00-18:00","sun":"closed"}')$$,
  'an agent sets the venue of their own terminal');
reset role;
select is(
  (select venue_channel::text || '|' || venue_name || '|' || extensions.st_astext(location)
     from public.fintech_terminals where id = '61000000-0000-0000-0000-000000000001'),
  'CHURCH|RCCG Grace Parish|POINT(3.35 6.6)', 'the venue and its point are stored');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'set_terminal_venue' and idempotency_key = 'aaaaaaaa-0000-0000-0000-000000000001'
      and actor_id = '20000000-0000-0000-0000-000000000004'),
  1, 'one audit row names the agent');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000002',
      '61000000-0000-0000-0000-000000000005', 'MOSQUE', 'Fagge Central Mosque',
      'Fagge Road', 'Kano', null, 12.00, 8.52, null)$$,
  '42501', null, 'an agent cannot set another agent''s terminal');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000003',
      '61000000-0000-0000-0000-000000000005', 'MOSQUE', 'Fagge Central Mosque',
      'Fagge Road', 'Kano', null, 12.00, 8.52, null)$$,
  '42501', null, 'a TM cannot set a terminal outside their territory');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000004',
      '61000000-0000-0000-0000-000000000005', 'MOSQUE', 'Fagge Central Mosque',
      'Fagge Road', 'Kano', 'Fagge', 12.00, 8.52, null)$$,
  'a ZSM sets any terminal in the tenant');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000005',
      '61000000-0000-0000-0000-000000000001', 'HOSPITAL', 'National Hospital',
      'Central Area', 'FCT', null, 9.07, 7.49, null)$$,
  'P0001', null, 'a point outside the territory boundary is refused');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000006',
      '61000000-0000-0000-0000-000000000001', 'CHURCH', 'RCCG Grace Parish',
      '12 Allen Avenue, Ikeja', 'Lagos', null, 6.60, 3.35, '{"mon":"8am-6pm"}')$$,
  'P0001', null, 'operating hours must be HH:MM-HH:MM or closed');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000007',
      '61000000-0000-0000-0000-000000000001', 'CHURCH', '  ',
      '12 Allen Avenue, Ikeja', 'Lagos', null, 6.60, 3.35, null)$$,
  'P0001', null, 'a blank venue name is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000008',
      '61000000-0000-0000-0000-000000000001', 'CHURCH', 'RCCG Grace Parish',
      '12 Allen Avenue, Ikeja', 'Lagos', null, 6.60, 3.35, null)$$,
  '42501', null, 'a DSA cannot set venues');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  $$select public.set_terminal_venue('aaaaaaaa-0000-0000-0000-000000000009',
      '61000000-0000-0000-0000-000000000001', 'CHURCH', 'Hijack',
      'Nowhere', 'Lagos', null, 6.60, 3.35, null)$$,
  'P0001', 'terminal not found', 'another tenant''s terminal does not exist for the caller');
reset role;

select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db`
Expected: FAIL in `011` — `function public.set_terminal_venue(...) does not exist`.

- [ ] **Step 3: Write `20261015120200_commerce_terminal_venue.sql`**

```sql
-- Addendum A1 §4.1 — set the venue a POS terminal sits in.
-- ZSM: any terminal in the tenant. TM: terminals in their own territory.
-- FINTECH_AGENT: their own terminals. The point must fall inside the
-- territory boundary when the territory has one.
create or replace function public.set_terminal_venue(
  p_idempotency_key  uuid,
  p_terminal_id      uuid,
  p_venue_channel    public.venue_channel_enum,
  p_venue_name       text,
  p_address_text     text,
  p_state            text,
  p_lga              text,
  p_latitude         double precision,
  p_longitude        double precision,
  p_operating_hours  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       public.tenant_users := public.assert_tenant_role(
                array['ZSM', 'TM', 'FINTECH_AGENT']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_before   public.fintech_terminals;
  v_after    public.fintech_terminals;
  v_point    extensions.geometry;
  v_boundary extensions.geometry;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_terminal_venue',
    jsonb_build_object('terminal_id', p_terminal_id, 'venue_channel', p_venue_channel,
                       'venue_name', p_venue_name, 'address_text', p_address_text,
                       'state', p_state, 'lga', p_lga, 'latitude', p_latitude,
                       'longitude', p_longitude, 'operating_hours', p_operating_hours));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.fintech_terminals
   where id = p_terminal_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'terminal not found' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_before.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM sets venues for terminals in their own territory only' using errcode = '42501';
  end if;
  if v_me.role = 'FINTECH_AGENT' and v_before.agent_id is distinct from v_me.profile_id then
    raise exception 'an agent sets the venue of their own terminals only' using errcode = '42501';
  end if;

  if p_venue_channel is null
     or coalesce(btrim(p_venue_name), '') = ''
     or coalesce(btrim(p_address_text), '') = ''
     or coalesce(btrim(p_state), '') = '' then
    raise exception 'venue type, name, address and state are required' using errcode = 'P0001';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'a valid GPS location is required' using errcode = 'P0001';
  end if;
  if p_operating_hours is not null and (
       jsonb_typeof(p_operating_hours) <> 'object'
       or exists (
         select 1 from jsonb_each(p_operating_hours) e
          where e.key not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
             or jsonb_typeof(e.value) <> 'string'
             or (e.value #>> '{}') !~ '^(closed|([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9])$')) then
    raise exception 'operating hours use mon..sun keys with "HH:MM-HH:MM" or "closed"' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326);
  select t.boundary into v_boundary from public.territories t
   where t.tenant_id = v_me.tenant_id and t.id = v_before.territory_id;
  if v_boundary is not null and not extensions.st_covers(v_boundary, v_point) then
    raise exception 'the venue lies outside the terminal''s territory' using errcode = 'P0001';
  end if;

  update public.fintech_terminals
     set venue_channel   = p_venue_channel,
         venue_name      = btrim(p_venue_name),
         address_text    = btrim(p_address_text),
         state           = btrim(p_state),
         lga             = nullif(btrim(p_lga), ''),
         location        = v_point,
         operating_hours = p_operating_hours
   where id = v_before.id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_terminal_venue', 'fintech_terminals', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('terminal_id', v_after.id));
end;
$$;

grant execute on function public.set_terminal_venue(uuid, uuid, public.venue_channel_enum, text, text, text, text,
                                                    double precision, double precision, jsonb) to authenticated;
```

- [ ] **Step 4: Apply and run**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS` (011: 13). The 003 and 004 structural checks (search_path pinned, idempotency key first, no tenant parameter) also pass for the new function.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261015120200_commerce_terminal_venue.sql supabase/tests/database/011_commerce_web_management.test.sql
git commit -m "feat(commerce): set_terminal_venue RPC (A1 §4.1)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `upsert_agent_code` RPC

**Files:**
- Create: `supabase/migrations/20261015120300_commerce_agent_codes.sql`
- Modify: `supabase/tests/database/011_commerce_web_management.test.sql` (plan count; append before `select * from finish();`)

**Interfaces:**
- Consumes: Task 1 `agent_codes`; Task 2 test fixtures.
- Produces: `public.upsert_agent_code(p_idempotency_key uuid, p_code text, p_agent_id uuid, p_terminal_id uuid, p_discount_type text, p_discount_value numeric, p_max_redemptions integer, p_expires_at timestamptz, p_is_active boolean) returns jsonb` → `{"agent_code_id": uuid, "code": text}`. Executable by `authenticated`.

- [ ] **Step 1: Append the failing tests**

Change `select plan(13);` to `select plan(30);` and insert this block immediately before `select * from finish();`:

```sql
-- ── upsert_agent_code ───────────────────────────────────────────────────
select ok(has_function_privilege('authenticated',
  'public.upsert_agent_code(uuid,text,uuid,uuid,text,numeric,integer,timestamp with time zone,boolean)', 'execute'),
  'the app may call upsert_agent_code');
select ok(not has_function_privilege('anon',
  'public.upsert_agent_code(uuid,text,uuid,uuid,text,numeric,integer,timestamp with time zone,boolean)', 'execute'),
  'anon may not');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000001', ' grace-01 ',
      '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001',
      'PERCENT', 10, null, null, true)$$,
  'a TM issues a code for an agent in their territory');
reset role;
select is(
  (select code || '|' || created_by::text from public.agent_codes
    where agent_id = '20000000-0000-0000-0000-000000000004'),
  'GRACE-01|20000000-0000-0000-0000-000000000002', 'the code is stored trimmed, upper-case, with its issuer');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'upsert_agent_code' and idempotency_key = 'bbbbbbbb-0000-0000-0000-000000000001'),
  1, 'issuing a code is audited');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000002', 'MINE-01',
      '20000000-0000-0000-0000-000000000004', null, 'PERCENT', 50, null, null, true)$$,
  '42501', null, 'an agent cannot issue codes, because codes carry discounts');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000003', 'KANO-05',
      '20000000-0000-0000-0000-000000000005', null, null, null, null, null, true)$$,
  '42501', null, 'a TM cannot issue codes for agents outside their territory');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000004', 'KANO-05',
      '20000000-0000-0000-0000-000000000005', '61000000-0000-0000-0000-000000000005',
      null, null, null, null, true)$$,
  'a ZSM issues codes anywhere in the tenant');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000005', 'GRACE-02',
      '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000005',
      null, null, null, null, true)$$,
  'P0001', null, 'a code can only be bound to the agent''s own terminal');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000006', 'GRACE-03',
      '20000000-0000-0000-0000-000000000004', null, 'PERCENT', 150, null, null, true)$$,
  'P0001', null, 'a percentage above 100 is refused');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000007', 'GRACE-04',
      '20000000-0000-0000-0000-000000000004', null, 'FIXED', null, null, null, true)$$,
  'P0001', null, 'a discount type needs a value');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000008', 'ab',
      '20000000-0000-0000-0000-000000000004', null, null, null, null, null, true)$$,
  'P0001', null, 'a code is 4–32 letters, digits or dashes');
select lives_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-000000000009', 'GRACE-01',
      '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001',
      'PERCENT', 10, null, null, false)$$,
  'a TM deactivates a code');
reset role;
select is((select is_active from public.agent_codes where code = 'GRACE-01'), false,
  'the code is now inactive');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-00000000000a', 'GRACE-01',
      '20000000-0000-0000-0000-000000000006', null, null, null, null, null, true)$$,
  'P0001', null, 'a code''s agent never changes');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-00000000000b', 'GRACE-01',
      '20000000-0000-0000-0000-000000000009', null, null, null, null, null, true)$$,
  'P0001', 'that code is already taken', 'another tenant cannot take over a code');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_agent_code('bbbbbbbb-0000-0000-0000-00000000000c', 'HOUSE-IKEJA',
      '20000000-0000-0000-0000-000000000006', null, null, null, null, null, true)$$,
  'a staff member can hold a house code with no terminal');
reset role;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db`
Expected: FAIL in `011` — `function public.upsert_agent_code(...) does not exist`.

- [ ] **Step 3: Write `20261015120300_commerce_agent_codes.sql`**

```sql
-- Addendum A1 §4.1 — issue, edit or deactivate an agent code.
-- ZSM: any agent in the tenant. TM: agents in their own territory. Agents
-- never issue their own codes, because codes carry discounts. A code's
-- tenant and agent never change; to move one, deactivate it and issue another.
create or replace function public.upsert_agent_code(
  p_idempotency_key  uuid,
  p_code             text,
  p_agent_id         uuid,
  p_terminal_id      uuid,
  p_discount_type    text,
  p_discount_value   numeric,
  p_max_redemptions  integer,
  p_expires_at       timestamptz,
  p_is_active        boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_agent  public.tenant_users;
  v_before public.agent_codes;
  v_after  public.agent_codes;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_agent_code',
    jsonb_build_object('code', v_code, 'agent_id', p_agent_id, 'terminal_id', p_terminal_id,
                       'discount_type', p_discount_type, 'discount_value', p_discount_value,
                       'max_redemptions', p_max_redemptions, 'expires_at', p_expires_at,
                       'is_active', p_is_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_code !~ '^[A-Z0-9][A-Z0-9-]{3,31}$' then
    raise exception 'a code is 4 to 32 letters, digits or dashes' using errcode = 'P0001';
  end if;

  select * into v_agent from public.tenant_users
   where tenant_id = v_me.tenant_id and profile_id = p_agent_id and status = 'ACTIVE';
  if not found then
    raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_agent.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM issues codes for agents in their own territory only' using errcode = '42501';
  end if;
  if p_terminal_id is not null and not exists (
    select 1 from public.fintech_terminals ft
     where ft.tenant_id = v_me.tenant_id and ft.id = p_terminal_id and ft.agent_id = p_agent_id
  ) then
    raise exception 'the terminal must belong to the agent' using errcode = 'P0001';
  end if;

  if (p_discount_type is null) <> (p_discount_value is null) then
    raise exception 'a discount needs both a type and a value' using errcode = 'P0001';
  end if;
  if p_discount_type is not null and p_discount_type not in ('PERCENT', 'FIXED') then
    raise exception 'discount type must be PERCENT or FIXED' using errcode = 'P0001';
  end if;
  if p_discount_type = 'PERCENT' and not (p_discount_value > 0 and p_discount_value <= 100) then
    raise exception 'a percentage discount is more than 0 and at most 100' using errcode = 'P0001';
  end if;
  if p_discount_type = 'FIXED' and not (p_discount_value > 0) then
    raise exception 'a fixed discount is more than 0' using errcode = 'P0001';
  end if;
  if p_max_redemptions is not null and p_max_redemptions < 1 then
    raise exception 'max_redemptions is at least 1' using errcode = 'P0001';
  end if;

  select * into v_before from public.agent_codes where code = v_code for update;
  if found then
    if v_before.tenant_id <> v_me.tenant_id then
      raise exception 'that code is already taken' using errcode = 'P0001';
    end if;
    if v_before.agent_id <> p_agent_id then
      raise exception 'a code''s agent never changes; deactivate it and issue a new code' using errcode = 'P0001';
    end if;
    update public.agent_codes
       set terminal_id     = p_terminal_id,
           discount_type   = p_discount_type,
           discount_value  = p_discount_value,
           max_redemptions = p_max_redemptions,
           expires_at      = p_expires_at,
           is_active       = coalesce(p_is_active, true)
     where id = v_before.id
    returning * into v_after;
  else
    insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, discount_type, discount_value,
                                    max_redemptions, expires_at, is_active, created_by)
    values (v_me.tenant_id, v_code, p_agent_id, p_terminal_id, p_discount_type, p_discount_value,
            p_max_redemptions, p_expires_at, coalesce(p_is_active, true), v_me.profile_id)
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_agent_code', 'agent_codes', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_code_id', v_after.id, 'code', v_after.code));
end;
$$;

grant execute on function public.upsert_agent_code(uuid, text, uuid, uuid, text, numeric, integer, timestamptz, boolean)
  to authenticated;
```

- [ ] **Step 4: Apply and run**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS` (011: 30).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261015120300_commerce_agent_codes.sql supabase/tests/database/011_commerce_web_management.test.sql
git commit -m "feat(commerce): upsert_agent_code RPC, ZSM/TM only (A1 §4.1)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Public reads — `storefront_catalogue` and `quote_web_order`

**Files:**
- Create: `supabase/migrations/20261015120400_commerce_web_storefront_reads.sql`
- Create: `supabase/tests/database/012_commerce_web_public.test.sql`

**Interfaces:**
- Consumes: Task 1 schema.
- Produces (internal, no API grant): `public.web_resolve_code(p_code text) returns public.agent_codes` (raises `P0001 'This link is no longer valid'`); `public.web_price_cart(p_code public.agent_codes, p_items jsonb) returns jsonb` → `{lines:[{sku_code, product_name, qty, unit_price, line_total}], subtotal, discount, total, currency, split: {fintech_partner_id, subaccount_code, commission_bps, partner_share} | null}`.
- Produces (service_role only): `public.storefront_catalogue(p_code text) returns jsonb` → `{code, tenant:{name, logo_url}, currency, discount:{type, value}|null, venue:{name, channel}|null, products:[{sku_code, product_name, brand, category, unit_price, description}]}`; `public.quote_web_order(p_code text, p_items jsonb) returns jsonb` → the `web_price_cart` object.

- [ ] **Step 1: Write `012_commerce_web_public.test.sql` (failing)**

Task 5 appends to this file.

```sql
-- Addendum A1 §4.2 — the public RPCs. They are executable by service_role
-- only: the public gateways call them, the app and anon never do.
begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into public.tenant_settings (tenant_id, currency) values
  ('10000000-0000-0000-0000-000000000001', 'NGN');

-- 1 ZSM · 2 TM Ikeja · 4 POS agent Ikeja · 6 DSA Ikeja · 7 POS agent in a
-- territory with no TM · 8 disabled POS agent · 9 ZSM Unilever
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000007', '2348000000007'),
  ('20000000-0000-0000-0000-000000000008', '2348000000008'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000008', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';

-- partner 1 is ACTIVE (splits); partner 3 is PENDING (no split)
insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now()),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Pending PalmPay', 'PALMPAY',
   150, '+2348000000004', 'ACCT_pend01', 'PENDING', null, null);
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id, is_active,
                                      venue_channel, venue_name, address_text, state, location) values
  ('61000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0001', '40000000-0000-0000-0000-000000000001', true,
   'CHURCH', 'RCCG Grace Parish', '12 Allen Avenue, Ikeja', 'Lagos',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)),
  ('61000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000003',
   '20000000-0000-0000-0000-000000000004', 'PP-0003', '40000000-0000-0000-0000-000000000001', true,
   null, null, null, null, null),
  ('61000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0004', '40000000-0000-0000-0000-000000000001', false,
   null, null, null, null, null),
  ('61000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000007', 'MP-0007', '40000000-0000-0000-0000-000000000008', true,
   null, null, null, null, null);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, is_active) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400',  'Milo 400g',        'Milo',  'Beverages', 2500, 2000, true),
  ('10000000-0000-0000-0000-000000000001', 'MAGGI-12',  'Maggi 12 cubes',   'Maggi', 'Seasoning', 1200, 1000, true),
  ('10000000-0000-0000-0000-000000000001', 'SACHET-15', 'Coconut oil 15ml', 'Teafair', 'Oils',     500,  400, true),
  ('10000000-0000-0000-0000-000000000001', 'OLD-SKU',   'Discontinued',     'Milo',  'Beverages',  500,  400, false),
  ('10000000-0000-0000-0000-000000000002', 'OMO-1KG',   'Omo 1kg',          'Omo',   'Laundry',   3000, 2500, true);

insert into public.agent_codes (id, tenant_id, code, agent_id, terminal_id, discount_type, discount_value,
                                max_redemptions, expires_at, is_active, created_by) values
  ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GRACE-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', 'PERCENT', 10,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'GRACE-FIX',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000003', 'FIXED', 1000,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'OFF-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   null, null, false, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'OLD-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   null, now() - interval '1 day', true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'DEAD-TERM',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000004', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', 'HOUSE-01',
   '20000000-0000-0000-0000-000000000006', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001'),
  ('62000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', 'NOTM-01',
   '20000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-000000000007', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001'),
  ('62000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'CAP-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   1, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'UNI-01',
   '20000000-0000-0000-0000-000000000009', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000009'),
  ('62000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'GONE-01',
   '20000000-0000-0000-0000-000000000008', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001');

-- CAP-01 has already been redeemed once (a PAID order), so it is used up
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, agent_code_id,
                           attributed_agent_id, payment_route, delivery_address, public_reference) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000002', 100, 'PAID', '62000000-0000-0000-0000-000000000008',
   '20000000-0000-0000-0000-000000000004', 'PAYSTACK_WEB', '5 Opebi Road', 'TF-CAP001');

create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
grant execute on function pg_temp.as_service() to service_role;

-- ── privileges ──────────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.storefront_catalogue(text)', 'execute'),
  'the app cannot call storefront_catalogue');
select ok(not has_function_privilege('anon', 'public.storefront_catalogue(text)', 'execute'),
  'anon cannot call storefront_catalogue');
select ok(has_function_privilege('service_role', 'public.storefront_catalogue(text)', 'execute'),
  'the public gateway (service_role) can');
select ok(not has_function_privilege('authenticated', 'public.quote_web_order(text,jsonb)', 'execute'),
  'the app cannot call quote_web_order');

-- ── storefront_catalogue ────────────────────────────────────────────────
select pg_temp.as_service();
select is(public.storefront_catalogue('GRACE-01') -> 'venue',
  '{"name":"RCCG Grace Parish","channel":"CHURCH"}'::jsonb, 'the catalogue shows the venue');
select is(jsonb_array_length(public.storefront_catalogue('GRACE-01') -> 'products'), 3,
  'only the active products of the code''s tenant');
select ok(position('20000000-0000-0000-0000-000000000004' in public.storefront_catalogue('GRACE-01')::text) = 0,
  'no agent id leaks into the catalogue');
select is(public.storefront_catalogue('GRACE-01') -> 'discount',
  '{"type":"PERCENT","value":10}'::jsonb, 'the discount is shown');
select is(public.storefront_catalogue(' grace-01 ') ->> 'code', 'GRACE-01',
  'a lower-case, padded code resolves');
select is(public.storefront_catalogue('UNI-01') -> 'tenant' ->> 'name', 'Unilever Nigeria',
  'the code alone decides the tenant');
select throws_ok($$select public.storefront_catalogue('OFF-01')$$,
  'P0001', 'This link is no longer valid', 'an inactive code is refused');
select throws_ok($$select public.storefront_catalogue('OLD-01')$$,
  'P0001', 'This link is no longer valid', 'an expired code is refused');
select throws_ok($$select public.storefront_catalogue('DEAD-TERM')$$,
  'P0001', 'This link is no longer valid', 'a code on an inactive terminal is refused');
select throws_ok($$select public.storefront_catalogue('GONE-01')$$,
  'P0001', 'This link is no longer valid', 'a code whose agent is no longer active is refused');
select throws_ok($$select public.storefront_catalogue('CAP-01')$$,
  'P0001', 'This link is no longer valid', 'a used-up code is refused');
select throws_ok($$select public.storefront_catalogue('NOPE-99')$$,
  'P0001', 'This link is no longer valid', 'an unknown code is refused');

-- ── quote_web_order ─────────────────────────────────────────────────────
-- 2 × 2500 + 1 × 1200 = 6200; 10% off = 620; total 5580; partner 150 bps = 83.70
select is(public.quote_web_order('GRACE-01',
            '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]') ->> 'total',
  '5580.00', 'percentage discounts are applied on the server');
select is(public.quote_web_order('GRACE-01',
            '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]') -> 'split',
  '{"fintech_partner_id":"60000000-0000-0000-0000-000000000001","subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":83.70}'::jsonb,
  'an active partner takes commission_bps of the total');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"MAGGI-12","qty":1}]') -> 'split',
  'null'::jsonb, 'a partner that is not ACTIVE gets no split');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"MAGGI-12","qty":1}]') ->> 'total',
  '200.00', 'fixed discounts are applied on the server');
select throws_ok($$select public.quote_web_order('GRACE-FIX', '[{"sku_code":"SACHET-15","qty":1}]')$$,
  'P0001', null, 'a discount that leaves nothing to pay is refused');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"OLD-SKU","qty":1}]')$$,
  'P0001', null, 'an inactive product cannot be ordered');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"OMO-1KG","qty":1}]')$$,
  'P0001', null, 'another tenant''s product cannot be ordered');
select throws_ok($$select public.quote_web_order('GRACE-01',
                     '[{"sku_code":"MILO-400","qty":1},{"sku_code":"MILO-400","qty":2}]')$$,
  'P0001', null, 'a product appears once per order');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"MILO-400","qty":0}]')$$,
  'P0001', null, 'a quantity is at least 1');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"MILO-400","qty":1.5}]')$$,
  'P0001', null, 'a quantity is a whole number');
select throws_ok($$select public.quote_web_order('GRACE-01', '[]')$$,
  'P0001', null, 'an empty cart is refused');
reset role;

select * from finish();
rollback;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db`
Expected: FAIL in `012` — `function public.storefront_catalogue(unknown) does not exist`.

- [ ] **Step 3: Write `20261015120400_commerce_web_storefront_reads.sql`**

```sql
-- Addendum A1 §4.2 — the public reads. The public gateways call them as
-- service_role; the app and anon cannot. The agent code alone decides the
-- tenant (A1 decision 2), and no agent PII is ever returned.

-- ── internal: resolve a code, or refuse with one message ────────────────
-- Every reason (unknown, inactive, expired, agent gone, terminal off, used
-- up) gives the same message, so a link reveals nothing about why.
create or replace function public.web_resolve_code(p_code text)
returns public.agent_codes
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes;
begin
  select ac.* into v_code
    from public.agent_codes ac
    join public.tenants t on t.id = ac.tenant_id and t.status = 'ACTIVE'
    join public.tenant_users tu
      on tu.tenant_id = ac.tenant_id and tu.profile_id = ac.agent_id and tu.status = 'ACTIVE'
    left join public.fintech_terminals ft on ft.tenant_id = ac.tenant_id and ft.id = ac.terminal_id
   where ac.code = upper(btrim(coalesce(p_code, '')))
     and ac.is_active
     and (ac.expires_at is null or ac.expires_at > now())
     and (ac.terminal_id is null or ft.is_active)
     and (ac.max_redemptions is null or (
           select count(*) from public.orders o
            where o.tenant_id = ac.tenant_id and o.agent_code_id = ac.id
              and o.status in ('PAID', 'IN_TRANSIT', 'DELIVERED')) < ac.max_redemptions);
  if not found then
    raise exception 'This link is no longer valid' using errcode = 'P0001';
  end if;
  return v_code;
end;
$$;

-- ── internal: price a cart on the server ────────────────────────────────
-- Items: 1–50 distinct active SKUs of the code's tenant, whole quantities
-- 1–1000, priced at central_products.unit_price. The discount is capped at
-- the subtotal and the total must stay above zero. A split applies when the
-- code's terminal belongs to an ACTIVE partner (A1 decision 9).
create or replace function public.web_price_cart(p_code public.agent_codes, p_items jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_count    integer;
  v_matched  integer;
  v_lines    jsonb;
  v_subtotal numeric(15,2);
  v_discount numeric(15,2);
  v_total    numeric(15,2);
  v_split    jsonb;
begin
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'items must be a list' using errcode = 'P0001';
  end if;
  v_count := jsonb_array_length(p_items);
  if v_count < 1 or v_count > 50 then
    raise exception 'an order has between 1 and 50 items' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) e
     where jsonb_typeof(e) <> 'object'
        or jsonb_typeof(e -> 'sku_code') is distinct from 'string'
        or not (case when jsonb_typeof(e -> 'qty') = 'number' and (e ->> 'qty') ~ '^[0-9]{1,4}$'
                     then (e ->> 'qty')::integer between 1 and 1000
                     else false end)
  ) then
    raise exception 'each item needs a sku_code and a whole quantity from 1 to 1000' using errcode = 'P0001';
  end if;
  if (select count(distinct e ->> 'sku_code') from jsonb_array_elements(p_items) e) <> v_count then
    raise exception 'each product may appear only once' using errcode = 'P0001';
  end if;

  select count(*),
         jsonb_agg(jsonb_build_object(
           'sku_code', p.sku_code, 'product_name', p.product_name,
           'qty', (e ->> 'qty')::integer, 'unit_price', p.unit_price,
           'line_total', round((e ->> 'qty')::integer * p.unit_price, 2)) order by p.sku_code),
         coalesce(sum(round((e ->> 'qty')::integer * p.unit_price, 2)), 0)
    into v_matched, v_lines, v_subtotal
    from jsonb_array_elements(p_items) e
    join public.central_products p
      on p.tenant_id = p_code.tenant_id and p.sku_code = e ->> 'sku_code' and p.is_active;
  if v_matched <> v_count then
    raise exception 'a product in your cart is no longer available' using errcode = 'P0001';
  end if;

  v_discount := case p_code.discount_type
                  when 'PERCENT' then round(v_subtotal * p_code.discount_value / 100, 2)
                  when 'FIXED'   then p_code.discount_value
                  else 0
                end;
  v_discount := least(v_discount, v_subtotal);
  v_total := v_subtotal - v_discount;
  if v_total <= 0 then
    raise exception 'the order total must be more than zero' using errcode = 'P0001';
  end if;

  select jsonb_build_object('fintech_partner_id', fp.id,
                            'subaccount_code', fp.paystack_subaccount_code,
                            'commission_bps', fp.commission_bps,
                            'partner_share', round(v_total * fp.commission_bps / 10000, 2))
    into v_split
    from public.fintech_terminals ft
    join public.fintech_partners fp
      on fp.tenant_id = ft.tenant_id and fp.id = ft.partner_id and fp.status = 'ACTIVE'
   where ft.tenant_id = p_code.tenant_id and ft.id = p_code.terminal_id;

  return jsonb_build_object(
    'lines', v_lines,
    'subtotal', v_subtotal,
    'discount', v_discount,
    'total', v_total,
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = p_code.tenant_id), 'NGN'),
    'split', v_split);
end;
$$;

-- ── storefront_catalogue ────────────────────────────────────────────────
create or replace function public.storefront_catalogue(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes := public.web_resolve_code(p_code);
begin
  return jsonb_build_object(
    'code', v_code.code,
    'tenant', (select jsonb_build_object('name', t.name, 'logo_url', t.logo_url)
                 from public.tenants t where t.id = v_code.tenant_id),
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_code.tenant_id), 'NGN'),
    'discount', case when v_code.discount_type is null then null
                     else jsonb_build_object('type', v_code.discount_type, 'value', v_code.discount_value) end,
    'venue', (select case when ft.venue_name is null then null
                          else jsonb_build_object('name', ft.venue_name, 'channel', ft.venue_channel) end
                from public.fintech_terminals ft
               where ft.tenant_id = v_code.tenant_id and ft.id = v_code.terminal_id),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', p.sku_code, 'product_name', p.product_name, 'brand', p.brand,
               'category', p.category, 'unit_price', p.unit_price, 'description', p.description)
             order by p.brand, p.product_name)
        from public.central_products p
       where p.tenant_id = v_code.tenant_id and p.is_active), '[]'::jsonb));
end;
$$;

-- ── quote_web_order ─────────────────────────────────────────────────────
create or replace function public.quote_web_order(p_code text, p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  return public.web_price_cart(public.web_resolve_code(p_code), p_items);
end;
$$;

revoke execute on function public.web_resolve_code(text) from public, anon, authenticated, service_role;
revoke execute on function public.web_price_cart(public.agent_codes, jsonb) from public, anon, authenticated, service_role;
revoke execute on function public.storefront_catalogue(text) from public, anon, authenticated;
revoke execute on function public.quote_web_order(text, jsonb) from public, anon, authenticated;
grant execute on function public.storefront_catalogue(text) to service_role;
grant execute on function public.quote_web_order(text, jsonb) to service_role;
```

- [ ] **Step 4: Apply and run**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS` (012: 27).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261015120400_commerce_web_storefront_reads.sql supabase/tests/database/012_commerce_web_public.test.sql
git commit -m "feat(commerce): storefront_catalogue and quote_web_order, service_role only (A1 §4.2)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `place_web_order`

**Files:**
- Create: `supabase/migrations/20261015120500_commerce_place_web_order.sql`
- Modify: `supabase/tests/database/012_commerce_web_public.test.sql` (plan count; append before `select * from finish();`)

**Interfaces:**
- Consumes: Task 4 `web_resolve_code`, `web_price_cart`.
- Produces: `public.place_web_order(p_idempotency_key uuid, p_code text, p_items jsonb, p_customer jsonb, p_utm jsonb, p_payment_route text, p_expected_total numeric, p_checkout jsonb) returns jsonb` → `{order_id, public_reference, total, currency, payment_route, paystack_reference, authorization_url}` (the last two null on `POS_AGENT`). `p_customer` = `{name, phone (E.164), email?, delivery_address}`; `p_utm` = `{source?, medium?, campaign?}`; `p_checkout` = `{reference, access_code, authorization_url}` or null. service_role only.

- [ ] **Step 1: Append the failing tests**

Change `select plan(27);` to `select plan(50);` and insert immediately before `select * from finish();`:

```sql
-- ── place_web_order ─────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated',
  'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb)', 'execute'),
  'the app cannot call place_web_order');
select ok(has_function_privilege('service_role',
  'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb)', 'execute'),
  'the public gateway (service_role) can');

select pg_temp.as_service();
select lives_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000001', 'grace-01',
      '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031234567","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
      '{"source":"whatsapp","medium":"social","campaign":"easter"}',
      'PAYSTACK_WEB', 5580.00,
      '{"reference":"TFW-r1","access_code":"ac_1","authorization_url":"https://checkout.paystack.com/ac_1"}')$$,
  'a web order is placed for the Paystack route');
reset role;
select is(
  (select channel || '|' || status || '|' || payment_route || '|' || total_amount || '|' || discount_amount
          || '|' || attributed_terminal_id || '|' || teafair_agent_id || '|' || utm_source
     from public.orders where agent_code_id = '62000000-0000-0000-0000-000000000001' and payment_route = 'PAYSTACK_WEB'),
  'ONLINE|PENDING|PAYSTACK_WEB|5580.00|620.00|61000000-0000-0000-0000-000000000001|20000000-0000-0000-0000-000000000002|whatsapp',
  'the order carries attribution, discount, UTM and the territory''s TM as accountable agent');
select is(
  (select sum(oi.line_total) from public.order_items oi join public.orders o on o.id = oi.order_id
    where o.agent_code_id = '62000000-0000-0000-0000-000000000001' and o.payment_route = 'PAYSTACK_WEB'),
  6200.00::numeric, 'the items are priced on the server');
select is(
  (select payment_status || '|' || amount || '|' || paystack_reference || '|' || fintech_partner_id
     from public.payments where paystack_reference = 'TFW-r1'),
  'INITIATED|5580.00|TFW-r1|60000000-0000-0000-0000-000000000001', 'an INITIATED payment holds the reference');
select ok(
  (select public_reference ~ '^TF-[0-9A-HJKMNP-TV-Z]{6}$' from public.orders
    where agent_code_id = '62000000-0000-0000-0000-000000000001' and payment_route = 'PAYSTACK_WEB'),
  'the order has a public reference');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'place_web_order' and source = 'WEB' and actor_id is null
      and teafair_agent_id = '20000000-0000-0000-0000-000000000002'
      and idempotency_key = 'cccccccc-0000-0000-0000-000000000001'),
  1, 'a WEB audit row with no actor names the accountable agent');

select pg_temp.as_service();
select is(
  public.place_web_order('cccccccc-0000-0000-0000-000000000001', 'grace-01',
      '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031234567","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
      '{"source":"whatsapp","medium":"social","campaign":"easter"}',
      'PAYSTACK_WEB', 5580.00,
      '{"reference":"TFW-r2","access_code":"ac_2","authorization_url":"https://checkout.paystack.com/ac_2"}') ->> 'authorization_url',
  'https://checkout.paystack.com/ac_1', 'a retry with the same key returns the original checkout URL');
reset role;
select is(
  (select count(*)::int from public.orders
    where agent_code_id = '62000000-0000-0000-0000-000000000001' and payment_route = 'PAYSTACK_WEB'),
  1, 'a retry writes no second order');

select pg_temp.as_service();
select lives_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000002', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1080.00, null)$$,
  'a pay-at-agent order is placed');
reset role;
select is(
  (select count(*)::int from public.payments p join public.orders o on o.id = p.order_id
    where o.payment_route = 'POS_AGENT'),
  0, 'a pay-at-agent order has no payment row yet');

select pg_temp.as_service();
select lives_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000003', 'HOUSE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Chi","phone":"+2348031234569","delivery_address":"9 Awolowo Way"}',
      '{}', 'PAYSTACK_WEB', 1200.00,
      '{"reference":"TFW-r3","access_code":"ac_3","authorization_url":"https://checkout.paystack.com/ac_3"}')$$,
  'a house code works on the Paystack route');
reset role;
select is(
  (select teafair_agent_id::text || '|' || coalesce(attributed_terminal_id::text, 'none')
     from public.orders where agent_code_id = '62000000-0000-0000-0000-000000000006'),
  '20000000-0000-0000-0000-000000000006|none', 'a staff code holder is their own accountable agent');

select pg_temp.as_service();
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000004', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null)$$,
  'P0001', 'Prices changed — refresh and try again', 'a stale total is refused');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000005', 'HOUSE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null)$$,
  'P0001', null, 'pay-at-agent needs a code bound to a terminal');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000006', 'NOTM-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null)$$,
  'P0001', 'This link is not active yet', 'no accountable agent means the link is not active');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000007', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"08031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1080.00, null)$$,
  'P0001', null, 'the phone must already be E.164');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000008', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568"}',
      null, 'POS_AGENT', 1080.00, null)$$,
  'P0001', null, 'a delivery address is required');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000009', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'PAYSTACK_WEB', 1080.00, null)$$,
  'P0001', null, 'the Paystack route needs checkout details');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-00000000000a', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'CASH', 1080.00, null)$$,
  'P0001', null, 'an unknown payment route is refused');
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-000000000001', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1080.00, null)$$,
  'TF002', null, 'a key reused for a different order is refused');
reset role;

-- five unpaid web orders in the last hour from one phone
insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, customer_phone)
select '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000002', 100, '+2348099999999'
  from generate_series(1, 5);
select pg_temp.as_service();
select throws_ok(
  $$select public.place_web_order('cccccccc-0000-0000-0000-00000000000b', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Spam","phone":"+2348099999999","delivery_address":"1 Nowhere"}',
      null, 'POS_AGENT', 1080.00, null)$$,
  'P0001', 'Too many unpaid orders for this phone number. Try again later.',
  'a sixth pending web order within the hour is refused');
reset role;
```

- [ ] **Step 2: Run to verify it fails**

Run: `supabase test db`
Expected: FAIL in `012` — `function public.place_web_order(...) does not exist`.

- [ ] **Step 3: Write `20261015120500_commerce_place_web_order.sql`**

```sql
-- Addendum A1 §4.2 — place a web order. Called by web-checkout as
-- service_role, so there is no actor: the agent code decides the tenant,
-- prices are recomputed here, and the request hash excludes p_checkout so a
-- retry (which initialises a new Paystack transaction) replays the original
-- order and checkout URL (A1 §5.3).
create or replace function public.place_web_order(
  p_idempotency_key  uuid,
  p_code             text,
  p_items            jsonb,
  p_customer         jsonb,
  p_utm              jsonb,
  p_payment_route    text,
  p_expected_total   numeric,
  p_checkout         jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior       jsonb;
  v_code        public.agent_codes;
  v_cart        jsonb;
  v_total       numeric(15,2);
  v_name        text := nullif(btrim(p_customer ->> 'name'), '');
  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));
  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));
  v_address     text := nullif(btrim(p_customer ->> 'delivery_address'), '');
  v_agent       public.tenant_users;
  v_terminal    public.fintech_terminals;
  v_accountable uuid;
  v_ref         text;
  v_order       public.orders;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_payment_route is null or p_payment_route not in ('PAYSTACK_WEB', 'POS_AGENT') then
    raise exception 'payment route must be PAYSTACK_WEB or POS_AGENT' using errcode = 'P0001';
  end if;

  v_code := public.web_resolve_code(p_code);
  if p_payment_route = 'POS_AGENT' and v_code.terminal_id is null then
    raise exception 'paying at an agent needs a link from a POS agent' using errcode = 'P0001';
  end if;

  v_cart := public.web_price_cart(v_code, p_items);
  v_total := (v_cart ->> 'total')::numeric;
  if p_expected_total is distinct from v_total then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  if v_name is null then
    raise exception 'your name is required' using errcode = 'P0001';
  end if;
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'a valid phone number is required' using errcode = 'P0001';
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'the email address is not valid' using errcode = 'P0001';
  end if;
  if v_address is null then
    raise exception 'a delivery address is required' using errcode = 'P0001';
  end if;
  if p_payment_route = 'PAYSTACK_WEB' and (
       coalesce(p_checkout ->> 'reference', '') = '' or coalesce(p_checkout ->> 'authorization_url', '') = '') then
    raise exception 'checkout details are missing' using errcode = 'P0001';
  end if;

  if (select count(*) from public.orders o
       where o.customer_phone = v_phone and o.channel = 'ONLINE' and o.status = 'PENDING'
         and o.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many unpaid orders for this phone number. Try again later.' using errcode = 'P0001';
  end if;

  -- the accountable Teafair agent (Spec A §6.10): a staff code holder is
  -- their own; otherwise the TM of the terminal's (or the agent's) territory
  select * into v_agent from public.tenant_users
   where tenant_id = v_code.tenant_id and profile_id = v_code.agent_id and status = 'ACTIVE';
  if v_code.terminal_id is not null then
    select * into v_terminal from public.fintech_terminals
     where tenant_id = v_code.tenant_id and id = v_code.terminal_id;
  end if;
  if v_agent.role in ('DSA', 'DSM', 'ASM', 'TM', 'ZSM') then
    v_accountable := v_agent.profile_id;
  else
    select t.tm_id into v_accountable from public.territories t
     where t.tenant_id = v_code.tenant_id and t.id = coalesce(v_terminal.territory_id, v_agent.territory_id);
  end if;
  if v_accountable is null then
    raise exception 'This link is not active yet' using errcode = 'P0001';
  end if;

  -- TF- + 6 Crockford base-32 characters; 256 is a multiple of 32, so uniform
  loop
    v_ref := 'TF-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                                                 1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
                         from generate_series(1, 6));
    exit when not exists (select 1 from public.orders where public_reference = v_ref);
  end loop;

  insert into public.orders (tenant_id, channel, teafair_agent_id, customer_name, customer_phone, customer_email,
                             delivery_address, total_amount, discount_amount, status, agent_code_id,
                             attributed_agent_id, attributed_terminal_id, utm_source, utm_medium, utm_campaign,
                             payment_route, public_reference)
  values (v_code.tenant_id, 'ONLINE', v_accountable, v_name, v_phone, v_email,
          v_address, v_total, (v_cart ->> 'discount')::numeric, 'PENDING', v_code.id,
          v_code.agent_id, v_code.terminal_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref)
  returning * into v_order;

  insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
  select v_order.tenant_id, v_order.id, l ->> 'sku_code', (l ->> 'qty')::numeric, (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_cart -> 'lines') l;

  if p_payment_route = 'PAYSTACK_WEB' then
    insert into public.payments (tenant_id, order_id, teafair_agent_id, fintech_partner_id, fintech_terminal_id,
                                 amount, payment_status, paystack_reference, gateway_response_payload)
    values (v_order.tenant_id, v_order.id, v_accountable, v_terminal.partner_id, v_code.terminal_id,
            v_total, 'INITIATED', p_checkout ->> 'reference',
            jsonb_build_object('checkout', jsonb_build_object(
              'access_code', p_checkout ->> 'access_code',
              'authorization_url', p_checkout ->> 'authorization_url')));
  end if;

  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null, to_jsonb(v_order), p_idempotency_key, 'WEB', v_accountable);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id,
    'public_reference', v_ref,
    'total', v_total,
    'currency', v_cart ->> 'currency',
    'payment_route', p_payment_route,
    'paystack_reference', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'reference' end,
    'authorization_url', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'authorization_url' end));
end;
$$;

revoke execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb)
  from public, anon, authenticated;
grant execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb)
  to service_role;
```

- [ ] **Step 4: Apply and run**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS` (012: 50). Then run `supabase db reset` followed by `supabase test db` once, to prove all 26 migrations replay from scratch.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261015120500_commerce_place_web_order.sql supabase/tests/database/012_commerce_web_public.test.sql
git commit -m "feat(commerce): place_web_order with server pricing, throttle and WEB audit (A1 §4.2)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Public gateway kernel

**Files:**
- Create: `supabase/functions/_shared/core/public-gateway.ts`
- Create: `supabase/functions/_shared/core/public-gateway.test.ts`

**Interfaces:**
- Consumes: `Rpc` from `./db.ts`; `GatewayError`, `errorResponse` from `./errors.ts`; `json` from `./http.ts`; `parseJsonBody`, `stripTenantKeys` from `./validate.ts`.
- Produces:
  - `type PublicGatewayDeps = { rpc: Rpc; allowedOrigins: string[] }`
  - `type PublicContext<B> = { body: B; rpc: Rpc; req: Request }`
  - `function publicGateway<S extends z.ZodTypeAny>(route: { method: "GET" | "POST"; schema: S; cacheControl?: string }, handle: (ctx: PublicContext<z.infer<S>>) => Promise<unknown>, deps: PublicGatewayDeps): (req: Request) => Promise<Response>`
  - `function allowedOriginsFromEnv(): string[]` (reads `WEB_ALLOWED_ORIGINS`)

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "./db.ts";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { publicGateway } from "./public-gateway.ts";

const ORIGIN = "https://teafairweb.com";
const rpc: Rpc = <T>() => Promise.resolve({} as T);
const deps = { rpc, allowedOrigins: [ORIGIN] };

const getRoute = publicGateway(
  { method: "GET", schema: z.object({ code: z.string().min(4) }), cacheControl: "public, max-age=60" },
  ({ body }) => Promise.resolve({ code: body.code }),
  deps,
);
const postRoute = publicGateway(
  { method: "POST", schema: z.object({ n: z.number() }).passthrough() },
  ({ body }) => {
    if (body.n < 0) throw new GatewayError(422, "BUSINESS_RULE", "negative");
    return Promise.resolve({ keys: Object.keys(body).sort() });
  },
  deps,
);

const req = (method: string, url: string, opts: { origin?: string; body?: unknown } = {}) =>
  new Request(url, {
    method,
    headers: opts.origin ? { Origin: opts.origin } : {},
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });

Deno.test("a preflight from the storefront is answered with CORS headers", async () => {
  const res = await getRoute(req("OPTIONS", "http://x/", { origin: ORIGIN }));
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("a preflight from any other origin is refused", async () => {
  const res = await getRoute(req("OPTIONS", "http://x/", { origin: "https://evil.example" }));
  assertEquals(res.status, 403);
  assertEquals(res.headers.get("access-control-allow-origin"), null);
});

Deno.test("a GET from the storefront validates the query and sets cache headers", async () => {
  const res = await getRoute(req("GET", "http://x/?code=GRACE-01", { origin: ORIGIN }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { code: "GRACE-01" });
  assertEquals(res.headers.get("cache-control"), "public, max-age=60");
  assertEquals(res.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("a request from another origin is 403", async () => {
  const res = await getRoute(req("GET", "http://x/?code=GRACE-01", { origin: "https://evil.example" }));
  assertEquals([res.status, (await res.json()).error.code], [403, "ORIGIN_NOT_ALLOWED"]);
});

Deno.test("a server-side request with no Origin is served without CORS headers", async () => {
  const res = await getRoute(req("GET", "http://x/?code=GRACE-01"));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("access-control-allow-origin"), null);
  await res.body?.cancel();
});

Deno.test("errors are never cached", async () => {
  const res = await getRoute(req("GET", "http://x/?code=ab", { origin: ORIGIN }));
  assertEquals([res.status, (await res.json()).error.code], [400, "VALIDATION_FAILED"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(res.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("the wrong method is 405", async () => {
  const res = await getRoute(req("POST", "http://x/", { origin: ORIGIN, body: {} }));
  assertEquals(res.status, 405);
  await res.body?.cancel();
});

Deno.test("a POST body has tenant keys stripped before validation", async () => {
  const res = await postRoute(req("POST", "http://x/", { origin: ORIGIN, body: { n: 1, tenant_id: "evil", tenantId: "evil" } }));
  assertEquals(await res.json(), { keys: ["n"] });
});

Deno.test("business errors keep the §3.5 shape and no-store", async () => {
  const res = await postRoute(req("POST", "http://x/", { origin: ORIGIN, body: { n: -1 } }));
  assertEquals([res.status, (await res.json()).error.code], [422, "BUSINESS_RULE"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `deno test --allow-env supabase/functions/_shared/core/public-gateway.test.ts`
Expected: FAIL — module `./public-gateway.ts` not found.

- [ ] **Step 3: Write `public-gateway.ts`**

```ts
// Addendum A1 §5.1 — the public gateway flavour. A web buyer has no JWT, so
// the RPCs these gateways call are granted to service_role only and decide
// the tenant themselves from the agent code. CORS limits browsers to
// WEB_ALLOWED_ORIGINS; a request with no Origin (server-side rendering) is
// served, because CORS is not an access control.
import type { Rpc } from "./db.ts";
import type { z } from "./deps.ts";
import { errorResponse, GatewayError } from "./errors.ts";
import { json } from "./http.ts";
import { parseJsonBody, stripTenantKeys } from "./validate.ts";

export type PublicGatewayDeps = { rpc: Rpc; allowedOrigins: string[] };

export type PublicContext<B> = { body: B; rpc: Rpc; req: Request };

export type PublicRoute<S extends z.ZodTypeAny> = {
  method: "GET" | "POST";
  schema: S;
  cacheControl?: string;
};

export function allowedOriginsFromEnv(): string[] {
  return (Deno.env.get("WEB_ALLOWED_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(Boolean);
}

function corsHeaders(origin: string): Record<string, string> {
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-allow-headers": "content-type, authorization, apikey, x-client-info",
    "access-control-max-age": "86400",
    vary: "Origin",
  };
}

function withHeaders(res: Response, headers: Record<string, string>): Response {
  for (const [k, v] of Object.entries(headers)) res.headers.set(k, v);
  return res;
}

function parseQuery<S extends z.ZodTypeAny>(req: Request, schema: S): z.infer<S> {
  const query = Object.fromEntries(new URL(req.url).searchParams);
  const result = schema.safeParse(stripTenantKeys(query));
  if (!result.success) {
    throw new GatewayError(400, "VALIDATION_FAILED", "Request is invalid.", result.error.flatten());
  }
  return result.data;
}

export function publicGateway<S extends z.ZodTypeAny>(
  route: PublicRoute<S>,
  handle: (ctx: PublicContext<z.infer<S>>) => Promise<unknown>,
  deps: PublicGatewayDeps,
): (req: Request) => Promise<Response> {
  return async (req) => {
    const origin = req.headers.get("origin");
    const allowed = origin !== null && deps.allowedOrigins.includes(origin);
    const cors = allowed ? corsHeaders(origin) : {};

    if (req.method === "OPTIONS") {
      return new Response(null, { status: allowed ? 204 : 403, headers: cors });
    }
    try {
      if (origin !== null && !allowed) {
        throw new GatewayError(403, "ORIGIN_NOT_ALLOWED", "This site may not call this endpoint.");
      }
      if (req.method !== route.method) {
        throw new GatewayError(405, "METHOD_NOT_ALLOWED", `Use ${route.method}.`);
      }
      const body = route.method === "GET" ? parseQuery(req, route.schema) : await parseJsonBody(req, route.schema);
      const result = await handle({ body, rpc: deps.rpc, req });
      return withHeaders(json(200, result), {
        ...cors,
        "cache-control": route.cacheControl ?? "no-store",
      });
    } catch (e) {
      return withHeaders(errorResponse(e), { ...cors, "cache-control": "no-store" });
    }
  };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `deno test --allow-env supabase/functions/_shared/core/public-gateway.test.ts`
Expected: `ok | 9 passed | 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/core/public-gateway.ts supabase/functions/_shared/core/public-gateway.test.ts
git commit -m "feat(functions): public gateway kernel with CORS allowlist (A1 §5.1)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Checkout helpers — phone, Turnstile, Paystack Initialize

**Files:**
- Create: `supabase/functions/_shared/commerce/phone.ts`, `phone.test.ts`
- Create: `supabase/functions/_shared/commerce/turnstile.ts`, `turnstile.test.ts`
- Modify: `supabase/functions/_shared/fintech-liquidity/paystack.ts` (append), `paystack.test.ts` (append)

**Interfaces:**
- Produces:
  - `normalizePhone(input: string): string | null` — E.164 or null.
  - `type VerifyTurnstile = (token: string, remoteIp: string | null) => Promise<boolean>`; `turnstileVerifier(opts: { secretKey: string; url?: string; fetchFn?: typeof fetch }): VerifyTurnstile` — resolves false on a failed check, throws on a network error or non-JSON reply.
  - `type InitializeRequest = { reference: string; amountMinor: number; currency: string; email: string; callbackUrl: string; metadata: Record<string, unknown>; split?: { subaccount: string; transactionChargeMinor: number } }`; `type InitializedTransaction = { reference: string; accessCode: string; authorizationUrl: string }`; `type InitializeTransaction = (req: InitializeRequest) => Promise<InitializedTransaction>`; `paystackInitializer(opts: { secretKey: string; baseUrl?: string; fetchFn?: typeof fetch }): InitializeTransaction`.

- [ ] **Step 1: Write the failing tests**

`supabase/functions/_shared/commerce/phone.test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert@1";
import { normalizePhone } from "./phone.ts";

Deno.test("Nigerian local numbers become E.164", () => {
  assertEquals(normalizePhone("08031234567"), "+2348031234567");
  assertEquals(normalizePhone("0803 123 4567"), "+2348031234567");
  assertEquals(normalizePhone("0703-123-4567"), "+2347031234567");
});

Deno.test("international forms are accepted with or without +", () => {
  assertEquals(normalizePhone("+234 803-123-4567"), "+2348031234567");
  assertEquals(normalizePhone("2348031234567"), "+2348031234567");
  assertEquals(normalizePhone("(+234) 803 123 4567"), "+2348031234567");
  assertEquals(normalizePhone("+447700900123"), "+447700900123");
});

Deno.test("anything else is rejected", () => {
  assertEquals(normalizePhone("12345"), null);
  assertEquals(normalizePhone("0803123456"), null);
  assertEquals(normalizePhone("call me"), null);
  assertEquals(normalizePhone(""), null);
});
```

`supabase/functions/_shared/commerce/turnstile.test.ts`:

```ts
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { turnstileVerifier } from "./turnstile.ts";

function fakeFetch(body: unknown, seen: Request[] = [], status = 200): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
}

Deno.test("a passing token is verified with the secret, token and IP", async () => {
  const seen: Request[] = [];
  const verify = turnstileVerifier({ secretKey: "s3cret", fetchFn: fakeFetch({ success: true }, seen) });
  assertEquals(await verify("tok", "1.2.3.4"), true);
  assertEquals(seen[0].url, "https://challenges.cloudflare.com/turnstile/v0/siteverify");
  const form = await seen[0].formData();
  assertEquals([form.get("secret"), form.get("response"), form.get("remoteip")], ["s3cret", "tok", "1.2.3.4"]);
});

Deno.test("a failed check is false", async () => {
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: fakeFetch({ success: false, "error-codes": ["invalid-input-response"] }) });
  assertEquals(await verify("bad", null), false);
});

Deno.test("a URL override is honoured (local fake)", async () => {
  const seen: Request[] = [];
  await turnstileVerifier({ secretKey: "s", url: "http://host.docker.internal:54399/turnstile/v0/siteverify", fetchFn: fakeFetch({ success: true }, seen) })("t", null);
  assertEquals(seen[0].url, "http://host.docker.internal:54399/turnstile/v0/siteverify");
});

Deno.test("a network failure throws, so the gateway can answer 503", async () => {
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: () => Promise.reject(new TypeError("network down")) });
  await assertRejects(() => verify("t", null), TypeError);
});
```

Append to `supabase/functions/_shared/fintech-liquidity/paystack.test.ts` (and add `paystackInitializer` to its import line: `import { paystackInitializer, paystackVerifier } from "./paystack.ts";`):

```ts
const initialized = {
  status: true,
  message: "Authorization URL created",
  data: { authorization_url: "https://checkout.paystack.com/ac_9", access_code: "ac_9", reference: "TFW-1" },
};

Deno.test("Initialize posts the amount, split and callback with the secret key", async () => {
  const seen: Request[] = [];
  const init = paystackInitializer({ secretKey: "sk_test_x", fetchFn: fakeFetch(initialized, 200, seen) });
  const tx = await init({
    reference: "TFW-1", amountMinor: 558000, currency: "NGN", email: "ada@example.com",
    callbackUrl: "https://teafairweb.com/checkout/complete", metadata: { agent_code: "GRACE-01" },
    split: { subaccount: "ACCT_grace01", transactionChargeMinor: 549630 },
  });
  assertEquals(seen[0].url, "https://api.paystack.co/transaction/initialize");
  assertEquals(seen[0].headers.get("Authorization"), "Bearer sk_test_x");
  assertEquals(await seen[0].json(), {
    reference: "TFW-1", amount: 558000, currency: "NGN", email: "ada@example.com",
    callback_url: "https://teafairweb.com/checkout/complete", metadata: { agent_code: "GRACE-01" },
    subaccount: "ACCT_grace01", transaction_charge: 549630, bearer: "account",
  });
  assertEquals(tx, { reference: "TFW-1", accessCode: "ac_9", authorizationUrl: "https://checkout.paystack.com/ac_9" });
});

Deno.test("Initialize without a split sends no subaccount fields", async () => {
  const seen: Request[] = [];
  await paystackInitializer({ secretKey: "k", fetchFn: fakeFetch(initialized, 200, seen) })({
    reference: "TFW-1", amountMinor: 120000, currency: "NGN", email: "e@x.com", callbackUrl: "https://t/c", metadata: {},
  });
  const body = await seen[0].json();
  assertEquals(["subaccount" in body, "transaction_charge" in body, "bearer" in body], [false, false, false]);
});

Deno.test("Initialize status:false is an error", async () => {
  const init = paystackInitializer({ secretKey: "k", fetchFn: fakeFetch({ status: false, message: "Duplicate Transaction Reference" }, 400) });
  await assertRejects(
    () => init({ reference: "r", amountMinor: 1, currency: "NGN", email: "e@x.com", callbackUrl: "https://t/c", metadata: {} }),
    Error, "Duplicate Transaction Reference");
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `deno test --allow-env supabase/functions/_shared/commerce/ supabase/functions/_shared/fintech-liquidity/`
Expected: FAIL — `phone.ts` / `turnstile.ts` not found; `paystackInitializer` not exported.

- [ ] **Step 3: Implement**

`supabase/functions/_shared/commerce/phone.ts`:

```ts
// Addendum A1 §5.3 step 2 — buyers type numbers the way Nigerians write them.
// The result must satisfy orders.customer_phone's E.164 check.
export function normalizePhone(input: string): string | null {
  const plus = input.trim().replace(/[()]/g, "").startsWith("+");
  const digits = input.replace(/[^0-9]/g, "");
  if (!plus && /^0[789][01][0-9]{8}$/.test(digits)) return `+234${digits.slice(1)}`;
  if (!plus && /^234[0-9]{10}$/.test(digits)) return `+${digits}`;
  if (plus && /^[1-9][0-9]{7,14}$/.test(digits)) return `+${digits}`;
  return null;
}
```

`supabase/functions/_shared/commerce/turnstile.ts`:

```ts
// Addendum A1 §5.3 step 1 — Cloudflare Turnstile siteverify. A failed check
// resolves false (403 to the buyer); a network failure throws, so the gateway
// answers a retryable 503 instead of blaming the buyer.
export type VerifyTurnstile = (token: string, remoteIp: string | null) => Promise<boolean>;

export function turnstileVerifier(opts: { secretKey: string; url?: string; fetchFn?: typeof fetch }): VerifyTurnstile {
  const fetchFn = opts.fetchFn ?? fetch;
  const url = opts.url ?? "https://challenges.cloudflare.com/turnstile/v0/siteverify";
  return async (token, remoteIp) => {
    const form = new FormData();
    form.set("secret", opts.secretKey);
    form.set("response", token);
    if (remoteIp) form.set("remoteip", remoteIp);
    const res = await fetchFn(url, { method: "POST", body: form });
    const payload = await res.json() as { success?: unknown };
    return res.ok && payload.success === true;
  };
}
```

Append to `supabase/functions/_shared/fintech-liquidity/paystack.ts`:

```ts
// Addendum A1 §5.3 step 4 — Initialize Transaction. Amount, split and charge
// are computed on the server; with bearer "account" the main account bears
// Paystack's fee and the subaccount receives amount − transaction_charge.
export type InitializeRequest = {
  reference: string;
  amountMinor: number;
  currency: string;
  email: string;
  callbackUrl: string;
  metadata: Record<string, unknown>;
  split?: { subaccount: string; transactionChargeMinor: number };
};
export type InitializedTransaction = { reference: string; accessCode: string; authorizationUrl: string };
export type InitializeTransaction = (req: InitializeRequest) => Promise<InitializedTransaction>;

const initializeResponse = z.object({
  status: z.literal(true),
  data: z.object({
    authorization_url: z.string().url(),
    access_code: z.string(),
    reference: z.string(),
  }),
});

export function paystackInitializer(opts: {
  secretKey: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
}): InitializeTransaction {
  const fetchFn = opts.fetchFn ?? fetch;
  const baseUrl = opts.baseUrl ?? "https://api.paystack.co";
  return async (req) => {
    const body: Record<string, unknown> = {
      reference: req.reference,
      amount: req.amountMinor,
      currency: req.currency,
      email: req.email,
      callback_url: req.callbackUrl,
      metadata: req.metadata,
    };
    if (req.split) {
      body.subaccount = req.split.subaccount;
      body.transaction_charge = req.split.transactionChargeMinor;
      body.bearer = "account";
    }
    const res = await fetchFn(`${baseUrl}/transaction/initialize`, {
      method: "POST",
      headers: { Authorization: `Bearer ${opts.secretKey}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const payload = await res.json().catch(() => null) as { message?: string } | null;
    const parsed = initializeResponse.safeParse(payload);
    if (!res.ok || !parsed.success) {
      throw new Error(`Paystack initialize failed: ${payload?.message ?? `HTTP ${res.status}`}`);
    }
    const { data } = parsed.data;
    return { reference: data.reference, accessCode: data.access_code, authorizationUrl: data.authorization_url };
  };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `deno test --allow-env supabase/functions/_shared/commerce/ supabase/functions/_shared/fintech-liquidity/`
Expected: all pass (3 phone, 4 Turnstile, 3 new Paystack + the existing Paystack tests).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/commerce supabase/functions/_shared/fintech-liquidity/paystack.ts supabase/functions/_shared/fintech-liquidity/paystack.test.ts
git commit -m "feat(functions): phone normalisation, Turnstile and Paystack Initialize clients (A1 §5.3)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `storefront-catalogue` function

**Files:**
- Create: `supabase/functions/storefront-catalogue/handler.ts`, `handler.test.ts`, `index.ts`
- Modify: `supabase/config.toml` (after the `[functions.otp-verify]` block)

**Interfaces:**
- Consumes: Task 6 `publicGateway`, `PublicGatewayDeps`, `allowedOriginsFromEnv`; `serviceRpc` from `_shared/core/db.ts`; RPC `storefront_catalogue(p_code)`.
- Produces: `createStorefrontCatalogueHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response>`; `GET /functions/v1/storefront-catalogue?code=<code>`.

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { createStorefrontCatalogueHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";

function setup(result: unknown | Error = { code: "GRACE-01", products: [] }) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result as T);
  };
  return { handler: createStorefrontCatalogueHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}

const get = (handler: (r: Request) => Promise<Response>, query: string) =>
  handler(new Request(`http://x/storefront-catalogue${query}`, { headers: { Origin: ORIGIN } }));

Deno.test("the code goes to storefront_catalogue and the reply is CDN-cacheable", async () => {
  const { handler, calls } = setup();
  const res = await get(handler, "?code=grace-01");
  assertEquals(res.status, 200);
  assertEquals(calls, [["storefront_catalogue", { p_code: "grace-01" }]]);
  assertEquals(res.headers.get("cache-control"), "public, max-age=60, s-maxage=300");
  assertEquals(await res.json(), { code: "GRACE-01", products: [] });
});

Deno.test("a missing code is 400 and calls nothing", async () => {
  const { handler, calls } = setup();
  const res = await get(handler, "");
  assertEquals([res.status, calls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("an invalid link is 422 and never cached", async () => {
  const { handler } = setup(new GatewayError(422, "BUSINESS_RULE", "This link is no longer valid"));
  const res = await get(handler, "?code=OFF-01");
  const body = await res.json();
  assertEquals([res.status, body.error.message], [422, "This link is no longer valid"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `deno test --allow-env supabase/functions/storefront-catalogue/`
Expected: FAIL — `./handler.ts` not found.

- [ ] **Step 3: Implement**

`handler.ts`:

```ts
// Addendum A1 §5.2 — the storefront's catalogue for one agent code. Cached at
// the Vercel CDN for 5 minutes (browsers 1 minute), so the function sees about
// one call per code per five minutes. No agent PII is in the RPC's reply.
import { z } from "../_shared/core/deps.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";

const schema = z.object({ code: z.string().trim().min(4).max(32) });

export function createStorefrontCatalogueHandler(deps: PublicGatewayDeps): (req: Request) => Promise<Response> {
  return publicGateway(
    { method: "GET", schema, cacheControl: "public, max-age=60, s-maxage=300" },
    ({ body, rpc }) => rpc("storefront_catalogue", { p_code: body.code }),
    deps,
  );
}
```

`index.ts`:

```ts
import { serviceRpc } from "../_shared/core/db.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { createStorefrontCatalogueHandler } from "./handler.ts";

// public-flavoured (A1 §5): anonymous callers; the RPC is granted to service_role only
Deno.serve(createStorefrontCatalogueHandler({ rpc: serviceRpc(), allowedOrigins: allowedOriginsFromEnv() }));
```

Add to `supabase/config.toml` after `[functions.otp-verify]`:

```toml
[functions.storefront-catalogue]
verify_jwt = false
```

- [ ] **Step 4: Run to verify it passes**

Run: `deno test --allow-env supabase/functions/storefront-catalogue/`
Expected: `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/storefront-catalogue supabase/config.toml
git commit -m "feat(functions): storefront-catalogue public gateway (A1 §5.2)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `web-checkout` function

**Files:**
- Create: `supabase/functions/web-checkout/handler.ts`, `handler.test.ts`, `index.ts`
- Modify: `supabase/config.toml`, `supabase/functions/.env.example`

**Interfaces:**
- Consumes: Task 6 kernel; Task 7 `normalizePhone`, `VerifyTurnstile`, `turnstileVerifier`, `InitializeTransaction`, `paystackInitializer`; RPCs `quote_web_order(p_code, p_items)` and `place_web_order(...)` from Tasks 4–5.
- Produces: `createWebCheckoutHandler(deps: WebCheckoutDeps)` where `WebCheckoutDeps = PublicGatewayDeps & { verifyTurnstile: VerifyTurnstile; initializeTransaction: InitializeTransaction; newReference: () => string; callbackUrl: string }`; `POST /functions/v1/web-checkout`.

- [ ] **Step 1: Write the failing test**

```ts
import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import type { InitializeRequest, InitializeTransaction } from "../_shared/fintech-liquidity/paystack.ts";
import { createWebCheckoutHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const KEY = "c0000000-0000-0000-0000-000000000001";
const QUOTE = {
  total: 5580, currency: "NGN",
  split: { fintech_partner_id: "p1", subaccount_code: "ACCT_grace01", commission_bps: 150, partner_share: 83.7 },
};
const PLACED = { order_id: "o1", public_reference: "TF-7K3Q9X", total: 5580 };

type Opts = {
  human?: boolean | Error;
  quote?: unknown | Error;
  initFails?: boolean;
};

function setup(opts: Opts = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const inits: InitializeRequest[] = [];
  const turnstileCalls: Array<[string, string | null]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    const result = fn === "quote_web_order" ? (opts.quote ?? QUOTE) : PLACED;
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result as T);
  };
  const initializeTransaction: InitializeTransaction = (req) => {
    inits.push(req);
    if (opts.initFails) return Promise.reject(new Error("Paystack down"));
    return Promise.resolve({ reference: req.reference, accessCode: "ac_1", authorizationUrl: "https://checkout.paystack.com/ac_1" });
  };
  const handler = createWebCheckoutHandler({
    rpc,
    allowedOrigins: [ORIGIN],
    verifyTurnstile: (token, ip) => {
      turnstileCalls.push([token, ip]);
      const h = opts.human ?? true;
      return h instanceof Error ? Promise.reject(h) : Promise.resolve(h);
    },
    initializeTransaction,
    newReference: () => "TFW-FIXED",
    callbackUrl: "https://teafairweb.com/checkout/complete",
  });
  return { handler, rpcCalls, inits, turnstileCalls };
}

const order = (over: Record<string, unknown> = {}) => ({
  idempotency_key: KEY,
  code: "grace-01",
  items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
  customer: { name: "Ada Obi", phone: "0803 123 4567", email: "Ada@Example.com", delivery_address: "5 Opebi Road, Ikeja" },
  utm: { source: "whatsapp", medium: "social" },
  payment_route: "PAYSTACK_WEB",
  turnstile_token: "tok",
  ...over,
});

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/web-checkout", {
    method: "POST",
    headers: { Origin: ORIGIN, "cf-connecting-ip": "1.2.3.4" },
    body: JSON.stringify(body),
  }));

Deno.test("Paystack route: verify, quote, initialize with split, then place", async () => {
  const { handler, rpcCalls, inits, turnstileCalls } = setup();
  const res = await post(handler, order());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), PLACED);
  assertEquals(turnstileCalls, [["tok", "1.2.3.4"]]);
  assertEquals(rpcCalls.map(([fn]) => fn), ["quote_web_order", "place_web_order"]);
  assertEquals(inits[0], {
    reference: "TFW-FIXED", amountMinor: 558000, currency: "NGN", email: "ada@example.com",
    callbackUrl: "https://teafairweb.com/checkout/complete",
    metadata: { agent_code: "GRACE-01", payment_route: "PAYSTACK_WEB" },
    split: { subaccount: "ACCT_grace01", transactionChargeMinor: 549630 },
  });
  assertEquals(rpcCalls[1][1], {
    p_idempotency_key: KEY,
    p_code: "grace-01",
    p_items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
    p_customer: { name: "Ada Obi", phone: "+2348031234567", email: "ada@example.com", delivery_address: "5 Opebi Road, Ikeja" },
    p_utm: { source: "whatsapp", medium: "social" },
    p_payment_route: "PAYSTACK_WEB",
    p_expected_total: 5580,
    p_checkout: { reference: "TFW-FIXED", access_code: "ac_1", authorization_url: "https://checkout.paystack.com/ac_1" },
  });
});

Deno.test("POS route: no Paystack call, no checkout", async () => {
  const { handler, rpcCalls, inits } = setup();
  const res = await post(handler, order({ payment_route: "POS_AGENT" }));
  assertEquals(res.status, 200);
  assertEquals(inits.length, 0);
  assertEquals(rpcCalls[1][1].p_checkout, null);
  await res.body?.cancel();
});

Deno.test("no email: Paystack gets a per-order address", async () => {
  const { handler, inits } = setup();
  const o = order();
  delete (o.customer as Record<string, unknown>).email;
  const res = await post(handler, o);
  assertEquals(inits[0].email, "order-tfw-fixed@pay.teafairweb.com");
  await res.body?.cancel();
});

Deno.test("no split: Initialize carries no subaccount", async () => {
  const { handler, inits } = setup({ quote: { total: 1200, currency: "NGN", split: null } });
  const res = await post(handler, order());
  assertEquals([inits[0].amountMinor, inits[0].split], [120000, undefined]);
  await res.body?.cancel();
});

Deno.test("a failed bot check is 403 and calls nothing", async () => {
  const { handler, rpcCalls } = setup({ human: false });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length], [403, "BOT_CHECK_FAILED", 0]);
});

Deno.test("a Turnstile outage is 503 and writes nothing", async () => {
  const { handler, rpcCalls } = setup({ human: new TypeError("network down") });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length], [503, "RETRY", 0]);
});

Deno.test("an unusable phone is 400 before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order({ customer: { name: "Ada", phone: "12345", delivery_address: "5 Opebi Road" } }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("a Paystack failure writes no order", async () => {
  const { handler, rpcCalls } = setup({ initFails: true });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.code], [502, "PAYMENT_PROVIDER_UNAVAILABLE"]);
  assertEquals(rpcCalls.map(([fn]) => fn), ["quote_web_order"]);
});

Deno.test("a business error from the quote passes through as 422", async () => {
  const { handler } = setup({ quote: new GatewayError(422, "BUSINESS_RULE", "This link is no longer valid") });
  const res = await post(handler, order());
  assertEquals([res.status, (await res.json()).error.message], [422, "This link is no longer valid"]);
});

Deno.test("an unknown payment route is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, order({ payment_route: "CASH" }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `deno test --allow-env supabase/functions/web-checkout/`
Expected: FAIL — `./handler.ts` not found.

- [ ] **Step 3: Implement**

`handler.ts`:

```ts
// Addendum A1 §5.3 — web checkout. Turnstile → normalise the phone → quote
// (server pricing) → on PAYSTACK_WEB, Initialize → place_web_order.
//
// Initialize runs BEFORE the write. A retry whose earlier attempt committed
// gets the original order and checkout URL back from place_web_order's
// idempotency replay; the transaction the retry initialised is never shown
// and expires unpaid. The other order would leave a committed order with no
// checkout URL whenever Paystack failed.
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { publicGateway, type PublicGatewayDeps } from "../_shared/core/public-gateway.ts";
import { idempotencyKey } from "../_shared/core/validate.ts";
import { normalizePhone } from "../_shared/commerce/phone.ts";
import type { VerifyTurnstile } from "../_shared/commerce/turnstile.ts";
import type { InitializeTransaction } from "../_shared/fintech-liquidity/paystack.ts";

export type WebCheckoutDeps = PublicGatewayDeps & {
  verifyTurnstile: VerifyTurnstile;
  initializeTransaction: InitializeTransaction;
  newReference: () => string;
  callbackUrl: string;
};

const schema = z.object({
  idempotency_key: idempotencyKey,
  code: z.string().trim().min(4).max(32),
  items: z.array(z.object({
    sku_code: z.string().min(1).max(64),
    qty: z.number().int().min(1).max(1000),
  })).min(1).max(50),
  customer: z.object({
    name: z.string().trim().min(2).max(120),
    phone: z.string().trim().min(7).max(24),
    email: z.string().trim().toLowerCase().email().max(254).optional(),
    delivery_address: z.string().trim().min(5).max(500),
  }),
  utm: z.object({
    source: z.string().max(100).optional(),
    medium: z.string().max(100).optional(),
    campaign: z.string().max(100).optional(),
  }).optional(),
  payment_route: z.enum(["PAYSTACK_WEB", "POS_AGENT"]),
  turnstile_token: z.string().min(1).max(2048),
});

type Quote = {
  total: number | string;
  currency: string;
  split: { subaccount_code: string; partner_share: number | string } | null;
};

const toMinor = (amount: number | string) => Math.round(Number(amount) * 100);

function clientIp(req: Request): string | null {
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? null;
}

export function createWebCheckoutHandler(deps: WebCheckoutDeps): (req: Request) => Promise<Response> {
  return publicGateway({ method: "POST", schema }, async ({ body, rpc, req }) => {
    let human: boolean;
    try {
      human = await deps.verifyTurnstile(body.turnstile_token, clientIp(req));
    } catch (e) {
      console.error("Turnstile verification failed", e);
      throw new GatewayError(503, "RETRY", "The security check is unavailable. Please try again.");
    }
    if (!human) throw new GatewayError(403, "BOT_CHECK_FAILED", "Please complete the security check and try again.");

    const phone = normalizePhone(body.customer.phone);
    if (!phone) throw new GatewayError(400, "VALIDATION_FAILED", "Enter a valid phone number.");
    const customer = { ...body.customer, phone };

    const quote = await rpc<Quote>("quote_web_order", { p_code: body.code, p_items: body.items });

    let checkout: { reference: string; access_code: string; authorization_url: string } | null = null;
    if (body.payment_route === "PAYSTACK_WEB") {
      const reference = deps.newReference();
      const amountMinor = toMinor(quote.total);
      try {
        const tx = await deps.initializeTransaction({
          reference,
          amountMinor,
          currency: quote.currency,
          email: customer.email ?? `order-${reference.toLowerCase()}@pay.teafairweb.com`,
          callbackUrl: deps.callbackUrl,
          metadata: { agent_code: body.code.toUpperCase(), payment_route: body.payment_route },
          split: quote.split
            ? { subaccount: quote.split.subaccount_code, transactionChargeMinor: amountMinor - toMinor(quote.split.partner_share) }
            : undefined,
        });
        checkout = { reference: tx.reference, access_code: tx.accessCode, authorization_url: tx.authorizationUrl };
      } catch (e) {
        console.error("Paystack initialize failed", e);
        throw new GatewayError(502, "PAYMENT_PROVIDER_UNAVAILABLE", "Payment could not be started. Please try again.");
      }
    }

    return await rpc("place_web_order", {
      p_idempotency_key: body.idempotency_key,
      p_code: body.code,
      p_items: body.items,
      p_customer: customer,
      p_utm: body.utm ?? {},
      p_payment_route: body.payment_route,
      p_expected_total: quote.total,
      p_checkout: checkout,
    });
  }, deps);
}
```

Note for the test "Paystack route": `p_utm` is the parsed `utm` object, so `{ source, medium }` with no `campaign` key — Zod drops absent optional keys.

`index.ts`:

```ts
import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { turnstileVerifier } from "../_shared/commerce/turnstile.ts";
import { paystackInitializer } from "../_shared/fintech-liquidity/paystack.ts";
import { createWebCheckoutHandler } from "./handler.ts";

// public-flavoured (A1 §5): anonymous callers, gated by Turnstile; RPCs are service_role only
Deno.serve(createWebCheckoutHandler({
  rpc: serviceRpc(),
  allowedOrigins: allowedOriginsFromEnv(),
  verifyTurnstile: turnstileVerifier({
    secretKey: requireEnv("TURNSTILE_SECRET_KEY"),
    url: Deno.env.get("TURNSTILE_VERIFY_URL") || undefined,
  }),
  initializeTransaction: paystackInitializer({
    secretKey: requireEnv("PAYSTACK_SECRET_KEY"),
    baseUrl: Deno.env.get("PAYSTACK_API_BASE") || undefined,
  }),
  newReference: () => `TFW-${crypto.randomUUID()}`,
  callbackUrl: requireEnv("WEB_CHECKOUT_CALLBACK_URL"),
}));
```

Add to `supabase/config.toml` after `[functions.storefront-catalogue]`:

```toml
[functions.web-checkout]
verify_jwt = false
```

Append to `supabase/functions/.env.example`:

```
# Public gateways (addendum A1). Comma-separated browser origins allowed by CORS.
WEB_ALLOWED_ORIGINS=http://localhost:3000
# Where Paystack returns the buyer after paying.
WEB_CHECKOUT_CALLBACK_URL=http://localhost:3000/checkout/complete
# Cloudflare Turnstile. Locally the integration test's fake answers at TURNSTILE_VERIFY_URL;
# omit TURNSTILE_VERIFY_URL in real environments.
TURNSTILE_SECRET_KEY=local-test-secret
TURNSTILE_VERIFY_URL=http://host.docker.internal:54399/turnstile/v0/siteverify
```

Copy the same four lines into your local `supabase/functions/.env` (gitignored).

- [ ] **Step 4: Run to verify it passes**

Run: `deno test --allow-env supabase/functions/web-checkout/` then the whole unit suite: `deno test --allow-env supabase/functions/`
Expected: web-checkout `10 passed`; whole suite passes (the integration file is not picked up by default because it does not end in `.test.ts`).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/web-checkout supabase/config.toml supabase/functions/.env.example
git commit -m "feat(functions): web-checkout public gateway, Paystack and pay-at-agent routes (A1 §5.3)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: End-to-end on the local stack, and docs

**Files:**
- Modify: `supabase/functions/_tests/gateway.integration.ts`
- Modify: `supabase/CLAUDE.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above, running under `supabase functions serve`.

- [ ] **Step 1: Extend the fake Paystack server to route by path**

In `gateway.integration.ts`, replace the `fakePaystack` block with:

```ts
// a fake Paystack (Verify + Initialize) and a fake Turnstile, reached from the
// edge runtime via host.docker.internal:54399
const paystackLedger = new Map<string, Record<string, unknown>>();
const initialized: Array<Record<string, unknown>> = [];
const fakePaystack = Deno.serve({ hostname: "0.0.0.0", port: 54399, onListen() {} }, async (req) => {
  const path = new URL(req.url).pathname;
  if (path === "/turnstile/v0/siteverify") {
    const form = await req.formData();
    return Response.json({ success: form.get("response") === "pass" });
  }
  if (path === "/transaction/initialize") {
    const body = await req.json() as Record<string, unknown>;
    initialized.push(body);
    const ref = String(body.reference);
    return Response.json({ status: true, data: { authorization_url: `https://checkout.paystack.test/${ref}`, access_code: `ac_${ref}`, reference: ref } });
  }
  const reference = decodeURIComponent(path.split("/").pop()!);
  const data = paystackLedger.get(reference);
  return data
    ? Response.json({ status: true, message: "Verification successful", data })
    : Response.json({ status: false, message: "Transaction reference not found" }, { status: 400 });
});
```

- [ ] **Step 2: Add storefront fixtures and tests**

Add `agent` to the `users` record type and `partner`, `terminal` to `ids`:

```ts
let users: Record<"tm" | "dsm" | "dsa" | "owner" | "agent", { id: string; email: string }>;
```

```ts
  partner: crypto.randomUUID(),
  terminal: crypto.randomUUID(),
```

In the `fixtures` test, change the users line to include `agent: await createUser(5)` and append at the end of `fn`:

```ts
    await must(admin.from("tenant_users").insert([
      { tenant_id: ids.tenant, profile_id: users.agent.id, role: "FINTECH_AGENT", territory_id: ids.territory, status: "ACTIVE", is_primary: true },
    ]));
    await must(admin.from("territories").update({ tm_id: users.tm.id }).eq("id", ids.territory));
    await must(admin.from("fintech_partners").insert({
      id: ids.partner, tenant_id: ids.tenant, business_name: `IT Moniepoint ${run}`, pos_network: "MONIEPOINT",
      commission_bps: 150, contact_phone: `+${phone(5)}`, paystack_subaccount_code: "ACCT_it01",
      status: "ACTIVE", approved_by: users.tm.id, approved_at: new Date().toISOString(),
    }));
    await must(admin.from("fintech_terminals").insert({
      id: ids.terminal, tenant_id: ids.tenant, partner_id: ids.partner, agent_id: users.agent.id,
      terminal_id: `IT-${run}`, territory_id: ids.territory,
    }));
    await must(admin.from("central_products").insert([
      { tenant_id: ids.tenant, sku_code: "MILO-400", product_name: "Milo 400g", brand: "Milo", category: "Beverages", unit_price: 2500, wholesale_price: 2000 },
      { tenant_id: ids.tenant, sku_code: "MAGGI-12", product_name: "Maggi 12 cubes", brand: "Maggi", category: "Seasoning", unit_price: 1200, wholesale_price: 1000 },
    ]));
```

Add these tests before `teardown`:

```ts
const CODE = `IT-${run.toUpperCase()}`;
const WEB = "http://localhost:3000";

Deno.test({
  name: "upsert_agent_code: a TM issues a 10% code through PostgREST",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const jwt = await signIn(users.tm.email);
    const tm = createClient(API, ANON, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const result = await must(tm.rpc("upsert_agent_code", {
      p_idempotency_key: crypto.randomUUID(), p_code: CODE, p_agent_id: users.agent.id, p_terminal_id: ids.terminal,
      p_discount_type: "PERCENT", p_discount_value: 10, p_max_redemptions: null, p_expires_at: null, p_is_active: true,
    })) as { code: string };
    assertEquals(result.code, CODE);
  },
});

Deno.test({
  name: "storefront-catalogue: products for the code, cacheable, no agent id",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await fetch(`${FN}/storefront-catalogue?code=${CODE.toLowerCase()}`, { headers: { Origin: WEB } });
    const text = await res.text();
    assertEquals(res.status, 200, text);
    assertEquals(res.headers.get("access-control-allow-origin"), WEB);
    assertEquals(res.headers.get("cache-control"), "public, max-age=60, s-maxage=300");
    assertEquals(JSON.parse(text).products.length, 2);
    assert(!text.includes(users.agent.id), "the agent's id never reaches the storefront");
  },
});

const checkout = (body: Record<string, unknown>) =>
  fetch(`${FN}/web-checkout`, { method: "POST", headers: { Origin: WEB, "content-type": "application/json" }, body: JSON.stringify(body) });

const webOrder = (over: Record<string, unknown> = {}) => ({
  idempotency_key: crypto.randomUUID(),
  code: CODE,
  items: [{ sku_code: "MILO-400", qty: 2 }, { sku_code: "MAGGI-12", qty: 1 }],
  customer: { name: "Ada Obi", phone: `+${phone(7)}`, delivery_address: "5 Opebi Road, Ikeja" },
  utm: { source: "whatsapp" },
  payment_route: "PAYSTACK_WEB",
  turnstile_token: "pass",
  ...over,
});

Deno.test({
  name: "web-checkout: a failed bot check is 403",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await checkout(webOrder({ turnstile_token: "fail" }));
    assertEquals([res.status, (await res.json()).error.code], [403, "BOT_CHECK_FAILED"]);
  },
});

Deno.test({
  name: "web-checkout: Paystack route initialises with the split and records an INITIATED payment",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const body = webOrder();
    const res = await checkout(body);
    const placed = await res.json();
    assertEquals(res.status, 200, JSON.stringify(placed));
    assert(/^TF-[0-9A-HJKMNP-TV-Z]{6}$/.test(placed.public_reference));
    assertEquals(placed.authorization_url, `https://checkout.paystack.test/${placed.paystack_reference}`);

    const init = initialized.find((i) => i.reference === placed.paystack_reference)!;
    assertEquals([init.amount, init.subaccount, init.transaction_charge], [558000, "ACCT_it01", 558000 - 8370]);

    const [payment] = (await must(admin.from("payments").select("payment_status, amount").eq("paystack_reference", placed.paystack_reference))) ?? [];
    assertEquals([payment.payment_status, Number(payment.amount)], ["INITIATED", 5580]);

    // a retry with the same key gets the same order and URL back
    const again = await (await checkout(body)).json();
    assertEquals([again.order_id, again.authorization_url], [placed.order_id, placed.authorization_url]);
  },
});

Deno.test({
  name: "web-checkout: pay-at-agent route returns a public reference and no payment",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const res = await checkout(webOrder({ payment_route: "POS_AGENT" }));
    const placed = await res.json();
    assertEquals(res.status, 200, JSON.stringify(placed));
    assertEquals(placed.authorization_url, null);
    const [order] = (await must(admin.from("orders").select("attributed_terminal_id, teafair_agent_id, payment_route").eq("id", placed.order_id))) ?? [];
    assertEquals([order.attributed_terminal_id, order.teafair_agent_id, order.payment_route], [ids.terminal, users.tm.id, "POS_AGENT"]);
    const payments = await must(admin.from("payments").select("id").eq("order_id", placed.order_id));
    assertEquals(payments?.length, 0);
  },
});
```

- [ ] **Step 3: Run the integration suite**

Run, in three terminals:

```bash
supabase start
supabase functions serve --env-file supabase/functions/.env
supabase status -o env > supabase/.env.test.local
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts
```

Expected: every test passes, including the 5 new ones. If a storefront test fails with 500, read the `functions serve` log first: a missing env var (`requireEnv`) fails at boot.

- [ ] **Step 4: Full verification**

Run: `supabase db reset` then `supabase test db` → `Result: PASS`, and note the assertion total it reports (expected 388: the previous 287 + 1 in `001` + 20 + 30 + 50). Run `deno test --allow-env supabase/functions/` → all pass.

- [ ] **Step 5: Update docs**

In `supabase/CLAUDE.md`:
- Status table: add a row `| A1. Web storefront — agent codes, venues, public gateways | done |`.
- Linked-remote paragraph: append "The six addendum A1 migrations and the `storefront-catalogue` / `web-checkout` functions are local only until explicitly pushed."
- Layout: change the `_shared/` comment to `core/ (gateway kernel, public-gateway) · auth/ · commerce/ · fintech-liquidity/`.
- Under "Writing an Edge Function", add after the **System functions** bullet:

```markdown
- **Public gateways** (`storefront-catalogue`, `web-checkout`; addendum A1)
  use `publicGateway(route, handle, deps)` from `_shared/core/public-gateway.ts`.
  Callers are anonymous, so their RPCs are granted to `service_role` only and
  resolve the tenant from the agent code. CORS is limited to
  `WEB_ALLOWED_ORIGINS`; checkout is gated by Turnstile.
```

- Secrets paragraph: add "`web-checkout` also needs `TURNSTILE_SECRET_KEY`, `WEB_ALLOWED_ORIGINS` and `WEB_CHECKOUT_CALLBACK_URL` (see `functions/.env.example`)."

In root `CLAUDE.md`, repository-state row for `supabase/`: replace "20 migrations, 287 pgTAP assertions, 4 Edge Functions" with "26 migrations, <total from Step 4> pgTAP assertions, 6 Edge Functions; addendum A1 (web storefront) done locally". Add a row under it:

```markdown
| `docs/superpowers/specs/2026-10-15-…` | Addendum A1 to Spec A — web storefront, agent codes, terminal venues |
```

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_tests/gateway.integration.ts supabase/CLAUDE.md CLAUDE.md
git commit -m "test(functions): storefront end-to-end on the local stack; docs: addendum A1 done

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Not in this plan

- **Phase 3, the `teafair-web` storefront.** It is a separate repository with its own spec and plan. Its TypeScript types come from `supabase gen types typescript --local` run against this stack, written into that repository.
- Anything the spec lists under §8 (order `PAID` transitions, commission rows, POS settlement, abandoned-order cleanup, order-status lookup, venue pickup).
- Any remote push or deploy.
