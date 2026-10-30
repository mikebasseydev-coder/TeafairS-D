-- Addendum A4 §3 — staff chat: schema constraints, group-channel triggers and
-- backfill, the live-derived access matrix (my_chat_channel_ids), RLS, grants,
-- Realtime.
begin;
create extension if not exists pgtap with schema extensions;

select plan(50);

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

-- D1: the direct chat DA–DA2 (sorted pair), inserted directly as postgres
insert into public.chat_channels (id, tenant_id, channel_type, direct_low_id, direct_high_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'DIRECT',
   '20000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000006');

-- channel labels, readable by the acting user, so the matrix compares id sets
create temp table ch (label text primary key, id uuid not null unique);
insert into ch (label, id)
select case c.channel_type
         when 'TERRITORY'    then 'TER:' || t.territory_name
         when 'ZONE'         then 'ZONE:' || z.zone_name
         when 'ANNOUNCEMENT' then 'ANN'
         else 'DIR:D1' end || case when c.tenant_id = '10000000-0000-0000-0000-000000000002' then '@T2' else '' end,
       c.id
  from public.chat_channels c
  left join public.territories t on t.id = c.territory_id
  left join public.zones z on z.id = c.zone_id
 where c.tenant_id in ('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
grant select on ch to authenticated;

insert into public.chat_messages (tenant_id, channel_id, sender_id, body) values
  ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'private hello'),
  ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006', 'private reply'),
  ('10000000-0000-0000-0000-000000000001', (select id from ch where label = 'TER:Ikeja'), '20000000-0000-0000-0000-000000000002', 'ikeja update'),
  ('10000000-0000-0000-0000-000000000001', (select id from ch where label = 'ANN'), '20000000-0000-0000-0000-000000000001', 'announcement');
insert into public.chat_read_state (tenant_id, channel_id, profile_id, last_read_at) values
  ('10000000-0000-0000-0000-000000000001', (select id from ch where label = 'TER:Ikeja'), '20000000-0000-0000-0000-000000000005', now()),
  ('10000000-0000-0000-0000-000000000001', (select id from ch where label = 'TER:Ikeja'), '20000000-0000-0000-0000-000000000006', now());

-- A6 §17: a ZSM's coverage is zones.zsm_id, not a zone on the membership
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id = '30000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000012'
 where id = '30000000-0000-0000-0000-000000000009';
-- A6 §18.3: an uncovered zone is open to every ZSM, so A's Kano gets its own
-- ZSM (K, a separate account)
insert into auth.users (id, phone) values ('20000000-0000-0000-0000-000000000013', '2348000000013');
insert into public.tenant_users (id, tenant_id, profile_id, role, status, is_primary) values
  ('50000000-0000-0000-0000-000000000093', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000013',
   'ZSM', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000013'
 where id = '30000000-0000-0000-0000-000000000002';

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- the labels of every channel the caller can read through RLS
create function pg_temp.visible() returns text language sql as $$
  select coalesce(string_agg(ch.label, ',' order by ch.label), '')
    from public.chat_channels c join ch on ch.id = c.id;
$$;
grant execute on function pg_temp.visible() to authenticated;

-- ── constraints ─────────────────────────────────────────────────────────
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, territory_id, zone_id)
  values ('10000000-0000-0000-0000-000000000001', 'TERRITORY',
          '40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'type ties to its columns');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, direct_low_id)
  values ('10000000-0000-0000-0000-000000000001', 'DIRECT', '20000000-0000-0000-0000-000000000005')$$,
  '23514', null, 'DIRECT needs both participants');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type)
  values ('10000000-0000-0000-0000-000000000001', 'GROUP')$$,
  '23514', null, 'unknown channel type refused');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, direct_low_id, direct_high_id)
  values ('10000000-0000-0000-0000-000000000001', 'DIRECT',
          '20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000005')$$,
  '23514', null, 'direct pair is sorted');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, direct_low_id, direct_high_id)
  values ('10000000-0000-0000-0000-000000000001', 'DIRECT',
          '20000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000005')$$,
  '23514', null, 'no direct chat with oneself');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, direct_low_id, direct_high_id)
  values ('10000000-0000-0000-0000-000000000001', 'DIRECT',
          '20000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000006')$$,
  '23505', null, 'one direct chat per pair');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'TERRITORY', '40000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'one room per territory');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, zone_id)
  values ('10000000-0000-0000-0000-000000000001', 'ZONE', '30000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'one room per zone');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type)
  values ('10000000-0000-0000-0000-000000000001', 'ANNOUNCEMENT')$$,
  '23505', null, 'one announcement stream per tenant');
