-- Addendum A6 §5 steps 9–10, §7.2 (Monvelo Step 3, Task 4) — repayments
-- recorded by the funder's member and confirmed with the shop owner's code
-- (record_monvelo_repayment, confirm_monvelo_repayment), the owner's rejection
-- (reject_monvelo_repayment), limit growth on repayment within the window, the
-- late charge applied at a confirmation after due_at, and outstanding-based
-- exposure (monvelo_brand_exposure).
begin;
create extension if not exists pgtap with schema extensions;

select plan(93);

-- A6 Task 6b: placing an order reserves stock. Every ordered line finds ample
-- stock in its order's fulfilment warehouse (one FIXTURE batch per SKU).
create function pg_temp.a6_stock_for_line() returns trigger language plpgsql as $f$
begin
  insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
  select o.tenant_id, o.fulfilment_warehouse_id, new.sku_code, 'FIXTURE', 100000
    from public.orders o
   where o.tenant_id = new.tenant_id and o.id = new.order_id and o.fulfilment_warehouse_id is not null
  on conflict (warehouse_id, sku_code, batch_number) do nothing;
  return null;
end;
$f$;
create trigger a6_stock_for_line after insert on public.order_items
  for each row execute function pg_temp.a6_stock_for_line();

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 08 LM (under 18 CSM)
-- 10 owner of S1 and S2 · 11 another shop owner (S3) · 06 MONVELO_OPERATOR
-- agent members: 21 and 23 of P ("ADE, BISI O.", ...0011) · 22 of N ("CHIOMA NNE OKAFOR", ...0022)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 6, 7, 8, 10, 11, 18, 21, 22, 23]) n;
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000006';

update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000018', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000018', 'CLIENT_SERVICE_MANAGER', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
update public.monvelo_tenant_settings set limit_growth_bps = 0, max_limit = null, default_cure_days = 0
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001';
-- Purerigin's approved terms: 10 %, 30 days, 10 % (A6 §5)
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 1000, 30, 1000, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');

insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'POS ' || n, 'OPAY', 'OP-' || n, '+23480311100' || lpad(n::text, 2, '0'),
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60 + dlat), 4326)::extensions.geography, 'a',
       '012345' || last4, last4, '058', holder, 'K' || n,
       '20000000-0000-0000-0000-000000000004', 'ACTIVE', 500000, 200000
  from (values (21, 0.0036, '0011', 'ADE, BISI O.'), (22, 0.0054, '0022', 'CHIOMA NNE OKAFOR')) v (n, dlat, last4, holder);
insert into public.monvelo_agent_members (agent_id, profile_id) values
  ('80000000-0000-0000-0000-000000000021', '20000000-0000-0000-0000-000000000021'),
  ('80000000-0000-0000-0000-000000000021', '20000000-0000-0000-0000-000000000023'),
  ('80000000-0000-0000-0000-000000000022', '20000000-0000-0000-0000-000000000022');
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), 1000000, 1000000, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;

-- S1 and S2, both enrolled in Allen, owner 10; S3 (owner 11) is not used for credit
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text, preferred_agent_id) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1', null),
  ('71000000-0000-0000-0000-000000000002', 'Shop 2', '+234803111002', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 2', null),
  ('71000000-0000-0000-0000-000000000003', 'Shop 3', '+234803111003', '20000000-0000-0000-0000-000000000011', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 3', null);
update public.retail_shops set shop_code = 'SH-AAAAA' || chr(65 + right(id::text, 1)::int) where id::text like '71000000-%';
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by)
select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000004'
  from generate_series(1, 2) n;
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id)
select c.tenant_id, c.shop_id, c.area_id, c.issued_by, now(), 'MV-SHARE-2026-10', c.id
  from public.monvelo_consent_challenges c where c.id::text like 'c0000000-%';

-- ── helpers ─────────────────────────────────────────────────────────────
create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d6300000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.s(n integer) returns uuid language sql as
  $$ select ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.t1(), pg_temp.s(integer)
  to authenticated;
