-- Addendum A6 §6.1 (Step 2, Task 6) — place_trade_order: a FIELD_SALES order at
-- wholesale, in whole packs, from the territory's REGIONAL warehouse.
begin;
create extension if not exists pgtap with schema extensions;

select plan(30);

-- A6 §18.4: every state is on, and every tenant opted in, for this file's fixtures
update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 02 ZSA (Lagos zone) · 03 TM (Ikeja) · 04 ASA (Ikeja) · 05 DSA · 06 TENANT_ADMIN
-- 07 TM (Ikorodu, no warehouse) · 08 ZSA (Ogun zone) · 09 shop owner
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 9) n;
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'Ogun', 'OG');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikorodu'),
  ('40000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000002', 'Abeokuta');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSA', '30000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005', 'DSA', null, '40000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000006', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TM', null, '40000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'ZSA', '30000000-0000-0000-0000-000000000002', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true);
-- Ikeja holds two REGIONAL warehouses (the older, W1, is chosen); Abeokuta one; Ikorodu none
insert into public.warehouses (id, tenant_id, name, kind, territory_id, created_at) values
  ('70000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA-NEW', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', now()),
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA-OLD', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', now() - interval '2 days'),
  ('70000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'ABEOKUTA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000003', now());
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000009', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1');
-- an inactive cosmetics SKU
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category, nafdac_number,
                                     unit_price, wholesale_price, is_active) values
  ('7eaf0000-0000-4000-8000-000000000001', 'OLD-SKU', 'Old stock', 'Purerigin', 'Skin care', 'COSMETICS', 'A7-9001', 100, 80, false);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d1000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated;
create function pg_temp.lines(p_sku text, p_qty numeric) returns jsonb language sql as
  $$ select jsonb_build_array(jsonb_build_object('sku_code', p_sku, 'qty', p_qty)) $$;
grant execute on function pg_temp.lines(text, numeric) to authenticated;
create temp table res (n integer primary key, r jsonb);
grant select, insert on res to authenticated;

-- ── the happy path: an ASA, one carton ──────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
insert into res select 1, public.place_trade_order(pg_temp.k(1), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12));
select is((select r ->> 'total_amount' from res where n = 1), '48000.00', 'an ASA orders one carton of 12: 48000.00');
select is((select r ->> 'warehouse_id' from res where n = 1), '70000000-0000-0000-0000-000000000001',
  'the older of two REGIONAL warehouses is chosen');
select is((select r ->> 'territory_id' from res where n = 1), '40000000-0000-0000-0000-000000000001', 'the ASA''s own territory');
select is(public.place_trade_order(pg_temp.k(1), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12)), (select r from res where n = 1), 'the same key replays the first result');
reset role;
select is((select count(*)::int from public.orders where channel = 'FIELD_SALES'), 1, 'the replay wrote no second order');
select is((select channel::text || '|' || status || '|' || (agent_id = teafair_agent_id)::text
                  || '|' || (teafair_agent_id = '20000000-0000-0000-0000-000000000004')::text
                  || '|' || (retail_shop_id = '71000000-0000-0000-0000-000000000001')::text
             from public.orders where id = ((select r ->> 'order_id' from res where n = 1))::uuid),
  'FIELD_SALES|PENDING|true|true|true', 'the order is a PENDING FIELD_SALES order of the caller for the shop');
select is((select fulfilment_warehouse_id::text || '|' || territory_id::text || '|' || total_amount::text
             from public.orders where id = ((select r ->> 'order_id' from res where n = 1))::uuid),
  '70000000-0000-0000-0000-000000000001|40000000-0000-0000-0000-000000000001|48000.00', 'the order records warehouse, territory and total');
select is((select unit_price from public.order_items where order_id = ((select r ->> 'order_id' from res where n = 1))::uuid),
  4000.00, 'the item is at the wholesale price of 4000');
select is((select count(*)::int from public.audit_logs where operation = 'place_trade_order' and idempotency_key = pg_temp.k(1)), 1,
  'one audit row');
