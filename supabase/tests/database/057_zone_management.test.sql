-- Addendum A6 §17 (Task 1d, fix round 1) — zones and ZSMs belong to the
-- platform: appoint_zone_manager, create_zone and set_zone_zsm are audited
-- platform-administrator RPCs; a ZSM only edits their own zone's boundary.
begin;
create extension if not exists pgtap with schema extensions;

select plan(37);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- A = Nestle (ACTIVE), B = Unilever (ACTIVE), C = Cadbury (SUSPENDED)
-- 01 platform admin · 02 Z (ZSM at A) · 03 Z2 (ZSM at A) · 04 appointee
-- · 05 INVITED ZSM at A · 06 ZSM at B · 07 TM at A · 08 unconfirmed phone
insert into public.tenants (id, name, code, status) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE',   'ACTIVE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER', 'ACTIVE'),
  ('10000000-0000-0000-0000-000000000003', 'Cadbury Nigeria',  'CADBURY',  'SUSPENDED');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0'), now()
from generate_series(1, 7) n;
insert into auth.users (id, phone) values ('20000000-0000-0000-0000-000000000008', '2348000000008');
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN' where id = '20000000-0000-0000-0000-000000000001';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Ogun',  'OG');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSM', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'ZSM', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'ZSM', null, 'INVITED', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000006', 'ZSM', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007', 'TM',
   '40000000-0000-0000-0000-000000000001', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000003' where id = '30000000-0000-0000-0000-000000000002';

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n int) returns uuid language sql as $$
  select ('e7000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(int) to authenticated;

-- ── grants ──────────────────────────────────────────────────────────────
select ok(has_function_privilege('authenticated', 'public.appoint_zone_manager(uuid,uuid,text)', 'execute')
          and not has_function_privilege('anon', 'public.appoint_zone_manager(uuid,uuid,text)', 'execute')
          and has_function_privilege('authenticated', 'public.create_zone(uuid,uuid,text)', 'execute')
          and not has_function_privilege('anon', 'public.create_zone(uuid,uuid,text)', 'execute')
          and has_function_privilege('authenticated', 'public.set_zone_zsm(uuid,uuid,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.set_zone_zsm(uuid,uuid,uuid)', 'execute'),
  'the three zone RPCs are for authenticated callers, never anon');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=public, pg_temp'])
             from pg_proc p where p.oid in ('public.appoint_zone_manager(uuid,uuid,text)'::regprocedure,
                                            'public.create_zone(uuid,uuid,text)'::regprocedure,
                                            'public.set_zone_zsm(uuid,uuid,uuid)'::regprocedure)),
  'the zone RPCs are SECURITY DEFINER with search_path pinned');

-- ── appoint_zone_manager ────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select is(public.appoint_zone_manager(pg_temp.k(1), '10000000-0000-0000-0000-000000000001', '2348000000004') ->> 'status',
  'INVITED', 'a platform administrator appoints a ZSM (INVITED)');
select is(public.appoint_zone_manager(pg_temp.k(1), '10000000-0000-0000-0000-000000000001', '2348000000004'),
          public.appoint_zone_manager(pg_temp.k(1), '10000000-0000-0000-0000-000000000001', '2348000000004'),
  'a replayed appointment returns the same response');
select throws_ok(
  $$select public.appoint_zone_manager(pg_temp.k(2), '10000000-0000-0000-0000-000000000001', '2348000000004')$$,
  '23505', 'this person is already a member of the tenant', 'appointing an existing member is 23505');
select throws_ok(
  $$select public.appoint_zone_manager(pg_temp.k(3), '10000000-0000-0000-0000-000000000003', '2348000000004')$$,
  'P0001', 'the tenant is not active', 'a suspended tenant gets no ZSM');
select throws_ok(
  $$select public.appoint_zone_manager(pg_temp.k(4), '10000000-0000-0000-0000-000000000002', '2348000000008')$$,
  'P0001', null, 'an unconfirmed phone cannot be appointed');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.appoint_zone_manager(pg_temp.k(5), '10000000-0000-0000-0000-000000000001', '2348000000006')$$,
  '42501', null, 'a ZSM cannot appoint a ZSM');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(6), '+2348000000006', 'ZSM', null, null)$$,
  '42501', 'only a platform administrator appoints a ZSM', 'invite_tenant_user still refuses a ZSM invite');
reset role;
select results_eq(
  $$select role::text, status::text, zone_id from public.tenant_users
     where tenant_id = '10000000-0000-0000-0000-000000000001' and profile_id = '20000000-0000-0000-0000-000000000004'$$,
  $$values ('ZSM', 'INVITED', null::uuid)$$, 'the appointee is an INVITED ZSM with no zone');
select is((select count(*)::int from public.notifications
            where user_id = '20000000-0000-0000-0000-000000000004' and kind = 'TENANT_INVITE'), 1,
  'the appointee is notified once');
select is((select count(*)::int from public.audit_logs
            where operation = 'appoint_zone_manager' and idempotency_key = pg_temp.k(1)
              and actor_id = '20000000-0000-0000-0000-000000000001'), 1,
  'the appointment is audited once');

-- ── create_zone ─────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select is(public.create_zone(pg_temp.k(10), '10000000-0000-0000-0000-000000000001', 'oy') ->> 'zone_name',
  'Oyo', 'a platform administrator creates a zone named after its state');
