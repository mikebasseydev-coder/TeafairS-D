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
