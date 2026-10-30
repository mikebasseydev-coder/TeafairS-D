-- Addendum A6 §17 (Task 1d) — the Teafair field structure: zones are
-- states, and one Teafair ZSM covers several zones across tenants through
-- zones.zsm_id. Every check that used "the ZSM's zone" now uses "one of the
-- ZSM's zones"; a single zone comes from the object in hand.
begin;
create extension if not exists pgtap with schema extensions;

select plan(54);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- A = Nestle, B = Unilever.
-- 01 Z: ZSM at A (Lagos + Ogun) and at B (Lagos) · 02 Z2: ZSM at A (Oyo)
-- 03-08 invitees · 09 TM Abeokuta (A) · 10 TM Ibadan (A)
-- 11 ZSA Ogun (A) · 14 ZSA Lagos (A) · 12 shop owner
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0'), now()
from generate_series(1, 14) n;

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000032', '10000000-0000-0000-0000-000000000001', 'Ogun',  'OG'),
  ('30000000-0000-0000-0000-000000000033', '10000000-0000-0000-0000-000000000001', 'Oyo',   'OY'),
  ('30000000-0000-0000-0000-000000000034', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000035', '10000000-0000-0000-0000-000000000002', 'Ogun',  'OG');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000031', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000042', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000032', 'Abeokuta'),
  ('40000000-0000-0000-0000-000000000043', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000033', 'Ibadan'),
  ('40000000-0000-0000-0000-000000000044', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000034', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000045', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000035', 'Abeokuta');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000051', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000052', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000053', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000059', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000009',
   'TM', null, '40000000-0000-0000-0000-000000000042', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000060', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000010',
   'TM', null, '40000000-0000-0000-0000-000000000043', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000061', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011',
   'ZSA', '30000000-0000-0000-0000-000000000032', null, '50000000-0000-0000-0000-000000000051', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000064', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000014',
   'ZSA', '30000000-0000-0000-0000-000000000031', null, '50000000-0000-0000-0000-000000000051', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id in ('30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000032',
              '30000000-0000-0000-0000-000000000034');
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000002'
 where id = '30000000-0000-0000-0000-000000000033';

-- web routing: Ogun and Oyo state coverage, territories without a TM manager
insert into public.territory_coverage (tenant_id, state_code, territory_id) values
  ('10000000-0000-0000-0000-000000000001', 'OG', '40000000-0000-0000-0000-000000000042'),
  ('10000000-0000-0000-0000-000000000001', 'OY', '40000000-0000-0000-0000-000000000043');

-- a pre-purchase ticket for assign_ticket
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, status) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'TK-ZZZZZ1', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000041', 'OPEN');

-- chat: one message in the Ogun and Oyo ZONE rooms
insert into public.chat_messages (id, tenant_id, channel_id, sender_id, body)
select ('61000000-0000-0000-0000-0000000000' || right(z.id::text, 2))::uuid, c.tenant_id, c.id,
       '20000000-0000-0000-0000-000000000009', 'hello'
  from public.zones z join public.chat_channels c on c.zone_id = z.id and c.channel_type = 'ZONE'
 where z.id in ('30000000-0000-0000-0000-000000000032', '30000000-0000-0000-0000-000000000033');

-- Monvelo: enabled at A, an area in Abeokuta (Ogun) and in Ikeja (Lagos), two shops
insert into public.monvelo_tenant_settings (tenant_id, enabled) values ('10000000-0000-0000-0000-000000000001', true);
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('70000000-0000-0000-0000-000000000071', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000042', 'Kuto'),
  ('70000000-0000-0000-0000-000000000072', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000041', 'Allen');
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text)
select ('80000000-0000-0000-0000-00000000008' || n)::uuid, 'Shop ' || n, '+23480311100' || n,
       '20000000-0000-0000-0000-000000000012', 'SUBURBAN',
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street ' || n
from generate_series(1, 2) n;
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── zones are states ────────────────────────────────────────────────────
select has_column('public', 'zones', 'state_code', 'zones.state_code exists');
select col_not_null('public', 'zones', 'state_code', 'zones.state_code is NOT NULL');
select fk_ok('public', 'zones', 'state_code', 'public', 'ng_states', 'code', 'zones.state_code references ng_states');
select has_index('public', 'zones', 'idx_zones_state_code', 'state_code'::name, 'zones.state_code is indexed');
select throws_ok(
  $$insert into public.zones (tenant_id, zone_name, state_code)
    values ('10000000-0000-0000-0000-000000000001', 'Lagos Two', 'LA')$$,
  '23505', null, 'a second Lagos zone in the same tenant is refused');
select lives_ok(
  $$insert into public.zones (tenant_id, zone_name, state_code)
    values ('10000000-0000-0000-0000-000000000002', 'Oyo', 'OY')$$,
  'another tenant has its own Oyo zone');

-- ── one ZSM, many zones ─────────────────────────────────────────────────
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, zone_id, status)
    values ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'ZSM',
            '30000000-0000-0000-0000-000000000035', 'ACTIVE')$$,
  '23514', null, 'a ZSM membership with a zone_id is refused');