select throws_ok(
  $$select public.create_zone(pg_temp.k(11), '10000000-0000-0000-0000-000000000001', 'LA')$$,
  '23505', 'this tenant already has a zone for that state', 'one zone per state per tenant');
select throws_ok(
  $$select public.create_zone(pg_temp.k(12), '10000000-0000-0000-0000-000000000001', 'XX')$$,
  'P0001', 'unknown state code', 'an unknown state code is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.create_zone(pg_temp.k(13), '10000000-0000-0000-0000-000000000001', 'KN')$$,
  '42501', null, 'a ZSM cannot create a zone');
reset role;
select results_eq(
  $$select state_code, zsm_id from public.zones where tenant_id = '10000000-0000-0000-0000-000000000001' and zone_name = 'Oyo'$$,
  $$values ('OY'::text, null::uuid)$$, 'the new zone carries its state code and no ZSM');
select is((select count(*)::int from public.chat_channels c join public.zones z on z.id = c.zone_id
            where z.zone_name = 'Oyo' and c.channel_type = 'ZONE'), 1, 'the new zone has its ZONE chat channel');
select is((select count(*)::int from public.audit_logs where operation = 'create_zone' and idempotency_key = pg_temp.k(10)), 1,
  'zone creation is audited');

-- ── set_zone_zsm ────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select is(public.set_zone_zsm(pg_temp.k(20), '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002') ->> 'zsm_id',
  '20000000-0000-0000-0000-000000000002', 'a platform administrator assigns Lagos to Z');
select is(public.set_zone_zsm(pg_temp.k(21), '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003') ->> 'zsm_id',
  '20000000-0000-0000-0000-000000000003', 'and reassigns it to Z2');
select is(public.set_zone_zsm(pg_temp.k(22), '30000000-0000-0000-0000-000000000001', null) ->> 'zsm_id',
  null, 'and clears its coverage');
select is(public.set_zone_zsm(pg_temp.k(23), '30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002') ->> 'zsm_id',
  '20000000-0000-0000-0000-000000000002', 'and assigns Z again');
select throws_ok(
  $$select public.set_zone_zsm(pg_temp.k(24), '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005')$$,
  'P0001', 'the zone manager must be an active ZSM of this tenant', 'an INVITED ZSM cannot take a zone');
select throws_ok(
  $$select public.set_zone_zsm(pg_temp.k(25), '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000006')$$,
  'P0001', 'the zone manager must be an active ZSM of this tenant', 'a ZSM of another tenant cannot take the zone');
select throws_ok(
  $$select public.set_zone_zsm(pg_temp.k(26), '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007')$$,
  'P0001', 'the zone manager must be an active ZSM of this tenant', 'a TM cannot take a zone');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_zone_zsm(pg_temp.k(27), '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'a ZSM cannot assign zones');
reset role;
select is((select zsm_id from public.zones where id = '30000000-0000-0000-0000-000000000002'),
  '20000000-0000-0000-0000-000000000003'::uuid, 'the refused calls changed nothing');
select results_eq(
  $$select before ->> 'zsm_id', after ->> 'zsm_id', actor_id::text from public.audit_logs
     where operation = 'set_zone_zsm' and idempotency_key = pg_temp.k(21)$$,
  $$values ('20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001')$$,
  'set_zone_zsm audits zsm_id before and after, and the platform actor');
select is((select tenant_id from public.audit_logs where operation = 'set_zone_zsm' and idempotency_key = pg_temp.k(21)),
  '10000000-0000-0000-0000-000000000001'::uuid, 'the audit lands in the zone''s tenant');

-- ── upsert_zone: a ZSM edits only their own zone, never its state ───────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_zone(pg_temp.k(30), null, 'Kano', null)$$,
  '42501', 'zones are created by a platform administrator', 'a ZSM cannot create a zone through upsert_zone');
select throws_ok(
  $$select public.upsert_zone(pg_temp.k(31), '30000000-0000-0000-0000-000000000002', 'Ogun', null)$$,
  '42501', 'this zone is not yours', 'a ZSM cannot edit another ZSM''s zone');
select throws_ok(
  $$select public.upsert_zone(pg_temp.k(32), '30000000-0000-0000-0000-000000000001', 'Lagos Mainland', null)$$,
  'P0001', 'a zone is named after its state', 'a zone cannot be renamed away from its state');
select lives_ok(
  $$select public.upsert_zone(pg_temp.k(33), '30000000-0000-0000-0000-000000000001', 'lagos',
      '{"type":"Polygon","coordinates":[[[3.1,6.4],[3.6,6.4],[3.6,6.7],[3.1,6.7],[3.1,6.4]]]}')$$,
  'a ZSM edits their own zone''s boundary');
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_zone(pg_temp.k(34), '30000000-0000-0000-0000-000000000001', 'Lagos', null)$$,
  '42501', null, 'a TM cannot edit a zone');
reset role;
select results_eq(
  $$select zone_name, extensions.geometrytype(boundary) from public.zones where id = '30000000-0000-0000-0000-000000000001'$$,
  $$values ('Lagos'::text, 'MULTIPOLYGON'::text)$$, 'the boundary changed and the name stayed the state''s');
select is((select count(*)::int from public.audit_logs where operation = 'upsert_zone' and idempotency_key = pg_temp.k(33)), 1,
  'the boundary edit is audited');

select * from finish();
rollback;
