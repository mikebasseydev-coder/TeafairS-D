-- Domain separation, Task 3 (A6 section 15.4): the web domain renames.
-- Shape, grants and one end-to-end smoke through the renamed objects.
begin;
create extension if not exists pgtap with schema extensions;

select plan(56);

-- ── shape ───────────────────────────────────────────────────────────────
select has_table('public', 'web_pos_partners',   'web_pos_partners exists');
select has_table('public', 'web_pos_venues',     'web_pos_venues exists');
select has_table('public', 'web_referral_codes', 'web_referral_codes exists');
select has_table('public', 'web_commissions',    'web_commissions exists');
select hasnt_table('public', 'fintech_partners',   'fintech_partners is gone');
select hasnt_table('public', 'fintech_terminals',  'fintech_terminals is gone');
select hasnt_table('public', 'agent_codes',        'agent_codes is gone');
select hasnt_table('public', 'commission_records', 'commission_records is gone');

select has_column('public', 'payments', 'web_pos_partner_id', 'payments.web_pos_partner_id');
select has_column('public', 'payments', 'web_pos_venue_id',   'payments.web_pos_venue_id');
select hasnt_column('public', 'payments', 'fintech_partner_id',  'payments.fintech_partner_id is gone');
select hasnt_column('public', 'payments', 'fintech_terminal_id', 'payments.fintech_terminal_id is gone');
select has_column('public', 'web_commissions', 'web_pos_partner_id', 'web_commissions.web_pos_partner_id');
select has_column('public', 'web_referral_codes', 'venue_id', 'web_referral_codes.venue_id');
select hasnt_column('public', 'web_referral_codes', 'terminal_id', 'web_referral_codes.terminal_id is gone');
select has_column('public', 'web_pos_venues', 'network_terminal_id', 'web_pos_venues.network_terminal_id');
select hasnt_column('public', 'web_pos_venues', 'terminal_id', 'web_pos_venues.terminal_id is gone');
select has_column('public', 'orders', 'referral_code_id',    'orders.referral_code_id');
select has_column('public', 'orders', 'attributed_venue_id', 'orders.attributed_venue_id');
select hasnt_column('public', 'orders', 'agent_code_id',          'orders.agent_code_id is gone');
select hasnt_column('public', 'orders', 'attributed_terminal_id', 'orders.attributed_terminal_id is gone');

select policies_are('public', 'web_pos_partners',   array['web_pos_partners_select_tenant_member']);
select policies_are('public', 'web_pos_venues',     array['web_pos_venues_select_tenant_member']);
select policies_are('public', 'web_referral_codes', array['web_referral_codes_select_tenant_member']);
select policies_are('public', 'web_commissions',    array['web_commissions_select_tenant_member']);

select has_trigger('public', 'web_referral_codes', 'web_referral_codes_no_discount', 'the no-discount trigger');
select has_trigger('public', 'web_commissions', 'web_commissions_support_ticket_ins', 'the dispute-ticket insert trigger');
select has_trigger('public', 'web_commissions', 'web_commissions_support_ticket_upd', 'the dispute-ticket update trigger');

select fk_ok('public', 'orders', array['tenant_id', 'attributed_venue_id'], 'public', 'web_pos_venues', array['tenant_id', 'id']);
select fk_ok('public', 'orders', array['tenant_id', 'referral_code_id'], 'public', 'web_referral_codes', array['tenant_id', 'id']);
select fk_ok('public', 'payments', array['tenant_id', 'web_pos_partner_id'], 'public', 'web_pos_partners', array['tenant_id', 'id']);
select fk_ok('public', 'payments', array['tenant_id', 'web_pos_venue_id'], 'public', 'web_pos_venues', array['tenant_id', 'id']);
select fk_ok('public', 'web_commissions', array['tenant_id', 'web_pos_partner_id'], 'public', 'web_pos_partners', array['tenant_id', 'id']);
select fk_ok('public', 'web_referral_codes', array['tenant_id', 'venue_id'], 'public', 'web_pos_venues', array['tenant_id', 'id']);

-- ── grants ──────────────────────────────────────────────────────────────
select ok(has_column_privilege('authenticated', 'public.payments', 'web_pos_partner_id', 'SELECT'), 'authenticated reads payments.web_pos_partner_id');
select ok(has_column_privilege('authenticated', 'public.payments', 'web_pos_venue_id', 'SELECT'), 'authenticated reads payments.web_pos_venue_id');
select has_function('public', 'upsert_web_referral_code',
  array['uuid','text','uuid','uuid','text','numeric','integer','timestamp with time zone','boolean']);
select has_function('public', 'set_web_pos_venue',
  array['uuid','uuid','venue_channel_enum','text','text','text','text','double precision','double precision','jsonb']);
select hasnt_function('public', 'upsert_agent_code', 'upsert_agent_code is gone');
select hasnt_function('public', 'set_terminal_venue', 'set_terminal_venue is gone');
select function_privs_are('public', 'upsert_web_referral_code',
  array['uuid','text','uuid','uuid','text','numeric','integer','timestamp with time zone','boolean'],
  'authenticated', array['EXECUTE']);
select function_privs_are('public', 'upsert_web_referral_code',
  array['uuid','text','uuid','uuid','text','numeric','integer','timestamp with time zone','boolean'],
  'anon', array[]::text[]);
select function_privs_are('public', 'set_web_pos_venue',
  array['uuid','uuid','venue_channel_enum','text','text','text','text','double precision','double precision','jsonb'],
  'authenticated', array['EXECUTE']);
select function_privs_are('public', 'set_web_pos_venue',
  array['uuid','uuid','venue_channel_enum','text','text','text','text','double precision','double precision','jsonb'],
  'anon', array[]::text[]);

