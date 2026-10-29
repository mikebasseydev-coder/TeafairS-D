-- Teafairweb retail pricing (migration 20261024140000): full retail price,
-- no discounts, a flat transport fare, and the tenant commission rate (A6 15.5).
begin;
create extension if not exists pgtap with schema extensions;

select plan(23);

-- ── fixtures ────────────────────────────────────────────────────────────
-- TEAFAIR: ZSM (1) and Grace (2), a POS agent at Moniepoint; TEAFAIR's rate is 0, so
-- no split. Ikeja is deliverable. BRANDCO: another tenant with no fare, whose
-- rate this test sets to 150 bps.
insert into public.tenants (id, name, code) values ('10000000-0000-0000-0000-000000000003', 'Brand Co', 'BRANDCO');
insert into public.tenant_settings (tenant_id) values ('10000000-0000-0000-0000-000000000003') on conflict do nothing;
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (tenant_id, profile_id, role, zone_id, territory_id, status, is_primary) values
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000003', null, 'ACTIVE', false);
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001');
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000001'
 where id = '40000000-0000-0000-0000-000000000001';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id) values
  ('7eaf0000-0000-4000-8000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001');
insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   '+2348000000005', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now()),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'Brand Opay', 'OPAY',
   '+2348000000006', 'ACCT_brand01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.web_pos_venues (id, tenant_id, partner_id, agent_id, network_terminal_id) values
  ('61000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'MP-0001'),
  ('61000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000003',
   '20000000-0000-0000-0000-000000000001', 'OP-0003');
insert into public.web_referral_codes (tenant_id, code, agent_id, venue_id, created_by) values
  ('7eaf0000-0000-4000-8000-000000000001', 'GRACE-POS', '20000000-0000-0000-0000-000000000001',
   '61000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000003', 'BRAND-POS', '20000000-0000-0000-0000-000000000001',
   '61000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                     nafdac_number, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000003', 'BC-SHEA', 'Shea butter', 'BrandCo', 'Skin care', 'COSMETICS', 'A7-1234', 2000, 1500);
-- a buyer whose WhatsApp number is already verified (token "tok-1")
insert into public.web_phone_verifications (phone, code_hash, expires_at, verified_at, token_hash, token_expires_at) values
  ('+2348031111111', 'x', now() + interval '10 minutes', now(),
   encode(extensions.digest('tok-1', 'sha256'), 'hex'), now() + interval '30 minutes');

-- ── settings ────────────────────────────────────────────────────────────
select is((select web_transport_fare::text || '|' || web_agent_commission_bps::text from public.tenant_settings
            where tenant_id = '7eaf0000-0000-4000-8000-000000000001'), '750.00|0',
  'Teafair: 750 transport fare, commission rate 0 until agreed');
select is((select web_transport_fare::text || '|' || web_agent_commission_bps::text from public.tenant_settings
            where tenant_id = '10000000-0000-0000-0000-000000000003'), '0.00|0',
  'another tenant: no fare and rate 0 until set');
update public.tenant_settings set web_agent_commission_bps = 150
 where tenant_id = '10000000-0000-0000-0000-000000000003';

create temp table q as
select public.web_price_cart(public.web_storefront_code(null),
         '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":2}]') as codeless,
       public.web_price_cart(public.web_storefront_code('GRACE-POS'),
         '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":2},{"sku_code":"PURERIGIN-COCONUT-OIL-100ML","qty":1}]') as pos,
       public.web_price_cart(public.web_storefront_code('BRAND-POS'),
         '[{"sku_code":"BC-SHEA","qty":1}]') as other;


-- ── no web discounts ────────────────────────────────────────────────────
select throws_ok(
  $$insert into public.web_referral_codes (tenant_id, code, agent_id, discount_type, discount_value, created_by)
    values ('7eaf0000-0000-4000-8000-000000000001', 'PROMO-10', '20000000-0000-0000-0000-000000000001',
            'PERCENT', 10, '20000000-0000-0000-0000-000000000001')$$,
  'P0001', 'Web discounts are switched off: Teafairweb sells at full retail price.',
  'a promo code cannot carry a percentage discount');
select throws_ok(
  $$update public.web_referral_codes set discount_type = 'FIXED', discount_value = 1000 where code = 'GRACE-POS'$$,
  'P0001', 'Web discounts are switched off: Teafairweb sells at full retail price.',
  'nor have a fixed one added later');
select is((select count(*) from public.web_referral_codes where discount_type is not null or discount_value is not null),
  0::bigint, 'no link carries a discount');
select ok(not (public.storefront_catalogue('GRACE-POS') ? 'discount'), 'the storefront offers no discount');

-- ── the quote ───────────────────────────────────────────────────────────
-- codeless: 2 × 5,000 = 10,000 goods, no discount, + 750 fare, no split
select is((select codeless ->> 'goods_total' || '|' || (codeless ->> 'discount') || '|' || (codeless ->> 'transport_fare')
                  || '|' || (codeless ->> 'total') from q),
  '10000.00|0.00|750.00|10750.00', 'codeless: retail goods, no discount, plus the fare');
select is((select codeless -> 'split' from q), 'null'::jsonb, 'a codeless order pays no commission');
-- POS link: 2 × 5,000 + 1 × 3,000 = 13,000 goods, + 750 = 13,750
select is((select pos ->> 'discount' from q), '0.00', 'a POS link gives no discount');
select is((select pos ->> 'total' from q), '13750.00', 'POS link total is retail goods plus the fare');
select is((select pos -> 'split' from q),
  'null'::jsonb, 'TEAFAIR''s rate is 0: a POS link gets no split (the old flat 500 is gone)');
-- a tenant with a rate pays it on the goods only, never on the fare
select is((select other -> 'split' ->> 'partner_share' || '|' || (other -> 'split' ->> 'commission_bps') || '|' || (other ->> 'total') from q),
  '30.00|150|2000.00', 'a tenant with a rate of 150 bps pays 1.5 % of the goods');

-- ── a placed POS-link order ─────────────────────────────────────────────
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
create temp table placed as
select public.place_web_order('b0000000-0000-0000-0000-000000000001', 'GRACE-POS',
         '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":2},{"sku_code":"PURERIGIN-COCONUT-OIL-100ML","qty":1}]',
         '{"name":"Ada Obi","phone":"+2348031111111","delivery_address":"5 Opebi Road, Ikeja"}', null,
         'PAYSTACK_WEB', 13750.00,
         '{"reference":"TFW-bounty-1","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac",
           "split":null}',
         md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-1') as r;
reset role;
select is((select r ->> 'total' || '|' || (r ->> 'transport_fare') from placed), '13750.00|750.00',
  'the placement reply carries the total and the fare');
select is(
  (select o.total_amount::text || '|' || o.discount_amount::text || '|' || o.transport_fare::text
     from public.orders o where o.id = (select (r ->> 'order_id')::uuid from placed)),
  '13750.00|0.00|750.00', 'the order: 13,000 goods plus 750 fare, no discount');
select is(
  (select string_agg(oi.sku_code || ':' || oi.unit_price::text, ',' order by oi.sku_code)
     from public.order_items oi where oi.order_id = (select (r ->> 'order_id')::uuid from placed)),
  'PURERIGIN-COCONUT-OIL-100ML:3000.00,PURERIGIN-COCONUT-OIL-200ML:5000.00', 'lines are billed at the retail price');
select is(
  (select p.amount::text || '|' || coalesce(p.split_subaccount_code, '') || '|' || coalesce(p.split_bps::text, '')
            || '|' || coalesce(p.split_amount::text, '')
     from public.payments p where p.paystack_reference = 'TFW-bounty-1'),
  '13750.00|||', 'at rate 0 the payment carries no split snapshot');
select throws_ok(
  $$select public.place_web_order('b0000000-0000-0000-0000-000000000002', 'GRACE-POS',
      '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031111111","delivery_address":"5 Opebi Road, Ikeja"}', null,
      'PAYSTACK_WEB', 5750.00,
      '{"reference":"TFW-bounty-2","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac",
        "split":{"subaccount_code":"ACCT_grace01","commission_bps":200,"partner_share":100.00}}',
      md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-1')$$,
  'P0001', 'Prices changed — refresh and try again', 'a checkout that asks for a split the quote does not have is refused');

-- ── the evidence bundle ─────────────────────────────────────────────────
grant select on placed to authenticated;
select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', json_build_object(
         'sub', '20000000-0000-0000-0000-000000000001', 'role', 'authenticated',
         'app_metadata', json_build_object('active_tenant_id', '7eaf0000-0000-4000-8000-000000000001'))::text, true);
