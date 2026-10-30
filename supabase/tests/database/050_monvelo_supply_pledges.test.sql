-- Addendum A6 §4.3, §7.1, §16.6 (Step 2, Task 5) — platform settings, supply
-- days, pledges, the totals-only supply-day read and the staff proximity search.
begin;
create extension if not exists pgtap with schema extensions;

select plan(56);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');

-- 01 ZSM · 02 ZSA · 03 TM (T1) · 08 TM (T2) · 09 operator · 10 TENANT_ADMIN
-- 11 member of ACTIVE agent · 12 member of PENDING agent · 13 stranger · 14 member of far agent
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0'), now()
from unnest(array[1,2,3,8,9,10,11,12,13,14,15,16]) as n;
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000009';

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into public.tenant_users (id, tenant_id, profile_id, role, status, is_primary) values
  ('50000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000016', 'ZSM', 'ACTIVE', true);

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikorodu');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008', 'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010', 'TENANT_ADMIN', null, null, null, 'ACTIVE', true);

insert into public.monvelo_tenant_settings (tenant_id, enabled) values ('10000000-0000-0000-0000-000000000001', true);

-- shops S1 (enrolled) and S2 at (3.35, 6.60)
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('70000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000015', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1'),
  ('70000000-0000-0000-0000-000000000002', 'Shop 2', '+234803111002', '20000000-0000-0000-0000-000000000015', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 2');
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by) values
  ('c0000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', 'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000002');
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id) values
  ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', now(), 'MV-SHARE-2026-10', 'c0000000-0000-0000-0000-000000000001');

-- agents: 1 ACTIVE ~400 m north; 2 PENDING near; 3 ACTIVE ~5 km north
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status) values
  ('80000000-0000-0000-0000-000000000001', 'Near POS', 'OPAY', 'OP-1', '+2348031110001',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
   '0123456789', '6789', '058', 'Near POS', 'K1', '20000000-0000-0000-0000-000000000002', 'ACTIVE'),
  ('80000000-0000-0000-0000-000000000002', 'Pending POS', 'OPAY', 'OP-2', '+2348031110002',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
   '0123456780', '6780', '058', 'Pending POS', 'K2', '20000000-0000-0000-0000-000000000002', 'PENDING'),
  ('80000000-0000-0000-0000-000000000003', 'Far POS', 'MONIEPOINT', 'MP-3', '+2348031110003',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.645), 4326)::extensions.geography, 'a',
   '0123456781', '6781', '058', 'Far POS', 'K3', '20000000-0000-0000-0000-000000000002', 'ACTIVE'),
  ('80000000-0000-0000-0000-000000000004', 'Suspended POS', 'OPAY', 'OP-4', '+2348031110004',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
   '0123456782', '6782', '058', 'Suspended POS', 'K4', '20000000-0000-0000-0000-000000000002', 'SUSPENDED');
insert into public.monvelo_agent_members (agent_id, profile_id) values
  ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011'),
  ('80000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000012'),
  ('80000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000014'),
  ('80000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000015');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- dates: the next Thursday (today counts), the next Wednesday, today
select set_config('test.today', public.monvelo_today()::text, true);
select set_config('test.thu', (public.monvelo_today() + ((4 - extract(isodow from public.monvelo_today())::int + 7) % 7))::text, true);
select set_config('test.wed', (public.monvelo_today() + ((3 - extract(isodow from public.monvelo_today())::int + 7) % 7))::text, true);

-- ── shape and defaults ──────────────────────────────────────────────────
select has_table('public', 'monvelo_platform_settings', 'settings table exists');
select has_table('public', 'monvelo_supply_days', 'supply days table exists');
select has_table('public', 'monvelo_pledges', 'pledges table exists');
select has_index('public', 'monvelo_agents', 'idx_monvelo_agents_location', 'agent location is indexed');
select is((select row(offer_radius_m, preferred_window_minutes, claim_minutes)::text from public.monvelo_platform_settings),
  '(1000,10,15)', 'defaults are 1000 m, 10 min, 15 min');
select is((select count(*)::int from public.monvelo_platform_settings), 1, 'one settings row');
select hasnt_column('public', 'monvelo_platform_settings', 'min_cash_orders', 'there is no cash-order threshold');
select ok(not has_table_privilege('authenticated', 'public.monvelo_platform_settings', 'UPDATE'), 'settings are not API-writable');
select ok(not has_table_privilege('authenticated', 'public.monvelo_pledges', 'INSERT'), 'pledges are not API-writable');
select ok(not has_function_privilege('authenticated', 'public.monvelo_settings()', 'EXECUTE'), 'the settings getter is internal');
select ok(has_function_privilege('authenticated', 'public.monvelo_today()', 'EXECUTE'), 'monvelo_today is callable');
select is(public.monvelo_today(), (now() at time zone 'Africa/Lagos')::date, 'monvelo_today is the Lagos date');
select throws_ok($$truncate public.monvelo_pledges$$, 'P0001', null, 'pledges are never truncated');
select throws_ok($$truncate public.monvelo_supply_days$$, 'P0001', null, 'supply days are never truncated');

-- ── set_monvelo_supply_day ──────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', 4, true), jsonb_build_object(
  'area_id', '60000000-0000-0000-0000-000000000001', 'day_of_week', 4, 'active', true), 'the TM sets Thursday');
