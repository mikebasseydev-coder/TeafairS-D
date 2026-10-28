-- Cartons and break-bulk wholesale packs (migrations 20261024130000 and 130100), with the
-- Purerigin Coconut Oil sizes as the reference.
begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

-- ── fixtures ────────────────────────────────────────────────────────────
-- TEAFAIR: a DSA (user 1) who sells to Mama Nkechi's shop.
insert into auth.users (id, phone) values ('20000000-0000-0000-0000-000000000001', '2348000000001');
insert into public.retail_shops (id, shop_name, contact_phone, density_category, location) values
  ('90000000-0000-0000-0000-000000000001', 'Mama Nkechi Provisions', '+2348000000010', 'MARKET_SQUARE',
   extensions.st_setsrid(extensions.st_makepoint(3.3515, 6.6018), 4326));
insert into public.orders (id, tenant_id, channel, retail_shop_id, agent_id, teafair_agent_id, total_amount) values
  ('80000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES',
   '90000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 0),
  ('80000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'RETAIL',
   '90000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 0);
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, policy_version_tag, policy_accepted_at) values
  ('80000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000001', 0, 'CANCELLED', 'PAYSTACK_WEB', 'TF-BBBBBB',
   'v2.0-food-cosmetics', now());
insert into public.retail_stock_pickups (id, tenant_id, retail_shop_id, dsa_agent_id) values
  ('a0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '90000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');

create function pg_temp.purerigin(p_size text) returns public.central_products language sql as $$
  select * from public.central_products
   where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-' || p_size;
$$;

-- ── the Purerigin seed ──────────────────────────────────────────────────
select is((select row(p.product_name, p.unit_price, p.wholesale_price, p.carton_units, p.break_bulk_units)::text
             from pg_temp.purerigin('200ML') p),
  row('Purerigin Coconut Oil - 200ml', 5000.00, 4000.00, 12, 3)::text,
  '200ml: retail 5,000, wholesale 4,000 a bottle, cartons of 12, packs of 3');
select is((select row(p.product_name, p.unit_price, p.wholesale_price, p.carton_units, p.break_bulk_units)::text
             from pg_temp.purerigin('100ML') p),
  row('Purerigin Coconut Oil - 100ml', 3000.00, 2500.00, 24, 6)::text,
  '100ml: retail 3,000, wholesale 2,500 a bottle, cartons of 24, packs of 6');
select is((select p.carton_wholesale_price from pg_temp.purerigin('200ML') p), 48000.00, '200ml carton is 48,000');
select is((select p.break_bulk_wholesale_price from pg_temp.purerigin('200ML') p), 12000.00, '200ml quarter carton is 12,000');
select is((select p.carton_wholesale_price from pg_temp.purerigin('100ML') p), 60000.00, '100ml carton is 60,000');
select is((select p.break_bulk_wholesale_price from pg_temp.purerigin('100ML') p), 15000.00, '100ml quarter carton is 15,000');
select ok((select bool_and(p.is_active and p.sale_category = 'COSMETICS' and p.nafdac_number = 'LG-IKJ-02-2134')
             from (select * from pg_temp.purerigin('200ML') union all select * from pg_temp.purerigin('100ML')) p),
  'both sizes are active COSMETICS with NAFDAC LG-IKJ-02-2134');
select is((select count(*) from jsonb_array_elements(public.storefront_catalogue(null) -> 'products') e
            where e ->> 'sku_code' like 'PURERIGIN-COCONUT-OIL-%'),
  2::bigint, 'both sizes are listed in the Teafair storefront');

-- ── trade orders come in whole packs ────────────────────────────────────
select lives_ok(
  $$insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price) values
      ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000001', 'PURERIGIN-COCONUT-OIL-200ML', 3, 4000),
      ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000001', 'PURERIGIN-COCONUT-OIL-100ML', 24, 2500)$$,
  'a field order takes a quarter carton of 200ml and a full carton of 100ml');
select is((select sum(line_total) from public.order_items where order_id = '80000000-0000-0000-0000-000000000001'),
  72000.00, 'quarter carton 12,000 plus carton 60,000');
select throws_ok(
  $$update public.order_items set qty = 4
     where order_id = '80000000-0000-0000-0000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-200ML'$$,
  'P0001', 'Purerigin Coconut Oil - 200ml sells to the trade in packs of 3 units; 4 is not a whole number of packs.',
  'a field order cannot break a quarter carton');
select throws_ok(
  $$update public.order_items set qty = 9
     where order_id = '80000000-0000-0000-0000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-100ML'$$,
  'P0001', 'Purerigin Coconut Oil - 100ml sells to the trade in packs of 6 units; 9 is not a whole number of packs.',
  'nor a 100ml one');
select lives_ok(
  $$update public.order_items set qty = 18
     where order_id = '80000000-0000-0000-0000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-100ML'$$,
  'three quarter cartons of 100ml');
select throws_ok(
  $$insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
    values ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000002', 'PURERIGIN-COCONUT-OIL-200ML', 1, 4000)$$,
  'P0001', null, 'a RETAIL-channel order is a trade sale too');
select lives_ok(
  $$insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
    values ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000002', 'PURERIGIN-COCONUT-OIL-200ML', 12, 4000)$$,
  'a RETAIL-channel order takes a full carton');
select lives_ok(
  $$insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
    values ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000003', 'PURERIGIN-COCONUT-OIL-200ML', 1, 5000)$$,
  'a web buyer buys a single bottle');

-- ── app sales are at the wholesale price ────────────────────────────────
select throws_ok(
  $$insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
    values ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000002', 'PURERIGIN-COCONUT-OIL-100ML', 6, 3000)$$,
  'P0001', 'App sales are at the wholesale price: Purerigin Coconut Oil - 100ml is 2500.00 a unit, not 3000.00.',
  'an app order line cannot use the retail price');
select throws_ok(
  $$update public.order_items set unit_price = 3500
     where order_id = '80000000-0000-0000-0000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-200ML'$$,
  'P0001', 'App sales are at the wholesale price: Purerigin Coconut Oil - 200ml is 4000.00 a unit, not 3500.00.',
  'nor be repriced');
select is((select unit_price from public.order_items
            where order_id = '80000000-0000-0000-0000-000000000003'),
  5000.00, 'the web line keeps the retail price');

-- ── pickups ─────────────────────────────────────────────────────────────
select throws_ok(
  $$insert into public.retail_stock_pickup_items (tenant_id, pickup_id, sku_code, quantity_picked)
    values ('7eaf0000-0000-4000-8000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'PURERIGIN-COCONUT-OIL-200ML', 2)$$,
  'P0001', null, 'a stock pickup cannot break a quarter carton');
select lives_ok(
  $$insert into public.retail_stock_pickup_items (tenant_id, pickup_id, sku_code, quantity_picked)
    values ('7eaf0000-0000-4000-8000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'PURERIGIN-COCONUT-OIL-200ML', 6)$$,
  'a stock pickup of two quarter cartons');

-- ── products without packs, and pack rules ──────────────────────────────
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, nafdac_number, unit_price, wholesale_price)
values ('7eaf0000-0000-4000-8000-000000000001', 'TF-TEA-1', 'Black tea', 'Teafair', 'Beverages', 'A1-0007', 500, 400);
select lives_ok(
  $$insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
    values ('7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000001', 'TF-TEA-1', 7, 400)$$,
  'a product without packs sells in any quantity');
update public.central_products set carton_units = 10 where sku_code = 'TF-TEA-1';
select throws_ok(
  $$insert into public.retail_stock_pickup_items (tenant_id, pickup_id, sku_code, quantity_picked)
    values ('7eaf0000-0000-4000-8000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'TF-TEA-1', 5)$$,
  'P0001', 'Black tea sells to the trade in packs of 10 units; 5 is not a whole number of packs.',
  'a carton with no break-bulk pack is the smallest trade pack');
select throws_ok(
  $$update public.central_products set break_bulk_units = 4 where sku_code = 'TF-TEA-1'$$,
  '23514', null, 'a break-bulk pack must divide the carton');
select throws_ok(
  $$update public.central_products set carton_units = null, break_bulk_units = 5 where sku_code = 'TF-TEA-1'$$,
  '23514', null, 'a break-bulk pack needs a carton');
select throws_ok(
  $$update public.central_products set carton_units = 0 where sku_code = 'TF-TEA-1'$$,
  '23514', null, 'a carton holds at least one unit');

select ok(not has_function_privilege('authenticated', 'public.assert_wholesale_pack(uuid,text,numeric)', 'execute')
      and not has_function_privilege('service_role', 'public.assert_wholesale_pack(uuid,text,numeric)', 'execute')
      and not has_function_privilege('authenticated', 'public.order_items_wholesale_pack()', 'execute')
      and not has_function_privilege('authenticated', 'public.retail_stock_pickup_items_wholesale_pack()', 'execute'),
  'the pack functions have no grant');

select * from finish();
rollback;
