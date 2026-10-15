# Buyer Contact Privacy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Buyer contact details (name, phone, email, delivery address) are readable only by the tenant's ZSM and the order's TM; the order's POS agent gets a masked till lookup; Paystack's raw payload is withheld from the app.

**Architecture:** Contact details move from `orders` into a new `order_contacts` table with its own narrow `FOR SELECT` policy. `place_web_order` writes there and audits a redacted summary. A new read RPC, `pos_order_lookup`, returns masked fields to the attributed agent. `payments.gateway_response_payload` is excluded by column grant.

**Tech Stack:** Postgres 17 (Supabase local stack), PL/pgSQL, pgTAP.

**Spec:** `docs/superpowers/specs/2026-10-15-buyer-contact-privacy-design.md` (addendum A2). Spec A and addendum A1 are the context it amends.

## Global Constraints

- Local stack only. No `supabase db push`, `functions deploy`, `secrets set`, `config push`, `migration list`, `link`, or any other command that reaches the remote project.
- Every `SECURITY DEFINER` function pins `set search_path = public, pg_temp`.
- RLS policies are `FOR SELECT` only and call `public.*` helpers inside `(select …)`.
- New functions get no EXECUTE for `public`/`anon`/`authenticated` unless granted explicitly.
- Error codes: `P0001` business 422 · `42501` forbidden 403 · `23505` 409 · `TF002` 409 · `40001`/`55P03` 503.
- Tenant-scoped tables: `tenant_id … on delete restrict`, composite `(tenant_id, x)` foreign keys.
- Test first: write the pgTAP assertions, watch them fail, then write the migration.
- `supabase test db` must end with `Result: PASS`; `deno test --allow-env supabase/functions/` must pass.

## Review Focus

