-- Transport fare on web orders (migration 20261024140000): a flat fare per
-- order, set per tenant; never discounted, never commissioned.
begin;
create extension if not exists pgtap with schema extensions;

select plan(15);

-- ── fixtures ────────────────────────────────────────────────────────────
-- TEAFAIR: ZSM (1) and a POS agent (2) whose partner takes 2 % (200 bps),
-- with a 10 % discount link. BRANDCO: another tenant, fare not set.
insert into public.tenants (id, name, code) values ('10000000-0000-0000-0000-000000000003', 'Brand Co', 'BRANDCO');
insert into public.tenant_settings (tenant_id) values ('10000000-0000-0000-0000-000000000003') on conflict do nothing;
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'Lagos');
insert into public.tenant_users (tenant_id, profile_id, role, zone_id, status, is_primary) values
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000003', 'ACTIVE', false);
insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   200, '+2348000000005', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id) values
  ('61000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'MP-0001');
insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, discount_type, discount_value, created_by) values
  ('7eaf0000-0000-4000-8000-000000000001', 'GRACE10', '20000000-0000-0000-0000-000000000001',
   '61000000-0000-0000-0000-000000000001', 'PERCENT', 10, '20000000-0000-0000-0000-000000000001');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                     nafdac_number, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000003', 'BC-SHEA', 'Shea butter', 'BrandCo', 'Skin care', 'COSMETICS', 'A7-1234', 2000, 1500);

insert into public.agent_codes (tenant_id, code, agent_id, created_by) values
  ('10000000-0000-0000-0000-000000000003', 'BRAND01', '20000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001');

create temp table q as
select public.web_price_cart(public.web_storefront_code(null),
         '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":2}]') as codeless,
       public.web_price_cart(public.web_storefront_code('GRACE10'),
         '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":2}]') as coded,
       public.web_price_cart(public.web_storefront_code('BRAND01'),
         '[{"sku_code":"BC-SHEA","qty":1}]') as other;

-- ── settings ────────────────────────────────────────────────────────────
select is((select web_transport_fare from public.tenant_settings
            where tenant_id = '7eaf0000-0000-4000-8000-000000000001'), 750.00, 'Teafair''s fare is 750');
select is((select web_transport_fare from public.tenant_settings
            where tenant_id = '10000000-0000-0000-0000-000000000003'), 0.00, 'another tenant''s fare is 0 until set');

-- ── the quote ───────────────────────────────────────────────────────────
-- codeless: 2 x 5,000 = 10,000 goods, + 750 fare
select is((select codeless ->> 'goods_total' from q), '10000.00', 'codeless goods total');
select is((select codeless ->> 'transport_fare' from q), '750.00', 'codeless fare');
select is((select codeless ->> 'total' from q), '10750.00', 'codeless total is goods plus fare');
-- coded: 10,000 less 10 % = 9,000 goods; the fare is not discounted
select is((select coded ->> 'discount' from q), '1000.00', 'the discount comes off the goods');
select is((select coded ->> 'total' from q), '9750.00', 'and not off the fare');
-- the partner's 2 % is cut from 9,000 goods, not 9,750
select is((select coded -> 'split' ->> 'partner_share' from q), '180.00', 'the partner''s share excludes the fare');
select is((select other ->> 'transport_fare' || '|' || (other ->> 'total') from q), '0.00|2000.00',
  'another tenant''s link charges no fare');

-- ── catalogue ───────────────────────────────────────────────────────────
select is(public.storefront_catalogue(null) ->> 'transport_fare', '750.00', 'the storefront shows the fare up front');

-- ── constraints ─────────────────────────────────────────────────────────
select throws_ok(
  $$update public.tenant_settings set web_transport_fare = -1
     where tenant_id = '7eaf0000-0000-4000-8000-000000000001'$$,
  '23514', null, 'a fare cannot be negative');
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, transport_fare)
    values ('7eaf0000-0000-4000-8000-000000000001', 'FIELD_DSA', '20000000-0000-0000-0000-000000000001', 5000, 750)$$,
  '23514', null, 'app orders carry no transport fare');
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, transport_fare, status, payment_route)
    values ('7eaf0000-0000-4000-8000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 500, 750,
            'CANCELLED', 'PAYSTACK_WEB')$$,
  '23514', null, 'the fare cannot exceed the order total');

-- ── refund policy ───────────────────────────────────────────────────────
select ok(position('The fare is refunded only if the order is cancelled before it is dispatched, or is never delivered.'
                   in (select content from public.refund_policies where is_active)) > 0,
  'the refund policy states when the fare is refunded');
select ok(position('Once an order has been delivered, the fare is not refunded'
                   in (select content from public.refund_policies where is_active)) > 0,
  'and that it is not refunded after delivery');

select * from finish();
rollback;
