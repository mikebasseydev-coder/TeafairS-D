-- Spec D1 — locations and routing. Task 1: Nigerian states and LGAs (§3.1).
begin;
create extension if not exists pgtap with schema extensions;

select plan(62);

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

-- ── Task 3: routing and the management RPCs (§4, §5.1) ──────────────────
-- 3 TM Ikeja · 4 DSA Ikeja · 5 POS agent Ikeja · 6 POS agent Epe (no TM) · 7 default agent
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000007', '2348000000007');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id = '30000000-0000-0000-0000-000000000001';
update public.tenant_settings set web_default_agent_id = '20000000-0000-0000-0000-000000000007'
 where tenant_id = '10000000-0000-0000-0000-000000000001';

insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000005', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
-- the Epe terminal has no territory of its own
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'MP-0005', '40000000-0000-0000-0000-000000000001'),
  ('61000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006', 'MP-0006', null);
insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'DSACODE1', '20000000-0000-0000-0000-000000000004', null, '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'POSIKEJA', '20000000-0000-0000-0000-000000000005', '61000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'POSEPE01', '20000000-0000-0000-0000-000000000006', '61000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- codeless tenant
select is(public.web_codeless_tenant(), (select id from public.tenants where code = 'TEAFAIR'), 'codeless traffic belongs to TEAFAIR');
update public.tenants set status = 'SUSPENDED' where code = 'TEAFAIR';
select throws_ok($$select public.web_codeless_tenant()$$, 'P0001', 'This shop is not open yet', 'no active TEAFAIR tenant');
update public.tenants set status = 'ACTIVE' where code = 'TEAFAIR';

-- codeless routing
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).territory_id,
          '40000000-0000-0000-0000-000000000001'::uuid, 'LGA hit');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Epe')::uuid)).territory_id,
          '40000000-0000-0000-0000-000000000002'::uuid, 'state fallback');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Epe')::uuid)).warehouse_id,
          '70000000-0000-0000-0000-000000000003'::uuid, 'CENTRAL fallback when the territory has no regional warehouse');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).warehouse_id,
          '70000000-0000-0000-0000-000000000001'::uuid, 'the territory''s regional warehouse wins');
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:KN:Fagge')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'uncovered state refused');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:KN:Fagge')::uuid)).territory_id,
          null, 'try never raises, it returns nulls');
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, gen_random_uuid())$$,
  'P0001', 'choose a delivery area from the list', 'unknown LGA is a clean refusal');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000003'::uuid, 'codeless -> territory TM');

-- coded
select is((public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'DSACODE1'), md5('ng_lga:KN:Fagge')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000004'::uuid, 'staff holder accountable for own sale, LGA ignored for territory');
select is((public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'DSACODE1'), md5('ng_lga:KN:Fagge')::uuid)).territory_id,
          '40000000-0000-0000-0000-000000000001'::uuid, 'coded territory comes from the holder');
select is((public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'POSIKEJA'), md5('ng_lga:LA:Epe')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000003'::uuid, 'FINTECH_AGENT code -> TM of terminal territory');
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'POSEPE01'), md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'This link is not active yet', 'coded, no TM (holder territory Epe)');

-- territory resolved but no warehouse at all
update public.tenant_settings set web_default_warehouse_id = null
 where tenant_id = '10000000-0000-0000-0000-000000000001';
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Epe')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'no warehouse refused');
update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000003'
 where tenant_id = '10000000-0000-0000-0000-000000000001';

-- accountable fallbacks (Ikeja)
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000003';
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000001'::uuid, 'inactive TM skipped -> ZSM');
update public.zones set zsm_id = null where id = '30000000-0000-0000-0000-000000000001';
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000007'::uuid, 'no ZSM -> web_default_agent_id');
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000007';
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'no accountable person refused');
update public.tenant_users set status = 'ACTIVE' where id in ('50000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000007');

-- management RPCs
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000001', 'LA',
  md5('ng_lga:LA:Eti-Osa')::uuid, '40000000-0000-0000-0000-000000000002')$$, 'ZSM sets coverage');
select is((select territory_id from public.territory_coverage where lga_id = md5('ng_lga:LA:Eti-Osa')::uuid),
          '40000000-0000-0000-0000-000000000002'::uuid, 'the coverage row is stored');
select is((public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000002', 'LA',
  md5('ng_lga:LA:Eti-Osa')::uuid, null) ->> 'coverage_id'), null, 'null territory deletes the row');
select is((select count(*)::int from public.territory_coverage where lga_id = md5('ng_lga:LA:Eti-Osa')::uuid),
          0, 'and the row is gone');
select throws_ok($$select public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000003', 'LA',
  md5('ng_lga:OG:Abeokuta North')::uuid, '40000000-0000-0000-0000-000000000002')$$, 'P0001', null, 'LGA must belong to the state');
select lives_ok($$select public.set_territory_web_warehouse('bbbbbbbb-0000-0000-0000-000000000004',
  '40000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002')$$, 'ZSM sets a territory warehouse');
select is((select web_fulfilment_warehouse_id from public.territories where id = '40000000-0000-0000-0000-000000000002'),
          '70000000-0000-0000-0000-000000000002'::uuid, 'pointer stored');
select is((public.set_web_defaults('bbbbbbbb-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000003',
  '20000000-0000-0000-0000-000000000007') ->> 'agent_id'), '20000000-0000-0000-0000-000000000007', 'ZSM sets defaults');
select is((select count(*)::int from public.audit_logs where operation = 'set_web_defaults'
  and idempotency_key = 'bbbbbbbb-0000-0000-0000-000000000005'), 1, 'one audit row');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000006', 'LA', null,
  '40000000-0000-0000-0000-000000000002')$$, '42501', null, 'TM cannot set coverage');
select throws_ok($$select public.set_web_defaults('bbbbbbbb-0000-0000-0000-000000000007', null, null)$$,
  '42501', null, 'TM cannot set defaults');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_territory_web_warehouse('bbbbbbbb-0000-0000-0000-000000000008',
  '40000000-0000-0000-0000-000000000002', null)$$, '42501', null, 'DSA cannot set warehouse');
reset role;

select ok(not has_function_privilege('authenticated', 'public.web_route_order(uuid,public.agent_codes,uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.web_route_order(uuid,public.agent_codes,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_route_try(uuid,public.agent_codes,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_codeless_tenant()', 'execute'), 'routing is internal');
select ok(has_function_privilege('authenticated', 'public.set_territory_coverage(uuid,text,uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.set_territory_web_warehouse(uuid,uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.set_web_defaults(uuid,uuid,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.set_web_defaults(uuid,uuid,uuid)', 'execute'), 'management RPCs are for the app');

select * from finish();
rollback;
