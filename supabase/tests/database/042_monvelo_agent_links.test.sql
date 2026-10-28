-- Addendum A6 §15.2 (Monvelo Step 1b, Task 1) — agent-tenant links, platform
-- terminals and Paystack subaccounts.
begin;
create extension if not exists pgtap with schema extensions;

select plan(82);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Tenant A', 'TENANTA'),
  ('10000000-0000-0000-0000-000000000002', 'Tenant B', 'TENANTB');

-- 1 ZSM A · 2 TM A · 3 ZSM B · 4 operator · 5 member M · 6 stranger · 7 recruiter · 8 DSA A
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', now()),
  ('20000000-0000-0000-0000-000000000002', '2348000000002', now()),
  ('20000000-0000-0000-0000-000000000003', '2348000000003', now()),
  ('20000000-0000-0000-0000-000000000004', '2348000000004', now()),
  ('20000000-0000-0000-0000-000000000005', '2348000000005', now()),
  ('20000000-0000-0000-0000-000000000006', '2348000000006', now()),
  ('20000000-0000-0000-0000-000000000007', '2348000000007', now());
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000004';

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikorodu');
-- A's territory has a boundary around lng 3..4, lat 6..7
update public.territories
   set boundary = extensions.st_multi(extensions.st_makeenvelope(3, 6, 4, 7, 4326))
 where id = '40000000-0000-0000-0000-000000000001';

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);

-- agent X (ACTIVE, member M), agent P (PENDING), agent Y (ACTIVE, venue far away)
insert into public.monvelo_fintech_agents (id, business_name, pos_network, network_agent_id, contact_phone, location,
  address_text, settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name,
  network_kyc_reference, recruited_by, status, approved_by, approved_at) values
  ('a0000000-0000-0000-0000-000000000001', 'Grace POS', 'MONIEPOINT', 'MP-GRACE', '+2348000000000',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'Allen Ave',
   '0123456789', '6789', '058', 'Grace POS', 'KYC-1', '20000000-0000-0000-0000-000000000007', 'ACTIVE',
   '20000000-0000-0000-0000-000000000007', now()),
  ('a0000000-0000-0000-0000-000000000002', 'Pending POS', 'OPAY', 'OP-PEND', '+2348000000000',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'Allen Ave',
   '0123456789', '6789', '058', 'Pending POS', 'KYC-2', '20000000-0000-0000-0000-000000000007', 'PENDING', null, null),
  ('a0000000-0000-0000-0000-000000000003', 'Far POS', 'PALMPAY', 'PP-FAR', '+2348000000000',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'Allen Ave',
   '0123456789', '6789', '058', 'Far POS', 'KYC-3', '20000000-0000-0000-0000-000000000007', 'ACTIVE',
   '20000000-0000-0000-0000-000000000007', now());
insert into public.monvelo_fintech_members (agent_id, profile_id) values
  ('a0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005');
-- Y's terminal sits at lng 10, lat 10: outside A's boundary
insert into public.monvelo_agent_terminals (id, agent_id, network_terminal_id, venue_channel, venue_name, address_text,
  state, location) values
  ('b0000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000003', 'T-FAR-1',
   (enum_range(null::public.venue_channel_enum))[1], 'Far kiosk', 'Far road', 'Kano',
   extensions.st_setsrid(extensions.st_makepoint(10, 10), 4326));

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
-- claims only, no role switch: for the helpers that have no API grant
create function pg_temp.claims_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- ── shape ───────────────────────────────────────────────────────────────
select has_table('public', 'monvelo_agent_tenants', 'links table exists');
select has_table('public', 'monvelo_agent_terminals', 'terminals table exists');

-- ── subaccount ──────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_monvelo_agent_subaccount('c0000000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000001', 'ACCT_grace01')$$,
  '42501', null, 'a tenant ZSM cannot set a subaccount');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select throws_ok(
  $$select public.set_monvelo_agent_subaccount('c0000000-0000-0000-0000-000000000002',
      'a0000000-0000-0000-0000-000000000001', 'ACCT 1')$$,
  'P0001', 'a Paystack subaccount code looks like ACCT_…', 'a malformed code is refused');
