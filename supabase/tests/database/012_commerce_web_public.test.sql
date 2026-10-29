-- Addendum A1 §4.2 — the public RPCs. They are executable by service_role
-- only: the public gateways call them, the app and anon never do.
begin;
create extension if not exists pgtap with schema extensions;

select plan(50);

-- A5: ONLINE orders created from 2026-10-23 must carry refund-policy consent.
-- These fixtures insert ONLINE orders directly and are not about consent, so
-- stamp it for them (027 tests the CHECK itself).
create function pg_temp.a5_stamp_consent() returns trigger language plpgsql as $f$
begin
  if new.channel = 'ONLINE' then
    new.policy_version_tag := coalesce(new.policy_version_tag, 'v2.0-food-cosmetics');
    new.policy_accepted_at := coalesce(new.policy_accepted_at, now());
  end if;
  return new;
end;
$f$;
create trigger a5_stamp_consent before insert on public.orders
  for each row execute function pg_temp.a5_stamp_consent();

-- A5: place_web_order now needs a consent assertion and a WhatsApp-verified
-- token for the buyer's phone. This wrapper keeps the 9-argument calls in
-- this file readable: it mints a verified token for the order's phone, then
-- calls the real function with consent, the active policy and a client IP.
create function pg_temp.pwo(
  p_key uuid, p_code text, p_items jsonb, p_customer jsonb, p_utm jsonb,
  p_route text, p_total numeric, p_checkout jsonb, p_lga uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $f$
declare
  v_tok text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  if p_customer ->> 'phone' ~ '^\+[1-9][0-9]{7,14}$' then
    insert into public.web_phone_verifications (phone, code_hash, expires_at, verified_at, token_hash, token_expires_at)
    values (p_customer ->> 'phone', 'x', now() + interval '10 minutes', now(),
            encode(extensions.digest(v_tok, 'sha256'), 'hex'), now() + interval '30 minutes');
  end if;
  return public.place_web_order(p_key, p_code, p_items, p_customer, p_utm, p_route, p_total, p_checkout, p_lga,
                                true, 'v2.0-food-cosmetics', '10.0.0.9'::inet, v_tok);
end;
$f$;
grant execute on function pg_temp.pwo(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb, uuid) to service_role;

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
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000008', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';

-- D1 routing: each used Nestle territory ships web orders from its own
-- REGIONAL warehouse, and Lagos/Ikeja is covered by the Ikeja territory
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'REG-EPE', 'REGIONAL',
   '40000000-0000-0000-0000-000000000008');
update public.territories set web_fulfilment_warehouse_id = '71000000-0000-0000-0000-000000000001'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set web_fulfilment_warehouse_id = '71000000-0000-0000-0000-000000000008'
 where id = '40000000-0000-0000-0000-000000000008';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id) values
  ('10000000-0000-0000-0000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001');

-- partner 1 is ACTIVE (splits); partner 3 is PENDING (no split)
insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now()),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Pending PalmPay', 'PALMPAY',
   '+2348000000004', 'ACCT_pend01', 'PENDING', null, null);
update public.tenant_settings set web_agent_commission_bps = 150
 where tenant_id = '10000000-0000-0000-0000-000000000001';
insert into public.web_pos_venues (id, tenant_id, partner_id, agent_id, network_terminal_id, territory_id, is_active,
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

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, is_active, nafdac_number) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400',  'Milo 400g',        'Milo',  'Beverages', 2500, 2000, true, 'A1-0101'),
  ('10000000-0000-0000-0000-000000000001', 'MAGGI-12',  'Maggi 12 cubes',   'Maggi', 'Seasoning', 1200, 1000, true, 'A1-0102'),
  ('10000000-0000-0000-0000-000000000001', 'SACHET-15', 'Coconut oil 15ml', 'Teafair', 'Oils',     500,  400, true, 'A1-0103'),
  ('10000000-0000-0000-0000-000000000001', 'OLD-SKU',   'Discontinued',     'Milo',  'Beverages',  500,  400, false, 'A1-0104'),
  ('10000000-0000-0000-0000-000000000002', 'OMO-1KG',   'Omo 1kg',          'Omo',   'Laundry',   3000, 2500, true, 'A1-0105');