1. **A TM with no territory, or a ZSM-held code:** the contact row has a null `territory_id` and only ZSMs see it (Task 1 tests ZSM-01).
2. **Throttle after the move:** the per-phone limit must still count only ONLINE + PENDING orders from the last hour (Task 1 throttle test; Task 1 updates 012's fixture).
3. **Reference probing:** every non-matching `pos_order_lookup` case returns the same `Order not found` (Task 2).
4. **`select *` on `payments`** now fails for `authenticated` because one column is withheld. The app must list columns. Recorded in docs (Task 3).
5. **Deploy order:** A1 must never reach a live database without A2. Recorded in docs (Task 3).

---

### Task 1: `order_contacts`, the data move, payments column grant and `place_web_order`

**Files:**
- Create: `supabase/migrations/20261015130000_commerce_order_contacts.sql`
- Create: `supabase/migrations/20261015130100_commerce_place_web_order_contacts.sql`
- Create: `supabase/tests/database/013_commerce_buyer_privacy.test.sql`
- Modify: `supabase/tests/database/001_schema_shape.test.sql` (table list → 35)
- Modify: `supabase/tests/database/010_commerce_web_schema.test.sql` (three `orders` inserts)
- Modify: `supabase/tests/database/012_commerce_web_public.test.sql` (CAP-01 fixture, throttle fixture)

**Interfaces:**
- Consumes: `public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb)` (A1), `public.my_tenant_ids_with_role(tenant_role_enum[])`, `public.write_audit(...)`.
- Produces: table `public.order_contacts(order_id, tenant_id, territory_id, customer_name, customer_phone, customer_email, delivery_address, created_at, updated_at)`; function `public.my_tm_territory_ids() returns setof uuid`. Task 2 reads `order_contacts`.

- [ ] **Step 1: Write the failing test file**

Create `supabase/tests/database/013_commerce_buyer_privacy.test.sql`:

```sql
-- Addendum A2 — buyer contact details are readable only by the ZSM and the
-- order's TM; the POS agent gets a masked till lookup (Task 2 appends it).
begin;
create extension if not exists pgtap with schema extensions;

select plan(24);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into public.tenant_settings (tenant_id, currency) values
  ('10000000-0000-0000-0000-000000000001', 'NGN');

-- 1 ZSM · 2 TM Ikeja · 3 TM Epe · 4 POS agent Ikeja · 5 shop owner
-- 6 DSA Ikeja · 7 POS agent Epe · 8 disabled POS agent · 9 ZSM Unilever
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
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
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000003', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'RETAIL_SHOP_OWNER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000003', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000003';

insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id, is_active) values
  ('61000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0001', '40000000-0000-0000-0000-000000000001', true),
  ('61000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000007', 'MP-0007', '40000000-0000-0000-0000-000000000003', true);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, is_active) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400', 'Milo 400g', 'Milo', 'Beverages', 2500, 2000, true);

insert into public.agent_codes (id, tenant_id, code, agent_id, terminal_id, discount_type, discount_value,
                                max_redemptions, expires_at, is_active, created_by) values
  ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GRACE-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', 'PERCENT', 10,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'EPE-01',
   '20000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-000000000007', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000003'),
  ('62000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'ZSM-01',
   '20000000-0000-0000-0000-000000000001', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001');

create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
grant execute on function pg_temp.as_service() to service_role;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── schema ──────────────────────────────────────────────────────────────
select hasnt_column('public', 'orders', 'customer_name',    'orders no longer holds the buyer''s name');
select hasnt_column('public', 'orders', 'customer_phone',   'orders no longer holds the buyer''s phone');
select hasnt_column('public', 'orders', 'customer_email',   'orders no longer holds the buyer''s email');
select hasnt_column('public', 'orders', 'delivery_address', 'orders no longer holds the delivery address');
select ok((select relrowsecurity from pg_class where oid = 'public.order_contacts'::regclass),
  'order_contacts has RLS enabled');
select ok(not has_column_privilege('authenticated', 'public.payments', 'gateway_response_payload', 'select'),
  'the app cannot read Paystack''s raw payload');
select ok(has_column_privilege('authenticated', 'public.payments', 'payment_status', 'select'),
  'the app can still read payment status');

-- ── place_web_order writes the contact row ──────────────────────────────
select pg_temp.as_service();
select lives_ok(
  $$select public.place_web_order('dddddddd-0000-0000-0000-000000000001', 'GRACE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031234567","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
      null, 'POS_AGENT', 2250.00, null)$$,
  'a pay-at-agent order is placed');
select lives_ok(
  $$select public.place_web_order('dddddddd-0000-0000-0000-000000000002', 'EPE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street, Epe"}',
      null, 'PAYSTACK_WEB', 2500.00,
      '{"reference":"TFW-e1","access_code":"ac_e1","authorization_url":"https://checkout.paystack.com/ac_e1"}')$$,
  'a Paystack order in Epe is placed');
select lives_ok(
  $$select public.place_web_order('dddddddd-0000-0000-0000-000000000003', 'ZSM-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Chi","phone":"+2348031234569","delivery_address":"9 Awolowo Way"}',
      null, 'PAYSTACK_WEB', 2500.00,
      '{"reference":"TFW-z1","access_code":"ac_z1","authorization_url":"https://checkout.paystack.com/ac_z1"}')$$,
  'an order on a ZSM''s code is placed');
select lives_ok(
  $$select public.place_web_order('dddddddd-0000-0000-0000-000000000004', 'GRACE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Dayo","phone":"+2348031234570","delivery_address":"3 Allen Avenue"}',
      null, 'PAYSTACK_WEB', 2250.00,
      '{"reference":"TFW-g2","access_code":"ac_g2","authorization_url":"https://checkout.paystack.com/ac_g2"}')$$,
  'a Paystack order on the agent''s code is placed');
reset role;

-- the references, for the lookups in Task 2 and the role checks below
create temp table refs on commit drop as
  select l.key, l.response ->> 'public_reference' as public_reference, (l.response ->> 'order_id')::uuid as order_id
    from public.idempotency_logs l
   where l.key in ('dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000002',
                   'dddddddd-0000-0000-0000-000000000003', 'dddddddd-0000-0000-0000-000000000004');
grant select on refs to authenticated;

select is(
  (select c.customer_name || '|' || c.customer_phone || '|' || c.customer_email || '|' || c.delivery_address
          || '|' || c.territory_id
     from public.order_contacts c join refs r on r.order_id = c.order_id
    where r.key = 'dddddddd-0000-0000-0000-000000000001'),
  'Ada Obi|+2348031234567|ada@example.com|5 Opebi Road, Ikeja|40000000-0000-0000-0000-000000000001',
  'the contact row holds the details and the terminal''s territory');
select is(
  (select c.territory_id from public.order_contacts c join refs r on r.order_id = c.order_id
    where r.key = 'dddddddd-0000-0000-0000-000000000003'),
  null::uuid, 'a ZSM''s code gives no territory');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'place_web_order'
      and (after::text like '%+234803123456%' or after::text like '%@example.com%'
           or after::text like '%Opebi%' or after::text like '%Toyin%')),
  0, 'audit rows carry no phone, email or address');
select is(
  (select a.after -> 'contact' from public.audit_logs a join refs r on r.order_id::text = a.entity_id
    where a.operation = 'place_web_order' and r.key = 'dddddddd-0000-0000-0000-000000000001'),
  '{"phone_last4":"4567","has_email":true,"has_address":true}'::jsonb,
  'the audit row carries a redacted contact summary');

-- ── who can read contact rows ───────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 4, 'the ZSM sees every contact row in the tenant');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 2, 'the Ikeja TM sees only Ikeja''s rows');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 1, 'the Epe TM sees only Epe''s row');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 0, 'a POS agent sees no contact rows');
select is((select count(*)::int from public.orders), 4, 'a POS agent still sees the orders themselves');
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 0, 'a DSA sees no contact rows');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 0, 'a shop owner sees no contact rows');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.order_contacts), 0, 'another tenant''s ZSM sees no contact rows');
reset role;

-- ── the throttle reads order_contacts ───────────────────────────────────
with o as (
  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount)
  select '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000002', 100
    from generate_series(1, 5)
  returning id, tenant_id)
insert into public.order_contacts (order_id, tenant_id, customer_phone)
select id, tenant_id, '+2348099999999' from o;
select pg_temp.as_service();
select throws_ok(
  $$select public.place_web_order('dddddddd-0000-0000-0000-000000000009', 'GRACE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Spam","phone":"+2348099999999","delivery_address":"1 Nowhere"}',
      null, 'POS_AGENT', 2250.00, null)$$,
  'P0001', 'Too many unpaid orders for this phone number. Try again later.',
  'a sixth pending web order within the hour is still refused');
reset role;

select * from finish();
rollback;
```

24 assertions: 7 schema, 4 placements, 4 contact/audit, 8 role reads, 1 throttle.

- [ ] **Step 2: Run it to verify it fails**

Run: `supabase test db`
Expected: FAIL in `013_commerce_buyer_privacy.test.sql` (`relation "public.order_contacts" does not exist` or the `hasnt_column` assertions failing).

- [ ] **Step 3: Write the schema migration**

Create `supabase/migrations/20261015130000_commerce_order_contacts.sql`:

```sql
-- Addendum A2 §3 — buyer contact details leave orders for order_contacts,
-- which only the tenant's ZSM and the order's TM can read. Paystack's raw
-- payload on payments is withheld from the app by column grant.

-- ── order_contacts ──────────────────────────────────────────────────────
create table public.order_contacts (
  order_id          uuid primary key,
  tenant_id         uuid not null references public.tenants (id) on delete restrict,
  -- the territory accountable for the order, stamped at checkout (A2 §2.5);
  -- null means only ZSMs can read the row
  territory_id      uuid,
  customer_name     text check (customer_name is null or length(btrim(customer_name)) > 0),
  customer_phone    text check (customer_phone ~ '^\+[1-9][0-9]{7,14}$'),
  customer_email    text check (customer_email = lower(customer_email)),
  delivery_address  text check (delivery_address is null or length(btrim(delivery_address)) > 0),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, order_id),
  foreign key (tenant_id, order_id)     references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.order_contacts enable row level security;
create index idx_order_contacts_territory on public.order_contacts (tenant_id, territory_id);
-- the place_web_order throttle: orders per phone, last hour
create index idx_order_contacts_phone on public.order_contacts (customer_phone, created_at);
create trigger order_contacts_set_updated_at before update on public.order_contacts
  for each row execute function public.set_updated_at();

-- Territories the caller manages as an ACTIVE TM.
create or replace function public.my_tm_territory_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select tu.territory_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role = 'TM';
$$;
grant execute on function public.my_tm_territory_ids() to authenticated;

create policy order_contacts_select_zsm_or_tm on public.order_contacts
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
         or territory_id in (select public.my_tm_territory_ids()));

-- ── move the data, then drop the columns ────────────────────────────────
insert into public.order_contacts (order_id, tenant_id, customer_name, customer_phone, customer_email,
                                   delivery_address, created_at)
select o.id, o.tenant_id, nullif(btrim(o.customer_name), ''), o.customer_phone, o.customer_email,
       o.delivery_address, o.created_at
  from public.orders o
 where num_nonnulls(o.customer_name, o.customer_phone, o.customer_email, o.delivery_address) > 0;

alter table public.orders drop constraint orders_web_attribution_complete;
drop index public.idx_orders_web_pending_phone;
alter table public.orders
  drop column customer_name,
  drop column customer_phone,
  drop column customer_email,
  drop column delivery_address,
  add constraint orders_web_attribution_complete
    check (channel <> 'ONLINE' or agent_code_id is null
           or num_nulls(payment_route, attributed_agent_id, public_reference) = 0);

-- ── payments: Paystack's verified transaction holds the buyer's email,
-- phone and card details. Every column but that one stays readable. A new
-- payments column must be added to this grant to become readable.
revoke select on public.payments from authenticated;
grant select (id, tenant_id, order_id, customer_id, teafair_agent_id, fintech_partner_id,
              fintech_terminal_id, amount, gateway_provider, payment_status, paystack_reference,
              otp_challenge_id, created_at, updated_at)
  on public.payments to authenticated;
```

- [ ] **Step 4: Write the `place_web_order` migration**

Create `supabase/migrations/20261015130100_commerce_place_web_order_contacts.sql`. It is the A1 function with four changes, marked `-- A2`: a `v_territory` variable, the throttle reading `order_contacts`, the contact insert, and the redacted audit.

```sql
-- Addendum A2 §4.1 — place_web_order writes contact details to
-- order_contacts, stamps the accountable territory, and audits a redacted
-- summary instead of the details. Signature, grants and idempotency are
-- unchanged from A1 §4.2.
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
  v_territory   uuid;  -- A2
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

  -- A2: the phone now lives on order_contacts
  if (select count(*) from public.order_contacts c
        join public.orders o on o.id = c.order_id
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour'
         and o.channel = 'ONLINE' and o.status = 'PENDING') >= 5 then
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
  v_territory := coalesce(v_terminal.territory_id, v_agent.territory_id);  -- A2
  if v_agent.role in ('DSA', 'DSM', 'ASM', 'TM', 'ZSM') then
    v_accountable := v_agent.profile_id;
  else
    select t.tm_id into v_accountable from public.territories t
     where t.tenant_id = v_code.tenant_id and t.id = v_territory;
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

  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, status,
                             agent_code_id, attributed_agent_id, attributed_terminal_id,
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference)
  values (v_code.tenant_id, 'ONLINE', v_accountable, v_total, (v_cart ->> 'discount')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.terminal_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref)
  returning * into v_order;

  -- A2
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address)
  values (v_order.id, v_order.tenant_id, v_territory, v_name, v_phone, v_email, v_address);

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

  -- A2: the audit log is readable by every ZSM and TM, so it gets a summary
  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null,
                             to_jsonb(v_order) || jsonb_build_object('contact', jsonb_build_object(
                               'phone_last4', right(v_phone, 4),
                               'has_email', v_email is not null,
                               'has_address', v_address is not null)),
                             p_idempotency_key, 'WEB', v_accountable);

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

- [ ] **Step 5: Check the data move once on the local stack**

With the stack running and the Task 1 migrations **not yet applied** (`supabase migration list --local` shows them pending; if they are already applied, run `supabase db reset`, then temporarily move the two new migration files out of `supabase/migrations/`, reset again, and move them back):

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "
insert into public.tenants (id, name, code) values ('a0000000-0000-0000-0000-000000000001', 'Move test', 'MOVETEST');
insert into auth.users (id, phone) values ('a0000000-0000-0000-0000-000000000002', '2348000000777');
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, customer_name, customer_phone)
values ('a0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'FIELD_DSA',
        'a0000000-0000-0000-0000-000000000002', 100, ' Field Buyer ', '+2348000000777');"
supabase migration up
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -At -c "
select customer_name || '|' || customer_phone from public.order_contacts
 where order_id = 'a0000000-0000-0000-0000-000000000003';"
```

Expected: `Field Buyer|+2348000000777`. Then `supabase db reset` to clear the test rows.

- [ ] **Step 6: Update the existing tests**

`supabase/tests/database/001_schema_shape.test.sql`:
- Comment above `tables_are`: `-- the 33 Spec A tables (§6.1) + agent_codes (addendum A1) + order_contacts (addendum A2)`.
- In the commerce group, change the comment to `-- commerce (6) + web storefront (1, addendum A1) + buyer contacts (1, addendum A2)` and add `'order_contacts'` after `'agent_codes'`.
- `'public holds exactly the 34 tables'` → `'public holds exactly the 35 tables'`.
- The RLS count `34, 'RLS is enabled on all 34 tables'` → `35, 'RLS is enabled on all 35 tables'`.

`supabase/tests/database/010_commerce_web_schema.test.sql`, the three `orders` inserts under `-- ── orders: web attribution`: remove `delivery_address` from each column list and `'5 Opebi Road', ` from each values list. The assertions' expected outcomes do not change.

`supabase/tests/database/012_commerce_web_public.test.sql`:
- The CAP-01 fixture insert: remove `delivery_address` from the column list and `'5 Opebi Road', ` from the values.
- Replace the throttle fixture

  ```sql
  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, customer_phone)
  select '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000002', 100, '+2348099999999'
    from generate_series(1, 5);
  ```

  with

  ```sql
  with o as (
    insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount)
    select '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000002', 100
      from generate_series(1, 5)
    returning id, tenant_id)
  insert into public.order_contacts (order_id, tenant_id, customer_phone)
  select id, tenant_id, '+2348099999999' from o;
  ```

- [ ] **Step 7: Run the suite**

Run: `supabase db reset` then `supabase test db`
Expected: `Result: PASS`, 416 assertions (392 + 24).

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20261015130000_commerce_order_contacts.sql \
        supabase/migrations/20261015130100_commerce_place_web_order_contacts.sql \
        supabase/tests/database/001_schema_shape.test.sql \
        supabase/tests/database/010_commerce_web_schema.test.sql \
        supabase/tests/database/012_commerce_web_public.test.sql \
        supabase/tests/database/013_commerce_buyer_privacy.test.sql
git commit -m "feat(db): buyer contact details move to order_contacts, ZSM/TM only (A2 §3, §4.1)"
```

---

### Task 2: `pos_order_lookup`

**Files:**
- Create: `supabase/migrations/20261015130200_commerce_pos_order_lookup.sql`
- Modify: `supabase/tests/database/013_commerce_buyer_privacy.test.sql` (append lookups; plan 24 → 34)

**Interfaces:**
- Consumes: `public.order_contacts` (Task 1), the `refs` temp table and `pg_temp.act_as` in test 013 (Task 1), `public.assert_tenant_role(tenant_role_enum[])`.
- Produces: `public.pos_order_lookup(p_public_reference text) returns jsonb` with keys `public_reference, first_name, phone_last4, total, currency, status`, executable by `authenticated`.

- [ ] **Step 1: Append the failing tests**

In `013_commerce_buyer_privacy.test.sql`, change `select plan(24);` to `select plan(35);`, and insert before `select * from finish();`:

```sql
-- ── pos_order_lookup: a masked till view for the order's agent ──────────
select ok(has_function_privilege('authenticated', 'public.pos_order_lookup(text)', 'execute'),
  'the app can call pos_order_lookup');
select ok(not has_function_privilege('anon', 'public.pos_order_lookup(text)', 'execute'),
  'anon cannot');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is(
  public.pos_order_lookup((select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001'))
    - 'public_reference',
  '{"first_name":"Ada","phone_last4":"4567","total":2250.00,"currency":"NGN","status":"PENDING"}'::jsonb,
  'the agent sees first name, phone last 4, total and status');
select is(
  public.pos_order_lookup((select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001'))
    ->> 'public_reference',
  (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001'),
  'and the reference');
select is(
  public.pos_order_lookup((select ' ' || lower(public_reference) || ' ' from refs
                            where key = 'dddddddd-0000-0000-0000-000000000001')) ->> 'first_name',
  'Ada', 'a lower-case, padded reference is accepted');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000004')),
  'P0001', 'Order not found', 'a Paystack-route order is not shown');
select throws_ok($$select public.pos_order_lookup('TF-000000')$$,
  'P0001', 'Order not found', 'an unknown reference is not shown');

select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  'P0001', 'Order not found', 'another agent cannot look the order up');

select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  'P0001', 'Order not found', 'another tenant cannot look the order up');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  'P0001', 'Order not found', 'the till lookup is only for the order''s agent, not the ZSM');

select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  '42501', null, 'a disabled member is refused');
reset role;
```

11 assertions: 24 + 11 = 35.

- [ ] **Step 2: Run it to verify it fails**

Run: `supabase test db`
Expected: FAIL in 013 — `function public.pos_order_lookup(text) does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20261015130200_commerce_pos_order_lookup.sql`:

```sql
-- Addendum A2 §4.2 — the till view of a pay-at-agent order. Only the order's
-- attributed agent may look it up, and they see the buyer's first name and
-- the last four digits of the phone, never the full contact details. A read:
-- no idempotency key and no audit row (as verify_pin). Every miss gives the
-- same message, so the lookup cannot probe which references exist.
create or replace function public.pos_order_lookup(p_public_reference text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_me  public.tenant_users := public.assert_tenant_role(null);
  v_out jsonb;
begin
  select jsonb_build_object(
           'public_reference', o.public_reference,
           'first_name',       split_part(c.customer_name, ' ', 1),
           'phone_last4',      right(c.customer_phone, 4),
           'total',            o.total_amount,
           'currency',         coalesce(s.currency, 'NGN'),
           'status',           o.status)
    into v_out
    from public.orders o
    left join public.order_contacts c on c.order_id = o.id
    left join public.tenant_settings s on s.tenant_id = o.tenant_id
   where o.tenant_id = v_me.tenant_id
     and o.public_reference = upper(btrim(coalesce(p_public_reference, '')))
     and o.payment_route = 'POS_AGENT'
     and o.attributed_agent_id = v_me.profile_id;

  if v_out is null then
    raise exception 'Order not found' using errcode = 'P0001';
  end if;
  return v_out;
end;
$$;

revoke execute on function public.pos_order_lookup(text) from public, anon;
grant execute on function public.pos_order_lookup(text) to authenticated;
```

`assert_tenant_role(null)` checks only for an ACTIVE membership of the JWT tenant (`p_roles is not null and …` skips the role test).

- [ ] **Step 4: Run the suite**

Run: `supabase migration up` then `supabase test db`
Expected: `Result: PASS`, 427 assertions (392 + 35).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20261015130200_commerce_pos_order_lookup.sql \
        supabase/tests/database/013_commerce_buyer_privacy.test.sql
git commit -m "feat(db): pos_order_lookup, a masked till view for the order's agent (A2 §4.2)"
```

---

### Task 3: Documentation and full verification

**Files:**
- Modify: `supabase/functions/_shared/commerce/phone.ts` (line 2 comment)
- Modify: `supabase/CLAUDE.md`
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md` (header "Amended by" line)
- Modify: `docs/superpowers/specs/2026-10-15-web-storefront-agent-attribution-design.md` (header)
- Modify: `docs/superpowers/specs/2026-10-15-buyer-contact-privacy-design.md` (status)

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the comment in `phone.ts`**

Line 2: `// The result must satisfy orders.customer_phone's E.164 check.` → `// The result must satisfy order_contacts.customer_phone's E.164 check.`

- [ ] **Step 2: Update `supabase/CLAUDE.md`**

- Status table: add the row `| A2. Buyer contact privacy — order_contacts, till lookup | done |` after the A1 row.
- Replace `The six addendum A1 migrations and the \`storefront-catalogue\` / \`web-checkout\` functions are local only until explicitly pushed.` with `The addendum A1 and A2 migrations (nine) and the \`storefront-catalogue\` / \`web-checkout\` functions are local only until explicitly pushed. **A1 never deploys without A2**: A1 alone exposes buyer contact details to every tenant member.`
- Under "Writing a migration", add a bullet: `- Buyer contact details live only in \`order_contacts\` (addendum A2), readable by the ZSM and the order's TM. Never add personal data to \`orders\` or to an audit payload; audit a redacted summary.`
- Under "Writing a migration", add a bullet: `- \`payments\` and \`tenant_users\` are readable column by column. A new column on either is invisible to the app until it is added to the grant, and the app must name columns rather than \`select *\`.`

- [ ] **Step 3: Update root `CLAUDE.md`**

- Repository-state row for `supabase/`: `**Phases 1–3 done**: 29 migrations, 427 pgTAP assertions, 6 Edge Functions; addenda A1 (web storefront) and A2 (buyer contact privacy) done locally. See \`supabase/CLAUDE.md\``.
- Add a table row: `| \`docs/superpowers/specs/2026-10-15-buyer-contact…\` | Addendum A2 — buyer contact privacy |`.
- In "Rules that hold everywhere", after the `bvn_nin_hash` bullet, add: `- Buyer contact details live only in \`order_contacts\` (ZSM and the order's TM).`

- [ ] **Step 4: Update the spec headers**

- Spec A header: extend the "Amended by" line to also name `A2 (\`2026-10-15-buyer-contact-privacy-design.md\`)`.
- A1 header: add `**Amended by:** A2 (\`2026-10-15-buyer-contact-privacy-design.md\`) — contact columns moved off \`orders\`.`
- A2 header: `**Status:** approved 2026-10-15 — implementation plan: \`docs/superpowers/plans/2026-10-15-buyer-contact-privacy.md\``.

- [ ] **Step 5: Full verification**

```bash
supabase db reset
supabase test db                                   # Result: PASS, 427
deno test --allow-env supabase/functions/          # 114 passed
supabase status -o env > supabase/.env.test.local
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts
```

The integration test needs `supabase functions serve --env-file supabase/functions/.env` running and `TURNSTILE_VERIFY_URL` active in `supabase/functions/.env`. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/commerce/phone.ts supabase/CLAUDE.md CLAUDE.md docs/superpowers/specs/
git commit -m "docs: addendum A2 done — buyer contact privacy"
```
