-- Spec D1 — locations and routing (§3–§5), and the public storefront RPCs (§5.2, §8.3, §8.4).
begin;
create extension if not exists pgtap with schema extensions;

select plan(111);

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

-- ── Task 1: ng_states / ng_lgas (§3.1) ──────────────────────────────────
select is((select count(*)::int from public.ng_states), 37, 'exactly 37 states (FCT included)');
select is((select count(*)::int from public.ng_lgas), 774, 'exactly 774 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'LA'), 20, 'Lagos has 20 LGAs');
select is((select count(*)::int from public.ng_lgas where state_code = 'FC'), 6, 'FCT has 6 area councils');
select is((select id from public.ng_lgas where state_code = 'LA' and name = 'Ikeja'),
          md5('ng_lga:LA:Ikeja')::uuid, 'LGA ids are deterministic');
select ok(has_table_privilege('authenticated', 'public.ng_lgas', 'select'), 'authenticated reads LGAs');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'insert'), 'no write grant on LGAs');
select throws_ok($$insert into public.ng_states values ('lagos', 'X')$$, '23514', null, 'state code is two capitals');

select ok(not has_table_privilege('authenticated', 'public.ng_states', 'insert')
       and not has_table_privilege('authenticated', 'public.ng_states', 'update')
       and not has_table_privilege('authenticated', 'public.ng_states', 'delete'), 'no write grant on states');
select ok(not has_table_privilege('authenticated', 'public.ng_lgas', 'update')
       and not has_table_privilege('authenticated', 'public.ng_lgas', 'delete'), 'no update/delete grant on LGAs');
select is((select count(*)::int from public.ng_lgas where (state_code, name) in (
  ('LA','Ikeja'), ('LA','Eti-Osa'), ('OY','Oyo West'), ('NI','Munya'),
  ('NA','Nasarawa Eggon'), ('FC','Abuja Municipal'), ('AD','Girei'))), 7,
  'spot-checked LGA names exist under their state');

-- ── Task 2: coverage, routing columns, constraints (§3.2–3.4) ───────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1CODE'),
  ('10000000-0000-0000-0000-000000000002', 'T2', 'T2CODE');
insert into public.tenant_settings (tenant_id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Epe');
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'REG-EPE', 'REGIONAL', '40000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'CENTRAL-1', 'CENTRAL', null),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'T2-CENTRAL', 'CENTRAL', null);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', '30000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSM', '30000000-0000-0000-0000-000000000001', 'DISABLED', false);

-- coverage
select lives_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001')$$, 'LGA row');
select lives_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'LA', null, '40000000-0000-0000-0000-000000000002')$$, 'state fallback row');
select throws_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'LA', null, '40000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'a second state fallback is rejected (NULLS NOT DISTINCT)');
select throws_ok($$insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values ('10000000-0000-0000-0000-000000000001', 'OG', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001')$$,
  'P0001', null, 'LGA must belong to the state');
select ok(has_table_privilege('authenticated', 'public.territory_coverage', 'select')
      and not has_table_privilege('authenticated', 'public.territory_coverage', 'insert'), 'coverage is select-only');

-- warehouse pointers
select throws_ok($$update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000003'
  where id = '40000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'territory pointer must be REGIONAL');
select throws_ok($$update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000002'
  where id = '40000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'regional warehouse must belong to this territory');
select lives_ok($$update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000001'
  where id = '40000000-0000-0000-0000-000000000001'$$, 'own regional warehouse');
select throws_ok($$update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000001'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'default must be CENTRAL');
select throws_ok($$update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000009'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, '23503', null, 'default must be same tenant');
select lives_ok($$update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000003'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'central default accepted');
select throws_ok($$update public.tenant_settings set web_default_agent_id = '20000000-0000-0000-0000-000000000002'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'P0001', null, 'default agent must be ACTIVE');
select lives_ok($$update public.tenant_settings set web_default_agent_id = '20000000-0000-0000-0000-000000000001'
  where tenant_id = '10000000-0000-0000-0000-000000000001'$$, 'active default agent accepted');

-- orders / payments constraints
select throws_ok($$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status)
  values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, 'PENDING')$$,
  '23514', null, 'orders_online_routed');
select lives_ok($$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status)
  values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, 'CANCELLED')$$,
  'cancelled orders need no routing');
select throws_ok($$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
    delivery_lga_id, territory_id, fulfilment_warehouse_id)
  values ('10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000001', 100, 'PENDING', 'POS_AGENT',
    md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'orders_codeless_pays_online');

insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
    delivery_lga_id, territory_id, fulfilment_warehouse_id)
  values ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'ONLINE',
    '20000000-0000-0000-0000-000000000001', 100, 'PENDING', 'PAYSTACK_WEB',
    md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001');
select throws_ok($$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference, split_bps)
  values ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001', 100, 'REF1', 150)$$,
  '23514', null, 'split snapshot all-or-none');
