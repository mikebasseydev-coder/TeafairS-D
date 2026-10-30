-- Addendum A6 §18.4 (Task 1f) — operational states. A platform administrator
-- switches each state on, separately for the app and the web; each brand then
-- opts in to the platform-active states through a cited DISTRIBUTION decision.
-- A new web order, storefront location, web route, enrolment, supply day or
-- pledge needs both switches. Orders already placed are never blocked.
begin;
create extension if not exists pgtap with schema extensions;

select plan(72);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- tenant A = TEAFAIR: 2 CSM · 3 ZSM · 4 DSA · 8 TENANT_ADMIN
-- tenant B (BrandB):  5 CSM · 6 ZSM · 7 DSA      user 1 = platform administrator
-- Monvelo, tenant A: 9 ZSA · 10 TM · 11 shop owner · 12 member of a Monvelo agent
insert into public.tenants (id, name, code) values ('10000000-0000-0000-0000-000000000002', 'BrandB', 'BRANDB');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 12) n;
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN' where id = '20000000-0000-0000-0000-000000000001';
insert into public.tenant_settings (tenant_id, web_transport_fare) values ('10000000-0000-0000-0000-000000000002', 0);
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008',
   'TENANT_ADMIN', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000006',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007',
   'DSA', null, '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000006', 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000009', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000009',
   'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000010',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen');
insert into public.monvelo_tenant_settings (tenant_id, enabled) values ('7eaf0000-0000-4000-8000-000000000001', true);
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000011', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1');
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by) values
  ('c0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '71000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', extensions.crypt('123456', extensions.gen_salt('bf')),
   now() + interval '1 hour', '20000000-0000-0000-0000-000000000009');
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status) values
  ('80000000-0000-0000-0000-000000000001', 'Near POS', 'OPAY', 'OP-1', '+2348031110001',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
   '0123456789', '6789', '058', 'Near POS', 'K1', '20000000-0000-0000-0000-000000000009', 'ACTIVE');
insert into public.monvelo_agent_members (agent_id, profile_id) values
  ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000012');
update public.zones z
   set zsm_id = (select tu.profile_id from public.tenant_users tu
                  where tu.tenant_id = z.tenant_id and tu.role = 'ZSM' and tu.status = 'ACTIVE' limit 1);
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-A', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'REG-B', 'REGIONAL',
   '40000000-0000-0000-0000-000000000002');
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000001'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000002';
insert into public.web_referral_codes (tenant_id, code, agent_id, created_by) values
  ('7eaf0000-0000-4000-8000-000000000001', 'OPA-DSA', '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000003'),
  ('10000000-0000-0000-0000-000000000002', 'OPB-DSA', '20000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000006');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                     nafdac_number, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'OPA-1', 'A pack', 'BrandA', 'Skin care', 'COSMETICS', 'A7-2001', 100, 80),
  ('10000000-0000-0000-0000-000000000002', 'OPB-1', 'B pack', 'BrandB', 'Skin care', 'COSMETICS', 'A7-2002', 100, 80);
insert into public.web_phone_verifications (phone, code_hash, expires_at, verified_at, token_hash, token_expires_at)
select '+23480311111' || lpad(n::text, 2, '0'), 'x', now() + interval '10 minutes', now(),
       encode(extensions.digest('tok-' || n, 'sha256'), 'hex'), now() + interval '30 minutes'
  from generate_series(1, 6) n;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated, service_role;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer) to authenticated;

