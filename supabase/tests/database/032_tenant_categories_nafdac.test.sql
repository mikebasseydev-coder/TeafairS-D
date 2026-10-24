-- Per-tenant sale categories (NCC licence: TELECOM is Sureach's alone) and
-- NAFDAC numbers on regulated products (migration 20261024120000).
begin;
create extension if not exists pgtap with schema extensions;

select plan(38);

-- ── fixtures ────────────────────────────────────────────────────────────
-- BRANDCO: a contracted third-party cosmetics brand. User 1 is its ZSM.
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000003', 'Brand Co Cosmetics', 'BRANDCO');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'Lagos');
insert into public.tenant_users (tenant_id, profile_id, role, zone_id, status, is_primary) values
  ('10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000003', 'ACTIVE', true);

create function pg_temp.categories(p_code text) returns text[] language sql as $$
  select array_agg(a.category order by a.category)
    from public.tenant_allowed_categories a join public.tenants t on t.id = a.tenant_id
   where t.code = p_code and a.enabled;
$$;

-- ── seeds ───────────────────────────────────────────────────────────────
select is((select name from public.tenants where code = 'SUREACH'), 'Sureach Nigeria Limited', 'Sureach is a tenant');
select is((select id from public.tenants where code = 'SUREACH'), '5eac0000-0000-4000-8000-000000000001'::uuid,
  'Sureach has its fixed id');
select is(pg_temp.categories('SUREACH'), array['COSMETICS', 'ELECTRONICS', 'FOOD', 'TELECOM'],
  'Sureach may sell all four categories');
select is(pg_temp.categories('TEAFAIR'), array['COSMETICS', 'FOOD'], 'Teafair may sell FOOD and COSMETICS');
select is(pg_temp.categories('BRANDCO'), array['COSMETICS', 'FOOD'],
  'a new tenant starts with FOOD and COSMETICS only');
select col_is_pk('public', 'tenant_allowed_categories', array['tenant_id', 'category'], 'primary key (tenant_id, category)');

-- ── TELECOM is Sureach's alone ──────────────────────────────────────────
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price)
    values ('10000000-0000-0000-0000-000000000003', 'AIRTIME-100', 'Airtime 100', 'BrandCo', 'Airtime', 'TELECOM', 100, 95)$$,
  'P0001', 'Tenant is not authorized to sell products in category TELECOM.',
  'a non-Sureach tenant cannot create a TELECOM product');
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price, is_active)
    values ('7eaf0000-0000-4000-8000-000000000001', 'TF-SIM', 'SIM card', 'Teafair', 'SIM', 'TELECOM', 100, 95, false)$$,
  'P0001', 'Tenant is not authorized to sell products in category TELECOM.',
  'Teafair cannot create a TELECOM product, even inactive');

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                     nafdac_number, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000003', 'BC-SHEA', 'Shea butter', 'BrandCo', 'Skin care', 'COSMETICS', 'A7-1234', 2000, 1500);
select throws_ok(
  $$update public.central_products set sale_category = 'TELECOM' where sku_code = 'BC-SHEA'$$,
  'P0001', 'Tenant is not authorized to sell products in category TELECOM.',
  'a non-Sureach product cannot be moved into TELECOM');
select throws_ok(
  $$insert into public.tenant_allowed_categories (tenant_id, category)
    values ('10000000-0000-0000-0000-000000000003', 'TELECOM')$$,
  'P0001', 'Only Sureach Nigeria Limited holds the NCC licence to sell TELECOM products.',
  'TELECOM cannot be granted to another tenant');
select throws_ok(
  $$insert into public.tenant_allowed_categories (tenant_id, category, enabled)
    values ('7eaf0000-0000-4000-8000-000000000001', 'TELECOM', true)$$,
  'P0001', 'Only Sureach Nigeria Limited holds the NCC licence to sell TELECOM products.',
  'TELECOM cannot be granted to Teafair either');
select throws_ok(
  $$update public.tenant_allowed_categories set tenant_id = '10000000-0000-0000-0000-000000000003'
     where tenant_id = '5eac0000-0000-4000-8000-000000000001' and category = 'TELECOM'$$,
  'P0001', null, 'Sureach''s TELECOM row cannot be moved to another tenant');
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price)
    values ('10000000-0000-0000-0000-000000000003', 'BC-PHONE', 'Phone', 'BrandCo', 'Phones', 'ELECTRONICS', 100, 95)$$,
  'P0001', 'Tenant is not authorized to sell products in category ELECTRONICS.',
  'a cosmetics tenant cannot sell ELECTRONICS');

select lives_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price)
    values ('5eac0000-0000-4000-8000-000000000001', 'SR-AIRTIME-100', 'Airtime 100', 'Sureach', 'Airtime', 'TELECOM', 100, 95),
           ('5eac0000-0000-4000-8000-000000000001', 'SR-ROUTER', 'MiFi router', 'Sureach', 'Devices', 'ELECTRONICS', 25000, 22000)$$,
  'Sureach can sell TELECOM and ELECTRONICS, which need no NAFDAC number');
select ok(not public.web_category_sellable('TELECOM'),
  'TELECOM stays off the web until a policy version covers it');

-- ── withdrawing a category ──────────────────────────────────────────────
select throws_ok(
  $$update public.tenant_allowed_categories set enabled = false
     where tenant_id = '10000000-0000-0000-0000-000000000003' and category = 'COSMETICS'$$,
  'P0001', 'Deactivate this tenant''s COSMETICS products before withdrawing the category.',
  'a category with active products cannot be withdrawn');