select throws_ok($$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference,
    split_subaccount_code, split_bps, split_amount)
  values ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
    '20000000-0000-0000-0000-000000000001', 100, 'REF2', 'ACCT_x1', 150, 100)$$,
  '23514', null, 'split below amount');
select ok(has_column_privilege('authenticated', 'public.payments', 'split_amount', 'select'), 'split columns readable');

-- ── Task 3: routing and the management RPCs (§4, §5.1) ──────────────────
-- 3 TM Ikeja · 4 DSA Ikeja · 5 POS agent Ikeja · 6 POS agent Epe (no TM) · 7 default agent
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000007', '2348000000007');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id = '30000000-0000-0000-0000-000000000001';
update public.tenant_settings set web_default_agent_id = '20000000-0000-0000-0000-000000000007'
 where tenant_id = '10000000-0000-0000-0000-000000000001';

insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000005', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
-- the Epe terminal has no territory of its own
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'MP-0005', '40000000-0000-0000-0000-000000000001'),
  ('61000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006', 'MP-0006', null);
insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'DSACODE1', '20000000-0000-0000-0000-000000000004', null, '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'POSIKEJA', '20000000-0000-0000-0000-000000000005', '61000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'POSEPE01', '20000000-0000-0000-0000-000000000006', '61000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- codeless tenant
select is(public.web_codeless_tenant(), (select id from public.tenants where code = 'TEAFAIR'), 'codeless traffic belongs to TEAFAIR');
update public.tenants set status = 'SUSPENDED' where code = 'TEAFAIR';
select throws_ok($$select public.web_codeless_tenant()$$, 'P0001', 'This shop is not open yet', 'no active TEAFAIR tenant');
update public.tenants set status = 'ACTIVE' where code = 'TEAFAIR';

-- codeless routing
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).territory_id,
          '40000000-0000-0000-0000-000000000001'::uuid, 'LGA hit');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Epe')::uuid)).territory_id,
          '40000000-0000-0000-0000-000000000002'::uuid, 'state fallback');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Epe')::uuid)).warehouse_id,
          '70000000-0000-0000-0000-000000000003'::uuid, 'CENTRAL fallback when the territory has no regional warehouse');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).warehouse_id,
          '70000000-0000-0000-0000-000000000001'::uuid, 'the territory''s regional warehouse wins');
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:KN:Fagge')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'uncovered state refused');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:KN:Fagge')::uuid)).territory_id,
          null, 'try never raises, it returns nulls');
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, gen_random_uuid())$$,
  'P0001', 'choose a delivery area from the list', 'unknown LGA is a clean refusal');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000003'::uuid, 'codeless -> territory TM');

-- coded
select is((public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'DSACODE1'), md5('ng_lga:KN:Fagge')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000004'::uuid, 'staff holder accountable for own sale, LGA ignored for territory');
select is((public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'DSACODE1'), md5('ng_lga:KN:Fagge')::uuid)).territory_id,
          '40000000-0000-0000-0000-000000000001'::uuid, 'coded territory comes from the holder');