create temp table fin (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on fin, res to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
-- the repayment behind a record reply
create function pg_temp.rp(p_n text) returns uuid language sql as $$ select (r ->> 'repayment_id')::uuid from res where n = p_n $$;
grant execute on function pg_temp.f(text), pg_temp.r(text), pg_temp.rp(text) to authenticated;

-- 12 Purerigin 200 ml (48000) for shop p_shop: requested, claimed and funded by
-- P, dispatched by the LM and delivered with the owner's code by the TM
create function pg_temp.delivered(p_n text, p_key integer, p_shop integer) returns text
language plpgsql as $$
declare v_o uuid; v_f uuid; v_ref text; v_start jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), pg_temp.s(p_shop),
          jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 12))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform pg_temp.act_as(pg_temp.u(21), null);
  perform public.claim_monvelo_financing(pg_temp.k(p_key + 2), v_f, pg_temp.ag(21));
  v_ref := public.start_monvelo_funding(pg_temp.k(p_key + 3), v_f, pg_temp.ag(21)) ->> 'reference';
  perform set_config('role', 'postgres', true);
  perform public.settle_monvelo_funding('charge.success', v_ref, 'success', 4800000, 'NGN',
    jsonb_build_object('status', 'success', 'channel', 'bank_transfer',
      'authorization', jsonb_build_object('channel', 'bank_transfer', 'sender_bank', 'Guaranty Trust Bank',
                                          'sender_name', 'BISI ADE', 'sender_bank_account_number', 'XXXXXX0011')),
    'T-' || p_n);
  perform pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
  perform public.dispatch_monvelo_financing(pg_temp.k(p_key + 4), v_f, null);
  perform pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
  v_start := public.start_monvelo_delivery(pg_temp.k(p_key + 5), 'test-gw-secret', v_f);
  perform public.confirm_monvelo_delivery(pg_temp.k(p_key + 6), (v_start ->> 'challenge_id')::uuid, v_start ->> 'code');
  perform set_config('role', 'postgres', true);
  insert into fin values (p_n, v_f);
  return (select status from public.monvelo_financings where id = v_f);
end; $$;
-- an agent member records a repayment; the reply is kept as p_n
create function pg_temp.rec(p_n text, p_user integer, p_key integer, p_fin text, p_amount numeric, p_agent integer default 21)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), null);
  v := public.record_monvelo_repayment(pg_temp.k(p_key), 'test-gw-secret', pg_temp.f(p_fin), pg_temp.ag(p_agent), p_amount);
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
-- the recorder types the owner's code (p_rec's, unless p_code is given)
create function pg_temp.conf(p_n text, p_user integer, p_key integer, p_rec text, p_code text default null) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), null);
  v := public.confirm_monvelo_repayment(pg_temp.k(p_key), (pg_temp.r(p_rec) ->> 'challenge_id')::uuid,
                                        coalesce(p_code, pg_temp.r(p_rec) ->> 'code'));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
-- a 6-digit code that is not p_rec's
create function pg_temp.wrong(p_rec text) returns text language sql as $$
  select lpad(((((pg_temp.r(p_rec) ->> 'code')::int) + 1) % 1000000)::text, 6, '0') $$;
create function pg_temp.fin_state(p_n text) returns text language sql as $$
  select row(status, outstanding, late_charge_amount, closed_at is not null)::text
    from public.monvelo_financings where id = pg_temp.f(p_n) $$;
create function pg_temp.lim(p_shop integer) returns numeric language sql as $$
  select limit_amount from public.monvelo_shop_limits
   where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(p_shop) and brand_key = 'purerigin' $$;

-- ── shape and security ──────────────────────────────────────────────────
select has_table('public', 'monvelo_repayments', 'monvelo_repayments exists');
select columns_are('public', 'monvelo_repayments',
  array['id', 'tenant_id', 'financing_id', 'amount', 'recorded_by', 'recorded_at', 'status', 'challenge_id',
        'confirmed_at', 'ended_at'],
  'the repayment columns');
