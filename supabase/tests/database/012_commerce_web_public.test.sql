-- Addendum A1 §4.2 — the public RPCs. They are executable by service_role
-- only: the public gateways call them, the app and anon never do.
begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into public.tenant_settings (tenant_id, currency) values
  ('10000000-0000-0000-0000-000000000001', 'NGN');

-- 1 ZSM · 2 TM Ikeja · 4 POS agent Ikeja · 6 DSA Ikeja · 7 POS agent in a
-- territory with no TM · 8 disabled POS agent · 9 ZSM Unilever
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000007', '2348000000007'),
  ('20000000-0000-0000-0000-000000000008', '2348000000008'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000008', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';

-- partner 1 is ACTIVE (splits); partner 3 is PENDING (no split)
insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now()),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Pending PalmPay', 'PALMPAY',
   150, '+2348000000004', 'ACCT_pend01', 'PENDING', null, null);
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id, is_active,
                                      venue_channel, venue_name, address_text, state, location) values
  ('61000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0001', '40000000-0000-0000-0000-000000000001', true,
   'CHURCH', 'RCCG Grace Parish', '12 Allen Avenue, Ikeja', 'Lagos',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)),
  ('61000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000003',
   '20000000-0000-0000-0000-000000000004', 'PP-0003', '40000000-0000-0000-0000-000000000001', true,
   null, null, null, null, null),
  ('61000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0004', '40000000-0000-0000-0000-000000000001', false,
   null, null, null, null, null),
  ('61000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000007', 'MP-0007', '40000000-0000-0000-0000-000000000008', true,
   null, null, null, null, null);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, is_active) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400',  'Milo 400g',        'Milo',  'Beverages', 2500, 2000, true),
  ('10000000-0000-0000-0000-000000000001', 'MAGGI-12',  'Maggi 12 cubes',   'Maggi', 'Seasoning', 1200, 1000, true),
  ('10000000-0000-0000-0000-000000000001', 'SACHET-15', 'Coconut oil 15ml', 'Teafair', 'Oils',     500,  400, true),
  ('10000000-0000-0000-0000-000000000001', 'OLD-SKU',   'Discontinued',     'Milo',  'Beverages',  500,  400, false),
  ('10000000-0000-0000-0000-000000000002', 'OMO-1KG',   'Omo 1kg',          'Omo',   'Laundry',   3000, 2500, true);

insert into public.agent_codes (id, tenant_id, code, agent_id, terminal_id, discount_type, discount_value,
                                max_redemptions, expires_at, is_active, created_by) values
  ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GRACE-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', 'PERCENT', 10,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'GRACE-FIX',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000003', 'FIXED', 1000,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'OFF-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   null, null, false, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'OLD-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   null, now() - interval '1 day', true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'DEAD-TERM',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000004', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', 'HOUSE-01',
   '20000000-0000-0000-0000-000000000006', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001'),
  ('62000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', 'NOTM-01',
   '20000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-000000000007', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001'),
  ('62000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'CAP-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   1, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'UNI-01',
   '20000000-0000-0000-0000-000000000009', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000009'),
  ('62000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'GONE-01',
   '20000000-0000-0000-0000-000000000008', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001');

-- CAP-01 has already been redeemed once (a PAID order), so it is used up
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, agent_code_id,
                           attributed_agent_id, payment_route, delivery_address, public_reference) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000002', 100, 'PAID', '62000000-0000-0000-0000-000000000008',
   '20000000-0000-0000-0000-000000000004', 'PAYSTACK_WEB', '5 Opebi Road', 'TF-CAP001');

create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
grant execute on function pg_temp.as_service() to service_role;

-- ── privileges ──────────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.storefront_catalogue(text)', 'execute'),
  'the app cannot call storefront_catalogue');
select ok(not has_function_privilege('anon', 'public.storefront_catalogue(text)', 'execute'),
  'anon cannot call storefront_catalogue');
select ok(has_function_privilege('service_role', 'public.storefront_catalogue(text)', 'execute'),
  'the public gateway (service_role) can');