select is((public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'POSIKEJA'), md5('ng_lga:LA:Epe')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000003'::uuid, 'FINTECH_AGENT code -> TM of terminal territory');
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001',
            (select ac from public.agent_codes ac where code = 'POSEPE01'), md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'This link is not active yet', 'coded, no TM (holder territory Epe)');

-- territory resolved but no warehouse at all
update public.tenant_settings set web_default_warehouse_id = null
 where tenant_id = '10000000-0000-0000-0000-000000000001';
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Epe')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'no warehouse refused');
update public.tenant_settings set web_default_warehouse_id = '70000000-0000-0000-0000-000000000003'
 where tenant_id = '10000000-0000-0000-0000-000000000001';

-- accountable fallbacks (Ikeja)
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000003';
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000001'::uuid, 'inactive TM skipped -> ZSM');
update public.zones set zsm_id = null where id = '30000000-0000-0000-0000-000000000001';
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)).accountable_id,
          '20000000-0000-0000-0000-000000000007'::uuid, 'no ZSM -> web_default_agent_id');
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000007';
select throws_ok($$select public.web_route_order('10000000-0000-0000-0000-000000000001', null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'no accountable person refused');
update public.tenant_users set status = 'ACTIVE' where id in ('50000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000007');

-- management RPCs
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok($$select public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000001', 'LA',
  md5('ng_lga:LA:Eti-Osa')::uuid, '40000000-0000-0000-0000-000000000002')$$, 'ZSM sets coverage');
select is((select territory_id from public.territory_coverage where lga_id = md5('ng_lga:LA:Eti-Osa')::uuid),
          '40000000-0000-0000-0000-000000000002'::uuid, 'the coverage row is stored');
select is((public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000002', 'LA',
  md5('ng_lga:LA:Eti-Osa')::uuid, null) ->> 'coverage_id'), null, 'null territory deletes the row');
select is((select count(*)::int from public.territory_coverage where lga_id = md5('ng_lga:LA:Eti-Osa')::uuid),
          0, 'and the row is gone');
select throws_ok($$select public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000003', 'LA',
  md5('ng_lga:OG:Abeokuta North')::uuid, '40000000-0000-0000-0000-000000000002')$$, 'P0001', null, 'LGA must belong to the state');
select lives_ok($$select public.set_territory_web_warehouse('bbbbbbbb-0000-0000-0000-000000000004',
  '40000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002')$$, 'ZSM sets a territory warehouse');
select is((select web_fulfilment_warehouse_id from public.territories where id = '40000000-0000-0000-0000-000000000002'),
          '70000000-0000-0000-0000-000000000002'::uuid, 'pointer stored');
select is((public.set_web_defaults('bbbbbbbb-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000003',
  '20000000-0000-0000-0000-000000000007') ->> 'agent_id'), '20000000-0000-0000-0000-000000000007', 'ZSM sets defaults');
select is((select count(*)::int from public.audit_logs where operation = 'set_web_defaults'
  and idempotency_key = 'bbbbbbbb-0000-0000-0000-000000000005'), 1, 'one audit row');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_territory_coverage('bbbbbbbb-0000-0000-0000-000000000006', 'LA', null,
  '40000000-0000-0000-0000-000000000002')$$, '42501', null, 'TM cannot set coverage');
select throws_ok($$select public.set_web_defaults('bbbbbbbb-0000-0000-0000-000000000007', null, null)$$,
  '42501', null, 'TM cannot set defaults');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.set_territory_web_warehouse('bbbbbbbb-0000-0000-0000-000000000008',
  '40000000-0000-0000-0000-000000000002', null)$$, '42501', null, 'DSA cannot set warehouse');
reset role;

select ok(not has_function_privilege('authenticated', 'public.web_route_order(uuid,public.agent_codes,uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.web_route_order(uuid,public.agent_codes,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_route_try(uuid,public.agent_codes,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_codeless_tenant()', 'execute'), 'routing is internal');
select ok(has_function_privilege('authenticated', 'public.set_territory_coverage(uuid,text,uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.set_territory_web_warehouse(uuid,uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.set_web_defaults(uuid,uuid,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.set_web_defaults(uuid,uuid,uuid)', 'execute'), 'management RPCs are for the app');