select ok((select relrowsecurity from pg_class where oid = 'public.monvelo_repayments'::regclass),
  'RLS is on for the repayments');
select is((select string_agg(cmd, ',') from pg_policies where schemaname = 'public' and tablename = 'monvelo_repayments'),
  'SELECT', 'one SELECT policy, nothing else');
select ok(has_table_privilege('authenticated', 'public.monvelo_repayments', 'select')
      and not has_table_privilege('authenticated', 'public.monvelo_repayments', 'insert')
      and not has_table_privilege('authenticated', 'public.monvelo_repayments', 'update')
      and not has_table_privilege('anon', 'public.monvelo_repayments', 'select')
      and not has_table_privilege('service_role', 'public.monvelo_repayments', 'insert'),
  'authenticated reads (through the policy); no API role writes');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'notification_logs_purpose_check') like '%MONVELO_REPAYMENT%',
  'notification_logs accepts the MONVELO_REPAYMENT purpose');
select ok(has_function_privilege('authenticated', 'public.record_monvelo_repayment(uuid,text,uuid,uuid,numeric)', 'execute')
      and has_function_privilege('authenticated', 'public.confirm_monvelo_repayment(uuid,uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'public.reject_monvelo_repayment(uuid,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.record_monvelo_repayment(uuid,text,uuid,uuid,numeric)', 'execute')
      and not has_function_privilege('anon', 'public.confirm_monvelo_repayment(uuid,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.reject_monvelo_repayment(uuid,uuid)', 'execute'),
  'the three RPCs are for signed-in users only');
select ok(not has_function_privilege('authenticated', 'public.monvelo_apply_late_charge(public.monvelo_financings)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_apply_late_charge(public.monvelo_financings)', 'execute')
      and not has_function_privilege('authenticated', 'public.monvelo_brand_exposure(uuid,uuid,text,uuid)', 'execute'),
  'the late charge and the exposure are internal');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=public, pg_temp']) from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('record_monvelo_repayment', 'confirm_monvelo_repayment', 'reject_monvelo_repayment'))
      and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('record_monvelo_repayment', 'confirm_monvelo_repayment', 'reject_monvelo_repayment')) = 3,
  'the RPCs are SECURITY DEFINER with the pinned search_path');

-- ── five delivered financings: R on S1; G2, G3, L, J on S2 ──────────────
select is(pg_temp.delivered('R', 100, 1) || pg_temp.delivered('G2', 110, 2) || pg_temp.delivered('G3', 120, 2)
          || pg_temp.delivered('L', 130, 2) || pg_temp.delivered('J', 140, 2),
  'DELIVERED' || 'DELIVERED' || 'DELIVERED' || 'DELIVERED' || 'DELIVERED', 'R, G2, G3, L and J are DELIVERED');

-- ── R29: one FUNDED_GROSS and one FEE per financing ─────────────────────
select throws_ok(format($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                          values (%L, public.monvelo_today(), 'FUNDED_GROSS', %L, 48000)$$, pg_temp.t1(), pg_temp.f('R')),
  '23505', null, 'a second FUNDED_GROSS for a financing is refused');
insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
values (pg_temp.t1(), public.monvelo_today(), 'FEE', pg_temp.f('G3'), -10);
select throws_ok(format($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                          values (%L, public.monvelo_today(), 'FEE', %L, -10)$$, pg_temp.t1(), pg_temp.f('G3')),
  '23505', null, 'a second FEE for a financing is refused');
select lives_ok(format($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                         values (%L, public.monvelo_today(), 'REBATE', %L, -1), (%L, public.monvelo_today(), 'REBATE', %L, -1)$$,
                       pg_temp.t1(), pg_temp.f('G3'), pg_temp.t1(), pg_temp.f('G3')),
  'other entry types may repeat');