select is((select count(*)::int from public.tenant_users where role = 'ZSM' and zone_id is not null), 0,
  'no ZSM membership carries a zone');
select ok(not has_function_privilege('authenticated', 'public.zsm_zone_ids(uuid,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.zsm_zone_ids(uuid,uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.zsm_zone_ids(uuid,uuid)', 'execute'),
  'zsm_zone_ids is internal');
select ok((select p.prosecdef and p.provolatile = 's' and p.proconfig @> array['search_path=public, pg_temp']
             from pg_proc p where p.oid = 'public.zsm_zone_ids(uuid,uuid)'::regprocedure),
  'zsm_zone_ids is SECURITY DEFINER, STABLE, search_path pinned');
select ok(has_function_privilege('authenticated', 'public.my_zsm_zone_ids()', 'execute')
          and not has_function_privilege('anon', 'public.my_zsm_zone_ids()', 'execute'),
  'my_zsm_zone_ids is for authenticated callers');
select ok(not has_function_privilege('authenticated', 'public.chat_staff_zone_ids(uuid,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.chat_staff_zone_ids(uuid,uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.chat_staff_zone_ids(uuid,uuid)', 'execute')
          and not has_function_privilege('authenticated', 'public.zone_state_backfill()', 'execute')
          and not has_function_privilege('service_role', 'public.zone_state_backfill()', 'execute'),
  'chat_staff_zone_ids and zone_state_backfill are internal');
select is(array(select z from public.zsm_zone_ids('10000000-0000-0000-0000-000000000001',
                                                   '20000000-0000-0000-0000-000000000001') z order by z),
  array['30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000032']::uuid[],
  'Z covers Lagos and Ogun at A');
select is(array(select public.zsm_zone_ids('10000000-0000-0000-0000-000000000002',
                                            '20000000-0000-0000-0000-000000000001')),
  array['30000000-0000-0000-0000-000000000034']::uuid[], 'Z covers Lagos at B');
select is(array(select public.zsm_zone_ids('10000000-0000-0000-0000-000000000001',
                                            '20000000-0000-0000-0000-000000000009')),
  '{}'::uuid[], 'a TM covers no zone, even if named nowhere');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(array(select z from public.my_zsm_zone_ids() z order by z),
  array['30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000032']::uuid[],
  'my_zsm_zone_ids: Z''s zones in the active tenant A');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
-- A6 §18.3 (user ruling 2026-10-30): zones with no ACTIVE ZSM stay within
-- reach of every ACTIVE ZSM of the tenant; B's Ogun and Oyo have none
select is(array(select z from public.my_zsm_zone_ids() z order by z),
  array(select z.id from public.zones z
         where z.tenant_id = '10000000-0000-0000-0000-000000000002'
           and z.state_code in ('LA', 'OG', 'OY') order by z.id),
  'my_zsm_zone_ids: Z''s zones in the active tenant B (Lagos covered; Ogun and Oyo uncovered)');
