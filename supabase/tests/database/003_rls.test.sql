-- Phase 2 — grants and RLS (Spec A §8). Every check runs as the
-- `authenticated` role with a JWT claim set, exactly as PostgREST does.
begin;
create extension if not exists pgtap with schema extensions;

select plan(36);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into public.tenant_settings (tenant_id, allow_shared_network) values
  ('10000000-0000-0000-0000-000000000001', true),
  ('10000000-0000-0000-0000-000000000002', false);

-- 1 ZSM Nestle · 2 TM Nestle · 3 DSA Nestle · 4 ZSM Unilever · 5 revoked Nestle member
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, pin_hash) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', null),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', null),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE',
   extensions.crypt('1234', extensions.gen_salt('bf', 4))),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000004',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', null),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'DISABLED', null);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400', 'Milo 400g', 'Milo', 'Beverages', 2500, 2200),
  ('10000000-0000-0000-0000-000000000002', 'OMO-1KG',  'Omo 1kg',   'Omo',  'Detergent', 1800, 1600);

insert into public.user_secure_profiles (user_id, bvn_nin_hash, bvn_hash_version) values
  ('20000000-0000-0000-0000-000000000003', 'hash-dsa', 1);

insert into public.retail_shops (id, shop_name, contact_phone, density_category, location) values
  ('90000000-0000-0000-0000-000000000001', 'Covered by Unilever', '+2348000000010', 'MARKET_SQUARE',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)),
  ('90000000-0000-0000-0000-000000000002', 'Uncovered shop', '+2348000000011', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.36, 6.61), 4326));
insert into public.tenant_shop_coverage (tenant_id, retail_shop_id, territory_id, assigned_by) values
  ('10000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000004');

insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, source) values
  ('10000000-0000-0000-0000-000000000001', 'TEST', 'tenants', 'x', 'SYSTEM');
insert into public.notifications (tenant_id, user_id, kind, title) values
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'TEST', 'for the DSA');
insert into public.otp_challenges (tenant_id, subject_id, purpose, code_hash, destination_phone, issued_by, expires_at) values
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'PICKUP_CONFIRM',
   'secret-hash', '+2348000000003', '20000000-0000-0000-0000-000000000002', now() + interval '5 minutes');

-- act as a user: role + verified claims, as PostgREST sets them
create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
-- functions get no PUBLIC execute by default here (grants migration)
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── structure: policies are SELECT-only, everywhere ─────────────────────
select is(
  (select count(*)::int from pg_tables t where t.schemaname = 'public'
     and not exists (select 1 from pg_policies p
                     where p.schemaname = 'public' and p.tablename = t.tablename and p.cmd = 'SELECT')),
  0, 'every public table has a SELECT policy');
select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and cmd <> 'SELECT'),
  0, 'no table has an INSERT/UPDATE/DELETE/ALL policy');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  0, 'every SECURITY DEFINER function in public pins search_path');
select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
  0, 'anon and authenticated hold no write privilege on any table');
select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon'),
  0, 'anon holds no privilege on any table');

-- ── helpers read the verified JWT ───────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.jwt_tenant_id(), '10000000-0000-0000-0000-000000000001'::uuid,
  'jwt_tenant_id() reads active_tenant_id from app_metadata');
select ok(public.is_tenant_member('10000000-0000-0000-0000-000000000001'), 'DSA is a member of Nestle');
select ok(not public.is_tenant_member('10000000-0000-0000-0000-000000000002'), 'DSA is not a member of Unilever');
select is(public.tenant_role('10000000-0000-0000-0000-000000000001'), 'DSA'::public.tenant_role_enum,
  'tenant_role() returns the live role');

-- ── no direct writes, ever ──────────────────────────────────────────────
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price)
    values ('10000000-0000-0000-0000-000000000001', 'HACK', 'x', 'x', 'x', 0, 0)$$,
  '42501', null, 'a member cannot insert a product directly');
select throws_ok(
  $$update public.central_products set unit_price = 0$$,
  '42501', null, 'a member cannot rewrite prices directly');
select throws_ok(
  $$delete from public.retail_stock_pickups$$,
  '42501', null, 'a member cannot delete pickups directly');
select throws_ok(
  $$update public.tenant_users set role = 'ZSM' where profile_id = '20000000-0000-0000-0000-000000000003'$$,
  '42501', null, 'a member cannot promote themselves');

-- ── class A isolation ───────────────────────────────────────────────────
select results_eq(
  $$select sku_code from public.central_products order by 1$$,
  array['MILO-400'], 'a Nestle member sees only Nestle products');
select is((select count(*)::int from public.tenants), 1, 'a member sees only their own tenant');
select is((select count(*)::int from public.zones), 1, 'a member sees only their own tenant''s zones');

-- the claim proposes, the database decides (§4.4): claiming another tenant
-- grants nothing
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.central_products where tenant_id = '10000000-0000-0000-0000-000000000002'),
  0, 'claiming a tenant you do not belong to reveals none of its rows');

-- a revoked member with a still-valid JWT sees nothing (§4.4)
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.central_products), 0, 'a DISABLED member sees no products');
select is((select count(*)::int from public.tenants), 0, 'a DISABLED member sees no tenant');

-- ── identity ────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select results_eq(
  $$select phone_number from public.profiles order by 1$$,
  array['+2348000000001', '+2348000000002', '+2348000000003'],
  'a TM sees their own profile and active Nestle peers only');
select is((select count(*)::int from public.user_secure_profiles), 0,
  'a TM cannot read a peer''s BVN hash (decision 16)');
select throws_ok(
  $$select pin_hash from public.tenant_users$$,
  '42501', null, 'pin_hash is never selectable');
select is((select count(*)::int from public.tenant_users), 4,
  'a TM sees the memberships of their tenant (including the disabled one)');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is((select bvn_nin_hash from public.user_secure_profiles), 'hash-dsa',
  'the owner can read their own secure profile');
select is((select count(*)::int from public.notifications), 1, 'a user sees their own notifications');
select is((select count(*)::int from public.otp_challenges), 1, 'a subject sees their own OTP challenge');
select throws_ok(
  $$select code_hash from public.otp_challenges$$,
  '42501', null, 'otp code_hash is never selectable');

-- ── audit_logs: ZSM and TM only ─────────────────────────────────────────
select is((select count(*)::int from public.audit_logs), 0, 'a DSA cannot read the audit log');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.audit_logs), 1, 'a TM can read their tenant''s audit log');
select throws_ok(
  $$delete from public.audit_logs$$,
  '42501', null, 'a TM cannot delete audit rows');

-- ── shared retail network (§4.3) ────────────────────────────────────────
-- Nestle allows the shared network: sees every shop
select is((select count(*)::int from public.retail_shops), 2,
  'allow_shared_network = true sees the whole registry');
-- Unilever does not: sees only its covered shop
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002');
select results_eq(
  $$select shop_name from public.retail_shops$$,
  array['Covered by Unilever'], 'allow_shared_network = false sees only covered shops');
select is((select count(*)::int from public.tenant_shop_coverage), 1, 'coverage is visible to its own tenant');
-- a revoked member sees no shops
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.retail_shops), 0, 'a user with no active membership sees no shops');

-- ── anon sees nothing ───────────────────────────────────────────────────
select set_config('role', 'anon', true);
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select * from public.retail_shops$$, '42501', null, 'anon cannot read retail_shops');
select throws_ok($$select * from public.profiles$$, '42501', null, 'anon cannot read profiles');

reset role;
select * from finish();
rollback;