-- ── record: refusals ────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(200), 'wrong', pg_temp.f('R'), pg_temp.ag(21), 1000)$$,
  '42501', 'this operation must come through its gateway', 'record without the gateway proof is refused');
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(201), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 1000)$$,
  '42501', 'not an active member of this agent', 'a member of another agent cannot record for P');
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(202), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(22), 1000)$$,
  '42501', 'only the funding agent records repayments on this financing', 'a non-funder member is refused');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(203), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 1000)$$,
  '42501', 'not an active member of this agent', 'the TM cannot record');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(204), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 48000.01)$$,
  'P0001', 'the amount is more than is left to repay', 'above outstanding is refused');
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(205), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 0)$$,
  'P0001', 'the amount must be positive, with at most 2 decimals', 'zero is refused');
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(206), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 100.005)$$,
  'P0001', 'the amount must be positive, with at most 2 decimals', 'three decimals are refused');
reset role;

-- ── record: 30000 pending, then 20000 is over what is left ──────────────
select lives_ok($$select pg_temp.rec('R1', 21, 210, 'R', 30000)$$, 'P''s member records 30000 on R');
select ok((pg_temp.r('R1') ->> 'code') ~ '^[0-9]{6}$' and (pg_temp.r('R1') ->> 'replayed')::boolean = false
      and pg_temp.r('R1') ->> 'destination_phone' = (select phone_number from public.profiles where id = pg_temp.u(10)),
  'the first call returns a 6-digit code for the owner''s verified phone');
select is((select row(r.status, r.amount, r.recorded_by = pg_temp.u(21), r.tenant_id = pg_temp.t1(),
                      r.challenge_id = (pg_temp.r('R1') ->> 'challenge_id')::uuid, r.confirmed_at is null, r.ended_at is null)::text
             from public.monvelo_repayments r where r.id = pg_temp.rp('R1')),
  '(PENDING,30000.00,t,t,t,t,t)', 'one PENDING repayment of 30000, recorded by the member, linked to its challenge');
select is((select row(c.purpose, c.repayment_id = pg_temp.rp('R1'), c.financing_id = pg_temp.f('R'), c.issued_by = pg_temp.u(21),
                      c.code_hash = extensions.crypt(pg_temp.r('R1') ->> 'code', c.code_hash))::text
             from public.monvelo_owner_challenges c where c.id = (pg_temp.r('R1') ->> 'challenge_id')::uuid),
  '(REPAYMENT,t,t,t,t)', 'a hashed REPAYMENT challenge for the repayment');
select is(pg_temp.rec('R1R', 21, 210, 'R', 30000), (pg_temp.r('R1') - 'code' - 'replayed') || '{"replayed": true}'::jsonb,
  'the replay returns the same challenge with no code');
select ok((select bool_and(response::text !~ (pg_temp.r('R1') ->> 'code')) from public.idempotency_logs
            where operation = 'record_monvelo_repayment'),
  'the stored reply never holds the code');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(211), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 20000)$$,
  'P0001', 'the amount is more than is left to repay', '30000 pending + 20000 against 48000: the second is refused');
reset role;

-- ── confirm: refusals and a wrong code ──────────────────────────────────
select pg_temp.act_as(pg_temp.u(23), null);
select throws_ok(format($$select public.confirm_monvelo_repayment(pg_temp.k(300), %L, %L)$$,
                        pg_temp.r('R1') ->> 'challenge_id', pg_temp.r('R1') ->> 'code'),
  '42501', 'only the member who recorded this repayment confirms it', 'R32: a colleague of the recorder cannot confirm');
select pg_temp.act_as(pg_temp.u(10), null);
select throws_ok(format($$select public.confirm_monvelo_repayment(pg_temp.k(301), %L, %L)$$,
                        pg_temp.r('R1') ->> 'challenge_id', pg_temp.r('R1') ->> 'code'),
  '42501', 'only the member who recorded this repayment confirms it', 'nor can the shop owner');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok(format($$select public.confirm_monvelo_repayment(pg_temp.k(302), %L, '12ab')$$, pg_temp.r('R1') ->> 'challenge_id'),
  'P0001', 'the repayment code must be 6 digits', 'a malformed code is refused');
