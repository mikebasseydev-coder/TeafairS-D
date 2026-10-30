-- Addendum A4 §4.1 — get_or_create_direct_channel: scope (same territory, zone
-- ZSM, TMs of one zone), sorted pair, replay, reopen after a move, no audit
-- row (chat audits moderation only, §7.9).
begin;
create extension if not exists pgtap with schema extensions;

select plan(19);

-- ── fixtures (plan "common fixture shape") ──────────────────────────────
-- T1: zone Lagos (ZSM Z) with Ikeja (TM TA, ASM AA, DSM MA, DSA DA, DSA DA2,
-- POS_AGENT F, DISABLED DSA X) and Epe (TM TB, DSA DB); zone Kano with
-- Fagge (DSA DK). T2: zone Lagos2 with ZSM Z2.
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),  -- Z
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),  -- TA
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),  -- AA
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),  -- MA
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),  -- DA
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),  -- DA2
  ('20000000-0000-0000-0000-000000000007', '2348000000007'),  -- TB
  ('20000000-0000-0000-0000-000000000008', '2348000000008'),  -- DB
  ('20000000-0000-0000-0000-000000000009', '2348000000009'),  -- DK
  ('20000000-0000-0000-0000-000000000010', '2348000000010'),  -- F
  ('20000000-0000-0000-0000-000000000011', '2348000000011'),  -- X
  ('20000000-0000-0000-0000-000000000012', '2348000000012');  -- Z2
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Kano', 'KN'),
  ('30000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe'),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', 'Fagge');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000012',
   'ZSM', null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'ASM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008',
   'DSA', null, '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000007', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000009',
   'DSA', null, '40000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'DISABLED', true);

-- A6 §17: a ZSM's coverage is zones.zsm_id, not a zone on the membership
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id = '30000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000012'
 where id = '30000000-0000-0000-0000-000000000009';

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- DA opens with DA2: same territory
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
create temp table r1 as select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006') as r;
grant select on r1 to authenticated;
select is((select r ->> 'created' from r1), 'true', 'same territory allowed');
select ok(exists (select 1 from public.chat_channels c where c.id = (select (r ->> 'channel_id')::uuid from r1) and c.channel_type = 'DIRECT' and c.direct_low_id < c.direct_high_id), 'a sorted DIRECT channel was created');
select is(public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006') ->> 'channel_id', (select r ->> 'channel_id' from r1), 'replay returns the stored reply');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
create temp table r2 as select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005') as r;
grant select on r2 to authenticated;
select is((select r ->> 'channel_id' from r2), (select r ->> 'channel_id' from r1), 'reversed pair returns the same channel');
select is((select r ->> 'created' from r2), 'false', 'and does not create');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001')$$, 'zone ZSM allowed');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000007')$$, 'two TMs in one zone allowed');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000008')$$, 'ZSM reaches anyone in the zone');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000008')$$, '42501', null, 'DSA cannot reach another territory');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000009')$$, '42501', null, 'nor another zone');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000008', '20000000-0000-0000-0000-000000000009')$$, '42501', null, 'TM cannot reach another zone');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000010')$$, 'P0001', 'that person is not available', 'fintech agent unavailable');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000010', '20000000-0000-0000-0000-000000000011')$$, 'P0001', 'that person is not available', 'disabled user unavailable');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-000000000005')$$, 'P0001', 'you cannot message yourself', 'no self chat');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000012', '20000000-0000-0000-0000-000000000005')$$, '42501', null, 'fintech agent cannot open chats');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000013', '20000000-0000-0000-0000-000000000012')$$, 'P0001', 'that person is not available', 'a target in another tenant is not available');
reset role;

-- DA moves to Epe: the pair no longer shares a territory, but the chat exists
update public.tenant_users set territory_id = '40000000-0000-0000-0000-000000000002'
 where tenant_id = '10000000-0000-0000-0000-000000000001' and profile_id = '20000000-0000-0000-0000-000000000005';
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
create temp table r3 as select public.get_or_create_direct_channel('a0000000-0000-0000-0000-000000000014', '20000000-0000-0000-0000-000000000006') as r;
reset role;
select is((select r from r3),
          jsonb_build_object('channel_id', (select r ->> 'channel_id' from r1), 'created', false),
          'reopening a direct chat after one person moves returns it');

select is((select count(*)::int from public.audit_logs
            where operation = 'get_or_create_direct_channel' or entity_type = 'chat_channels'),
          0, 'opening a direct chat writes no audit row');
select ok(not has_function_privilege('anon', 'public.get_or_create_direct_channel(uuid,uuid)', 'execute'), 'not for anon');

select * from finish();
rollback;
