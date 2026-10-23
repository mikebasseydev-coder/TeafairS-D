-- Addendum A4 4.2-4.5: post_chat_message, mark_chat_read, list_my_chat_channels.
begin;
create extension if not exists pgtap with schema extensions;

select plan(41);

-- ── fixtures (plan "common fixture shape") ──────────────────────────────
-- T1: zone Lagos (ZSM Z) with Ikeja (TM TA, ASM AA, DSM MA, DSA DA, DSA DA2,
-- FINTECH_AGENT F, DISABLED DSA X) and Epe (TM TB, DSA DB); zone Kano with
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
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
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
  (select id from public.chat_channels where channel_type = 'ANNOUNCEMENT' and tenant_id = '10000000-0000-0000-0000-000000000001') as ann;
grant select on ids to authenticated;

-- ── posting scope ───────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is(public.post_chat_message('b0000000-0000-0000-0000-000000000001', (select ikeja from ids), 'secret-body-xyz') ? 'message_id', true, 'DSA posts in the team room');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000002', (select epe from ids), 'hi')$$, '42501', null, 'not another territory');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000003', (select lagos from ids), 'hi')$$, '42501', null, 'DSA not in the zone room');
select is(public.post_chat_message('b0000000-0000-0000-0000-000000000001', (select ikeja from ids), 'secret-body-xyz') ? 'message_id', true, 'replay returns the stored reply');
reset role;
select is((select count(*)::int from public.chat_messages where body = 'secret-body-xyz'), 1, 'replay wrote one message');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000004', (select lagos from ids), 'zone hello')$$, 'TM posts in the zone room');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000005', (select ann from ids), 'hi')$$, '42501', null, 'only ZSMs announce');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000006', (select ann from ids), 'big news')$$, 'ZSM announces');
reset role;

select is((select array_agg(user_id order by user_id) from public.notifications where kind = 'CHAT_ANNOUNCEMENT'),
          (select array_agg(profile_id order by profile_id) from public.tenant_users
            where tenant_id = '10000000-0000-0000-0000-000000000001' and status = 'ACTIVE'
              and role in ('ZSM','TM','ASM','DSM','DSA')
              and profile_id <> '20000000-0000-0000-0000-000000000001'),
          'announcement reaches available staff except the sender (not F, not X)');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(payload) k) = array['channel_id','message_id'])
             and bool_and(title = 'Announcement' and body = 'There is a new announcement.')
             from public.notifications where kind = 'CHAT_ANNOUNCEMENT'), 'fixed copy, payload ids only');
select is((select count(*)::int from public.notifications where kind = 'CHAT_MESSAGE'), 0, 'rooms do not notify');

-- ── direct ──────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
create temp table d1 as select (public.get_or_create_direct_channel('b1000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006') ->> 'channel_id')::uuid as id;
grant select on d1 to authenticated;
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000007', (select id from d1), 'direct one')$$, 'DSA posts in the direct chat');
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000008', (select ikeja from ids), 'second room post')$$, 'DSA posts again in the room');
reset role;
select is((select count(*)::int from public.notifications where kind = 'CHAT_MESSAGE' and user_id = '20000000-0000-0000-0000-000000000006'
             and title = 'New message' and body = 'You have a new message.'
             and payload ->> 'channel_id' = (select id::text from d1)), 1, 'direct message notifies the other person');
select is((select count(*)::int from public.notifications where kind = 'CHAT_MESSAGE' and user_id = '20000000-0000-0000-0000-000000000005'), 0, 'and not the sender');

-- ── inbox and read state ────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select j ->> 'channel_id' from public.list_my_chat_channels() j limit 1), (select ikeja::text from ids),
          'inbox ordered by activity (latest post first)');