reset role;
select is(pg_temp.conf('RW', 21, 310, 'R1', pg_temp.wrong('R1')), '{"confirmed": false, "reason": "INVALID"}'::jsonb,
  'the wrong code is INVALID');
select is((select failed_attempts from public.monvelo_owner_challenges where id = (pg_temp.r('R1') ->> 'challenge_id')::uuid), 1,
  'the failure committed');

-- ── R30: a lapsed code stops counting, and its repayment EXPIRES ────────
update public.monvelo_owner_challenges set expires_at = now() - interval '1 second'
 where id = (pg_temp.r('R1') ->> 'challenge_id')::uuid;
select lives_ok($$select pg_temp.rec('R2', 21, 320, 'R', 20000)$$, 'once R1''s code lapsed, 20000 can be recorded');
select is(pg_temp.conf('R1E', 21, 321, 'R1'), '{"confirmed": false, "reason": "EXPIRED"}'::jsonb,
  'R1''s right code after expiry is EXPIRED');
select is((select status || ':' || (ended_at is not null)::text from public.monvelo_repayments where id = pg_temp.rp('R1')),
  'EXPIRED:true', 'and R1 moved PENDING -> EXPIRED in the same call');

-- ── partial 20000 ───────────────────────────────────────────────────────
select is(pg_temp.conf('R2C', 21, 330, 'R2'),
  jsonb_build_object('confirmed', true, 'outstanding', 28000.00, 'status', 'DELIVERED'),
  'the owner''s code confirms 20000: 28000 outstanding, still DELIVERED');
select is((select status || ':' || (confirmed_at is not null)::text || ':' || (ended_at is not null)::text
             from public.monvelo_repayments where id = pg_temp.rp('R2')),
  'CONFIRMED:true:true', 'R2 is CONFIRMED');
select is(pg_temp.fin_state('R'), '(DELIVERED,28000.00,0.00,f)', 'R: DELIVERED with 28000 outstanding');
select is(pg_temp.conf('R2C2', 21, 330, 'R2'), pg_temp.r('R2C'), 'the replay returns the first reply');
select is(pg_temp.conf('R2C3', 21, 331, 'R2') ->> 'confirmed', 'true', 'the spent code under a new key says confirmed');
select is(pg_temp.fin_state('R'), '(DELIVERED,28000.00,0.00,f)', 'and takes nothing more off');

-- ── exposure: outstanding, not principal ────────────────────────────────
select is(public.monvelo_brand_exposure(pg_temp.t1(), pg_temp.s(1), 'purerigin', null), 28000.00::numeric,
  'a DELIVERED financing with 28000 outstanding counts 28000, not 48000');
select is(public.monvelo_brand_exposure(pg_temp.t1(), pg_temp.s(1), 'purerigin', pg_temp.f('R')), 0::numeric,
  'p_exclude still leaves it out');

-- ── final 28000: REPAID_WITHIN_WINDOW, the limit grows 50000 -> 60000 ───
update public.monvelo_shop_limits set limit_amount = 50000
 where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(1) and brand_key = 'purerigin';
update public.monvelo_tenant_settings set limit_growth_bps = 2000, max_limit = null where tenant_id = pg_temp.t1();
select pg_temp.rec('R3', 21, 340, 'R', 28000);
select is(pg_temp.conf('R3C', 21, 341, 'R3'),
  jsonb_build_object('confirmed', true, 'outstanding', 0.00, 'status', 'REPAID_WITHIN_WINDOW'),
  'the final 28000 repays R within the window');
select is(pg_temp.fin_state('R'), '(REPAID_WITHIN_WINDOW,0.00,0.00,t)', 'R is REPAID_WITHIN_WINDOW, closed');
select is(pg_temp.lim(1), 60000.00::numeric, 'S1''s Purerigin limit grew 50000 -> 60000 at 2000 bps');
select is((select string_agg(kind || ':' || old_limit::text || ':' || new_limit::text, ',') from public.monvelo_shop_limit_events
            where financing_id = pg_temp.f('R')),
  'GROWN:50000.00:60000.00', 'one GROWN event naming R');