-- a report with a DISTRIBUTION and a STOCK decision
create function pg_temp.rep() returns jsonb language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'MEETING',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
    'summary', 'Agreed the states the brand distributes in.',
    'decisions', jsonb_build_array(
      jsonb_build_object('subject', 'DISTRIBUTION', 'text', 'Distribute in Lagos'),
      jsonb_build_object('subject', 'STOCK', 'text', 'Stock')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222')));
$$;
grant execute on function pg_temp.rep() to authenticated;
create temp table cd (n text, subject text, id uuid, primary key (n, subject));
grant select on cd to authenticated;

create function pg_temp.cite(p_name text, p_tenant uuid, p_csm uuid, p_zsm uuid, p_kb integer) returns void
language plpgsql as $$
declare v_rid uuid; v_slot jsonb;
begin
  perform pg_temp.act_as(p_csm, p_tenant);
  v_rid := (public.file_contact_report(pg_temp.k(p_kb), pg_temp.rep()) ->> 'report_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into cd select p_name, d.subject, d.id from public.contact_report_decisions d where d.report_id = v_rid;
  perform pg_temp.act_as(p_zsm, p_tenant);
  perform public.review_contact_report(pg_temp.k(p_kb + 1), v_rid, 'APPROVED');
  perform pg_temp.act_as(p_csm, p_tenant);
  v_slot := public.request_contact_report_hard_copy(pg_temp.k(p_kb + 2), v_rid, 'application/pdf', 1000);
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('contact-reports', v_slot ->> 'storage_path', jsonb_build_object('size', '1000', 'mimetype', 'application/pdf'));
  perform pg_temp.act_as(p_csm, p_tenant);
  perform public.attach_contact_report_hard_copy(pg_temp.k(p_kb + 3), (v_slot ->> 'hard_copy_id')::uuid);
  perform set_config('role', 'postgres', true);
end; $$;
create function pg_temp.d(p_n text, p_subject text) returns uuid language sql as
  $$ select id from cd where n = p_n and subject = p_subject $$;
grant execute on function pg_temp.d(text, text) to authenticated;
select pg_temp.cite('A', '7eaf0000-0000-4000-8000-000000000001', pg_temp.u(2), pg_temp.u(3), 100);
select pg_temp.cite('B', '10000000-0000-0000-0000-000000000002', pg_temp.u(5), pg_temp.u(6), 110);
reset role;

-- ── the platform switch ─────────────────────────────────────────────────
select is((select count(*)::int from public.operational_states), (select count(*)::int from public.ng_states),
  'every ng_states row is seeded');
select is((select count(*)::int from public.operational_states where app_enabled or web_enabled), 0,
  'both switches are off by default');
select is((select count(*)::int from public.tenant_operational_states), 0, 'no brand is opted in by default');
select ok(not public.state_app_operational('LA') and not public.state_web_operational('LA'),
  'the helpers report off');
select ok(not public.state_app_operational('ZZ') and not public.state_web_operational(null),
  'an unknown state is off');
select is(public.territory_state_code('7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001'),
  'LA', 'a territory''s state comes from its zone');
select is(public.territory_state_code('10000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001'),
  null, 'a territory of another tenant has no state');

select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_state_operational(pg_temp.k(1), 'LA', true, true, 'launch')$$,
  '42501', null, 'a ZSM cannot switch a state');
select pg_temp.act_as(pg_temp.u(1), null);
select throws_ok($$select public.set_state_operational(pg_temp.k(2), 'LA', true, true, '  ')$$,
  'P0001', 'a reason is required', 'a missing reason is refused');
select throws_ok($$select public.set_state_operational(pg_temp.k(3), 'ZZ', true, true, 'launch')$$,
  'P0001', 'unknown state', 'an unknown state is refused');
select throws_ok($$select public.set_state_operational(pg_temp.k(4), 'LA', null, true, 'launch')$$,
  'P0001', null, 'both switches are required');
select is(public.set_state_operational(pg_temp.k(5), 'LA', false, true, 'Lagos web launch') ->> 'web_enabled',
  'true', 'a platform administrator switches Lagos web on');
select is(public.set_state_operational(pg_temp.k(5), 'LA', false, true, 'Lagos web launch') ->> 'web_enabled',
  'true', 'a replay returns the first result');
reset role;
select is((select count(*)::int from public.operational_state_events where state_code = 'LA'), 1,
  'one history row, the replay wrote none');
select is((select count(*)::int from public.audit_logs
            where operation = 'set_state_operational' and idempotency_key = pg_temp.k(5)), 1, 'one audit row');
select is((select (after ->> 'reason') || '|' || (before ->> 'web_enabled') || '>' || (after ->> 'web_enabled')
             from public.audit_logs where operation = 'set_state_operational' and idempotency_key = pg_temp.k(5)),
  'Lagos web launch|false>true', 'the audit row holds the reason and the before and after');
select is((select app_enabled::text || web_enabled::text || (updated_by = pg_temp.u(1))::text
             from public.operational_states where state_code = 'LA'), 'falsetruetrue',
  'the row shows the switches and who set them');
select throws_ok($$update public.operational_state_events set reason = 'x'$$, 'P0001', null, 'history refuses UPDATE');
select throws_ok($$delete from public.operational_state_events$$, 'P0001', null, 'history refuses DELETE');
select throws_ok($$truncate public.operational_state_events$$, 'P0001', null, 'history refuses TRUNCATE');
select ok(not has_table_privilege('authenticated', 'public.operational_states', 'insert')
      and not has_table_privilege('authenticated', 'public.operational_states', 'update')
      and not has_table_privilege('anon', 'public.operational_states', 'select')
      and has_table_privilege('authenticated', 'public.operational_states', 'select'),
  'authenticated reads and never writes; anon holds nothing');

-- ── the brand opt-in ────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(10), 'LA', true, false, pg_temp.d('A', 'DISTRIBUTION'))$$,
  'P0001', 'Teafair is not operating in Lagos on this channel yet', 'a brand cannot opt in to the app where the platform app switch is off');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(11), 'LA', false, true, null)$$,
  'P0001', null, 'an opt-in without a decision is refused');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(12), 'LA', false, true, pg_temp.d('A', 'STOCK'))$$,
  'P0001', 'cite a decision on DISTRIBUTION', 'a decision on another subject is refused');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(13), 'LA', false, true, pg_temp.d('B', 'DISTRIBUTION'))$$,
  '42501', null, 'another brand''s decision is refused');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(14), 'ZZ', false, true, pg_temp.d('A', 'DISTRIBUTION'))$$,
  'P0001', 'unknown state', 'an unknown state is refused');