select ok(not has_function_privilege('authenticated', 'public.quote_web_order(text,jsonb)', 'execute'),
  'the app cannot call quote_web_order');

-- ── storefront_catalogue ────────────────────────────────────────────────
select pg_temp.as_service();
select is(public.storefront_catalogue('GRACE-01') -> 'venue',
  '{"name":"RCCG Grace Parish","channel":"CHURCH"}'::jsonb, 'the catalogue shows the venue');
select is(jsonb_array_length(public.storefront_catalogue('GRACE-01') -> 'products'), 3,
  'only the active products of the code''s tenant');
select ok(position('20000000-0000-0000-0000-000000000004' in public.storefront_catalogue('GRACE-01')::text) = 0,
  'no agent id leaks into the catalogue');
select is(public.storefront_catalogue('GRACE-01') -> 'discount',
  '{"type":"PERCENT","value":10}'::jsonb, 'the discount is shown');
select is(public.storefront_catalogue(' grace-01 ') ->> 'code', 'GRACE-01',
  'a lower-case, padded code resolves');
select is(public.storefront_catalogue('UNI-01') -> 'tenant' ->> 'name', 'Unilever Nigeria',
  'the code alone decides the tenant');
select throws_ok($$select public.storefront_catalogue('OFF-01')$$,
  'P0001', 'This link is no longer valid', 'an inactive code is refused');
select throws_ok($$select public.storefront_catalogue('OLD-01')$$,
  'P0001', 'This link is no longer valid', 'an expired code is refused');
select throws_ok($$select public.storefront_catalogue('DEAD-TERM')$$,
  'P0001', 'This link is no longer valid', 'a code on an inactive terminal is refused');
select throws_ok($$select public.storefront_catalogue('GONE-01')$$,
  'P0001', 'This link is no longer valid', 'a code whose agent is no longer active is refused');
select throws_ok($$select public.storefront_catalogue('CAP-01')$$,
  'P0001', 'This link is no longer valid', 'a used-up code is refused');
select throws_ok($$select public.storefront_catalogue('NOPE-99')$$,
  'P0001', 'This link is no longer valid', 'an unknown code is refused');

-- ── quote_web_order ─────────────────────────────────────────────────────
-- 2 × 2500 + 1 × 1200 = 6200; 10% off = 620; total 5580; partner 150 bps = 83.70
select is(public.quote_web_order('GRACE-01',
            '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]') ->> 'total',
  '5580.00', 'percentage discounts are applied on the server');
select is(public.quote_web_order('GRACE-01',
            '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]') -> 'split',
  '{"fintech_partner_id":"60000000-0000-0000-0000-000000000001","subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":83.70}'::jsonb,
  'an active partner takes commission_bps of the total');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"MAGGI-12","qty":1}]') -> 'split',
  'null'::jsonb, 'a partner that is not ACTIVE gets no split');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"MAGGI-12","qty":1}]') ->> 'total',
  '200.00', 'fixed discounts are applied on the server');
select throws_ok($$select public.quote_web_order('GRACE-FIX', '[{"sku_code":"SACHET-15","qty":1}]')$$,
  'P0001', null, 'a discount that leaves nothing to pay is refused');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"OLD-SKU","qty":1}]')$$,
  'P0001', null, 'an inactive product cannot be ordered');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"OMO-1KG","qty":1}]')$$,
  'P0001', null, 'another tenant''s product cannot be ordered');
select throws_ok($$select public.quote_web_order('GRACE-01',
                     '[{"sku_code":"MILO-400","qty":1},{"sku_code":"MILO-400","qty":2}]')$$,
  'P0001', null, 'a product appears once per order');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"MILO-400","qty":0}]')$$,
  'P0001', null, 'a quantity is at least 1');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"MILO-400","qty":1.5}]')$$,
  'P0001', null, 'a quantity is a whole number');
select throws_ok($$select public.quote_web_order('GRACE-01', '[]')$$,
  'P0001', null, 'an empty cart is refused');
reset role;

select * from finish();
rollback;