insert into public.web_referral_codes (id, tenant_id, code, agent_id, venue_id, discount_type, discount_value,
                                max_redemptions, expires_at, is_active, created_by) values
  ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GRACE-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'GRACE-FIX',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000003', null, null,
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
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, referral_code_id,
                           attributed_agent_id, payment_route, public_reference,
                           delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000002', 100, 'PAID', '62000000-0000-0000-0000-000000000008',
   '20000000-0000-0000-0000-000000000004', 'PAYSTACK_WEB', 'TF-CAP001',
   md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001');

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
select ok(not has_function_privilege('authenticated', 'public.quote_web_order(text,jsonb,uuid)', 'execute'),
  'the app cannot call quote_web_order');

-- ── storefront_catalogue ────────────────────────────────────────────────
select pg_temp.as_service();
select is(public.storefront_catalogue('GRACE-01') -> 'venue',
  '{"name":"RCCG Grace Parish","channel":"CHURCH"}'::jsonb, 'the catalogue shows the venue');
select is(jsonb_array_length(public.storefront_catalogue('GRACE-01') -> 'products'), 3,
  'only the active products of the code''s tenant');
select ok(position('20000000-0000-0000-0000-000000000004' in public.storefront_catalogue('GRACE-01')::text) = 0,
  'no agent id leaks into the catalogue');
select ok(not (public.storefront_catalogue('GRACE-01') ? 'discount'),
  'the storefront offers no discount');
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
-- 2 × 2500 + 1 × 1200 = 6200 at full retail price; partner 150 bps = 93.00
select is(public.quote_web_order('GRACE-01',
            '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) ->> 'total',
  '6200.00', 'web orders are billed at full retail price');
select is(public.quote_web_order('GRACE-01',
            '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) -> 'split',
  '{"web_pos_partner_id":"60000000-0000-0000-0000-000000000001","subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":93.00}'::jsonb,
  'an active partner link pays the tenant web_agent_commission_bps of the total');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"MAGGI-12","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) -> 'split',
  'null'::jsonb, 'a partner that is not ACTIVE gets no split');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"MAGGI-12","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) ->> 'total',
  '1200.00', 'a link never discounts the price');
select is(public.quote_web_order('GRACE-FIX', '[{"sku_code":"SACHET-15","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) ->> 'discount',
  '0.00', 'the web discount is always zero');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"OLD-SKU","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'an inactive product cannot be ordered');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"OMO-1KG","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'another tenant''s product cannot be ordered');
