-- Addendum A2 — buyer contact details are readable only by the ZSM and the
-- order's TM; the POS agent gets a masked till lookup (Task 2 appends it).
begin;
create extension if not exists pgtap with schema extensions;

select plan(35);

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

-- 1 ZSM · 2 TM Ikeja · 3 TM Epe · 4 POS agent Ikeja · 5 shop owner
-- 6 DSA Ikeja · 7 POS agent Epe · 8 disabled POS agent · 9 ZSM Unilever
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000007', '2348000000007'),
  ('20000000-0000-0000-0000-000000000008', '2348000000008'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe'),
  ('40000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikoyi');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000003', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'RETAIL_SHOP_OWNER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000003', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', null, null, null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000003';
-- A6 §17/§18.3: zones.zsm_id is the ZSM's coverage
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id = '30000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000009'
 where id = '30000000-0000-0000-0000-000000000002';

-- D1 routing: each used territory ships web orders from its own REGIONAL
-- warehouse. Ikoyi has no TM and serves Lagos/Eti-Osa: a ZSM's code, which
-- has no territory of its own, takes the covered territory of the LGA.
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'REG-EPE', 'REGIONAL',
   '40000000-0000-0000-0000-000000000003'),
  ('71000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'REG-IKOYI', 'REGIONAL',
   '40000000-0000-0000-0000-000000000004');
update public.territories set web_fulfilment_warehouse_id = '71000000-0000-0000-0000-000000000001'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set web_fulfilment_warehouse_id = '71000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000003';
update public.territories set web_fulfilment_warehouse_id = '71000000-0000-0000-0000-000000000004'
 where id = '40000000-0000-0000-0000-000000000004';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id) values
  ('10000000-0000-0000-0000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'LA', md5('ng_lga:LA:Eti-Osa')::uuid, '40000000-0000-0000-0000-000000000004');

insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   '+2348000000004', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
update public.tenant_settings set web_agent_commission_bps = 150
 where tenant_id = '10000000-0000-0000-0000-000000000001';
insert into public.web_pos_venues (id, tenant_id, partner_id, agent_id, network_terminal_id, territory_id, is_active) values
  ('61000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'MP-0001', '40000000-0000-0000-0000-000000000001', true),
  ('61000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000007', 'MP-0007', '40000000-0000-0000-0000-000000000003', true);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, is_active, nafdac_number) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400', 'Milo 400g', 'Milo', 'Beverages', 2500, 2000, true, 'A1-0101');

insert into public.web_referral_codes (id, tenant_id, code, agent_id, venue_id, discount_type, discount_value,
                                max_redemptions, expires_at, is_active, created_by) values
  ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GRACE-01',
   '20000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000001', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000002'),
  ('62000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'EPE-01',
   '20000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-000000000007', null, null,
   null, null, true, '20000000-0000-0000-0000-000000000003'),
  ('62000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'ZSM-01',
   '20000000-0000-0000-0000-000000000001', null, null, null,
   null, null, true, '20000000-0000-0000-0000-000000000001');

create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
grant execute on function pg_temp.as_service() to service_role;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── schema ──────────────────────────────────────────────────────────────
select hasnt_column('public', 'orders', 'customer_name',    'orders no longer holds the buyer''s name');
select hasnt_column('public', 'orders', 'customer_phone',   'orders no longer holds the buyer''s phone');
select hasnt_column('public', 'orders', 'customer_email',   'orders no longer holds the buyer''s email');
select hasnt_column('public', 'orders', 'delivery_address', 'orders no longer holds the delivery address');
select ok((select relrowsecurity from pg_class where oid = 'public.order_contacts'::regclass),
  'order_contacts has RLS enabled');
select ok(not has_column_privilege('authenticated', 'public.payments', 'gateway_response_payload', 'select'),
  'the app cannot read Paystack''s raw payload');
select ok(has_column_privilege('authenticated', 'public.payments', 'payment_status', 'select'),
  'the app can still read payment status');

-- ── place_web_order writes the contact row ──────────────────────────────
select pg_temp.as_service();
select lives_ok(
  $$select pg_temp.pwo('dddddddd-0000-0000-0000-000000000001', 'GRACE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031234567","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
      null, 'POS_AGENT', 2500.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a pay-at-agent order is placed');
select lives_ok(
  $$select pg_temp.pwo('dddddddd-0000-0000-0000-000000000002', 'EPE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Bola","phone":"+2348031234568","delivery_address":"7 Toyin Street, Epe"}',
      null, 'PAYSTACK_WEB', 2500.00,
      '{"reference":"TFW-e1","access_code":"ac_e1","authorization_url":"https://checkout.paystack.com/ac_e1",
        "split":{"subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":37.50}}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a Paystack order in Epe is placed');
select lives_ok(
  $$select pg_temp.pwo('dddddddd-0000-0000-0000-000000000003', 'ZSM-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Chi","phone":"+2348031234569","delivery_address":"9 Awolowo Way"}',
      null, 'PAYSTACK_WEB', 2500.00,
      '{"reference":"TFW-z1","access_code":"ac_z1","authorization_url":"https://checkout.paystack.com/ac_z1","split":null}', md5('ng_lga:LA:Eti-Osa')::uuid)$$,
  'an order on a ZSM''s code is placed');
select lives_ok(
  $$select pg_temp.pwo('dddddddd-0000-0000-0000-000000000004', 'GRACE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Dayo","phone":"+2348031234570","delivery_address":"3 Allen Avenue"}',
      null, 'PAYSTACK_WEB', 2500.00,
      '{"reference":"TFW-g2","access_code":"ac_g2","authorization_url":"https://checkout.paystack.com/ac_g2",
        "split":{"subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":37.50}}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a Paystack order on the agent''s code is placed');
reset role;

-- the references, for the lookups in Task 2 and the role checks below
create temp table refs on commit drop as
  select l.key, l.response ->> 'public_reference' as public_reference, (l.response ->> 'order_id')::uuid as order_id
    from public.idempotency_logs l
   where l.key in ('dddddddd-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000002',
                   'dddddddd-0000-0000-0000-000000000003', 'dddddddd-0000-0000-0000-000000000004');
grant select on refs to authenticated;

select is(
  (select c.customer_name || '|' || c.customer_phone || '|' || c.customer_email || '|' || c.delivery_address
          || '|' || c.territory_id
     from public.order_contacts c join refs r on r.order_id = c.order_id
    where r.key = 'dddddddd-0000-0000-0000-000000000001'),
  'Ada Obi|+2348031234567|ada@example.com|5 Opebi Road, Ikeja|40000000-0000-0000-0000-000000000001',
  'the contact row holds the details and the terminal''s territory');
select is(
  (select c.territory_id from public.order_contacts c join refs r on r.order_id = c.order_id
    where r.key = 'dddddddd-0000-0000-0000-000000000003'),
  '40000000-0000-0000-0000-000000000004'::uuid,
  'a ZSM''s code gives no territory of its own: the delivery LGA''s covered territory (no TM) is stamped');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'place_web_order'
      and (after::text like '%+234803123456%' or after::text like '%@example.com%'
           or after::text like '%Opebi%' or after::text like '%Toyin%')),
  0, 'audit rows carry no phone, email or address');
select is(
  (select a.after -> 'contact' from public.audit_logs a join refs r on r.order_id::text = a.entity_id
    where a.operation = 'place_web_order' and r.key = 'dddddddd-0000-0000-0000-000000000001'),
  '{"phone_last4":"4567","has_email":true,"has_address":true}'::jsonb,
  'the audit row carries a redacted contact summary');

-- ── who can read contact rows ───────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 4, 'the ZSM sees every contact row in the tenant');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 2, 'the Ikeja TM sees only Ikeja''s rows');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 1, 'the Epe TM sees only Epe''s row');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 0, 'a POS agent sees no contact rows');
select is((select count(*)::int from public.orders), 4, 'a POS agent still sees the orders themselves');
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 0, 'a DSA sees no contact rows');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.order_contacts), 0, 'a shop owner sees no contact rows');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.order_contacts), 0, 'another tenant''s ZSM sees no contact rows');
reset role;