select is(public.monvelo_brand_exposure(pg_temp.t1(), pg_temp.s(1), 'purerigin', null), 0::numeric,
  'a repaid financing counts nothing');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(342), 'test-gw-secret', pg_temp.f('R'), pg_temp.ag(21), 1)$$,
  'P0001', 'only a delivered financing takes repayments', 'a repaid financing takes no more repayments');
reset role;
select is((select count(*)::int from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('R')), 1,
  'R31: the repayments booked nothing in the tenant ledger');

-- ── growth capped by max_limit (G2) and none at 0 bps (G3) ──────────────
update public.monvelo_shop_limits set limit_amount = 50000
 where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(2) and brand_key = 'purerigin';
update public.monvelo_tenant_settings set limit_growth_bps = 2000, opening_limit = 50000, max_limit = 55000 where tenant_id = pg_temp.t1();
select pg_temp.rec('G2a', 23, 400, 'G2', 48000);
select is(pg_temp.conf('G2C', 23, 401, 'G2a') ->> 'status', 'REPAID_WITHIN_WINDOW', 'G2 repaid in one payment by member 23');
select is(pg_temp.lim(2), 55000.00::numeric, 'with max_limit 55000 the limit grows to 55000 only');
select is((select count(*)::int from public.monvelo_shop_limit_events where financing_id = pg_temp.f('G2') and kind = 'GROWN'), 1,
  'one GROWN event naming G2');
update public.monvelo_tenant_settings set limit_growth_bps = 0, max_limit = null where tenant_id = pg_temp.t1();
-- G3: five wrong codes lock the first record, which EXPIRES (R30)
select pg_temp.rec('G3a', 21, 410, 'G3', 48000);
select pg_temp.conf('G3W' || n, 21, 410 + n, 'G3a', pg_temp.wrong('G3a')) from generate_series(1, 4) n;
select is(pg_temp.conf('G3W5', 21, 415, 'G3a', pg_temp.wrong('G3a')), '{"confirmed": false, "reason": "LOCKED"}'::jsonb,
  'the fifth wrong code is LOCKED');
select is((select status from public.monvelo_repayments where id = pg_temp.rp('G3a')), 'EXPIRED',
  'and the locked repayment EXPIRED in the same call');
select is(pg_temp.conf('G3W6', 21, 416, 'G3a'), '{"confirmed": false, "reason": "EXPIRED"}'::jsonb,
  'its right code now says EXPIRED');
select pg_temp.rec('G3b', 21, 420, 'G3', 48000);
select is(pg_temp.conf('G3C', 21, 421, 'G3b') ->> 'status', 'REPAID_WITHIN_WINDOW', 'G3 repaid within the window');
select is(pg_temp.lim(2), 55000.00::numeric, 'at 0 bps the limit stays 55000');
select is((select count(*)::int from public.monvelo_shop_limit_events where financing_id = pg_temp.f('G3')), 0,
  'and no event names G3');
select is((select count(*)::int from public.audit_logs where operation = 'MONVELO_REPAYMENT_CODE_FAILED'), 6,
  'each wrong code is audited (one on R1, five on G3a)');

-- ── R32: a recorder no longer ACTIVE cannot confirm (J) ─────────────────
select pg_temp.rec('J0', 23, 500, 'J', 1000);
update public.monvelo_agent_members set status = 'REVOKED' where profile_id = pg_temp.u(23);
select pg_temp.act_as(pg_temp.u(23), null);
select throws_ok(format($$select public.confirm_monvelo_repayment(pg_temp.k(501), %L, %L)$$,
                        pg_temp.r('J0') ->> 'challenge_id', pg_temp.r('J0') ->> 'code'),
  '42501', 'only the member who recorded this repayment confirms it', 'a revoked recorder cannot confirm');