select throws_ok($$insert into public.chat_channels (tenant_id, channel_type, territory_id)
  values ('10000000-0000-0000-0000-000000000002', 'TERRITORY', '40000000-0000-0000-0000-000000000002')$$,
  '23503', null, 'a channel cannot point at another tenant''s territory');
select throws_ok($$insert into public.chat_messages (tenant_id, channel_id, sender_id, body)
  values ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
          '20000000-0000-0000-0000-000000000005', '   ')$$,
  '23514', null, 'empty body refused');
select throws_ok($$insert into public.chat_messages (tenant_id, channel_id, sender_id, body)
  values ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
          '20000000-0000-0000-0000-000000000005', E'\n\t\r\n')$$,
  '23514', null, 'a newline-only body is refused');
select throws_ok($$insert into public.chat_messages (tenant_id, channel_id, sender_id, body)
  values ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
          '20000000-0000-0000-0000-000000000005', repeat('x', 2001))$$,
  '23514', null, 'over 2000 refused');
select throws_ok($$insert into public.chat_messages (tenant_id, channel_id, sender_id, body)
  values ('10000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000001',
          '20000000-0000-0000-0000-000000000005', 'cross-tenant')$$,
  '23503', null, 'composite FK keeps tenants apart');

-- ── group channels: insert triggers and backfill ────────────────────────
select is((select count(*)::int from public.chat_channels
            where tenant_id = '10000000-0000-0000-0000-000000000001' and channel_type = 'TERRITORY'
              and territory_id in ('40000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002',
                                   '40000000-0000-0000-0000-000000000003')),
          3, 'insert trigger creates one room per territory');