select throws_ok($$select public.quote_web_order('GRACE-01',
                     '[{"sku_code":"MILO-400","qty":1},{"sku_code":"MILO-400","qty":2}]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'a product appears once per order');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"MILO-400","qty":0}]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'a quantity is at least 1');
select throws_ok($$select public.quote_web_order('GRACE-01', '[{"sku_code":"MILO-400","qty":1.5}]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'a quantity is a whole number');
select throws_ok($$select public.quote_web_order('GRACE-01', '[]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'an empty cart is refused');
reset role;

-- ── place_web_order ─────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated',
  'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', 'execute'),
  'the app cannot call place_web_order');
select ok(has_function_privilege('service_role',
  'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', 'execute'),
  'the public gateway (service_role) can');

select pg_temp.as_service();
select lives_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000001', 'grace-01',
      '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031234567","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
      '{"source":"whatsapp","medium":"social","campaign":"easter"}',
      'PAYSTACK_WEB', 6200.00,
      '{"reference":"TFW-r1","access_code":"ac_1","authorization_url":"https://checkout.paystack.com/ac_1","split":{"subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":93.00}}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a web order is placed for the Paystack route');
reset role;
select is(
  (select channel || '|' || status || '|' || payment_route || '|' || total_amount || '|' || discount_amount
          || '|' || attributed_venue_id || '|' || teafair_agent_id || '|' || utm_source
     from public.orders where referral_code_id = '62000000-0000-0000-0000-000000000001' and payment_route = 'PAYSTACK_WEB'),
  'ONLINE|PENDING|PAYSTACK_WEB|6200.00|0.00|61000000-0000-0000-0000-000000000001|20000000-0000-0000-0000-000000000002|whatsapp',
  'the order carries attribution, discount, UTM and the territory''s TM as accountable agent');
select is(
  (select sum(oi.line_total) from public.order_items oi join public.orders o on o.id = oi.order_id
    where o.referral_code_id = '62000000-0000-0000-0000-000000000001' and o.payment_route = 'PAYSTACK_WEB'),
  6200.00::numeric, 'the items are priced on the server');
select is(
  (select payment_status || '|' || amount || '|' || paystack_reference || '|' || web_pos_partner_id
     from public.payments where paystack_reference = 'TFW-r1'),
  'INITIATED|6200.00|TFW-r1|60000000-0000-0000-0000-000000000001', 'an INITIATED payment holds the reference');
select ok(
  (select public_reference ~ '^TF-[0-9A-HJKMNP-TV-Z]{6}$' from public.orders
    where referral_code_id = '62000000-0000-0000-0000-000000000001' and payment_route = 'PAYSTACK_WEB'),
  'the order has a public reference');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'place_web_order' and source = 'WEB' and actor_id is null
      and teafair_agent_id = '20000000-0000-0000-0000-000000000002'
      and idempotency_key = 'cccccccc-0000-0000-0000-000000000001'),
  1, 'a WEB audit row with no actor names the accountable agent');

select pg_temp.as_service();
select is(
  pg_temp.pwo('cccccccc-0000-0000-0000-000000000001', 'grace-01',
      '[{"sku_code":"MILO-400","qty":2},{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031234567","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
      '{"source":"whatsapp","medium":"social","campaign":"easter"}',
      'PAYSTACK_WEB', 6200.00,
      '{"reference":"TFW-r2","access_code":"ac_2","authorization_url":"https://checkout.paystack.com/ac_2","split":{"subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":93.00}}', md5('ng_lga:LA:Ikeja')::uuid) ->> 'authorization_url',
  'https://checkout.paystack.com/ac_1', 'a retry with the same key returns the original checkout URL');
reset role;
select is(
  (select count(*)::int from public.orders
    where referral_code_id = '62000000-0000-0000-0000-000000000001' and payment_route = 'PAYSTACK_WEB'),
  1, 'a retry writes no second order');

select pg_temp.as_service();
select lives_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000002', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a pay-at-agent order is placed');
reset role;
select is(
  (select count(*)::int from public.payments p join public.orders o on o.id = p.order_id
    where o.payment_route = 'POS_AGENT'),
  0, 'a pay-at-agent order has no payment row yet');

select pg_temp.as_service();
select lives_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000003', 'HOUSE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Chi","phone":"+2348031234569","delivery_address":"9 Awolowo Way"}',
      '{}', 'PAYSTACK_WEB', 1200.00,
      '{"reference":"TFW-r3","access_code":"ac_3","authorization_url":"https://checkout.paystack.com/ac_3","split":null}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a house code works on the Paystack route');
reset role;
select is(
  (select teafair_agent_id::text || '|' || coalesce(attributed_venue_id::text, 'none')
     from public.orders where referral_code_id = '62000000-0000-0000-0000-000000000006'),
  '20000000-0000-0000-0000-000000000006|none', 'a staff code holder is their own accountable agent');

select pg_temp.as_service();
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000004', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1080.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Prices changed — refresh and try again', 'a stale total is refused');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000005', 'HOUSE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'pay-at-agent needs a code bound to a terminal');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000006', 'NOTM-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'This link is not active yet', 'no accountable agent means the link is not active');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000007', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"08031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'the phone must already be E.164');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000008', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'a delivery address is required');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000009', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'PAYSTACK_WEB', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'the Paystack route needs checkout details');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-00000000000a', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'CASH', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'an unknown payment route is refused');
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-000000000001', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'TF002', null, 'a key reused for a different order is refused');
reset role;

-- five unpaid web orders in the last hour from one phone
with o as (
  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, payment_route,
                             delivery_lga_id, territory_id, fulfilment_warehouse_id)
  select '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000002', 100, 'PAYSTACK_WEB',
         md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001'
    from generate_series(1, 5)
  returning id, tenant_id)
insert into public.order_contacts (order_id, tenant_id, customer_phone)
select id, tenant_id, '+2348099999999' from o;
select pg_temp.as_service();
select throws_ok(
  $$select pg_temp.pwo('cccccccc-0000-0000-0000-00000000000b', 'GRACE-01',
      '[{"sku_code":"MAGGI-12","qty":1}]',
      '{"name":"Spam","phone":"+2348099999999","delivery_address":"1 Nowhere"}',
      null, 'POS_AGENT', 1200.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Too many unpaid orders for this phone number. Try again later.',
  'a sixth pending web order within the hour is refused');
reset role;
select * from finish();
rollback;