select is(public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', 4, true) ->> 'day_of_week', '4', 'a replay returns the same answer');
select throws_ok($$select public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000001', 9, true)$$, 'P0001', null, 'a bad weekday is refused');
select public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000021', '60000000-0000-0000-0000-000000000001', 5, true);
select public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000022', '60000000-0000-0000-0000-000000000001', 5, false);
select is((select active from public.monvelo_supply_days where day_of_week = 5), false, 'active = false deactivates the day');
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000003',
  '60000000-0000-0000-0000-000000000001', 5, true)$$, '42501', null, 'another territory''s TM is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000004',
  '60000000-0000-0000-0000-000000000001', 5, true)$$, '42501', null, 'a ZSA is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_monvelo_supply_day('e5000000-0000-0000-0000-000000000005',
  '60000000-0000-0000-0000-000000000001', 5, true)$$, '42501', null, 'a TENANT_ADMIN is refused');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'set_monvelo_supply_day'), 3, 'one audit row per effect (a replay writes none)');
select throws_ok($$delete from public.monvelo_supply_days$$, 'P0001', null, 'supply days are never deleted');

-- ── pledge_monvelo_funds ────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select is(public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000011', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', current_setting('test.thu')::date, 150000) ->> 'remaining', '150000.00',
  'the first pledge: remaining = amount');
select is(public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000012', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', current_setting('test.thu')::date, 200000) ->> 'remaining', '200000.00',
  're-pledging 200000 raises remaining to 200000');
select is((select count(*)::int from public.monvelo_pledges), 1, 'the member reads their own pledge');
select is(public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000011', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', current_setting('test.thu')::date, 150000) ->> 'remaining', '150000.00',
  'a replay returns the first result');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000013', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', %L, 100000)$$, current_setting('test.wed')), 'P0001', 'that date is not a supply day for this area',
  'a Wednesday is not a supply day');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000014', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', %L, 100000)$$, (current_setting('test.today')::date - 1)::text), 'P0001', null,
  'yesterday is refused');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000015', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', %L, 0)$$, current_setting('test.thu')), 'P0001', null, 'a zero amount is refused');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000016', '80000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000001', %L, 1000)$$, current_setting('test.thu')), '42501', null, 'a member of another agent is refused');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'pledge_monvelo_funds'), 2, 'each pledge effect writes one audit row');
select throws_ok($$delete from public.monvelo_pledges$$, 'P0001', null, 'pledges are never deleted');
update public.monvelo_pledges set remaining = 0;
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000017', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', %L, 100000)$$, current_setting('test.thu')), 'P0001',
  'a pledge cannot drop below what is already funded', 'a pledge below what is funded is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000018', '80000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000001', %L, 100000)$$, current_setting('test.thu')), 'P0001', 'the agent is not active',
  'a PENDING agent cannot pledge');
select pg_temp.act_as('20000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001');
select throws_ok(format($$select public.pledge_monvelo_funds('e5000000-0000-0000-0000-000000000019', '80000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', %L, 100000)$$, current_setting('test.thu')), '42501', null, 'a non-member is refused');
select is((select count(*)::int from public.monvelo_pledges), 0, 'a stranger reads no pledges');
select pg_temp.act_as('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_pledges), 0, 'another agent''s member reads none');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_pledges), 0, 'a tenant ZSM reads none');

-- ── supply day read policy ──
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select ok((select count(*) from public.monvelo_supply_days) >= 1, 'tenant staff read their tenant''s supply days');
select pg_temp.act_as('20000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.monvelo_supply_days), 0, 'another tenant''s staff read none');

-- ── monvelo_supply_days_near ────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select is((select shop_count from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000001', 14)
            where supply_date = current_setting('test.thu')::date), 1, 'the near agent sees A1 with one shop');
select is((select count(*)::int from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000001', 30)
            where supply_date > current_setting('test.today')::date + 13), 0, 'the window is capped at 14 days');
select pg_temp.act_as('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000003', 14)), 0,
  'the 5 km agent sees nothing');
select throws_ok($$select * from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000001', 7)$$, '42501', null,
  'a non-member is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select * from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000002', 7)$$, '42501', null,
  'a member of a PENDING agent is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select * from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000004', 7)$$, '42501', null,
  'a member of a SUSPENDED agent is refused');
select ok(pg_get_function_result('public.monvelo_supply_days_near(uuid,integer)'::regprocedure) !~* 'shop_id|shop_name|location|phone',
  'the read returns totals only');
reset role;
update public.monvelo_shop_enrolments set status = 'WITHDRAWN', withdrawn_at = now()
 where shop_id = '70000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_supply_days_near('80000000-0000-0000-0000-000000000001', 14)), 0,
  'a WITHDRAWN enrolment is not counted');

-- ── monvelo_agents_near ─────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', null);
select is((select array_agg(agent_id) from public.monvelo_agents_near('70000000-0000-0000-0000-000000000001')),
  array['80000000-0000-0000-0000-000000000001']::uuid[], 'the operator gets the near ACTIVE agent only');
select ok((select distance_m between 350 and 450 from public.monvelo_agents_near('70000000-0000-0000-0000-000000000001')),
  'the distance is an integer near 400');
select is((select count(*)::int from public.monvelo_agents_near('70000000-0000-0000-0000-000000000001', 6000)), 2,
  'a wider radius adds the 5 km agent');
select is((select count(*)::int from public.monvelo_agents_near('70000000-0000-0000-0000-000000000001', 999999)), 2,
  'the radius is capped at 50 km');
select throws_ok($$select * from public.monvelo_agents_near('70000000-0000-0000-0000-000000000009')$$, 'P0001', null,
  'an unknown shop is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select * from public.monvelo_agents_near('70000000-0000-0000-0000-000000000001')$$, '42501', null,
  'a ZSM is refused');
reset role;
select ok(pg_get_function_result('public.monvelo_agents_near(uuid,integer)'::regprocedure) !~* 'phone|name|account',
  'the search returns no phone, name or account');

select * from finish();
rollback;
