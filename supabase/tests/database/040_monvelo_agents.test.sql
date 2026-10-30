-- Addendum A6 §4.1 (Monvelo Step 1) — fintech (POS) agents, their staff
-- logins, settlement-account changes, caps and the final read policy.
begin;
create extension if not exists pgtap with schema extensions;

select plan(77);

-- A6 §18.4: every state is switched on, and every tenant opted in, for this file's fixtures
update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');

-- 1 ZSM · 2 ZSA · 3 TM · 4 ASA · 5 MONVELO_OPERATOR (no tenant)
-- · 6 fintech staff (to be linked) · 7 stranger · 8 ASA of the disabled tenant
-- · 9 MONVELO_FINANCE · 10 second ZSA (did not recruit) · 11 unconfirmed phone
-- · 12 Unilever ZSM
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', now()),
  ('20000000-0000-0000-0000-000000000002', '2348000000002', now()),
  ('20000000-0000-0000-0000-000000000003', '2348000000003', now()),
  ('20000000-0000-0000-0000-000000000004', '2348000000004', now()),
  ('20000000-0000-0000-0000-000000000005', '2348000000005', now()),
  ('20000000-0000-0000-0000-000000000006', '2348000000006', now()),
  ('20000000-0000-0000-0000-000000000007', '2348000000007', now()),
  ('20000000-0000-0000-0000-000000000008', '2348000000008', now()),
  ('20000000-0000-0000-0000-000000000009', '2348000000009', now()),
  ('20000000-0000-0000-0000-000000000010', '2348000000010', now()),
  ('20000000-0000-0000-0000-000000000012', '2348000000012', now()),
  ('20000000-0000-0000-0000-000000000013', '2348000000013', now());
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000011', '2348000000011');

update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000005';
update public.profiles set platform_role = 'MONVELO_FINANCE'  where id = '20000000-0000-0000-0000-000000000009';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'Allen'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000002', 'Allen');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000012',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010',
   'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000013',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'ASA', '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'ASA', '40000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000012', 'ACTIVE', true);

-- Nestle opted in; Unilever did not
insert into public.monvelo_tenant_settings (tenant_id, enabled) values
  ('10000000-0000-0000-0000-000000000001', true),
  ('10000000-0000-0000-0000-000000000002', false);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- the gateway secret, replaced inside this transaction only
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- ── shape ───────────────────────────────────────────────────────────────
select has_table('public', 'monvelo_agents', 'agents table exists');
select has_table('public', 'monvelo_agent_members', 'members table exists');
select col_is_unique('public', 'monvelo_agents', array['pos_network', 'network_agent_id'],
  'the network agent id is unique per network (the race-safe guard)');
select col_type_is('public', 'monvelo_agents', 'daily_cap', 'numeric(15,2)', 'daily_cap is money');
select col_default_is('public', 'monvelo_agents', 'per_financing_cap', '0', 'per_financing_cap defaults to 0');

-- ── register_monvelo_agent ──────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.reg1', public.register_monvelo_agent(
  'cccccccc-0000-0000-0000-000000000001', 'test-gw-secret',
  jsonb_build_object(
    'business_name', 'Mama Ngozi Ventures', 'pos_network', 'MONIEPOINT', 'network_agent_id', 'MP-100200',
    'contact_phone', '+2348031112222', 'latitude', 6.6018, 'longitude', 3.3515,
    'address_text', '12 Allen Avenue, Ikeja',
    'settlement_account_number', '0123456789', 'settlement_bank_code', '058',
    'settlement_account_name', ' MAMA NGOZI ventures ', 'network_kyc_reference', 'KYC-998877'))::text, true); end $$;
select is(current_setting('test.reg1')::jsonb ->> 'status', 'PENDING', 'a ZSA registers an agent as PENDING');
select is((current_setting('test.reg1')::jsonb ->> 'name_matches')::boolean, true,
  'name_matches ignores case and padding');
select ok(current_setting('test.reg1')::jsonb ? 'agent_id', 'the response carries agent_id');
select is(current_setting('test.reg1') !~ '0123456789', true, 'the response never carries the account number');

select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000002', 'wrong-secret',
    '{"business_name":"X","pos_network":"OPAY","network_agent_id":"OP-1","contact_phone":"+2348031110000","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"1111111111","settlement_bank_code":"058","settlement_account_name":"X","network_kyc_reference":"K"}'::jsonb)$$,
  '42501', null, 'a wrong gateway proof is refused');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000002', null,
    '{"business_name":"X","pos_network":"OPAY","network_agent_id":"OP-1","contact_phone":"+2348031110000","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"1111111111","settlement_bank_code":"058","settlement_account_name":"X","network_kyc_reference":"K"}'::jsonb)$$,
  '42501', null, 'no gateway proof is refused');