reset role;
update public.monvelo_agent_members set status = 'ACTIVE' where profile_id = pg_temp.u(23);

-- ── 3 codes an hour per financing; then the owner rejects ───────────────
select pg_temp.rec('J1', 21, 510, 'J', 10000);
select pg_temp.rec('J2', 21, 511, 'J', 10000);
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.record_monvelo_repayment(pg_temp.k(512), 'test-gw-secret', pg_temp.f('J'), pg_temp.ag(21), 10000)$$,
  'P0001', 'too many codes requested for this financing; try again later', 'a fourth repayment code in an hour is refused');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok(format($$select public.reject_monvelo_repayment(pg_temp.k(520), %L)$$, pg_temp.rp('J1')),
  '42501', 'only the shop owner rejects this repayment', 'the TM cannot reject');
select pg_temp.act_as(pg_temp.u(11), null);
select throws_ok(format($$select public.reject_monvelo_repayment(pg_temp.k(521), %L)$$, pg_temp.rp('J1')),
  '42501', 'only the shop owner rejects this repayment', 'another shop''s owner cannot reject');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok(format($$select public.reject_monvelo_repayment(pg_temp.k(522), %L)$$, pg_temp.rp('J1')),
  '42501', 'only the shop owner rejects this repayment', 'nor can the agent''s member');
select pg_temp.act_as(pg_temp.u(10), null);
select is(public.reject_monvelo_repayment(pg_temp.k(523), pg_temp.rp('J1')),
  jsonb_build_object('repayment_id', pg_temp.rp('J1'), 'status', 'REJECTED'), 'the owner rejects J1');
select is(public.reject_monvelo_repayment(pg_temp.k(523), pg_temp.rp('J1')),
  jsonb_build_object('repayment_id', pg_temp.rp('J1'), 'status', 'REJECTED'), 'the replay returns the first reply');
select throws_ok(format($$select public.reject_monvelo_repayment(pg_temp.k(524), %L)$$, pg_temp.rp('J1')),
  'P0001', 'only a pending repayment can be rejected', 'a second rejection is refused');
reset role;
select is((select status || ':' || (ended_at is not null)::text from public.monvelo_repayments where id = pg_temp.rp('J1')),
  'REJECTED:true', 'J1 is REJECTED');
select is((select string_agg(kind || ':' || (agent_id = pg_temp.ag(21))::text || ':' || (details ->> 'repayment_id'), ',')
             from public.monvelo_flags where financing_id = pg_temp.f('J')),
  'REPAYMENT_REJECTED:true:' || pg_temp.rp('J1'), 'one REPAYMENT_REJECTED flag');
select is((select string_agg(t.kind || ':' || t.priority || ':' || (t.order_id = f.order_id)::text, ',')
             from public.support_tickets t, public.monvelo_financings f
            where f.id = pg_temp.f('J') and t.system_key = 'monvelo-repayment:' || pg_temp.rp('J1')),
  'SYSTEM:HIGH:true', 'one HIGH SYSTEM ticket on J''s order');
select ok((select bool_and(m.body !~ ('ADE|BISI|POS 21|80000000-|20000000-0000-0000-0000-00000000002'))
             from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'monvelo-repayment:' || pg_temp.rp('J1')),
  'the ticket names no agent or member');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok(format($$select public.confirm_monvelo_repayment(pg_temp.k(526), %L, %L)$$,
                        pg_temp.r('J1') ->> 'challenge_id', pg_temp.r('J1') ->> 'code'),
  'P0001', 'the shop owner rejected this repayment', 'a rejected repayment cannot be confirmed');
reset role;

