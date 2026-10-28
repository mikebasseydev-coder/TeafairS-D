-- A6 15.5: the web POS commission is a tenant rate in bps, 0 until agreed. Only a code
-- tied to a venue of an ACTIVE POS partner earns; codeless orders and DSA links pay 0%;
-- the share is on goods only; a rate of 0 or a share that rounds to 0 is no split.
begin;
create extension if not exists pgtap with schema extensions;

select plan(21);

-- ── fixtures (as postgres): RATECO, fare 750, a POS partner and venue, a DSA ──
insert into public.tenants (id, name, code) values ('10000000-0000-0000-0000-000000000004', 'Rate Co', 'RATECO');
insert into public.tenant_settings (tenant_id, web_transport_fare) values ('10000000-0000-0000-0000-000000000004', 750);
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004',
   '30000000-0000-0000-0000-000000000004', 'Ikeja');
insert into public.tenant_users (tenant_id, profile_id, role, zone_id, territory_id, status, is_primary) values
  ('10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000004', null, 'ACTIVE', true);
insert into public.tenant_users (tenant_id, profile_id, role, territory_id, reports_to_id, status, is_primary)
select '10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'DSA',
       '40000000-0000-0000-0000-000000000004', tu.id, 'ACTIVE', true
  from public.tenant_users tu
 where tu.tenant_id = '10000000-0000-0000-0000-000000000004' and tu.role = 'ZSM';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000004');
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000004'
 where id = '40000000-0000-0000-0000-000000000004';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id) values
  ('10000000-0000-0000-0000-000000000004', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000004');
insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', 'Rate Moniepoint', 'MONIEPOINT',
   '+2348000000005', 'ACCT_rate01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.web_pos_venues (id, tenant_id, partner_id, agent_id, network_terminal_id) values
  ('61000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000004',
   '20000000-0000-0000-0000-000000000001', 'MP-0004');
insert into public.web_referral_codes (tenant_id, code, agent_id, venue_id, created_by) values
  ('10000000-0000-0000-0000-000000000004', 'RATE-POS', '20000000-0000-0000-0000-000000000001',
   '61000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001');
insert into public.web_referral_codes (tenant_id, code, agent_id, created_by) values
  ('10000000-0000-0000-0000-000000000004', 'RATE-DSA', '20000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000001');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                     nafdac_number, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000004', 'RC-BIG', 'Big pack', 'RateCo', 'Skin care', 'COSMETICS', 'A7-1234', 6200, 5000),
  ('10000000-0000-0000-0000-000000000004', 'RC-SMALL', 'Small pack', 'RateCo', 'Skin care', 'COSMETICS', 'A7-1235', 3, 2);
insert into public.web_phone_verifications (phone, code_hash, expires_at, verified_at, token_hash, token_expires_at) values
  ('+2348031111111', 'x', now() + interval '10 minutes', now(),
   encode(extensions.digest('tok-1', 'sha256'), 'hex'), now() + interval '30 minutes'),
  ('+2348032222222', 'x', now() + interval '10 minutes', now(),
   encode(extensions.digest('tok-2', 'sha256'), 'hex'), now() + interval '30 minutes');

create function pg_temp.quote(p_code text, p_sku text) returns jsonb language sql as $$
  select public.web_price_cart(public.web_storefront_code(p_code),
           jsonb_build_array(jsonb_build_object('sku_code', p_sku, 'qty', 1)))
$$;

-- ── the setting ─────────────────────────────────────────────────────────
select col_not_null('public', 'tenant_settings', 'web_agent_commission_bps', 'the rate is not null');
select col_default_is('public', 'tenant_settings', 'web_agent_commission_bps', '0', 'the rate defaults to 0');
select is((select count(*)::int from public.tenant_settings where web_agent_commission_bps <> 0), 0,
  'every tenant is at 0 until rates are agreed, TEAFAIR included');
select is((select web_agent_commission_bps from public.tenant_settings where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  0, 'TEAFAIR is at 0: its old 500 bounty has ended');
select throws_ok($$update public.tenant_settings set web_agent_commission_bps = 10001$$,
  '23514', null, 'a rate above 10000 bps is refused');
select throws_ok($$update public.tenant_settings set web_agent_commission_bps = -1$$,
  '23514', null, 'a negative rate is refused');
select hasnt_column('public', 'tenant_settings', 'web_agent_bounty', 'the flat bounty is gone');
select hasnt_column('public', 'web_pos_partners', 'commission_bps', 'the per-partner rate is gone');

-- ── who earns ───────────────────────────────────────────────────────────
select is(pg_temp.quote('RATE-POS', 'RC-BIG') -> 'split', 'null'::jsonb, 'at rate 0 a POS link has no split');

update public.tenant_settings set web_agent_commission_bps = 150
 where tenant_id in ('10000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
-- goods 6,200 + fare 750: the share is 1.5 % of the goods only (93.00, not 104.25)
select is((pg_temp.quote('RATE-POS', 'RC-BIG') -> 'split') - 'web_pos_partner_id',
  '{"subaccount_code":"ACCT_rate01","commission_bps":150,"partner_share":93.00}'::jsonb,
  'a POS link at 150 bps pays 93.00 on 6,200 of goods');
select is((select array_agg(k order by k) from jsonb_object_keys(pg_temp.quote('RATE-POS', 'RC-BIG') -> 'split') k),
  array['commission_bps','partner_share','subaccount_code','web_pos_partner_id'],
  'the split carries exactly the four keys');
select is(pg_temp.quote('RATE-POS', 'RC-BIG') ->> 'total', '6950.00', 'the total is goods plus the fare');
select is(public.web_price_cart(public.web_storefront_code(null),
            '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":1}]') -> 'split',
  'null'::jsonb, 'a codeless quote has no split, even at a non-zero rate');
select is(pg_temp.quote('RATE-DSA', 'RC-BIG') -> 'split', 'null'::jsonb, 'a DSA link has no split');
update public.web_pos_partners set status = 'SUSPENDED' where id = '60000000-0000-0000-0000-000000000004';
select is(pg_temp.quote('RATE-POS', 'RC-BIG') -> 'split', 'null'::jsonb, 'a SUSPENDED partner earns nothing');
update public.web_pos_partners set status = 'ACTIVE' where id = '60000000-0000-0000-0000-000000000004';
update public.tenant_settings set web_agent_commission_bps = 1
 where tenant_id = '10000000-0000-0000-0000-000000000004';
select is(pg_temp.quote('RATE-POS', 'RC-SMALL') -> 'split', 'null'::jsonb,
  'a share that rounds to 0.00 (1 bps of 3.00) gives no split');
update public.tenant_settings set web_agent_commission_bps = 150
 where tenant_id = '10000000-0000-0000-0000-000000000004';

-- ── a placed order carries the split into the payment and the commission row ──
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
create temp table placed as
select public.place_web_order('b0000000-0000-0000-0000-000000000001', 'RATE-POS',
         '[{"sku_code":"RC-BIG","qty":1}]',
         '{"name":"Ada Obi","phone":"+2348031111111","delivery_address":"5 Opebi Road, Ikeja"}', null,
         'PAYSTACK_WEB', 6950.00,
         '{"reference":"TFW-rate-1","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac",
           "split":{"subaccount_code":"ACCT_rate01","commission_bps":150,"partner_share":93.00}}',
         md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-1') as r;
reset role;
select is(
  (select p.split_bps::text || '|' || p.split_amount::text || '|' || p.split_subaccount_code
     from public.payments p where p.paystack_reference = 'TFW-rate-1'),
  '150|93.00|ACCT_rate01', 'the payment snapshots the rate, the share and the subaccount');
select is(public.settle_paystack_payment('charge.success', 'TFW-rate-1', 'success', 695000, 'NGN', '{}',
  '9101', 'ACCT_rate01', 9300) ->> 'commission_status', 'SPLIT', 'the verified split settles as SPLIT');
select is((select count(*)::int || '|' || min(c.bps_applied) || '|' || min(c.amount)
             from public.web_commissions c join public.payments p on p.id = c.payment_id
            where p.paystack_reference = 'TFW-rate-1'),
  '1|150|93.00', 'settlement writes one commission row, 150 bps and 93.00');

-- ── at rate 0 nothing splits and nothing is written ─────────────────────
update public.tenant_settings set web_agent_commission_bps = 0
 where tenant_id = '10000000-0000-0000-0000-000000000004';
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.place_web_order('b0000000-0000-0000-0000-000000000002', 'RATE-POS',
         '[{"sku_code":"RC-BIG","qty":1}]',
         '{"name":"Bola","phone":"+2348032222222","delivery_address":"7 Toyin Street, Ikeja"}', null,
         'PAYSTACK_WEB', 6950.00,
         '{"reference":"TFW-rate-2","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac",
           "split":null}',
         md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-2');
reset role;
select is((select num_nulls(split_subaccount_code, split_bps, split_amount) from public.payments
            where paystack_reference = 'TFW-rate-2'), 3, 'with no split the payment has no split_* fields');
select public.settle_paystack_payment('charge.success', 'TFW-rate-2', 'success', 695000, 'NGN', '{}',
  '9102', null, null);
select is((select count(*)::int from public.web_commissions c join public.payments p on p.id = c.payment_id
            where p.paystack_reference = 'TFW-rate-2'), 0, 'with no split settlement writes no commission row');

select * from finish();
rollback;