reset role;

-- ── invite_tenant_user: "the territory is in one of my zones" ───────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000001', '+2348000000003', 'TM',
      '40000000-0000-0000-0000-000000000042', null)$$,
  'Z invites a TM into an Ogun territory');
select lives_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000002', '+2348000000004', 'TM',
      '40000000-0000-0000-0000-000000000041', null)$$,
  'Z invites a TM into a Lagos territory');
select throws_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000003', '+2348000000005', 'TM',
      '40000000-0000-0000-0000-000000000043', null)$$,
  '42501', null, 'Z cannot invite into Oyo, which another ZSM covers');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
select lives_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000004', '+2348000000005', 'TM',
      '40000000-0000-0000-0000-000000000044', null)$$,
  'at B, Z invites into B''s Lagos territory');
-- B's Ogun has no ZSM: Z, B's only ZSM, may invite there (A6 §18.3)
select lives_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000005', '+2348000000006', 'TM',
      '40000000-0000-0000-0000-000000000045', null)$$,
  'at B, Z invites into B''s uncovered Ogun (no ZSM covers it at B)');
select throws_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000006', '+2348000000006', 'TM',
      '40000000-0000-0000-0000-000000000042', null)$$,
  '42501', null, 'at B, Z cannot invite into A''s Ogun territory');
reset role;
select is((select count(*)::int from public.tenant_users
            where profile_id in ('20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000004',
                                 '20000000-0000-0000-0000-000000000005') and role = 'TM' and status = 'INVITED'),
  3, 'three TM invitations were written');

-- ZSA: the zone of the territory in hand, or the ZSM's only zone
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000007', '+2348000000007', 'ZSA',
      '40000000-0000-0000-0000-000000000042', '50000000-0000-0000-0000-000000000051')$$,
  'Z invites a ZSA naming an Ogun territory');
select throws_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000008', '+2348000000006', 'ZSA',
      null, '50000000-0000-0000-0000-000000000051')$$,
  'P0001', 'a ZSM covering several zones names a territory of the ZSA''s zone',
  'a multi-zone ZSM must name a territory for a ZSA (never an arbitrary zone)');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000009', '+2348000000008', 'ZSA',
      null, '50000000-0000-0000-0000-000000000053')$$,
  'a single-zone ZSM invites a ZSA without a territory, as before');
select throws_ok(
  $$select public.invite_tenant_user('d0000000-0000-0000-0000-000000000010', '+2348000000006', 'ZSA',
      '40000000-0000-0000-0000-000000000043', '50000000-0000-0000-0000-000000000051')$$,
  'P0001', 'a ZSA reports to a ZSM of the zone', 'a ZSA cannot report to a ZSM who does not cover the zone');
reset role;
select is(array(select zone_id from public.tenant_users
                 where profile_id in ('20000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000008')
                 order by profile_id),
  array['30000000-0000-0000-0000-000000000032', '30000000-0000-0000-0000-000000000033']::uuid[],
  'the ZSAs take the territory''s zone and the single zone');

-- ── upsert_territory and upsert_area ────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_territory('d1000000-0000-0000-0000-000000000001', null,
      '30000000-0000-0000-0000-000000000031', 'Surulere', null)$$,
  'Z creates a territory in Lagos');
select lives_ok(
  $$select public.upsert_territory('d1000000-0000-0000-0000-000000000002', null,
      '30000000-0000-0000-0000-000000000032', 'Ijebu', null)$$,
  'Z creates a territory in Ogun');
select throws_ok(
  $$select public.upsert_territory('d1000000-0000-0000-0000-000000000003', null,
      '30000000-0000-0000-0000-000000000033', 'Ogbomosho', null)$$,
  '42501', null, 'Z cannot create a territory in Oyo');