-- ── the late charge at a confirmation after due_at (L) ──────────────────
update public.monvelo_financings set due_at = now() - interval '1 second' where id = pg_temp.f('L');
select pg_temp.rec('L1', 21, 600, 'L', 48000);
select is(pg_temp.conf('L1C', 21, 601, 'L1'),
  jsonb_build_object('confirmed', true, 'outstanding', 4800.00, 'status', 'DEFAULTED_WITH_LATE_CHARGE'),
  'paying 48000 after due_at: the 4800 charge is applied first, 4800 left, DEFAULTED_WITH_LATE_CHARGE');
select is(pg_temp.fin_state('L'), '(DEFAULTED_WITH_LATE_CHARGE,4800.00,4800.00,f)', 'L carries the one late charge');
select ok((select tenant_id = pg_temp.t1() and actor_id is null and (after ->> 'late_charge_amount')::numeric = 4800
             from public.audit_logs where operation = 'monvelo_apply_late_charge' and entity_id = pg_temp.f('L')::text),
  'the late charge is audited for the tenant, with no actor');
select pg_temp.rec('L2', 21, 610, 'L', 4800);
select is(pg_temp.conf('L2C', 21, 611, 'L2'),
  jsonb_build_object('confirmed', true, 'outstanding', 0.00, 'status', 'REPAID_LATE'), 'paying 4800 repays L late');
select is(pg_temp.fin_state('L'), '(REPAID_LATE,0.00,4800.00,t)', 'L is REPAID_LATE, closed, the charge once');
select is((select count(*)::int from public.monvelo_shop_limit_events where financing_id = pg_temp.f('L')), 0,
  'no growth on a late repayment');
select is((select count(*)::int from public.audit_logs where operation = 'monvelo_apply_late_charge'), 1,
  'the charge was applied once');

-- ── readers and audit ───────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_repayments), 0, 'the TM reads no repayments');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from public.monvelo_repayments), 0, 'nor does the TENANT_ADMIN');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is((select count(*)::int from public.monvelo_repayments), 0, 'nor the ZSM');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_repayments), 0, 'nor the raiser');
select pg_temp.act_as(pg_temp.u(10), null);
select is((select count(*)::int from public.monvelo_repayments), (select count(*)::int from res where r ? 'repayment_id' and n not like '%R'),
  'the owner reads its own shops'' repayments');
select pg_temp.act_as(pg_temp.u(11), null);
select is((select count(*)::int from public.monvelo_repayments), 0, 'another owner reads none');
select pg_temp.act_as(pg_temp.u(23), null);
select is((select count(*)::int from public.monvelo_repayments where recorded_by = pg_temp.u(21)) > 0, true,
  'a funder member reads its colleagues'' repayments');
select pg_temp.act_as(pg_temp.u(22), null);
select is((select count(*)::int from public.monvelo_repayments), 0, 'another agent''s member reads none');
select pg_temp.act_as(pg_temp.u(6), null);
select is((select count(*)::int from public.monvelo_repayments where financing_id in (select id from fin)),
  (select count(*)::int from res where r ? 'repayment_id' and n not like '%R'), 'Monvelo staff read them all');
reset role;
select ok((select bool_and(tenant_id is null) from public.audit_logs
            where operation in ('record_monvelo_repayment', 'confirm_monvelo_repayment', 'reject_monvelo_repayment',
                                'MONVELO_REPAYMENT_CODE_FAILED'))
      and (select count(*) from public.audit_logs
            where operation in ('record_monvelo_repayment', 'confirm_monvelo_repayment', 'reject_monvelo_repayment')) > 0,
  'R15: every repayment audit row is written with tenant_id null');
select ok((select bool_and(after::text !~ ('code_hash|' || (pg_temp.r('R1') ->> 'code'))) from public.audit_logs
            where operation = 'record_monvelo_repayment'),
  'no audit row holds a code or its hash');
select throws_ok($$delete from public.monvelo_repayments where id = pg_temp.rp('R2')$$,
  'P0001', 'Monvelo records are never deleted', 'a repayment is never deleted');
select throws_ok($$update public.monvelo_repayments set amount = 1 where id = pg_temp.rp('R2')$$,
  'P0001', null, 'a final repayment never changes');

select * from finish();
rollback;