-- ── Task 4: public storefront RPCs (§5.2, §8.3, §8.4) ───────────────────
-- TEAFAIR: zone, territory with TM 11, REGIONAL warehouse, coverage LA/Ikeja,
-- one active product. T1: a 0-bps ACTIVE partner with a code on its terminal.
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000011', '2348000000011');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001', 'TF Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000011', 'TF Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000011',
   'TM', null, '40000000-0000-0000-0000-000000000011', null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000011'
 where id = '40000000-0000-0000-0000-000000000011';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001', 'TF-REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000011');
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000011'
 where id = '40000000-0000-0000-0000-000000000011';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id) values
  ('7eaf0000-0000-4000-8000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000011');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, is_active, nafdac_number) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TF-TEA-50', 'Teafair Tea 50 bags', 'Teafair', 'Beverages', 1000, 800, true, 'A1-0101'),
  ('10000000-0000-0000-0000-000000000001', 'T1-SKU', 'T1 product', 'T1', 'Beverages', 1000, 800, true, 'A1-0102');

insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Zero OPay', 'OPAY',
   0, '+2348000000005', 'ACCT_zero01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.fintech_terminals (id, tenant_id, partner_id, agent_id, terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000005', 'OP-0007', '40000000-0000-0000-0000-000000000001');
insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'ZERO-BPS', '20000000-0000-0000-0000-000000000005',
   '61000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000001');

create function pg_temp.order_of(p_key uuid) returns uuid language sql as $$
  select (response ->> 'order_id')::uuid from public.idempotency_logs where key = p_key;
$$;
create function pg_temp.ref_of(p_key uuid) returns text language sql as $$
  select response ->> 'public_reference' from public.idempotency_logs where key = p_key;
$$;
create function pg_temp.lga_deliverable(p_locations jsonb, p_state text, p_lga text) returns boolean language sql as $$
  select (l ->> 'deliverable')::boolean
    from jsonb_array_elements(p_locations -> 'states') s, jsonb_array_elements(s -> 'lgas') l
   where s ->> 'code' = p_state and l ->> 'name' = p_lga;
$$;

-- catalogue
select is(public.storefront_catalogue(null) -> 'tenant' ->> 'name', 'Teafair', 'codeless catalogue is TEAFAIR');
select is(public.storefront_catalogue('  ') -> 'tenant' ->> 'name', 'Teafair', 'blank code is codeless');
select is(public.storefront_catalogue() -> 'code', 'null'::jsonb, 'code is null when codeless');
select ok(exists (select 1 from jsonb_array_elements(public.storefront_catalogue(null) -> 'products') e
                   where e ->> 'sku_code' = 'TF-TEA-50')
          and not exists (select 1 from jsonb_array_elements(public.storefront_catalogue(null) -> 'products') e
                           where e ->> 'sku_code' = 'T1-SKU'),
  'codeless sees TEAFAIR''s products');
select throws_ok($$select public.storefront_catalogue('NOPE-99')$$, 'P0001', 'This link is no longer valid',
  'an unknown code is still refused, not treated as codeless');