select is((select (j ->> 'unread_count')::int from public.list_my_chat_channels() j where j ->> 'channel_id' = (select ikeja::text from ids)), 0, 'own posts are read');
select is((select j ->> 'other_profile_id' from public.list_my_chat_channels() j where j ->> 'channel_id' = (select id::text from d1)), '20000000-0000-0000-0000-000000000006', 'direct row names the other person');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select is((select (j ->> 'unread_count')::int from public.list_my_chat_channels() j where j ->> 'channel_id' = (select ikeja::text from ids)), 2, 'unread counts others only');
select is((select (j ->> 'unread_count')::int from public.list_my_chat_channels() j where j ->> 'channel_id' = (select id::text from d1)), 1, 'direct unread');
create temp table rd as select public.mark_chat_read('b2000000-0000-0000-0000-000000000001', (select ikeja from ids), clock_timestamp()) as r;
grant select on rd to authenticated;
select is((select (j ->> 'unread_count')::int from public.list_my_chat_channels() j where j ->> 'channel_id' = (select ikeja::text from ids)), 0, 'mark read clears');
select is((public.mark_chat_read('b2000000-0000-0000-0000-000000000002', (select ikeja from ids), '2000-01-01')) ->> 'last_read_at', (select r ->> 'last_read_at' from rd), 'read state moves forward only');
select throws_ok($$select public.mark_chat_read('b2000000-0000-0000-0000-000000000003', (select epe from ids), now())$$, '42501', null, 'cannot mark an invisible channel');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'mark_chat_read'), 0, 'mark read writes no audit');

select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.mark_chat_read('b2000000-0000-0000-0000-000000000004', (select ikeja from ids), null)$$, 'P0001', 'read_up_to is required', 'a null read_up_to is refused');
reset role;

-- a direct exchange DA <-> DA2 and a room post in Epe; a third-party TM (TA)
-- reads audit_logs tenant-wide and must learn nothing from them (§7.9)
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000013', (select id from d1), 'ping')$$, 'DA posts in the direct chat again');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000014', (select id from d1), 'pong')$$, 'DA2 replies');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000015', (select epe from ids), 'epe hello')$$, 'DB posts in the Epe room');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.audit_logs
            where operation like '%chat%' or operation like '%direct_channel%' or entity_type like 'chat%'),
          0, 'a third-party TM sees no chat-derived audit rows');
reset role;

-- 105 messages by others, inserted directly (posting them would hit the throttle)
insert into public.chat_messages (tenant_id, channel_id, sender_id, body)
select '10000000-0000-0000-0000-000000000001', (select ikeja from ids), '20000000-0000-0000-0000-000000000005', 'bulk ' || g
  from generate_series(1, 105) g;
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select is((select (j ->> 'unread_count')::int from public.list_my_chat_channels() j where j ->> 'channel_id' = (select ikeja::text from ids)), 100, 'unread is capped at 100');
reset role;

-- ── limits ──────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000009', (select epe from ids), repeat('x', 2001))$$, 'P0001', null, 'over 2000 refused');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000010', (select epe from ids), '   ')$$, 'P0001', null, 'blank refused');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000016', (select epe from ids), E'

	')$$, 'P0001', 'a message must be 1 to 2000 characters', 'a newline-only post is refused');
select lives_ok($$select count(public.post_chat_message(gen_random_uuid(), (select epe from ids), 'burst ' || g)) from generate_series(1, 20) g$$, '20 posts in a minute allowed');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000011', (select epe from ids), 'one too many')$$, 'P0001', 'Too many messages. Please wait a moment.', 'throttle');
reset role;

-- partner becomes unavailable: history stays readable, posting stops
update public.tenant_users set status = 'DISABLED' where profile_id = '20000000-0000-0000-0000-000000000006' and tenant_id = '10000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000017', (select id from d1), 'still there?')$$, 'P0001', 'this person is no longer available', 'cannot post to a disabled partner');
reset role;
update public.tenant_users set status = 'ACTIVE' where profile_id = '20000000-0000-0000-0000-000000000006' and tenant_id = '10000000-0000-0000-0000-000000000001';
update public.tenant_users set role = 'FINTECH_AGENT' where profile_id = '20000000-0000-0000-0000-000000000006' and tenant_id = '10000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.post_chat_message('b0000000-0000-0000-0000-000000000012', (select id from d1), 'anyone there')$$, 'P0001', 'this person is no longer available', 'cannot post to an unavailable partner');
select is((select count(*)::int from public.chat_messages where channel_id = (select id from d1)), 3, 'history still readable');
reset role;

select ok(not exists (select 1 from public.audit_logs where operation in ('post_chat_message', 'mark_chat_read')
                        and (coalesce(before::text, '') || coalesce(after::text, '')) ~ 'secret-body-xyz|direct one|big news'), 'no bodies in audit');
select is((select count(*)::int from public.audit_logs where operation = 'post_chat_message'), 0, 'posting writes no audit row');
select ok(not has_function_privilege('anon', 'public.post_chat_message(uuid,uuid,text)', 'execute'), 'not for anon');

select * from finish();
rollback;
