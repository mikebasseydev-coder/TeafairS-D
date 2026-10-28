-- Addendum A4 4.4: hide_chat_message and the grants sweep across A4.
begin;
create extension if not exists pgtap with schema extensions;

select plan(34);

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
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Kano'),
  ('30000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe'),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', 'Fagge');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000012',
   'ZSM', '30000000-0000-0000-0000-000000000009', null, null, 'ACTIVE', true);
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

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

create temp table ids as select
  (select id from public.chat_channels where channel_type = 'TERRITORY' and territory_id = '40000000-0000-0000-0000-000000000001') as ikeja,
  (select id from public.chat_channels where channel_type = 'TERRITORY' and territory_id = '40000000-0000-0000-0000-000000000002') as epe,
  (select id from public.chat_channels where channel_type = 'ZONE' and zone_id = '30000000-0000-0000-0000-000000000001') as lagos,
  (select id from public.chat_channels where channel_type = 'TERRITORY' and territory_id = '40000000-0000-0000-0000-000000000003') as fagge,
  (select id from public.chat_channels where channel_type = 'ANNOUNCEMENT' and tenant_id = '10000000-0000-0000-0000-000000000001') as ann;
grant select on ids to authenticated;

-- messages inserted directly (as the table owner)
create temp table m as select
  gen_random_uuid() as room, gen_random_uuid() as fagge, gen_random_uuid() as ann, gen_random_uuid() as dm;
grant select on m to authenticated;
insert into public.chat_messages (id, tenant_id, channel_id, sender_id, body)
values ((select room from m),  '10000000-0000-0000-0000-000000000001', (select ikeja from ids), '20000000-0000-0000-0000-000000000005', 'original-secret-body'),
       ((select fagge from m), '10000000-0000-0000-0000-000000000001', (select fagge from ids), '20000000-0000-0000-0000-000000000009', 'fagge post'),
       ((select ann from m),   '10000000-0000-0000-0000-000000000001', (select ann from ids),   '20000000-0000-0000-0000-000000000001', 'announcement post');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
create temp table d1 as select (public.get_or_create_direct_channel('b1000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006') ->> 'channel_id')::uuid as id;
reset role;
grant select on d1 to authenticated;
insert into public.chat_messages (id, tenant_id, channel_id, sender_id, body)
values (gen_random_uuid(), '10000000-0000-0000-0000-000000000001', (select id from d1), '20000000-0000-0000-0000-000000000005', 'direct post');
update m set dm = (select id from public.chat_messages where body = 'direct post');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.hide_chat_message('c0000000-0000-0000-0000-000000000001', (select room from m), 'spam') ? 'hidden_at', true, 'ZSM hides a room message');
reset role;
select is((select body from public.chat_messages where id = (select room from m)), '[removed]', 'body removed');
select ok((select a."after" is not null
             and (select array_agg(k order by k) from jsonb_object_keys(a."after") k) = array['channel_id','message_id','reason']
             and not exists (select 1 from public.audit_logs x where x."after"::text like '%original-secret-body%'
                                or x."before"::text like '%original-secret-body%')
           from public.audit_logs a where a.operation = 'CHAT_MESSAGE_HIDDEN' limit 1), 'audit has no body');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000002', (select fagge from m), 'x')$$, '42501', null, 'TM cannot moderate');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000003', (select dm from m), 'x')$$, '42501', null, 'direct chats cannot be moderated');
select throws_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000004', (select fagge from m), 'x')$$, '42501', null, 'only in own zone');
select lives_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000005', (select ann from m), 'off topic')$$, 'any ZSM moderates announcements');
select ok(public.hide_chat_message('c0000000-0000-0000-0000-000000000006', (select room from m), 'again') ? 'message_id', 'repeat hide returns the row');
select is((select hidden_at is not null from public.chat_messages where id = (select room from m)), true, 'still hidden after repeat');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'CHAT_MESSAGE_HIDDEN' and entity_id = (select room::text from m)), 1, 'repeat hide writes no second audit');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000007', (select room from m), '  ')$$, 'P0001', null, 'reason required');
select throws_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000008', gen_random_uuid(), 'x')$$, 'P0001', null, 'unknown message');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.hide_chat_message('c0000000-0000-0000-0000-000000000009', (select room from m), 'x')$$, 'P0001', null, 'other tenant sees no such message');
reset role;