-- quote
select throws_ok($$select public.quote_web_order(null, '[{"sku_code":"TF-TEA-50","qty":1}]', md5('ng_lga:KN:Fagge')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'quote refuses before Paystack');
select throws_ok($$select public.quote_web_order(null, '[{"sku_code":"TF-TEA-50","qty":1}]', null)$$,
  'P0001', 'choose a delivery area from the list', 'quote needs a delivery area');
select is(public.quote_web_order(null, '[{"sku_code":"TF-TEA-50","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) -> 'split',
  'null'::jsonb, 'codeless has no split');
select is(public.quote_web_order(null, '[{"sku_code":"TF-TEA-50","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) ->> 'total',
  '1000.00', 'codeless quote prices TEAFAIR''s catalogue');
select is(public.quote_web_order('ZERO-BPS', '[{"sku_code":"T1-SKU","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) -> 'split',
  'null'::jsonb, 'a 0-bps partner gets no split');
select is(public.quote_web_order('POSIKEJA', '[{"sku_code":"T1-SKU","qty":2}]', md5('ng_lga:LA:Ikeja')::uuid) -> 'split',
  '{"fintech_partner_id":"60000000-0000-0000-0000-000000000001","subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":30.00}'::jsonb,
  'a terminal-bound code of an ACTIVE partner keeps its split shape');
select throws_ok($$select public.quote_web_order('POSEPE01', '[{"sku_code":"T1-SKU","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'This link is not active yet', 'a coded link with nobody accountable is not active');

-- a 100 % partner would take everything: no split (Decision 4: 0 < share < total)
update public.fintech_partners set commission_bps = 10000 where id = '60000000-0000-0000-0000-000000000002';
select is(public.quote_web_order('ZERO-BPS', '[{"sku_code":"T1-SKU","qty":1}]', md5('ng_lga:LA:Ikeja')::uuid) -> 'split',
  'null'::jsonb, 'a share equal to the total gives no split');
update public.fintech_partners set commission_bps = 0 where id = '60000000-0000-0000-0000-000000000002';

-- codeless PAYSTACK_WEB order
select lives_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000001', null,
    '[{"sku_code":"TF-TEA-50","qty":1}]',
    '{"name":"Ada Obi","phone":"+2348030000001","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
    '{}', 'PAYSTACK_WEB', 1000.00,
    '{"reference":"TFW-cl1","authorization_url":"https://x","split":null}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'codeless order placed');
select is((select coalesce(agent_code_id::text, 'none') || '|' || territory_id || '|' || fulfilment_warehouse_id
                  || '|' || teafair_agent_id || '|' || delivery_lga_id || '|' || tenant_id
             from public.orders where id = pg_temp.order_of('eeeeeeee-0000-0000-0000-000000000001')),
  'none|40000000-0000-0000-0000-000000000011|70000000-0000-0000-0000-000000000011|20000000-0000-0000-0000-000000000011|'
    || md5('ng_lga:LA:Ikeja')::uuid || '|7eaf0000-0000-4000-8000-000000000001',
  'codeless order routed and stamped');
select is((select territory_id from public.order_contacts where order_id = pg_temp.order_of('eeeeeeee-0000-0000-0000-000000000001')),
  '40000000-0000-0000-0000-000000000011'::uuid, 'contacts territory = orders territory');
select is((select num_nulls(split_subaccount_code, split_bps, split_amount) from public.payments
            where order_id = pg_temp.order_of('eeeeeeee-0000-0000-0000-000000000001')),
  3, 'a codeless payment has no split snapshot');
select throws_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000002', null,
    '[{"sku_code":"TF-TEA-50","qty":1}]',
    '{"name":"Bola","phone":"+2348030000002","delivery_address":"7 Toyin Street"}',
    null, 'POS_AGENT', 1000.00, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'paying at an agent needs a link from a POS agent', 'codeless must pay online');
select throws_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000003', null,
    '[{"sku_code":"TF-TEA-50","qty":1}]',
    '{"name":"Bola","phone":"+2348030000002","delivery_address":"7 Toyin Street"}',
    null, 'PAYSTACK_WEB', 1000.00,
    '{"reference":"TFW-cl3","authorization_url":"https://x","split":null}', md5('ng_lga:KN:Fagge')::uuid)$$,
  'P0001', 'We don''t deliver to this area yet.', 'an unshippable order is refused at placement too');
select throws_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000004', null,
    '[{"sku_code":"TF-TEA-50","qty":1}]',
    '{"name":"Bola","phone":"+2348030000002","delivery_address":"7 Toyin Street"}',
    null, 'PAYSTACK_WEB', 1000.00,
    '{"reference":"TFW-cl4","authorization_url":"https://x"}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Prices changed — refresh and try again', 'a missing split key is not JSON null');

-- coded orders: the split snapshot
select throws_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000005', 'POSIKEJA',
    '[{"sku_code":"T1-SKU","qty":2}]',
    '{"name":"Chi","phone":"+2348030000003","delivery_address":"9 Awolowo Way"}',
    null, 'PAYSTACK_WEB', 2000.00,
    '{"reference":"TFW-g1","authorization_url":"https://x","split":null}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Prices changed — refresh and try again', 'split snapshot must match the quote');
select throws_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000006', 'POSIKEJA',
    '[{"sku_code":"T1-SKU","qty":2}]',
    '{"name":"Chi","phone":"+2348030000003","delivery_address":"9 Awolowo Way"}',
    null, 'PAYSTACK_WEB', 2000.00,
    '{"reference":"TFW-g1","authorization_url":"https://x","split":{"subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":31.00}}',
    md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Prices changed — refresh and try again', 'a different partner share is refused');
select lives_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000007', 'POSIKEJA',
    '[{"sku_code":"T1-SKU","qty":2}]',
    '{"name":"Chi","phone":"+2348030000003","delivery_address":"9 Awolowo Way"}',
    null, 'PAYSTACK_WEB', 2000.00,
    '{"reference":"TFW-g1","authorization_url":"https://x","split":{"subaccount_code":"ACCT_grace01","commission_bps":150,"partner_share":30}}',
    md5('ng_lga:LA:Ikeja')::uuid)$$,
  'the matching split is accepted');
