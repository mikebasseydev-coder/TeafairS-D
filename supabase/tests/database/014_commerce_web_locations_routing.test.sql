-- Spec D1 — locations and routing. Task 1: Nigerian states and LGAs (§3.1).
begin;
create extension if not exists pgtap with schema extensions;

select plan(30);

-- ── Task 1: ng_states / ng_lgas (§3.1) ──────────────────────────────────
select is((select count(*)::int from public.ng_states), 37, 'exactly 37 states (FCT included)');
select is((select count(*)::int from public.ng_lgas), 774, 'exactly 774 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'LA'), 20, 'Lagos has 20 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'FC'), 6, 'FCT has 6 area councils');
select is((select id from public.ng_lgas where state_code = 'LA' and name = 'Ikeja'),
          md5('ng_lga:LA:Ikeja')::uuid, 'LGA ids are deterministic');
select ok(has_table_privilege('authenticated', 'public.ng_lgas', 'select'), 'authenticated reads LGAs');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'insert'), 'no write grant on LGAs');
select throws_ok($$insert into public.ng_states values ('lagos', 'X')$$, '23514', null, 'state code is two capitals');

select ok(not has_table_privilege('authenticated', 'public.ng_states', 'insert')
       and not has_table_privilege('authenticated', 'public.ng_states', 'update')
       and not has_table_privilege('authenticated', 'public.ng_states', 'delete'), 'no write grant on states');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'update')
       and not has_table_privilege('authenticated', 'public.ng_lgas', 'delete'), 'no update/delete grant on LGAs');
select is((select count(*)::int from public.ng_lgas where (state_code, name) in (
  ('LA','Ikeja'), ('LA','Eti-Osa'), ('OY','Oyo West'), ('NI','Munya'),
  ('NA','Nasarawa Eggon'), ('FC','Abuja Municipal'), ('AD','Girei'))), 7,
  'spot-checked LGA names exist under their state');

-- ── Task 2: coverage, routing columns, constraints (§3.2–3.4) ───────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1CODE'),
  ('10000000-0000-0000-0000-000000000002', 'T2', 'T2CODE');
insert into public.tenant_settings (tenant_id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Epe');
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'REG-EPE', 'REGIONAL', '40000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'CENTRAL-1', 'CENTRAL', null),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'T2-CENTRAL', 'CENTRAL', null);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', '30000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSM', '30000000-0000-0000-0000-000000000001', 'DISABLED', false);

-- coverage
select lives_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001')$$, 'LGA row');
select lives_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'LA', null, '40000000-0000-0000-0000-000000000002')$$, 'state fallback row');
select throws_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'LA', null, '40000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'a second state fallback is rejected (NULLS NOT DISTINCT)');
select throws_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'OG', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001')$$,
  'P0001', null, 'LGA must belong to the state');
select ok(has_table_privilege('authenticated', 'public.territory_coverage', 'select')
      and not has_table_privilege('authenticated', 'public.territory_coverage', 'insert'), 'coverage is select-only');

-- warehouse pointers
select throws_ok($$update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000003'
  where id = '40000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'territory pointer must be REGIONAL');
select throws_ok($$update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000002'
  where id = '40000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'regional warehouse must belong to this territory');
select lives_ok($$update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000001'
  where id = '40000000-0000-0000-0000-000000000001'$$, 'own regional warehouse');
select throws_ok($$update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000001'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'default must be CENTRAL');
select throws_ok($$update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000009'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, '23503', null, 'default must be same tenant');
select lives_ok($$update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000003'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'central default accepted');
select throws_ok($$update public.tenant_settings set web_default_agent_id = '20000000-0000-0000-0000-000000000002'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'default agent must be ACTIVE');
select lives_ok($$update public.tenant_settings set web_default_agent_id = '20000000-0000-0000-0000-000000000001'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'active default agent accepted');

-- orders / payments constraints
select throws_ok($$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status)
  values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, 'PENDING')$$,
  '23514', null, 'orders_online_routed');
select lives_ok($$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status)
  values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, 'CANCELLED')$$,
  'cancelled orders need no routing');
select throws_ok($$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
    delivery_lga_id, territory_id, fulfilment_warehouse_id)
  values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, 'PENDING', 'POS_AGENT',
    md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'orders_codeless_pays_online');

insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
    delivery_lga_id, territory_id, fulfilment_warehouse_id)
  values ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'ONLINE',
    '20000000-0000-0000-0000-000000000001', 100, 'PENDING', 'PAYSTACK_WEB',
    md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001');
select throws_ok($$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference, split_bps)
  values ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001', 100, 'REF1', 150)$$,
  '23514', null, 'split snapshot all-or-none');
select throws_ok($$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference,
    split_subaccount_code, split_bps, split_amount)
  values ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001', 100, 'REF2', 'ACCT_x1', 150, 100)$$,
  '23514', null, 'split below amount');
select ok(has_column_privilege('authenticated', 'public.payments', 'split_amount', 'select'), 'split columns readable');

select * from finish();
rollback;