-- ── grants across A4 ────────────────────────────────────────────────────
select ok(to_regprocedure('public.chat_is_available(uuid,uuid)') is not null and not has_function_privilege('anon', 'public.chat_is_available(uuid,uuid)', 'execute'), 'anon cannot execute chat_is_available');
select ok(to_regprocedure('public.chat_is_available(uuid,uuid)') is not null and not has_function_privilege('service_role', 'public.chat_is_available(uuid,uuid)', 'execute'), 'service_role cannot execute chat_is_available');
select ok(to_regprocedure('public.chat_staff_zone(uuid,uuid)') is not null and not has_function_privilege('anon', 'public.chat_staff_zone(uuid,uuid)', 'execute'), 'anon cannot execute chat_staff_zone');
select ok(to_regprocedure('public.chat_staff_zone(uuid,uuid)') is not null and not has_function_privilege('service_role', 'public.chat_staff_zone(uuid,uuid)', 'execute'), 'service_role cannot execute chat_staff_zone');
select ok(to_regprocedure('public.my_chat_channel_ids()') is not null and not has_function_privilege('anon', 'public.my_chat_channel_ids()', 'execute'), 'anon cannot execute my_chat_channel_ids');
select ok(to_regprocedure('public.my_chat_channel_ids()') is not null and not has_function_privilege('service_role', 'public.my_chat_channel_ids()', 'execute'), 'service_role cannot execute my_chat_channel_ids');
select ok(to_regprocedure('public.chat_create_group_channel()') is not null and not has_function_privilege('anon', 'public.chat_create_group_channel()', 'execute'), 'anon cannot execute chat_create_group_channel');
select ok(to_regprocedure('public.chat_create_group_channel()') is not null and not has_function_privilege('service_role', 'public.chat_create_group_channel()', 'execute'), 'service_role cannot execute chat_create_group_channel');
select ok(to_regprocedure('public.get_or_create_direct_channel(uuid,uuid)') is not null and not has_function_privilege('anon', 'public.get_or_create_direct_channel(uuid,uuid)', 'execute'), 'anon cannot execute get_or_create_direct_channel');
select ok(to_regprocedure('public.get_or_create_direct_channel(uuid,uuid)') is not null and not has_function_privilege('service_role', 'public.get_or_create_direct_channel(uuid,uuid)', 'execute'), 'service_role cannot execute get_or_create_direct_channel');
select ok(to_regprocedure('public.post_chat_message(uuid,uuid,text)') is not null and not has_function_privilege('anon', 'public.post_chat_message(uuid,uuid,text)', 'execute'), 'anon cannot execute post_chat_message');
select ok(to_regprocedure('public.post_chat_message(uuid,uuid,text)') is not null and not has_function_privilege('service_role', 'public.post_chat_message(uuid,uuid,text)', 'execute'), 'service_role cannot execute post_chat_message');
select ok(to_regprocedure('public.mark_chat_read(uuid,uuid,timestamptz)') is not null and not has_function_privilege('anon', 'public.mark_chat_read(uuid,uuid,timestamptz)', 'execute'), 'anon cannot execute mark_chat_read');
select ok(to_regprocedure('public.mark_chat_read(uuid,uuid,timestamptz)') is not null and not has_function_privilege('service_role', 'public.mark_chat_read(uuid,uuid,timestamptz)', 'execute'), 'service_role cannot execute mark_chat_read');
select ok(to_regprocedure('public.list_my_chat_channels()') is not null and not has_function_privilege('anon', 'public.list_my_chat_channels()', 'execute'), 'anon cannot execute list_my_chat_channels');
select ok(to_regprocedure('public.list_my_chat_channels()') is not null and not has_function_privilege('service_role', 'public.list_my_chat_channels()', 'execute'), 'service_role cannot execute list_my_chat_channels');
select ok(to_regprocedure('public.hide_chat_message(uuid,uuid,text)') is not null and not has_function_privilege('anon', 'public.hide_chat_message(uuid,uuid,text)', 'execute'), 'anon cannot execute hide_chat_message');
select ok(to_regprocedure('public.hide_chat_message(uuid,uuid,text)') is not null and not has_function_privilege('service_role', 'public.hide_chat_message(uuid,uuid,text)', 'execute'), 'service_role cannot execute hide_chat_message');
select ok(to_regprocedure('public.chat_is_available(uuid,uuid)') is not null and not has_function_privilege('authenticated', 'public.chat_is_available(uuid,uuid)', 'execute'), 'authenticated cannot execute chat_is_available');
select ok(to_regprocedure('public.chat_staff_zone(uuid,uuid)') is not null and not has_function_privilege('authenticated', 'public.chat_staff_zone(uuid,uuid)', 'execute'), 'authenticated cannot execute chat_staff_zone');
select ok(to_regprocedure('public.chat_create_group_channel()') is not null and not has_function_privilege('authenticated', 'public.chat_create_group_channel()', 'execute'), 'authenticated cannot execute chat_create_group_channel');

select * from finish();
rollback;