select throws_ok(
  $$select public.set_monvelo_agent_subaccount('c0000000-0000-0000-0000-000000000003',
      'a0000000-0000-0000-0000-000000000009', 'ACCT_x1')$$,
  'P0001', null, 'an unknown agent is refused');
do $$ begin perform set_config('test.sub1', public.set_monvelo_agent_subaccount(
  'c0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'ACCT_grace01')::text, true); end $$;
select is((current_setting('test.sub1')::jsonb ->> 'has_paystack_subaccount')::boolean, true,
  'the operator sets the subaccount');
select is(current_setting('test.sub1') ~ 'ACCT_', false, 'the response never carries the code');
select is(public.set_monvelo_agent_subaccount('c0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000001', 'ACCT_grace01') ->> 'agent_id',
  'a0000000-0000-0000-0000-000000000001', 'the same key replays');
reset role;
select is((select paystack_subaccount_code from public.monvelo_fintech_agents where id = 'a0000000-0000-0000-0000-000000000001'),
  'ACCT_grace01', 'the code is stored');
select is(has_column_privilege('authenticated', 'public.monvelo_fintech_agents', 'paystack_subaccount_code', 'select'), false,
  'authenticated has no column grant on paystack_subaccount_code');
select is(has_column_privilege('authenticated', 'public.monvelo_fintech_agents', 'has_paystack_subaccount', 'select'), true,
  'but has_paystack_subaccount is readable');
select is((select count(*)::int from public.audit_logs where operation = 'set_monvelo_agent_subaccount'), 1,
  'the subaccount change is audited once');
select is((select tenant_id is null from public.audit_logs where operation = 'set_monvelo_agent_subaccount'), true,
  'with a null tenant');
-- clearing, then setting again (audit rows are checked for the code below)
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select is((public.set_monvelo_agent_subaccount('c0000000-0000-0000-0000-000000000005',
    'a0000000-0000-0000-0000-000000000003', 'ACCT_far77') ->> 'has_paystack_subaccount')::boolean, true,
  'a second agent gets a subaccount');
select is((public.set_monvelo_agent_subaccount('c0000000-0000-0000-0000-000000000006',
    'a0000000-0000-0000-0000-000000000003', null) ->> 'has_paystack_subaccount')::boolean, false,
  'null clears it');
reset role;
select is((select count(*)::int from public.audit_logs where audit_logs::text like '%ACCT_%'), 0,
  'no audit row contains a subaccount code');

-- ── terminals ───────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_monvelo_terminal('d0000000-0000-0000-0000-000000000001', null,
      'a0000000-0000-0000-0000-000000000001', 'T-GRACE-1', '20000000-0000-0000-0000-000000000005', true)$$,
  '42501', null, 'a tenant ZSM cannot register a terminal');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
do $$ begin perform set_config('test.term1', public.upsert_monvelo_terminal(
  'd0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000001', ' t-grace-1 ', '20000000-0000-0000-0000-000000000005', true)::text, true); end $$;
select is(current_setting('test.term1')::jsonb ->> 'terminal_id', 'b0000000-0000-0000-0000-000000000001',
  'the operator registers a terminal with operator M');
select throws_ok(
  $$select public.upsert_monvelo_terminal('d0000000-0000-0000-0000-000000000003', null,
      'a0000000-0000-0000-0000-000000000001', 'T-OTHER', '20000000-0000-0000-0000-000000000006', true)$$,
  'P0001', 'the operator must be an active member of the agent', 'a non-member operator profile is refused');
select throws_ok(
  $$select public.upsert_monvelo_terminal('d0000000-0000-0000-0000-000000000004', null,
      'a0000000-0000-0000-0000-000000000001', 'T-GRACE-1', null, true)$$,
  '23505', 'this terminal is already registered for the agent', 'the same network id twice is a 23505');
select throws_ok(
  $$select public.upsert_monvelo_terminal('d0000000-0000-0000-0000-000000000005', 'b0000000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000003', 'T-GRACE-1', null, true)$$,
  'P0001', 'a terminal''s agent never changes', 'changing the agent is refused');
select throws_ok(
  $$select public.upsert_monvelo_terminal('d0000000-0000-0000-0000-000000000006', null,
      'a0000000-0000-0000-0000-000000000009', 'T-X', null, true)$$,
  'P0001', null, 'an unknown agent is refused');
select is(public.upsert_monvelo_terminal('d0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001', ' t-grace-1 ', '20000000-0000-0000-0000-000000000005', true) ->> 'terminal_id',
  'b0000000-0000-0000-0000-000000000001', 'the same key replays');
reset role;
select is((select network_terminal_id from public.monvelo_agent_terminals where id = 'b0000000-0000-0000-0000-000000000001'),
  'T-GRACE-1', 'the network terminal id is stored trimmed and upper-cased');
select is((select count(*)::int from public.audit_logs where operation = 'upsert_monvelo_terminal'), 1,
  'the terminal is audited once');

-- ── helpers without grants ──────────────────────────────────────────────
select is(has_function_privilege('authenticated', 'public.assert_monvelo_member(uuid)', 'execute'), false,
  'assert_monvelo_member has no API grant');
select is(has_function_privilege('authenticated', 'public.monvelo_agent_link_active(uuid, uuid)', 'execute'), false,
  'monvelo_agent_link_active has no API grant');
select is(has_function_privilege('authenticated', 'public.my_linked_monvelo_agent_ids()', 'execute'), true,
  'my_linked_monvelo_agent_ids is granted');

-- ── link_monvelo_agent ──────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.link_monvelo_agent('e0000000-0000-0000-0000-000000000001', 'MONIEPOINT', 'MP-GRACE',
      '40000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'a TM cannot link an agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.link1', public.link_monvelo_agent(
  'e0000000-0000-0000-0000-000000000002', 'MONIEPOINT', ' mp-grace ', '40000000-0000-0000-0000-000000000001')::text, true); end $$;