select is((select split_amount || '|' || split_bps || '|' || split_subaccount_code || '|' || fintech_partner_id
             from public.payments where order_id = pg_temp.order_of('eeeeeeee-0000-0000-0000-000000000007')),
  '30.00|150|ACCT_grace01|60000000-0000-0000-0000-000000000001', 'payment carries the split snapshot');
select is((select territory_id || '|' || fulfilment_warehouse_id || '|' || teafair_agent_id
             from public.orders where id = pg_temp.order_of('eeeeeeee-0000-0000-0000-000000000007')),
  '40000000-0000-0000-0000-000000000001|70000000-0000-0000-0000-000000000001|20000000-0000-0000-0000-000000000003',
  'a coded order is routed through its terminal''s territory and TM');
select lives_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000008', 'ZERO-BPS',
    '[{"sku_code":"T1-SKU","qty":1}]',
    '{"name":"Dayo","phone":"+2348030000004","delivery_address":"3 Allen Avenue"}',
    null, 'PAYSTACK_WEB', 1000.00,
    '{"reference":"TFW-z1","authorization_url":"https://x","split":null}', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'a 0-bps partner''s order is placed without a split');
select is((select num_nulls(split_subaccount_code, split_bps, split_amount) from public.payments
            where order_id = pg_temp.order_of('eeeeeeee-0000-0000-0000-000000000008')),
  3, 'and its payment has no split snapshot');

select throws_ok($$select pg_temp.pwo('eeeeeeee-0000-0000-0000-000000000001', null,
    '[{"sku_code":"TF-TEA-50","qty":1}]',
    '{"name":"Ada Obi","phone":"+2348030000001","email":"ada@example.com","delivery_address":"5 Opebi Road, Ikeja"}',
    '{}', 'PAYSTACK_WEB', 1000.00,
    '{"reference":"TFW-cl1","authorization_url":"https://x","split":null}', md5('ng_lga:LA:Epe')::uuid)$$,
  'TF002', null, 'lga_id is in the idempotency hash');

-- locations
select is(jsonb_array_length(public.storefront_locations(null) -> 'states'), 37, '37 states');
select is((select sum(jsonb_array_length(s -> 'lgas'))::int
             from jsonb_array_elements(public.storefront_locations(null) -> 'states') s), 774, '774 LGAs');
