-- Addendum A6 §3 (Monvelo Step 1) — areas, the ZSA / ASA anchors, their
-- invites and the platform-role gate.
begin;
create extension if not exists pgtap with schema extensions;

select plan(25);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');

-- 1 ZSM · 2 TM Ikeja · 3 plain member (DSA) · 4 TM Surulere · 5 ASA invitee
-- · 6 ZSA invitee · 7 ASM Ikeja · 8 MONVELO_OPERATOR with no tenant
-- · 9 Unilever TM · 10 MONVELO_FINANCE · 11 spare account for row-level checks
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
  ('20000000-0000-0000-0000-000000000011', '2348000000011', now());

update public.profiles set platform_role = 'MONVELO_OPERATOR'
 where id = '20000000-0000-0000-0000-000000000008';
update public.profiles set platform_role = 'MONVELO_FINANCE'
 where id = '20000000-0000-0000-0000-000000000010';

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Surulere'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TM', null, '40000000-0000-0000-0000-000000000004', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'ASM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── upsert_area ─────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000001', null,
      '40000000-0000-0000-0000-000000000001', 'Allen Avenue')$$,
  'the TM of a territory creates an area in it');
select lives_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000001', null,
      '40000000-0000-0000-0000-000000000001', 'Allen Avenue')$$,
  'the same key replays');
reset role;
select is(
  (select count(*)::int from public.areas
    where territory_id = '40000000-0000-0000-0000-000000000001' and area_name = 'Allen Avenue'),
  1, 'the replay did not create a second area');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'upsert_area' and idempotency_key = 'bbbbbbbb-0000-0000-0000-000000000001'),
  1, 'the area write is audited once');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000002', null,
      '40000000-0000-0000-0000-000000000001', 'Ikeja GRA')$$,
  '42501', null, 'the TM of another territory cannot create an area');

select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000004', null,
      '40000000-0000-0000-0000-000000000001', 'Ikeja GRA')$$,
  '42501', null, 'a TM of another tenant cannot create an area in this tenant''s territory');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000005', null,
      '40000000-0000-0000-0000-000000000004', 'Adeniran')$$,
  'the ZSM of the zone creates an area in any territory of it');
select lives_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000006',
      (select id from public.areas where area_name = 'Adeniran'),
      '40000000-0000-0000-0000-000000000004', 'Adeniran Ogunsanya')$$,
  'the ZSM renames an area');
select throws_ok(
  $$select public.upsert_area('bbbbbbbb-0000-0000-0000-000000000007',
      (select id from public.areas where area_name = 'Allen Avenue'),
      '40000000-0000-0000-0000-000000000004', 'Moved')$$,
  'P0001', 'area not found in this territory', 'an area is only edited through its own territory');

-- ── invite_tenant_user: ASA ─────────────────────────────────────────────
select throws_ok(
  $$select public.invite_tenant_user('bbbbbbbb-0000-0000-0000-000000000010', '+2348000000005', 'ASA',
      '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007',
      (select id from public.areas where area_name = 'Adeniran Ogunsanya'))$$,
  '42501', null, 'an ASA invite with an area of another territory is refused');
select throws_ok(
  $$select public.invite_tenant_user('bbbbbbbb-0000-0000-0000-000000000011', '+2348000000005', 'ASA',
      '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007')$$,
  'P0001', 'ASA requires an area', 'an ASA invite without an area is refused');
select throws_ok(
  $$select public.invite_tenant_user('bbbbbbbb-0000-0000-0000-000000000012', '+2348000000005', 'ASA',
      '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003',
      (select id from public.areas where area_name = 'Allen Avenue'))$$,
  'P0001', 'an ASA reports to an ASM or TM of the territory', 'an ASA cannot report to a DSM');
select lives_ok(
  $$select public.invite_tenant_user('bbbbbbbb-0000-0000-0000-000000000013', '+2348000000005', 'ASA',
      '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007',
      (select id from public.areas where area_name = 'Allen Avenue'))$$,
  'a ZSM invites an ASA into an area of a territory of the zone');

-- ── invite_tenant_user: ZSA ─────────────────────────────────────────────
select throws_ok(
  $$select public.invite_tenant_user('bbbbbbbb-0000-0000-0000-000000000014', '+2348000000006', 'ZSA',
      null, '50000000-0000-0000-0000-000000000002')$$,
  'P0001', 'a ZSA reports to a ZSM of the zone', 'a ZSA cannot report to a TM');
select lives_ok(
  $$select public.invite_tenant_user('bbbbbbbb-0000-0000-0000-000000000015', '+2348000000006', 'ZSA',
      null, '50000000-0000-0000-0000-000000000001')$$,
  'a ZSM invites a ZSA who reports to them');
reset role;
select results_eq(
  $$select role::text, zone_id, area_id, status::text from public.tenant_users
     where profile_id = '20000000-0000-0000-0000-000000000006'$$,
  $$values ('ZSA', '30000000-0000-0000-0000-000000000001'::uuid, null::uuid, 'INVITED')$$,
  'the ZSA takes the inviting ZSM''s zone');
select is(
  (select area_id from public.tenant_users where profile_id = '20000000-0000-0000-0000-000000000005'),
  (select id from public.areas where area_name = 'Allen Avenue'),
  'the ASA row carries the area');

-- ── anchor checks at insert level ───────────────────────────────────────
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, territory_id, reports_to_id)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011', 'ASA',
            '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007')$$,
  '23514', null, 'an ASA row without an area is refused');
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, zone_id)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011', 'ZSA',
            '30000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'a ZSA row without a manager is refused');

-- ── assert_platform_role ────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
reset role;
select throws_ok(
  $$select public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[])$$,
  '42501', 'not permitted for this platform role', 'a user with no platform role is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', null);
reset role;
select is(
  public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]),
  '20000000-0000-0000-0000-000000000008'::uuid,
  'a MONVELO_OPERATOR with no tenant passes and is returned');
select throws_ok(
  $$select public.assert_platform_role(array['MONVELO_FINANCE']::public.platform_role_enum[])$$,
  '42501', 'not permitted for this platform role', 'a role outside the list is refused');
select ok(
  not has_function_privilege('authenticated',
    'public.assert_platform_role(public.platform_role_enum[])', 'execute'),
  'assert_platform_role is internal: no API role can execute it');

-- ── RLS ─────────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.areas), 0, 'members of another tenant cannot read the areas');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.areas), 2, 'members of the tenant read its areas');

select * from finish();
rollback;