-- ── smoke fixtures (TEAFAIR) ────────────────────────────────────────────
-- 1 ZSM · 2 TM Ikeja · 3 POS_AGENT Ikeja · 4 TM Fagge
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000009', '7eaf0000-0000-4000-8000-000000000001', 'Kano');
insert into public.territories (id, tenant_id, zone_id, territory_name, boundary) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja',
   extensions.st_multi(extensions.st_makeenvelope(3.30, 6.55, 3.40, 6.65, 4326))),
  ('40000000-0000-0000-0000-000000000009', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000009', 'Fagge', null);
insert into public.tenant_users (tenant_id, profile_id, role, zone_id, territory_id, status, is_primary) values
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM',
   '30000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002', 'TM',
   null, '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'POS_AGENT',
   null, '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'TM',
   null, '40000000-0000-0000-0000-000000000009', 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001');
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000001'
 where id = '40000000-0000-0000-0000-000000000001';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id) values
  ('7eaf0000-0000-4000-8000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001');
insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   0, '+2348000000003', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.web_pos_venues (id, tenant_id, partner_id, agent_id, network_terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 'MP-0001', '40000000-0000-0000-0000-000000000001');
insert into public.web_phone_verifications (phone, code_hash, expires_at, verified_at, token_hash, token_expires_at) values
  ('+2348031111111', 'x', now() + interval '10 minutes', now(),
   encode(extensions.digest('tok-1', 'sha256'), 'hex'), now() + interval '30 minutes'),
  ('+2348032222222', 'x', now() + interval '10 minutes', now(),
   encode(extensions.digest('tok-2', 'sha256'), 'hex'), now() + interval '30 minutes');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── smoke: the TM issues a code with p_venue_id ────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001');
select lives_ok(
  $$select public.upsert_web_referral_code('bbbbbbbb-0000-0000-0000-000000000001', 'grace-01',
      '20000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001',
      null, null, null, null, true)$$,
  'a TM issues a code bound to a venue');
select is(
  (select public.upsert_web_referral_code('bbbbbbbb-0000-0000-0000-000000000001', 'grace-01',
      '20000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001',
      null, null, null, null, true) ->> 'referral_code_id'),
  (select id::text from public.web_referral_codes where code = 'GRACE-01'),
  'the same key replays the original result');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok(
  $$select public.upsert_web_referral_code('bbbbbbbb-0000-0000-0000-000000000002', 'FAGGE-01',
      '20000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001',
      null, null, null, null, true)$$,
  '42501', null, 'a TM of another territory is refused');
reset role;
select is(
  (select entity_type from public.audit_logs
    where operation = 'upsert_web_referral_code' and idempotency_key = 'bbbbbbbb-0000-0000-0000-000000000001'),
  'web_referral_codes', 'the code write is audited under the new table name');

-- ── smoke: the POS agent sets the venue ─────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001');
select lives_ok(
  $$select public.set_web_pos_venue('aaaaaaaa-0000-0000-0000-000000000001',
      '61000000-0000-0000-0000-000000000001', 'CHURCH', 'RCCG Grace Parish',
      '12 Allen Avenue, Ikeja', 'Lagos', 'Ikeja', 6.60, 3.35, null)$$,
  'the venue''s POS_AGENT sets its venue');
reset role;
select is(
  (select entity_type from public.audit_logs
    where operation = 'set_web_pos_venue' and idempotency_key = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'web_pos_venues', 'the venue write is audited under the new table name');

-- ── smoke: the storefront and checkout ──────────────────────────────────
select is(public.storefront_catalogue('GRACE-01') -> 'venue',
  '{"name":"RCCG Grace Parish","channel":"CHURCH"}'::jsonb, 'the storefront shows the venue name and channel');

select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(
  $$select public.place_web_order('b0000000-0000-0000-0000-000000000001', 'GRACE-01',
      '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":1}]',
      '{"name":"Ada Obi","phone":"+2348031111111","delivery_address":"5 Opebi Road, Ikeja"}', null,
      'POS_AGENT', 5750.00, null, md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-1')$$,
  'a pay-at-agent order is placed');
create temp table placed as
select public.place_web_order('b0000000-0000-0000-0000-000000000002', 'GRACE-01',
         '[{"sku_code":"PURERIGIN-COCONUT-OIL-200ML","qty":1}]',
         '{"name":"Bola","phone":"+2348032222222","delivery_address":"7 Toyin Street, Ikeja"}', null,
         'PAYSTACK_WEB', 5750.00,
         '{"reference":"TFW-rename-1","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac",
           "split":{"subaccount_code":"ACCT_grace01","commission_bps":0,"partner_share":500.00}}',
         md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-2') as r;
reset role;
select is(
  (select o.attributed_venue_id::text from public.orders o
    where o.payment_route = 'POS_AGENT' and o.referral_code_id = (select id from public.web_referral_codes where code = 'GRACE-01')),
  '61000000-0000-0000-0000-000000000001', 'a pay-at-agent order records the attributed venue');
select is(
  (select p.web_pos_partner_id::text || '|' || p.web_pos_venue_id::text from public.payments p
    where p.paystack_reference = 'TFW-rename-1'),
  '60000000-0000-0000-0000-000000000001|61000000-0000-0000-0000-000000000001',
  'the Paystack payment records the partner and the venue');

-- ── smoke: the dispute evidence key ─────────────────────────────────────
grant select on placed to authenticated;
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001');
create temp table ev as
select public.get_order_dispute_evidence((select (r ->> 'order_id')::uuid from placed)) as b;
reset role;
select ok((select b -> 'order' ? 'referral_code_id' from ev), 'the evidence order carries referral_code_id');
select ok((select not (b -> 'order' ? 'agent_code_id') from ev), 'and no longer agent_code_id');

select * from finish();
rollback;