-- ── the throttle reads order_contacts ───────────────────────────────────
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
  $$select pg_temp.pwo('dddddddd-0000-0000-0000-000000000009', 'GRACE-01',
      '[{"sku_code":"MILO-400","qty":1}]',
      '{"name":"Spam","phone":"+2348099999999","delivery_address":"1 Nowhere"}',
      null, 'POS_AGENT', 2500.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Too many unpaid orders for this phone number. Try again later.',
  'a sixth pending web order within the hour is still refused');
reset role;

-- ── pos_order_lookup: a masked till view for the order's agent ──────────
select ok(has_function_privilege('authenticated', 'public.pos_order_lookup(text)', 'execute'),
  'the app can call pos_order_lookup');
select ok(not has_function_privilege('anon', 'public.pos_order_lookup(text)', 'execute'),
  'anon cannot');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is(
  public.pos_order_lookup((select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001'))
    - 'public_reference',
  '{"first_name":"Ada","phone_last4":"4567","total":2500.00,"currency":"NGN","status":"PENDING"}'::jsonb,
  'the agent sees first name, phone last 4, total and status');
select is(
  public.pos_order_lookup((select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001'))
    ->> 'public_reference',
  (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001'),
  'and the reference');
select is(
  public.pos_order_lookup((select ' ' || lower(public_reference) || ' ' from refs
                            where key = 'dddddddd-0000-0000-0000-000000000001')) ->> 'first_name',
  'Ada', 'a lower-case, padded reference is accepted');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000004')),
  'P0001', 'Order not found', 'a Paystack-route order is not shown');
select throws_ok($$select public.pos_order_lookup('TF-000000')$$,
  'P0001', 'Order not found', 'an unknown reference is not shown');

select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  'P0001', 'Order not found', 'another agent cannot look the order up');

select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  'P0001', 'Order not found', 'another tenant cannot look the order up');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  'P0001', 'Order not found', 'the till lookup is only for the order''s agent, not the ZSM');

select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  format('select public.pos_order_lookup(%L)',
         (select public_reference from refs where key = 'dddddddd-0000-0000-0000-000000000001')),
  '42501', null, 'a disabled member is refused');
reset role;

select * from finish();
rollback;