select lives_ok(
  $$select public.upsert_territory('d1000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000042',
      '30000000-0000-0000-0000-000000000032', 'Abeokuta North', null)$$,
  'Z renames an Ogun territory');
select throws_ok(
  $$select public.upsert_territory('d1000000-0000-0000-0000-000000000005', '40000000-0000-0000-0000-000000000043',
      '30000000-0000-0000-0000-000000000032', 'Hijack', null)$$,
  'P0001', 'territory not found in your zone', 'an Oyo territory cannot be edited through Z''s Ogun zone');
select lives_ok(
  $$select public.upsert_area('d1000000-0000-0000-0000-000000000006', null,
      '40000000-0000-0000-0000-000000000041', 'Opebi')$$,
  'Z creates an area in a Lagos territory');
select lives_ok(
  $$select public.upsert_area('d1000000-0000-0000-0000-000000000007', null,
      '40000000-0000-0000-0000-000000000042', 'Lafenwa')$$,
  'Z creates an area in an Ogun territory');
select throws_ok(
  $$select public.upsert_area('d1000000-0000-0000-0000-000000000008', null,
      '40000000-0000-0000-0000-000000000043', 'Bodija')$$,
  '42501', null, 'Z cannot create an area in an Oyo territory');

-- (zone creation and upsert_zone edits: see 057, A6 §17 fix round 1)
reset role;

-- ── chat ────────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(array(select c.zone_id from public.chat_channels c
                 where c.tenant_id = '10000000-0000-0000-0000-000000000001' and c.channel_type = 'ZONE'
                   and c.zone_id in ('30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000032',
                                     '30000000-0000-0000-0000-000000000033')
                 order by c.zone_id),
  array['30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000032']::uuid[],
  'Z is in both ZONE channels of tenant A, not Oyo''s');
select is(array(select c.territory_id from public.chat_channels c
                 where c.channel_type = 'TERRITORY'
                   and c.territory_id in ('40000000-0000-0000-0000-000000000041', '40000000-0000-0000-0000-000000000042',
                                          '40000000-0000-0000-0000-000000000043')
                 order by c.territory_id),
  array['40000000-0000-0000-0000-000000000041', '40000000-0000-0000-0000-000000000042']::uuid[],
  'Z sees the territory rooms of both zones');
select lives_ok(
  $$select public.hide_chat_message('d2000000-0000-0000-0000-000000000001',
      '61000000-0000-0000-0000-000000000032', 'off topic')$$,
  'Z moderates the Ogun zone room');
select throws_ok(
  $$select public.hide_chat_message('d2000000-0000-0000-0000-000000000002',
      '61000000-0000-0000-0000-000000000033', 'off topic')$$,
  '42501', 'this room is outside your zone', 'Z cannot moderate the Oyo zone room');
select lives_ok(
  $$select public.get_or_create_direct_channel('d2000000-0000-0000-0000-000000000003',
      '20000000-0000-0000-0000-000000000009')$$,
  'Z opens a direct chat with the Abeokuta (Ogun) TM');
select throws_ok(
  $$select public.get_or_create_direct_channel('d2000000-0000-0000-0000-000000000004',
      '20000000-0000-0000-0000-000000000010')$$,
  '42501', null, 'Z may not open a direct chat with the Ibadan (Oyo) TM');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is(array(select c.zone_id from public.chat_channels c
                 where c.tenant_id = '10000000-0000-0000-0000-000000000001' and c.channel_type = 'ZONE'),
  array['30000000-0000-0000-0000-000000000033']::uuid[], 'Z2 is in the Oyo ZONE channel only');
