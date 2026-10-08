-- Spec A §4.7 — Teafair is a tenant for its house brands, with no special
-- access to client tenants.
begin;
create extension if not exists pgtap with schema extensions;

select plan(9);

select is(
  (select code || ':' || status from public.tenants where id = '7eaf0000-0000-4000-8000-000000000001'),
  'TEAFAIR:ACTIVE', 'the Teafair tenant exists and is ACTIVE in every environment');
select is(
  (select currency || ':' || timezone || ':' || allow_shared_network
     from public.tenant_settings where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  'NGN:Africa/Lagos:true', 'Teafair has default settings, including the shared network');

-- fixtures: a client tenant, and a Teafair ZSM who is also a DSA for the client
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE'),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE'),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'DSA', null, '40000000-0000-0000-0000-000000000002',
   '50000000-0000-0000-0000-000000000002', 'ACTIVE');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TF-TEA-50', 'Teafair Black Tea 50s', 'Teafair', 'Beverages', 900, 800),
  ('10000000-0000-0000-0000-000000000001', 'MILO-400',  'Milo 400g',              'Milo',    'Beverages', 2500, 2200);

insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, source) values
  ('10000000-0000-0000-0000-000000000001', 'TEST', 'tenants', 'nestle', 'SYSTEM');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- a Nestle-only TM cannot see Teafair's house brands
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select results_eq($$select sku_code from public.central_products$$, array['MILO-400'],
  'a client tenant never sees Teafair house-brand products');
select is((select count(*)::int from public.tenants where code = 'TEAFAIR'), 0,
  'a client tenant cannot see the Teafair tenant row');

-- a Teafair ZSM gains nothing at Nestle beyond the DSA role held there
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001');
select lives_ok(
  $$select public.set_brand_approval_policy('bbbbbbbb-0000-0000-0000-000000000001', 'Teafair', 'ASM')$$,
  'a Teafair ZSM sets brand policy for Teafair house brands');
select lives_ok(
  $$select public.upsert_zone('bbbbbbbb-0000-0000-0000-000000000002', null, 'Abuja', null)$$,
  'a Teafair ZSM manages Teafair''s own zones');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_zone('bbbbbbbb-0000-0000-0000-000000000003', null, 'Kano', null)$$,
  '42501', null, 'being a Teafair ZSM confers no ZSM power at a client tenant');
select is((select count(*)::int from public.audit_logs
            where tenant_id = '10000000-0000-0000-0000-000000000001'), 0,
  'a Teafair ZSM who is a DSA at Nestle cannot read Nestle''s audit log');

reset role;
select is(
  (select tenant_id from public.zones where zone_name = 'Abuja'),
  '7eaf0000-0000-4000-8000-000000000001'::uuid, 'Teafair''s zone lands in the Teafair tenant');

select * from finish();
rollback;