select is((select count(*)::int from public.chat_channels
            where tenant_id = '10000000-0000-0000-0000-000000000001' and channel_type = 'ZONE'
              and zone_id in ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002')),
          2, 'insert trigger creates one room per zone');
select is((select count(*)::int from public.chat_channels
            where tenant_id = '10000000-0000-0000-0000-000000000001' and channel_type = 'ANNOUNCEMENT'),
          1, 'insert trigger creates the tenant announcement stream');
select ok(not exists (select 1 from public.territories t where not exists (
            select 1 from public.chat_channels c
             where c.channel_type = 'TERRITORY' and c.tenant_id = t.tenant_id and c.territory_id = t.id))
          and not exists (select 1 from public.zones z where not exists (
            select 1 from public.chat_channels c
             where c.channel_type = 'ZONE' and c.tenant_id = z.tenant_id and c.zone_id = z.id))
          and not exists (select 1 from public.tenants tn where not exists (
            select 1 from public.chat_channels c
             where c.channel_type = 'ANNOUNCEMENT' and c.tenant_id = tn.id)),
          'every territory, zone and tenant (backfilled or new) has its channel');

-- ── privileges ──────────────────────────────────────────────────────────
select ok(not has_table_privilege('authenticated', 'public.chat_messages', 'insert')
          and not has_table_privilege('authenticated', 'public.chat_channels', 'update')
          and not has_table_privilege('authenticated', 'public.chat_read_state', 'insert'), 'no client writes');
select ok(has_table_privilege('authenticated', 'public.chat_channels', 'select')
          and has_table_privilege('authenticated', 'public.chat_messages', 'select')
          and has_table_privilege('authenticated', 'public.chat_read_state', 'select'), 'authenticated may select');
select ok(not has_table_privilege('anon', 'public.chat_channels', 'select')
          and not has_table_privilege('anon', 'public.chat_messages', 'select')
          and not has_table_privilege('anon', 'public.chat_read_state', 'select'), 'anon reads nothing');
select ok(not has_function_privilege('authenticated', 'public.chat_is_available(uuid,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.chat_is_available(uuid,uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.chat_is_available(uuid,uuid)', 'execute'), 'helper is internal');
select ok(not has_function_privilege('authenticated', 'public.chat_staff_zone(uuid,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.chat_staff_zone(uuid,uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.chat_staff_zone(uuid,uuid)', 'execute'), 'zone helper is internal');
select ok(not has_function_privilege('authenticated', 'public.chat_create_group_channel()', 'execute')
          and not has_function_privilege('anon', 'public.chat_create_group_channel()', 'execute')
          and not has_function_privilege('service_role', 'public.chat_create_group_channel()', 'execute'), 'trigger function is internal');
select ok(has_function_privilege('authenticated', 'public.my_chat_channel_ids()', 'execute')
          and not has_function_privilege('anon', 'public.my_chat_channel_ids()', 'execute')
          and not has_function_privilege('service_role', 'public.my_chat_channel_ids()', 'execute'), 'access helper: authenticated only');
select ok((select p.prosecdef and p.provolatile = 's' and p.proconfig @> array['search_path=public, pg_temp']
             from pg_proc p where p.oid = 'public.my_chat_channel_ids()'::regprocedure),
          'access helper is SECURITY DEFINER, STABLE, search_path pinned');

-- ── internal helpers (as postgres) ──────────────────────────────────────
select ok(public.chat_is_available('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005')
          and not public.chat_is_available('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010')
          and not public.chat_is_available('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011')
          and not public.chat_is_available('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005'),
          'available = ACTIVE staff of that tenant');
select is(array[public.chat_staff_zone('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
                public.chat_staff_zone('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000009'),
                public.chat_staff_zone('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010'),
                public.chat_staff_zone('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011')],
          array['30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', null, null]::uuid[],
          'staff zone: ZSM own zone, others via territory, null when unavailable');

-- ── access matrix ───────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,DIR:D1,TER:Ikeja', 'DSA: own room, announcements, own DM');
select is((select count(*)::int from public.chat_messages), 4, 'DSA reads its room, the stream and its DM');
select is((select count(*)::int from public.chat_read_state), 1, 'read state: only my own row');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,TER:Ikeja', 'DSM: own room only');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,TER:Ikeja', 'ASM: own room only');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,TER:Ikeja,ZONE:Lagos', 'TM: own room and zone room');
select is((select count(*)::int from public.chat_messages where channel_id = '70000000-0000-0000-0000-000000000001'),
          0, 'TM cannot read a direct chat');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,TER:Epe,TER:Ikeja,ZONE:Lagos', 'ZSM: whole zone');
select is((select count(*)::int from public.chat_messages where channel_id = '70000000-0000-0000-0000-000000000001'),
          0, 'ZSM cannot read a direct chat');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,TER:Fagge', 'DSA in the second zone: own room only');
reset role;

-- §7.2: a non-ZSM's zone comes from its territory, never tenant_users.zone_id
update public.tenant_users set zone_id = '30000000-0000-0000-0000-000000000002'
 where id = '50000000-0000-0000-0000-000000000007';
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,TER:Epe,ZONE:Lagos', 'TM zone follows the territory, not tenant_users.zone_id');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.chat_channels), 0, 'fintech agent sees no chat');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.chat_channels), 0, 'disabled user sees nothing');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.chat_channels where tenant_id = '10000000-0000-0000-0000-000000000001'),
          0, 'other tenant sees nothing');
select is(pg_temp.visible(), 'ANN@T2,ZONE:Lagos@T2', 'other tenant sees only its own channels');
reset role;

-- moved user: DA moves Ikeja → Epe
update public.tenant_users set territory_id = '40000000-0000-0000-0000-000000000002'
 where id = '50000000-0000-0000-0000-000000000005';
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is(pg_temp.visible(), 'ANN,DIR:D1,TER:Epe', 'moved DSA follows the move at once');
select is((select count(*)::int from public.chat_messages where channel_id = '70000000-0000-0000-0000-000000000001'),
          2, 'direct history survives a move');
select is((select count(*)::int from public.chat_read_state), 0, 'old room read state is gone with the room');
reset role;

-- §7.6: DA2 becomes a fintech agent — DA2 loses everything, DA keeps the history
update public.tenant_users set role = 'POS_AGENT', reports_to_id = null
 where id = '50000000-0000-0000-0000-000000000006';
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.chat_channels), 0, 'a staff member turned fintech agent sees nothing');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.chat_messages where channel_id = '70000000-0000-0000-0000-000000000001'),
          2, 'the partner''s status does not hide the history');
reset role;

-- ── Realtime ────────────────────────────────────────────────────────────
select ok(exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages'),
          'messages in Realtime');
select ok(exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_channels'),
          'channels in Realtime');

select * from finish();
rollback;
