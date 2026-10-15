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