select ok(not (select coalesce(after ? 'customer_phone' or after ? 'customer_name', true) from public.audit_logs
                where operation = 'place_trade_order' and idempotency_key = pg_temp.k(1)),
  'the audit row holds no contact details');
select is((select count(*)::int from public.inventory_batches), 0, 'no stock was touched');

-- ── lines ───────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(2), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 5))$$, 'P0001', null, '5 units is not a whole pack');
select throws_ok($$select public.place_trade_order(pg_temp.k(3), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('OLD-SKU', 12))$$, 'P0001', 'OLD-SKU is not an active product', 'an inactive SKU is refused');
select throws_ok($$select public.place_trade_order(pg_temp.k(4), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('NO-SUCH-SKU', 12))$$, 'P0001', 'NO-SUCH-SKU is not an active product', 'an unknown SKU is refused');
select throws_ok($$select public.place_trade_order(pg_temp.k(5), '71000000-0000-0000-0000-000000000001',
  '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":12},{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":12}]')$$,
  'P0001', null, 'a repeated SKU is refused');
select throws_ok($$select public.place_trade_order(pg_temp.k(6), '71000000-0000-0000-0000-000000000001', '[]')$$,
  'P0001', null, 'an empty order is refused');
select throws_ok($$select public.place_trade_order(pg_temp.k(7), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 0))$$, 'P0001', null, 'a zero quantity is refused');
select throws_ok($$select public.place_trade_order(pg_temp.k(8), '71000000-0000-0000-0000-0000000000ff',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, 'P0001', 'shop not found', 'an unknown shop is refused');

-- ── territory ───────────────────────────────────────────────────────────
select throws_ok($$select public.place_trade_order(pg_temp.k(9), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12), '40000000-0000-0000-0000-000000000002')$$,
  '42501', 'you sell in your own territory', 'an ASA cannot name another territory');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001');
select is(public.place_trade_order(pg_temp.k(10), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 3), '40000000-0000-0000-0000-000000000001') ->> 'total_amount', '12000.00',
  'a TM orders in their own territory (a quarter carton)');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(11), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, 'P0001', 'choose the territory for this order', 'a ZSA must name a territory');
select throws_ok($$select public.place_trade_order(pg_temp.k(12), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12), '40000000-0000-0000-0000-000000000003')$$,
  '42501', null, 'a ZSA cannot order outside the zone');
select is(public.place_trade_order(pg_temp.k(13), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12), '40000000-0000-0000-0000-000000000001') ->> 'total_amount', '48000.00',
  'a ZSA orders for a territory inside the zone');
select throws_ok($$select public.place_trade_order(pg_temp.k(14), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12), '40000000-0000-0000-0000-000000000002')$$,
  'P0001', 'the territory has no regional warehouse', 'a territory with no REGIONAL warehouse is refused');

-- ── callers ─────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(15), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, '42501', null, 'a DSA is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(16), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, '42501', null, 'a TENANT_ADMIN is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(17), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12), '40000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'a ZSM is not a caller');
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(18), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, 'P0001', 'the territory has no regional warehouse',
  'a TM whose territory has no warehouse is refused');

-- ── operational states (A6 §18.4) ───────────────────────────────────────
reset role;
update public.operational_states set app_enabled = false where state_code = 'LA';
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(19), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, 'P0001', 'Teafair is not operating in Lagos yet',
  'a trade order is refused where the app is switched off');
reset role;
update public.operational_states set app_enabled = true where state_code = 'LA';
set local session_replication_role = replica;
update public.tenant_operational_states set app_enabled = false
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and state_code = 'LA';
set local session_replication_role = origin;
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.place_trade_order(pg_temp.k(20), '71000000-0000-0000-0000-000000000001',
  pg_temp.lines('PURERIGIN-COCONUT-OIL-200ML', 12))$$, 'P0001', 'Teafair is not operating in Lagos yet',
  'and where the brand has not opted in');
reset role;

select * from finish();
rollback;