select pg_temp.act_as(pg_temp.u(8), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(15), 'LA', false, true, pg_temp.d('A', 'DISTRIBUTION'))$$,
  '42501', null, 'a TENANT_ADMIN cannot opt a brand in');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_tenant_operational_state(pg_temp.k(16), 'LA', false, true, pg_temp.d('A', 'DISTRIBUTION'))$$,
  '42501', null, 'a ZSM cannot opt in while the brand has a CSM');
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select is(public.set_tenant_operational_state(pg_temp.k(17), 'LA', false, true, pg_temp.d('A', 'DISTRIBUTION')) ->> 'web_enabled',
  'true', 'the CSM opts TEAFAIR in to Lagos on the web, citing a DISTRIBUTION decision');
select is(public.set_tenant_operational_state(pg_temp.k(17), 'LA', false, true, pg_temp.d('A', 'DISTRIBUTION')) ->> 'web_enabled',
  'true', 'a replay returns the first result');
select is((select count(*)::int from public.tenant_operational_states), 1, 'the opt-in is one row, visible to its own members');
select pg_temp.act_as(pg_temp.u(6), '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.tenant_operational_states), 0, 'another brand reads none of it');
reset role;
select is((select count(*)::int from public.tenant_operational_state_events
            where tenant_id = '7eaf0000-0000-4000-8000-000000000001'), 1, 'one history row for the opt-in');
select is((select count(*)::int from public.audit_logs
            where operation = 'set_tenant_operational_state' and idempotency_key = pg_temp.k(17)), 1, 'one audit row');
select throws_ok($$update public.tenant_operational_state_events set app_enabled = true$$, 'P0001', null,
  'the brand history refuses UPDATE');
select throws_ok($$delete from public.tenant_operational_state_events$$, 'P0001', null, 'the brand history refuses DELETE');
select ok(not has_table_privilege('authenticated', 'public.tenant_operational_states', 'insert')
      and not has_table_privilege('authenticated', 'public.tenant_operational_states', 'update')
      and not has_table_privilege('anon', 'public.tenant_operational_states', 'select'),
  'no API role writes the opt-in; anon holds nothing');

-- ── web: needs both switches ────────────────────────────────────────────
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok($$select public.place_web_order(pg_temp.k(30), 'OPA-DSA', '[{"sku_code":"OPA-1","qty":1}]',
    '{"name":"Ada Obi","phone":"+2348031111101","delivery_address":"5 Opebi Road, Ikeja"}', null,
    'PAYSTACK_WEB', 850.00,
    '{"reference":"TFW-op-1","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac","split":null}',
    md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-1')$$,
  'with the platform and the brand on, a web order to Lagos succeeds');
select throws_ok($$select public.place_web_order(pg_temp.k(31), 'OPB-DSA', '[{"sku_code":"OPB-1","qty":1}]',
    '{"name":"Bola","phone":"+2348031111102","delivery_address":"7 Toyin Street, Ikeja"}', null,
    'PAYSTACK_WEB', 100.00,
    '{"reference":"TFW-op-2","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac","split":null}',
    md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-2')$$,
  'P0001', 'we do not deliver to Lagos yet', 'brand B, not opted in, is refused in the same state');
reset role;
select is((select count(*)::int from public.web_phone_verifications where consumed_at is not null), 1,
  'the refused order did not consume the buyer''s verification');
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(jsonb_array_length(public.storefront_locations('OPA-DSA') -> 'states'), 1, 'the storefront lists the one state A is on in');
select is(public.storefront_locations('OPA-DSA') -> 'states' -> 0 ->> 'code', 'LA', 'and it is Lagos');
select is(jsonb_array_length(public.storefront_locations('OPB-DSA') -> 'states'), 0, 'brand B''s storefront lists no state');
select is(jsonb_array_length(public.storefront_locations(null) -> 'states'), 1, 'the codeless storefront (TEAFAIR) lists Lagos');
reset role;
select ok((public.web_route_try('7eaf0000-0000-4000-8000-000000000001', public.web_storefront_code('OPA-DSA'),
             md5('ng_lga:LA:Ikeja')::uuid)).territory_id is not null, 'web_route_try routes brand A in Lagos');
select ok((public.web_route_try('10000000-0000-0000-0000-000000000002', public.web_storefront_code('OPB-DSA'),
             md5('ng_lga:LA:Ikeja')::uuid)).territory_id is null, 'web_route_try never routes brand B in Lagos');
reset role;

-- bridging: brand B has no CSM, so its ZSM may opt in
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000005';
select pg_temp.act_as(pg_temp.u(6), '10000000-0000-0000-0000-000000000002');
select is(public.set_tenant_operational_state(pg_temp.k(40), 'LA', false, true, pg_temp.d('B', 'DISTRIBUTION')) ->> 'web_enabled',
  'true', 'a ZSM opts the brand in while it has no CSM');
reset role;
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok($$select public.place_web_order(pg_temp.k(41), 'OPB-DSA', '[{"sku_code":"OPB-1","qty":1}]',
    '{"name":"Bola","phone":"+2348031111102","delivery_address":"7 Toyin Street, Ikeja"}', null,
    'PAYSTACK_WEB', 100.00,
    '{"reference":"TFW-op-2","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac","split":null}',
    md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-2')$$,
  'once B opts in, its web order to Lagos succeeds');
reset role;

-- the platform switch is the master: with the web off, the opted-in brand is refused
select pg_temp.act_as(pg_temp.u(1), null);
select public.set_state_operational(pg_temp.k(50), 'LA', true, false, 'Lagos web paused; app on');
reset role;
select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok($$select public.place_web_order(pg_temp.k(51), 'OPA-DSA', '[{"sku_code":"OPA-1","qty":1}]',
    '{"name":"Ada Obi","phone":"+2348031111103","delivery_address":"5 Opebi Road, Ikeja"}', null,
    'PAYSTACK_WEB', 850.00,
    '{"reference":"TFW-op-3","access_code":"ac","authorization_url":"https://checkout.paystack.com/ac","split":null}',
    md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-3')$$,
  'P0001', 'we do not deliver to Lagos yet', 'the brand is opted in but the platform web switch is off');
select is(jsonb_array_length(public.storefront_locations('OPA-DSA') -> 'states'), 0, 'the storefront lists no state with the platform web off');
reset role;
select is((select count(*)::int from public.orders where channel = 'ONLINE'), 2, 'the two placed orders stand');

-- ── in-flight work is never blocked ─────────────────────────────────────
-- pay O1, then dispatch and deliver it with the platform switch off for both channels
select public.settle_paystack_payment('charge.success', 'TFW-op-1', 'success', 85000, 'NGN', '{}', '9201', null, null);
select pg_temp.act_as(pg_temp.u(1), null);
select public.set_state_operational(pg_temp.k(52), 'LA', false, false, 'Lagos switched off');
reset role;
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is(public.mark_order_dispatched(pg_temp.k(60),
    (select id from public.orders where public_reference is not null and total_amount = 850.00), null, '4321', 'test-gw-secret') ->> 'status',
  'IN_TRANSIT', 'an order placed before the switch-off is still dispatched');
select is(public.mark_order_delivered(pg_temp.k(61),
    (select id from public.orders where total_amount = 850.00), '4321') ->> 'status',
  'DELIVERED', 'and delivered');
reset role;
select ok(exists (select 1 from public.orders where total_amount = 850.00 and status = 'DELIVERED'), 'the order is DELIVERED');

-- ── app: enrolment, supply days, pledges ────────────────────────────────
create function pg_temp.enrol() returns jsonb language sql as
  $$ select public.enrol_monvelo_shop(pg_temp.k(80 + (random() * 1000)::int), 'c0000000-0000-0000-0000-000000000001', '123456') $$;
grant execute on function pg_temp.enrol() to authenticated;
select set_config('test.day', (public.monvelo_today() + 1)::text, true);
create function pg_temp.supply(p_n integer) returns jsonb language sql as
  $$ select public.set_monvelo_supply_day(pg_temp.k(p_n), '60000000-0000-0000-0000-000000000001',
       extract(isodow from current_setting('test.day')::date)::int, true) $$;
grant execute on function pg_temp.supply(integer) to authenticated;
create function pg_temp.pledge(p_n integer) returns jsonb language sql as
  $$ select public.pledge_monvelo_funds(pg_temp.k(p_n), '80000000-0000-0000-0000-000000000001',
       '60000000-0000-0000-0000-000000000001', current_setting('test.day')::date, 5000) $$;
grant execute on function pg_temp.pledge(integer) to authenticated;

-- the platform app switch is off (Lagos was switched off above)
select pg_temp.act_as(pg_temp.u(9), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.enrol()$$, 'P0001', 'Teafair is not operating in Lagos yet', 'enrolment is refused in an app-off state');
select pg_temp.act_as(pg_temp.u(10), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.supply(90)$$, 'P0001', 'Teafair is not operating in Lagos yet', 'a supply day is refused in an app-off state');
select pg_temp.act_as(pg_temp.u(12), null);
select throws_ok($$select pg_temp.pledge(91)$$, 'P0001', 'Teafair is not operating in Lagos yet', 'a pledge is refused in an app-off state');
reset role;
select throws_ok($$select public.assert_state_app_operational('7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001')$$,
  'P0001', 'Teafair is not operating in Lagos yet', 'the app assertion refuses an off state');
select ok(not public.tenant_state_app_operational('7eaf0000-0000-4000-8000-000000000001', 'LA'),
  'the effective app rule is off with the platform off');

-- the platform opens the app in Lagos, but brand A has not opted in
select pg_temp.act_as(pg_temp.u(1), null);
select public.set_state_operational(pg_temp.k(70), 'LA', true, false, 'Lagos app launch');
select pg_temp.act_as(pg_temp.u(10), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.supply(92)$$, 'P0001', 'Teafair is not operating in Lagos yet',
  'with the platform on, a brand that has not opted in is still refused');
-- brand A opts in to the app (and out of the web in the same call)
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select public.set_tenant_operational_state(pg_temp.k(71), 'LA', true, false, pg_temp.d('A', 'DISTRIBUTION'));
reset role;
select ok(public.tenant_state_app_operational('7eaf0000-0000-4000-8000-000000000001', 'LA')
      and not public.tenant_state_app_operational('10000000-0000-0000-0000-000000000002', 'LA'),
  'the app rule needs both: A is on, B is not');
select ok(not public.tenant_state_web_operational('7eaf0000-0000-4000-8000-000000000001', 'LA'),
  'and the web rule is off for A, which opted out of the web');
select is((select count(*)::int from public.tenant_operational_state_events
            where tenant_id = '7eaf0000-0000-4000-8000-000000000001'), 2,
  'opting out of the web (the same call) added a history row');
select pg_temp.act_as(pg_temp.u(10), '7eaf0000-0000-4000-8000-000000000001');
select is(pg_temp.supply(93) ->> 'active', 'true', 'with both on, the TM sets a supply day');
select pg_temp.act_as(pg_temp.u(9), '7eaf0000-0000-4000-8000-000000000001');
select is(pg_temp.enrol() ->> 'enrolled', 'true', 'with both on, the ZSA enrols the shop');
select pg_temp.act_as(pg_temp.u(12), null);
select is(pg_temp.pledge(94) ->> 'amount', '5000.00', 'with both on, the agent pledges');
reset role;

-- ── winding down is always allowed (A6 §18.4, user ruling 2026-10-30) ──
select pg_temp.act_as(pg_temp.u(1), null);
select public.set_state_operational(pg_temp.k(120), 'LA', false, false, 'Lagos app paused');
select pg_temp.act_as(pg_temp.u(12), null);
select is(public.pledge_monvelo_funds(pg_temp.k(121), '80000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000001', current_setting('test.day')::date, 3000) ->> 'amount', '3000.00',
  'in an app-off state an agent may still reduce a pledge');
select throws_ok($$select public.pledge_monvelo_funds(pg_temp.k(122), '80000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000001', current_setting('test.day')::date, 6000)$$,
  'P0001', 'Teafair is not operating in Lagos yet', 'an increase is refused in an app-off state');
select throws_ok($$select public.pledge_monvelo_funds(pg_temp.k(123), '80000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000001', current_setting('test.day')::date + 7, 1000)$$,
  'P0001', 'Teafair is not operating in Lagos yet', 'a new pledge is refused in an app-off state');
select pg_temp.act_as(pg_temp.u(10), '7eaf0000-0000-4000-8000-000000000001');
select is(public.set_monvelo_supply_day(pg_temp.k(124), '60000000-0000-0000-0000-000000000001',
    extract(isodow from current_setting('test.day')::date)::int, false) ->> 'active', 'false',
  'in an app-off state the TM may still deactivate a supply day');
select throws_ok($$select pg_temp.supply(125)$$, 'P0001', 'Teafair is not operating in Lagos yet',
  'activating a supply day is refused in an app-off state');
select pg_temp.act_as(pg_temp.u(9), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.start_monvelo_consent(pg_temp.k(126), 'test-gw-secret',
    '71000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001')$$,
  'P0001', 'Teafair is not operating in Lagos yet', 'a consent code is not issued in an app-off state');
reset role;

select * from finish();
rollback;