reset role;
select is(array[public.chat_staff_zone('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
                public.chat_staff_zone('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002')],
  array[null, '30000000-0000-0000-0000-000000000033']::uuid[],
  'chat_staff_zone: no single zone for a multi-zone ZSM; the one zone for a single-zone ZSM');

-- ── routing by the object's zone (mirrors 014 and 021) ──────────────────
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null,
            (select id from public.ng_lgas where state_code = 'OG' and name = 'Abeokuta South'))).accountable_id,
  '20000000-0000-0000-0000-000000000001'::uuid, 'web routing in Ogun falls back to Ogun''s ZSM (multi-zone Z)');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null,
            (select id from public.ng_lgas where state_code = 'OY' limit 1))).accountable_id,
  '20000000-0000-0000-0000-000000000002'::uuid, 'web routing in Oyo falls back to Oyo''s ZSM (single-zone Z2)');
-- assign_ticket: no territory has a TM manager here, so the accountable
-- person is the ZSM of the target territory's zone. A ZSM routes only within
-- their own zones (A6 §18.3), so the ticket starts with no territory and Oyo's
-- ZSM routes it into Oyo.
update public.support_tickets set territory_id = null where id = '60000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
do $$ begin perform public.assign_ticket('d3000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000043'); end $$;
reset role;
select is((select accountable_id from public.support_tickets where id = '60000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-000000000002'::uuid, 'assign_ticket into Oyo: accountable is Oyo''s ZSM (single-zone)');
update public.support_tickets set territory_id = null where id = '60000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
do $$ begin perform public.assign_ticket('d3000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000042'); end $$;
reset role;
select is((select accountable_id from public.support_tickets where id = '60000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-000000000001'::uuid, 'assign_ticket into Ogun: accountable is the multi-zone Z, by the territory''s zone');

-- ── Monvelo: a ZSA of either of Z's zones enrols a shop ─────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.c1', public.start_monvelo_consent(
  'd4000000-0000-0000-0000-000000000001', 'test-gw-secret',
  '80000000-0000-0000-0000-000000000081', '70000000-0000-0000-0000-000000000071')::text, true); end $$;
select is(public.enrol_monvelo_shop('d4000000-0000-0000-0000-000000000002',
            (current_setting('test.c1')::jsonb ->> 'challenge_id')::uuid,
            current_setting('test.c1')::jsonb ->> 'code') ->> 'enrolled',
  'true', 'the Ogun ZSA under Z enrols a shop in an Ogun area');
select pg_temp.act_as('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.c2', public.start_monvelo_consent(
  'd4000000-0000-0000-0000-000000000003', 'test-gw-secret',
  '80000000-0000-0000-0000-000000000082', '70000000-0000-0000-0000-000000000072')::text, true); end $$;
select is(public.enrol_monvelo_shop('d4000000-0000-0000-0000-000000000004',
            (current_setting('test.c2')::jsonb ->> 'challenge_id')::uuid,
            current_setting('test.c2')::jsonb ->> 'code') ->> 'enrolled',
  'true', 'the Lagos ZSA under Z enrols a shop in a Lagos area');
reset role;
select is((select count(*)::int from public.retail_shops
            where id in ('80000000-0000-0000-0000-000000000081', '80000000-0000-0000-0000-000000000082')
              and shop_code ~ '^SH-[A-Z2-7]{6}$'),
  2, 'monvelo_assign_shop_code gave both shops a code');

-- ── the backfill fails loudly on a zone that names no state ─────────────
-- (inside throws_like's subtransaction: the NOT NULL drop and the row roll back)
create function pg_temp.backfill_probe() returns void language plpgsql as $f$
begin
  alter table public.zones alter column state_code drop not null;
  insert into public.zones (id, tenant_id, zone_name)
  values ('30000000-0000-0000-0000-000000000099', '10000000-0000-0000-0000-000000000002', 'Ibadan');
  perform public.zone_state_backfill();
end;
$f$;
select throws_like('select pg_temp.backfill_probe()',
  'zones whose name matches no Nigerian state: Ibadan (zone 30000000-0000-0000-0000-000000000099%',
  'the backfill names the zone it cannot match and fails');
select col_not_null('public', 'zones', 'state_code', 'the probe rolled back: state_code is still NOT NULL');

select * from finish();
rollback;