select is(public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000001', 'test-gw-secret',
  jsonb_build_object(
    'business_name', 'Mama Ngozi Ventures', 'pos_network', 'MONIEPOINT', 'network_agent_id', 'MP-100200',
    'contact_phone', '+2348031112222', 'latitude', 6.6018, 'longitude', 3.3515,
    'address_text', '12 Allen Avenue, Ikeja',
    'settlement_account_number', '0123456789', 'settlement_bank_code', '058',
    'settlement_account_name', ' MAMA NGOZI ventures ', 'network_kyc_reference', 'KYC-998877')) ->> 'agent_id',
  current_setting('test.reg1')::jsonb ->> 'agent_id', 'the same key replays the same agent');

-- Review Focus 3: the same network agent recruited again by another street agent
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000003', 'test-gw-secret',
    '{"business_name":"Mama Ngozi","pos_network":"MONIEPOINT","network_agent_id":"MP-100200","contact_phone":"+2348031119999","latitude":6.5,"longitude":3.3,"address_text":"b","settlement_account_number":"2222222222","settlement_bank_code":"058","settlement_account_name":"Mama Ngozi","network_kyc_reference":"K2"}'::jsonb)$$,
  '23505', 'this agent is already registered with Monvelo',
  'the same POS agent recruited twice is a 23505 with a plain message');
select is(
  (select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000004', 'test-gw-secret',
    '{"business_name":"Mama Ngozi","pos_network":"OPAY","network_agent_id":"MP-100200","contact_phone":"+2348031119999","latitude":6.5,"longitude":3.3,"address_text":"b","settlement_account_number":"2222222222","settlement_bank_code":"058","settlement_account_name":"Somebody Else","network_kyc_reference":"K2"}'::jsonb) ->> 'name_matches'),
  'false', 'a mismatching name is reported as name_matches false, and the agent still registers (another network, same id)');
-- the guard is case- and padding-insensitive
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000008', 'test-gw-secret',
    '{"business_name":"Mama Ngozi","pos_network":"MONIEPOINT","network_agent_id":" mp-100200","contact_phone":"+2348031119999","latitude":6.5,"longitude":3.3,"address_text":"b","settlement_account_number":"2222222222","settlement_bank_code":"058","settlement_account_name":"Mama Ngozi","network_kyc_reference":"K2"}'::jsonb)$$,
  '23505', 'this agent is already registered with Monvelo',
  'a lower-case, padded copy of the id is the same agent');
reset role;
select is((select count(*)::int from public.monvelo_agents where network_agent_id = 'MP-100200'), 2,
  'two rows for the two networks');
select is((select count(*)::int from public.monvelo_agents where pos_network = 'MONIEPOINT' and network_agent_id = 'MP-100200'), 1,
  'the duplicate created no second Moniepoint agent');
select is((select settlement_account_last4 from public.monvelo_agents where pos_network = 'MONIEPOINT'), '6789',
  'the last four digits are derived');
select is((select recruited_by::text from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  '20000000-0000-0000-0000-000000000002', 'recruited_by is the caller');
select is((select status from public.monvelo_agents where pos_network = 'OPAY'), 'PENDING', 'the second agent is PENDING');
select is((select round(extensions.st_y(location::extensions.geometry)::numeric, 4) from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  6.6018, 'the location is stored as a point');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000005', 'test-gw-secret',
    '{"business_name":"Z","pos_network":"PALMPAY","network_agent_id":"PP-1","contact_phone":"+2348031110001","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"3333333333","settlement_bank_code":"058","settlement_account_name":"Z","network_kyc_reference":"K"}'::jsonb)$$,
  '42501', null, 'a TM cannot register an agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000009', 'test-gw-secret',
    '{"business_name":"Z","pos_network":"PALMPAY","network_agent_id":"PP-9","contact_phone":"+2348031110001","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"3333333333","settlement_bank_code":"058","settlement_account_name":"Z","network_kyc_reference":"K"}'::jsonb)$$,
  '42501', null, 'a DSA cannot register an agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000010', 'test-gw-secret',
    '{"business_name":"Z","pos_network":"PALMPAY","network_agent_id":"PP-10","contact_phone":"+2348031110001","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"3333333333","settlement_bank_code":"058","settlement_account_name":"Z","network_kyc_reference":"K"}'::jsonb)$$,
  '42501', 'Monvelo is not enabled for this tenant', 'an ASA of a tenant that has not enabled Monvelo cannot register');