select is(current_setting('test.link1')::jsonb ->> 'status', 'PENDING', 'ZSM A''s link of X is PENDING until the operator approves');
select is(current_setting('test.link1')::jsonb ->> 'agent_id', 'a0000000-0000-0000-0000-000000000001', 'the response names the agent');
select is(public.link_monvelo_agent('e0000000-0000-0000-0000-000000000002', 'MONIEPOINT', ' mp-grace ',
    '40000000-0000-0000-0000-000000000001') ->> 'status', 'PENDING', 'the same key replays');
select throws_ok(
  $$select public.link_monvelo_agent('e0000000-0000-0000-0000-000000000003', 'OPAY', 'OP-PEND',
      '40000000-0000-0000-0000-000000000001')$$,
  'P0001', 'no active Monvelo agent has that network id', 'a PENDING agent cannot be linked');
select throws_ok(
  $$select public.link_monvelo_agent('e0000000-0000-0000-0000-000000000004', 'OPAY', 'NOPE',
      '40000000-0000-0000-0000-000000000001')$$,
  'P0001', 'no active Monvelo agent has that network id', 'an unknown id gives the same text');
select throws_ok(
  $$select public.link_monvelo_agent('e0000000-0000-0000-0000-000000000005', 'MONIEPOINT', 'MP-GRACE',
      '40000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'B''s territory is refused for tenant A');
select throws_ok(
  $$select public.link_monvelo_agent('e0000000-0000-0000-0000-000000000006', 'PALMPAY', 'PP-FAR',
      '40000000-0000-0000-0000-000000000001')$$,
  'P0001', 'the agent''s venue lies outside that territory', 'a venue outside the boundary refuses the link');
-- relinking the same agent updates the existing link
select is(public.link_monvelo_agent('e0000000-0000-0000-0000-000000000007', 'MONIEPOINT', 'MP-GRACE',
    '40000000-0000-0000-0000-000000000001') ->> 'status', 'PENDING', 'a new key updates the existing link');
reset role;
select is((select count(*)::int from public.monvelo_agent_tenants), 1, 'still one link');
select is((select count(*)::int from public.audit_logs where operation = 'link_monvelo_agent'
            and tenant_id = '10000000-0000-0000-0000-000000000001'), 2, 'the link calls carry the tenant id');

-- composite FK: tenant A with B's territory
select throws_ok(
  $$insert into public.monvelo_agent_tenants (tenant_id, agent_id, territory_id, linked_by)
    values ('10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003',
            '40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001')$$,
  '23503', null, 'a link naming another tenant''s territory is a foreign-key violation');
select throws_ok(
  $$insert into public.monvelo_agent_terminals (agent_id, network_terminal_id, operator_profile_id)
    values ('a0000000-0000-0000-0000-000000000003', 'T-FAR-2', '20000000-0000-0000-0000-000000000005')$$,
  '23503', null, 'a terminal operator who is not a member of its agent is a foreign-key violation');

-- ── operator approval of the link ───────────────────────────────────────
select is(public.monvelo_agent_link_active('10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001'),
  false, 'a PENDING link is not active');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.approve_monvelo_agent_link('a1000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'the tenant ZSM cannot approve its own link');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select is(public.approve_monvelo_agent_link('a1000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001') ->> 'status', 'ACTIVE',
  'an operator with no tenant membership approves the link');
select is(public.approve_monvelo_agent_link('a1000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001') ->> 'tenant_id',
  '10000000-0000-0000-0000-000000000001', 'the approval replays');
select throws_ok(
  $$select public.approve_monvelo_agent_link('a1000000-0000-0000-0000-000000000003',
      '10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001')$$,
  'P0001', null, 'approving a link that is not PENDING is refused');
select throws_ok(
  $$select public.approve_monvelo_agent_link('a1000000-0000-0000-0000-000000000004',
      '10000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001')$$,
  'P0001', null, 'approving a link that does not exist is refused');
reset role;
select is(public.monvelo_agent_link_active('10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001'),
  true, 'an approved link is active');
select is((select approved_by::text from public.monvelo_agent_tenants), '20000000-0000-0000-0000-000000000004',
  'approved_by is the operator');
select throws_ok(
  $$update public.monvelo_agent_tenants set approved_at = null$$,
  '23514', null, 'an ACTIVE link needs approved_by and approved_at');
-- a territory change needs approval again
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.link_monvelo_agent('e0000000-0000-0000-0000-000000000008', 'MONIEPOINT', 'MP-GRACE',
    '40000000-0000-0000-0000-000000000003') ->> 'status', 'PENDING', 'a territory change returns the link to PENDING');
reset role;
select is(public.monvelo_agent_link_active('10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001'),
  false, 'and it is inactive until re-approved');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select is(public.approve_monvelo_agent_link('a1000000-0000-0000-0000-000000000005',
    '10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001') ->> 'status', 'ACTIVE',
  'the operator approves the new territory');
reset role;

-- ── set_monvelo_agent_link_status ───────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  $$select public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000001', 'SUSPENDED')$$,
  'P0001', 'this agent is not linked to your tenant', 'ZSM B cannot touch A''s link');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000002',
      'a0000000-0000-0000-0000-000000000001', 'SUSPENDED')$$,
  '42501', null, 'a TM cannot suspend a link');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000003',
      'a0000000-0000-0000-0000-000000000001', 'GONE')$$,
  'P0001', null, 'an unknown status is refused');