create temp table ev as
select public.get_order_dispute_evidence((select (r ->> 'order_id')::uuid from placed)) as b;
reset role;
select is((select b -> 'order' ->> 'goods_total' || '|' || (b -> 'order' ->> 'discount_amount') || '|'
                  || (b -> 'order' ->> 'transport_fare') || '|' || (b -> 'order' ->> 'total_amount') from ev),
  '13000.00|0.00|750.00|13750.00', 'evidence: retail goods, zero discount, the fare and the total');
select is((select b -> 'payments' -> 0 ->> 'agent_commission' from ev), null,
  'evidence: no agent commission at rate 0');
select ok((select b -> 'order' ->> 'referral_code_id' is not null from ev), 'evidence: the link the sale came through');

-- ── constraints ─────────────────────────────────────────────────────────
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, status, payment_route)
    values ('7eaf0000-0000-4000-8000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 500, 100,
            'CANCELLED', 'PAYSTACK_WEB')$$,
  '23514', null, 'a new web order cannot carry a discount');
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, transport_fare)
    values ('7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES', '20000000-0000-0000-0000-000000000001', 5000, 750)$$,
  '23514', null, 'app orders carry no transport fare');

-- ── refund policy ───────────────────────────────────────────────────────
select ok(position('The fare is refunded only if the order is cancelled before it is dispatched, or is never delivered.'
                   in (select content from public.refund_policies where is_active)) > 0
      and position('Once an order has been delivered, the fare is not refunded'
                   in (select content from public.refund_policies where is_active)) > 0,
  'the refund policy states when the fare is refunded');

select * from finish();
rollback;