select throws_ok(
  $$select public.request_monvelo_settlement_change('99999999-0000-0000-0000-000000000009', 'test-gw-secret',
      (select id from public.monvelo_agents limit 1),
      '{"settlement_account_number":"9876543210","settlement_bank_code":"044","settlement_account_name":"X"}'::jsonb)$$,
  '42501', 'Monvelo is not enabled for this tenant', 'nor request a settlement change');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000006', 'test-gw-secret',
    '{"business_name":"Z","pos_network":"PALMPAY","network_agent_id":"PP-2","contact_phone":"+2348031110001","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"33333","settlement_bank_code":"058","settlement_account_name":"Z","network_kyc_reference":"K"}'::jsonb)$$,
  'P0001', null, 'a settlement account number must be ten digits');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000007', 'test-gw-secret',
    '{"business_name":"Z","pos_network":"PALMPAY","network_agent_id":"PP-3","contact_phone":"+2348031110001","latitude":96.5,"longitude":3.3,"address_text":"a","settlement_account_number":"3333333333","settlement_bank_code":"058","settlement_account_name":"Z","network_kyc_reference":"K"}'::jsonb)$$,
  'P0001', null, 'an impossible latitude is refused');

-- ── approval needs the platform role ────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.approve_monvelo_agent('dddddddd-0000-0000-0000-000000000001',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'))$$,
  '42501', null, 'a tenant ZSM without the platform role cannot approve');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', null);
select throws_ok(
  $$select public.approve_monvelo_agent('dddddddd-0000-0000-0000-000000000001',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'))$$,
  '42501', null, 'MONVELO_FINANCE cannot approve (operator only)');

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select lives_ok(
  $$select public.approve_monvelo_agent('dddddddd-0000-0000-0000-000000000002',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'))$$,
  'the MONVELO_OPERATOR with no tenant membership approves');
select is(public.approve_monvelo_agent('dddddddd-0000-0000-0000-000000000002',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT')) ->> 'status', 'ACTIVE',
  'the approval replays');
reset role;
select is((select status from public.monvelo_agents where pos_network = 'MONIEPOINT'), 'ACTIVE', 'the agent is ACTIVE');
select is((select approved_by::text from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  '20000000-0000-0000-0000-000000000005', 'approved_by is the operator');
select ok((select approved_at is not null from public.monvelo_agents where pos_network = 'MONIEPOINT'), 'approved_at is set');
select is((select count(*)::int from public.audit_logs where operation = 'approve_monvelo_agent'
            and idempotency_key = 'dddddddd-0000-0000-0000-000000000002'), 1, 'the approval is audited once');

-- ── members ─────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.add_monvelo_member('eeeeeeee-0000-0000-0000-000000000001',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), '+2348000000006')$$,
  '42501', null, 'a tenant ZSM cannot link fintech staff');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select throws_ok(
  $$select public.add_monvelo_member('eeeeeeee-0000-0000-0000-000000000002',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), '+2348999999999')$$,
  'P0001', null, 'a phone with no account is refused');
select throws_ok(
  $$select public.add_monvelo_member('eeeeeeee-0000-0000-0000-000000000003',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), '+2348000000011')$$,
  'P0001', null, 'an unconfirmed phone is refused');
select lives_ok(
  $$select public.add_monvelo_member('eeeeeeee-0000-0000-0000-000000000004',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), '+2348000000006')$$,
  'the operator links a confirmed profile');
reset role;
select is((select count(*)::int from public.monvelo_agent_members where status = 'ACTIVE'
            and profile_id = '20000000-0000-0000-0000-000000000006'), 1, 'the member is ACTIVE');

-- ── reads ───────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', null);
select is((select count(*)::int from public.monvelo_agents), 1, 'a member reads their own agent only');
select is((select count(*)::int from public.monvelo_agent_members), 1, 'a member reads their own membership');
select throws_ok($$select settlement_account_number from public.monvelo_agents$$,
  '42501', null, 'a member cannot select the settlement account number');
select throws_ok($$select pending_settlement from public.monvelo_agents$$,
  '42501', null, 'nor the pending settlement');
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', null);
select is((select count(*)::int from public.monvelo_agents), 0, 'a stranger reads nothing');
select is((select count(*)::int from public.monvelo_agent_members), 0, 'a stranger reads no memberships');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', null);
select is((select count(*)::int from public.monvelo_agents), 2, 'MONVELO_FINANCE reads every agent');
reset role;
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'settlement_account_number', 'select'), false,
  'authenticated has no column grant on settlement_account_number');
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'settlement_bank_code', 'select'), false,
  'nor settlement_bank_code');
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'pending_settlement', 'select'), false,
  'nor pending_settlement');
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'paystack_payer_ref', 'select'), false,
  'nor paystack_payer_ref');
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'business_name', 'select'), true,
  'but business_name is readable');
select is(has_table_privilege('authenticated', 'public.monvelo_agents', 'insert'), false, 'no direct insert');