select is(public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000001', 'SUSPENDED') ->> 'status', 'SUSPENDED', 'ZSM A suspends the link');
select is(public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000001', 'SUSPENDED') ->> 'status', 'SUSPENDED', 'the suspension replays');
select is((select count(*)::int from public.monvelo_agent_tenants where status = 'SUSPENDED'), 1,
  'a suspended link is still visible to its tenant');
-- the agent is suspended platform-wide: reactivating the link needs an ACTIVE agent
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select lives_ok($$select public.suspend_monvelo_agent('f0000000-0000-0000-0000-000000000005',
    'a0000000-0000-0000-0000-000000000001', 'test')$$, 'the operator suspends the agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000006',
      'a0000000-0000-0000-0000-000000000001', 'ACTIVE')$$,
  'P0001', null, 'reactivating the link needs an ACTIVE agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select lives_ok($$select public.approve_monvelo_agent('f0000000-0000-0000-0000-000000000007',
    'a0000000-0000-0000-0000-000000000001')$$, 'the operator reactivates the agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.set_monvelo_agent_link_status('f0000000-0000-0000-0000-000000000008',
    'a0000000-0000-0000-0000-000000000001', 'ACTIVE') ->> 'status', 'ACTIVE', 'ZSM A reactivates the link');