select throws_ok(
  $$delete from public.tenant_allowed_categories
     where tenant_id = '10000000-0000-0000-0000-000000000003' and category = 'COSMETICS'$$,
  'P0001', 'Deactivate this tenant''s COSMETICS products before withdrawing the category.',
  'nor deleted');
update public.central_products set is_active = false where sku_code = 'BC-SHEA';
select lives_ok(
  $$update public.tenant_allowed_categories set enabled = false
     where tenant_id = '10000000-0000-0000-0000-000000000003' and category = 'COSMETICS'$$,
  'withdrawn once its products are inactive');
select throws_ok(
  $$update public.central_products set is_active = true where sku_code = 'BC-SHEA'$$,
  'P0001', 'Tenant is not authorized to sell products in category COSMETICS.',
  'a product cannot be reactivated in a withdrawn category');
update public.tenant_allowed_categories set enabled = true
 where tenant_id = '10000000-0000-0000-0000-000000000003' and category = 'COSMETICS';
select lives_ok($$update public.central_products set is_active = true where sku_code = 'BC-SHEA'$$,
  'reactivated once the category is restored');

-- ── Purerigin Coconut Oil ───────────────────────────────────────────────
select is(
  (select row(p.brand, p.sale_category, p.nafdac_number, p.is_active)::text
     from public.central_products p
    where p.tenant_id = '7eaf0000-0000-4000-8000-000000000001' and p.sku_code = 'PURERIGIN-COCONUT-OIL'),
  row('Purerigin', 'COSMETICS', 'LG-IKJ-02-2134', false)::text,
  'Purerigin Coconut Oil is seeded as COSMETICS with NAFDAC LG-IKJ-02-2134, inactive until priced');
select lives_ok(
  $$update public.central_products set unit_price = 3500, wholesale_price = 3000, is_active = true
     where sku_code = 'PURERIGIN-COCONUT-OIL'$$,
  'Purerigin activates once priced');
select ok(public.web_category_sellable('COSMETICS')
          and exists (select 1 from jsonb_array_elements(public.storefront_catalogue(null) -> 'products') e
                       where e ->> 'sku_code' = 'PURERIGIN-COCONUT-OIL'),
  'and is listed in the Teafair storefront');

-- ── NAFDAC numbers ──────────────────────────────────────────────────────
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price)
    values ('10000000-0000-0000-0000-000000000003', 'BC-SOAP', 'Black soap', 'BrandCo', 'Skin care', 'COSMETICS', 900, 700)$$,
  '23514', null, 'an active COSMETICS product needs a NAFDAC number');
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price)
    values ('10000000-0000-0000-0000-000000000003', 'BC-TEA', 'Herbal tea', 'BrandCo', 'Beverages', 'FOOD', 900, 700)$$,
  '23514', null, 'an active FOOD product needs a NAFDAC number');
select lives_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, unit_price, wholesale_price, is_active)
    values ('10000000-0000-0000-0000-000000000003', 'BC-SOAP', 'Black soap', 'BrandCo', 'Skin care', 'COSMETICS', 900, 700, false)$$,
  'an inactive draft may wait for its number');
select throws_ok(
  $$update public.central_products set is_active = true where sku_code = 'BC-SOAP'$$,
  '23514', null, 'but cannot be activated without it');
select throws_ok(
  $$update public.central_products set nafdac_number = null where sku_code = 'BC-SHEA'$$,
  '23514', null, 'an active product cannot lose its number');
select lives_ok(
  $$update public.central_products set nafdac_number = 'A7-5678', is_active = true where sku_code = 'BC-SOAP'$$,
  'activated with its number');
select throws_ok(
  $$update public.central_products set nafdac_number = 'a7-5678' where sku_code = 'BC-SOAP'$$,
  '23514', null, 'NAFDAC numbers are upper case');
select throws_ok(
  $$update public.central_products set nafdac_number = '' where sku_code = 'BC-SOAP'$$,
  '23514', null, 'and never blank');
select throws_ok(
  $$update public.central_products set nafdac_number = 'A7 5678' where sku_code = 'BC-SOAP'$$,
  '23514', null, 'and hold no spaces');
select throws_ok(
  $$update public.central_products set nafdac_number = 'A7' where sku_code = 'BC-SOAP'$$,
  '23514', null, 'and have at least two groups');

select is((select convalidated from pg_constraint
            where conname = 'central_products_nafdac_required' and conrelid = 'public.central_products'::regclass),
  false, 'the requirement is NOT VALID: products that exist on push are not checked until validated');

-- ── access ──────────────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.tenant_allowed_categories_guard()', 'execute')
      and not has_function_privilege('authenticated', 'public.central_products_category_guard()', 'execute')
      and not has_function_privilege('authenticated', 'public.tenants_default_categories()', 'execute')
      and not has_function_privilege('service_role', 'public.central_products_category_guard()', 'execute'),
  'the trigger functions have no grant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object(
  'sub', '20000000-0000-0000-0000-000000000001', 'role', 'authenticated',
  'app_metadata', json_build_object('active_tenant_id', '10000000-0000-0000-0000-000000000003'))::text, true);
select is((select array_agg(category order by category) from public.tenant_allowed_categories),
  array['COSMETICS', 'FOOD'], 'a member reads only their own tenant''s categories');
select throws_ok(
  $$insert into public.tenant_allowed_categories (tenant_id, category)
    values ('10000000-0000-0000-0000-000000000003', 'ELECTRONICS')$$,
  '42501', null, 'members cannot grant themselves a category');
select throws_ok(
  $$update public.tenant_allowed_categories set enabled = false$$,
  '42501', null, 'nor change one');
reset role;

select * from finish();
rollback;