select is(public.storefront_locations(null) -> 'states' -> 0 ->> 'code', 'AB', 'states ordered by name');
select is(pg_temp.lga_deliverable(public.storefront_locations(null), 'LA', 'Ikeja'), true, 'covered LGA deliverable');
select is(pg_temp.lga_deliverable(public.storefront_locations(null), 'KN', 'Fagge'), false, 'uncovered LGA not deliverable');
select is(pg_temp.lga_deliverable(public.storefront_locations(null), 'LA', 'Epe'), false,
  'another tenant''s coverage does not count');
select ok(position('40000000-0000-0000-0000-000000000011' in public.storefront_locations(null)::text) = 0
      and position('70000000-0000-0000-0000-000000000011' in public.storefront_locations(null)::text) = 0
      and position('20000000-0000-0000-0000-000000000011' in public.storefront_locations(null)::text) = 0,
  'no territory, warehouse or person ids exposed');
select is((select count(*)::int from jsonb_array_elements(public.storefront_locations('POSEPE01') -> 'states') s,
                  jsonb_array_elements(s -> 'lgas') l where (l ->> 'deliverable')::boolean), 0,
  'a coded link with nobody accountable delivers nowhere');
select is(pg_temp.lga_deliverable(public.storefront_locations('POSIKEJA'), 'KN', 'Fagge'), true,
  'a coded link routes through its own territory, whatever the LGA');

-- status
select is(public.web_order_status(pg_temp.ref_of('eeeeeeee-0000-0000-0000-000000000001'), 'TFW-cl1') ->> 'order_status',
  'PENDING', 'status read by the pair');
select is(public.web_order_status(pg_temp.ref_of('eeeeeeee-0000-0000-0000-000000000001'), 'TFW-cl1') - 'public_reference',
  '{"order_status":"PENDING","payment_status":"INITIATED","total":1000.00,"currency":"NGN",
    "lines":[{"name":"Teafair Tea 50 bags","qty":1,"unit_price":1000.00}]}'::jsonb,
  'status carries order and payment status, total, currency and lines only');
select is(public.web_order_status(pg_temp.ref_of('eeeeeeee-0000-0000-0000-000000000001'), 'TFW-other'), null,
  'mismatched pair is null');
select is(public.web_order_status(pg_temp.ref_of('eeeeeeee-0000-0000-0000-000000000001'), 'TFW-g1'), null,
  'another order''s payment reference is null');
select is(public.web_order_status('TF-000000', 'TFW-cl1'), null, 'an unknown order is null');
select is(public.web_order_status(pg_temp.ref_of('eeeeeeee-0000-0000-0000-000000000001'), 'TFW-CL1') ->> 'order_status',
  'PENDING', 'the Paystack reference matches whatever its case (the gateway accepts either)');
select ok(position('+234' in public.web_order_status(pg_temp.ref_of('eeeeeeee-0000-0000-0000-000000000001'), 'TFW-cl1')::text) = 0,
  'no contact details in status');

-- grants
select ok(not has_function_privilege('anon', 'public.web_order_status(text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_order_status(text,text)', 'execute')
      and has_function_privilege('service_role', 'public.web_order_status(text,text)', 'execute'),
  'status is service_role only');
select ok(not has_function_privilege('anon', 'public.storefront_locations(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.storefront_locations(text)', 'execute')
      and has_function_privilege('service_role', 'public.storefront_locations(text)', 'execute'),
  'locations is service_role only');
select ok(not has_function_privilege('authenticated', 'public.quote_web_order(text,jsonb,uuid)', 'execute')
      and has_function_privilege('service_role', 'public.quote_web_order(text,jsonb,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', 'execute')
      and has_function_privilege('service_role', 'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', 'execute')
      and has_function_privilege('service_role', 'public.storefront_catalogue(text)', 'execute'),
  'quote, place and catalogue are service_role only');
select ok(not has_function_privilege('service_role', 'public.web_storefront_code(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_storefront_code(text)', 'execute'),
  'web_storefront_code is internal');
select ok(to_regprocedure('public.quote_web_order(text,jsonb)') is null
      and to_regprocedure('public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb)') is null,
  'the old signatures are dropped');

select * from finish();
rollback;