-- ── visibility ──────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_agent_tenants), 1, 'A''s TM reads the link');
select is((select count(*)::int from public.monvelo_agent_terminals), 1, 'A''s TM reads the terminal');
select is((select has_paystack_subaccount from public.monvelo_fintech_agents where id = 'a0000000-0000-0000-0000-000000000001'),
  true, 'A''s TM reads the agent''s public columns');
select throws_ok($$select paystack_subaccount_code from public.monvelo_fintech_agents$$,
  '42501', null, 'but not the subaccount code');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.monvelo_agent_tenants), 0, 'B''s ZSM reads no link');
select is((select count(*)::int from public.monvelo_agent_terminals), 0, 'B''s ZSM reads no terminal');
select is((select count(*)::int from public.monvelo_fintech_agents), 0, 'B''s ZSM reads no agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select is((select count(*)::int from public.monvelo_agent_tenants), 1, 'member M reads its link');
select is((select count(*)::int from public.monvelo_agent_terminals), 1, 'member M reads its terminal');
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', null);
select is((select count(*)::int from public.monvelo_agent_tenants), 0, 'a stranger reads no link');
select is((select count(*)::int from public.monvelo_agent_terminals), 0, 'a stranger reads no terminal');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select is((select count(*)::int from public.monvelo_agent_terminals), 2, 'the operator reads every terminal');

-- ── assert_monvelo_member (claims only: the helper has no API grant) ────
reset role;
select pg_temp.claims_as('20000000-0000-0000-0000-000000000005');
select is(public.assert_monvelo_member('a0000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-000000000005'::uuid, 'M is a member of X');
select throws_ok($$select public.assert_monvelo_member('a0000000-0000-0000-0000-000000000003')$$,
  '42501', 'not a member of this Monvelo agent', 'M is not a member of Y');
select pg_temp.claims_as('20000000-0000-0000-0000-000000000006');
select throws_ok($$select public.assert_monvelo_member('a0000000-0000-0000-0000-000000000001')$$,
  '42501', 'not a member of this Monvelo agent', 'a stranger is refused');
update public.monvelo_fintech_agents set status = 'SUSPENDED' where id = 'a0000000-0000-0000-0000-000000000001';
select pg_temp.claims_as('20000000-0000-0000-0000-000000000005');
select throws_ok($$select public.assert_monvelo_member('a0000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'M is refused once X is suspended');
select is(public.monvelo_agent_link_active('10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001'),
  false, 'a link to a suspended agent is not active');
update public.monvelo_fintech_agents set status = 'ACTIVE' where id = 'a0000000-0000-0000-0000-000000000001';
select is(public.monvelo_agent_link_active('10000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001'),
  true, 'an ACTIVE link to an ACTIVE agent is active');
select is(public.monvelo_agent_link_active('10000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001'),
  false, 'no link at all is not active');

select * from finish();
rollback;