-- ── field agents: ruling 2 ──────────────────────────────────────────────
-- agent 1 (Moniepoint) is ACTIVE, agent 2 (OPay) is PENDING
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_agents), 1,
  'an enabled tenant''s ASA reads the ACTIVE agent and not the PENDING one');
select is((select pos_network::text from public.monvelo_agents), 'MONIEPOINT', 'the one it reads is the ACTIVE agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.monvelo_agents), 0, 'a disabled tenant''s ASA reads none');

-- ── caps (ruling 9) ─────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_monvelo_agent_caps('ffffffff-0000-0000-0000-000000000001',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), 500000, 100000)$$,
  '42501', null, 'a ZSA cannot set caps');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select lives_ok(
  $$select public.set_monvelo_agent_caps('ffffffff-0000-0000-0000-000000000002',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), 500000, 100000)$$,
  'the operator sets the caps');
select throws_ok(
  $$select public.set_monvelo_agent_caps('ffffffff-0000-0000-0000-000000000003',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), 100000, 500000)$$,
  'P0001', null, 'a per-financing cap above the daily cap is refused');
select throws_ok(
  $$select public.set_monvelo_agent_caps('ffffffff-0000-0000-0000-000000000004',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), -1, -1)$$,
  'P0001', null, 'negative caps are refused');
reset role;
select is((select daily_cap || '/' || per_financing_cap from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  '500000.00/100000.00', 'the caps are stored');
select is((select count(*)::int from public.audit_logs where operation = 'set_monvelo_agent_caps'), 1, 'the caps change is audited');

-- ── settlement change ───────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.request_monvelo_settlement_change('99999999-0000-0000-0000-000000000001', 'wrong',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'),
      '{"settlement_account_number":"9876543210","settlement_bank_code":"044","settlement_account_name":"Mama Ngozi Ventures"}'::jsonb)$$,
  '42501', null, 'a settlement change needs the gateway proof');
select pg_temp.act_as('20000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.request_monvelo_settlement_change('99999999-0000-0000-0000-000000000002', 'test-gw-secret',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'),
      '{"settlement_account_number":"9876543210","settlement_bank_code":"044","settlement_account_name":"Mama Ngozi Ventures"}'::jsonb)$$,
  '42501', null, 'a ZSA who did not recruit the agent cannot change its account');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.request_monvelo_settlement_change('99999999-0000-0000-0000-000000000003', 'test-gw-secret',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'),
      '{"settlement_account_number":"9876543210","settlement_bank_code":"044","settlement_account_name":"Mama Ngozi Ventures"}'::jsonb)$$,
  'the recruiting ZSA requests a settlement change through the gateway');
reset role;
select is((select settlement_account_last4 || '/' || settlement_account_number from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  '6789/0123456789', 'the account is unchanged before approval');
select is((select pending_settlement ->> 'settlement_account_number' from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  '9876543210', 'the new account waits in pending_settlement');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.approve_monvelo_settlement_change('88888888-0000-0000-0000-000000000001',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'))$$,
  '42501', null, 'a tenant ZSM cannot approve a settlement change');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select lives_ok(
  $$select public.approve_monvelo_settlement_change('88888888-0000-0000-0000-000000000002',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'))$$,
  'the operator approves the settlement change');
select throws_ok(
  $$select public.approve_monvelo_settlement_change('88888888-0000-0000-0000-000000000003',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'))$$,
  'P0001', null, 'with nothing pending there is nothing to approve');
reset role;
select is((select settlement_account_last4 || '/' || settlement_account_number || '/' || settlement_bank_code
            from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  '3210/9876543210/044', 'the account is swapped in after approval');
select ok((select pending_settlement is null from public.monvelo_agents where pos_network = 'MONIEPOINT'),
  'and the pending change is cleared');

-- ── suspension ──────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.suspend_monvelo_agent('77777777-0000-0000-0000-000000000001',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), 'x')$$,
  '42501', null, 'a tenant ZSM cannot suspend');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select lives_ok(
  $$select public.suspend_monvelo_agent('77777777-0000-0000-0000-000000000002',
      (select id from public.monvelo_agents where pos_network = 'MONIEPOINT'), 'chargeback dispute')$$,
  'the operator suspends an agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_agents), 0, 'a suspended agent is no longer visible to field agents');

-- ── no personal data in audit rows ──────────────────────────────────────
reset role;
select is((select count(*)::int from public.audit_logs
            where entity_type like 'monvelo_agent%'
              and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '0123456789|9876543210|2222222222|8031112222|settlement_account_number|contact_phone'),
  0, 'no audit row carries a full account number, a phone number or those keys');
select ok((select count(*) > 0 from public.audit_logs
            where entity_type like 'monvelo_agent%' and (after::text like '%"6789"%' or after::text like '%"3210"%')),
  'the audit rows do carry the last four digits');

select * from finish();
rollback;
