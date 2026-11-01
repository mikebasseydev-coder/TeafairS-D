-- Addendum A6 §4.4, §5 step 7 (Monvelo Step 3, Task 3) — dispatch of a FUNDED
-- financing (dispatch_monvelo_financing), the shop owner's delivery code
-- (start_monvelo_delivery, confirm_monvelo_delivery), DELIVERED with its due
-- date, and the tenant ledger's FUNDED_GROSS and FEE at delivery.
begin;
create extension if not exists pgtap with schema extensions;

select plan(86);

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
-- 09 DSA (Ikeja) · 10 owner of S1 and S2 · 06 MONVELO_OPERATOR (records fee terms)
-- agent members: 21 P ("ADE, BISI O.", ...0011) · 22 N ("CHIOMA NNE OKAFOR", ...0022)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 6, 7, 8, 9, 10, 18, 21, 22]) n;
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
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000009', 'DSA', null, '40000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
-- Purerigin's approved terms: 10 %, 30 days, 10 % (A6 §5)
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 1000, 30, 1000, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');
-- Teafair's fee: 100 bps for ten days that ended five days ago (none today yet)
insert into public.monvelo_tenant_fee_terms (tenant_id, fee_bps, valid_from, valid_to, recorded_by) values
  ('7eaf0000-0000-4000-8000-000000000001', 100, public.monvelo_today() - 10, public.monvelo_today() - 5,
   '20000000-0000-0000-0000-000000000006');

insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'POS ' || n, 'OPAY', 'OP-' || n, '+23480311100' || lpad(n::text, 2, '0'),
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60 + dlat), 4326)::extensions.geography, 'a',
       '012345' || last4, last4, '058', holder, 'K' || n,
       '20000000-0000-0000-0000-000000000004', 'ACTIVE', 500000, 200000
  from (values (21, 0.0036, '0011', 'ADE, BISI O.'), (22, 0.0054, '0022', 'CHIOMA NNE OKAFOR')) v (n, dlat, last4, holder);
insert into public.monvelo_agent_members (agent_id, profile_id)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), 150000, 150000, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;

-- S1 (preferred agent P) and S2 (none), both enrolled in Allen, owner 10
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text, preferred_agent_id) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1', '80000000-0000-0000-0000-000000000021'),
  ('71000000-0000-0000-0000-000000000002', 'Shop 2', '+234803111002', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 2', null);
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
  $$ select ('d6200000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.t1() to authenticated;
create temp table ord (n text primary key, id uuid);
create temp table fin (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on ord, fin, res to authenticated;
create function pg_temp.o(p_n text) returns uuid language sql as $$ select id from ord where n = p_n $$;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
grant execute on function pg_temp.o(text), pg_temp.f(text), pg_temp.r(text) to authenticated;
-- the ASA places 12 Purerigin 200 ml (48000) for shop p_shop and requests its financing
create function pg_temp.raise(p_n text, p_key integer, p_shop integer) returns uuid
language plpgsql as $$
declare v_o uuid; v_f uuid;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid,
          jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 12))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into ord values (p_n, v_o);
  insert into fin values (p_n, v_f);
  return v_f;
end; $$;
create function pg_temp.claim(p_key integer, p_agent integer, p_fin text) returns void
language plpgsql as $$
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  perform public.claim_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent));
  perform set_config('role', 'postgres', true);
end; $$;
-- P claims, starts the payment, and P's own transfer settles it: FUNDED, order PAID
create function pg_temp.fund(p_key integer, p_fin text) returns text
language plpgsql as $$
declare v_ref text;
begin
  perform pg_temp.claim(p_key, 21, p_fin);
  perform pg_temp.act_as(pg_temp.u(21), null);
  v_ref := public.start_monvelo_funding(pg_temp.k(p_key + 1), pg_temp.f(p_fin), pg_temp.ag(21)) ->> 'reference';
  perform set_config('role', 'postgres', true);
  return public.settle_monvelo_funding('charge.success', v_ref, 'success', 4800000, 'NGN',
    jsonb_build_object('status', 'success', 'channel', 'bank_transfer',
      'authorization', jsonb_build_object('channel', 'bank_transfer', 'sender_bank', 'Guaranty Trust Bank',
                                          'sender_name', 'BISI ADE', 'sender_bank_account_number', 'XXXXXX0011')),
    'T-' || p_fin) ->> 'outcome';
end; $$;
-- calls as a user; the reply is kept as p_n
create function pg_temp.dispatch(p_n text, p_user integer, p_key integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  v := public.dispatch_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), 'WAYBILL-' || p_fin);
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.start(p_n text, p_user integer, p_key integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  v := public.start_monvelo_delivery(pg_temp.k(p_key), 'test-gw-secret', pg_temp.f(p_fin));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.confirm(p_n text, p_user integer, p_key integer, p_start text, p_code text default null) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  v := public.confirm_monvelo_delivery(pg_temp.k(p_key), (pg_temp.r(p_start) ->> 'challenge_id')::uuid,
                                       coalesce(p_code, pg_temp.r(p_start) ->> 'code'));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
-- a 6-digit code that is not p_start's
create function pg_temp.wrong(p_start text) returns text language sql as $$
  select lpad(((((pg_temp.r(p_start) ->> 'code')::int) + 1) % 1000000)::text, 6, '0') $$;

-- ── shape and security ──────────────────────────────────────────────────
select has_table('public', 'monvelo_owner_challenges', 'monvelo_owner_challenges exists');
select ok((select relrowsecurity from pg_class where oid = 'public.monvelo_owner_challenges'::regclass),
  'RLS is on for the challenges');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'monvelo_owner_challenges'), 0,
  'the challenges have no policy');
select ok(not has_table_privilege('authenticated', 'public.monvelo_owner_challenges', 'select')
      and not has_table_privilege('anon', 'public.monvelo_owner_challenges', 'select')
      and not has_table_privilege('service_role', 'public.monvelo_owner_challenges', 'select')
      and not has_table_privilege('authenticated', 'public.monvelo_owner_challenges', 'insert'),
  'no API role reads or writes the challenges');
select columns_are('public', 'monvelo_owner_challenges',
  array['id', 'tenant_id', 'financing_id', 'repayment_id', 'purpose', 'code_hash', 'expires_at', 'failed_attempts',
        'consumed_at', 'issued_by', 'created_at'],
  'the challenge columns follow monvelo_consent_challenges (R21)');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'notification_logs_purpose_check') like '%MONVELO_DELIVERY%',
  'notification_logs accepts the MONVELO_DELIVERY purpose');
select ok(has_function_privilege('authenticated', 'public.dispatch_monvelo_financing(uuid,uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'public.start_monvelo_delivery(uuid,text,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.confirm_monvelo_delivery(uuid,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.dispatch_monvelo_financing(uuid,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.start_monvelo_delivery(uuid,text,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.confirm_monvelo_delivery(uuid,uuid,text)', 'execute'),
  'the three RPCs are for signed-in users only');
select ok(not has_function_privilege('authenticated', 'public.monvelo_fee_bps_at(uuid,date)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_fee_bps_at(uuid,date)', 'execute'),
  'monvelo_fee_bps_at is internal');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=public, pg_temp']) from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('dispatch_monvelo_financing', 'start_monvelo_delivery', 'confirm_monvelo_delivery')),
  'the RPCs are SECURITY DEFINER with the pinned search_path');

-- ── monvelo_fee_bps_at ──────────────────────────────────────────────────
select is(public.monvelo_fee_bps_at(pg_temp.t1(), public.monvelo_today() - 7), 100, 'the fee terms valid that day');
select is(public.monvelo_fee_bps_at(pg_temp.t1(), public.monvelo_today() - 10), 100, 'valid from its first day');
select is(public.monvelo_fee_bps_at(pg_temp.t1(), public.monvelo_today() - 5), 0, 'not on its end date (half-open)');
select is(public.monvelo_fee_bps_at(pg_temp.t1(), public.monvelo_today()), 0, 'no terms today: 0');

-- ── the financings: A (S1) and B, D (S2) funded by P; C claimed by N ────
select is(pg_temp.raise('A', 100, 1) is not null and pg_temp.fund(102, 'A') = 'funded', true, 'A is FUNDED');
select is(pg_temp.raise('B', 110, 2) is not null and pg_temp.fund(112, 'B') = 'funded', true, 'B is FUNDED');
select is(pg_temp.raise('D', 120, 2) is not null and pg_temp.fund(122, 'D') = 'funded', true, 'D is FUNDED');
select pg_temp.raise('C', 130, 2);
select pg_temp.claim(132, 22, 'C');
select is((select string_agg(f.status || '/' || o.status, ',' order by x.n)
             from fin x join public.monvelo_financings f on f.id = x.id join public.orders o on o.id = f.order_id),
  'FUNDED/PAID,FUNDED/PAID,CLAIMED/PENDING,FUNDED/PAID', 'A, B, D funded with PAID orders; C CLAIMED');

-- ── dispatch ────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(200), pg_temp.f('A'), null)$$,
  '42501', 'not permitted to dispatch this order', 'the TM cannot dispatch');
select pg_temp.act_as(pg_temp.u(9), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(201), pg_temp.f('A'), null)$$,
  '42501', 'not permitted to dispatch this order', 'a DSA cannot dispatch');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(202), pg_temp.f('A'), null)$$,
  '42501', 'not permitted to dispatch this order', 'the TENANT_ADMIN cannot dispatch');
select pg_temp.act_as(pg_temp.u(21), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(203), pg_temp.f('A'), null)$$,
  '42501', null, 'the funding agent''s member cannot dispatch');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(204), pg_temp.f('C'), null)$$,
  'P0001', 'only a funded financing can be dispatched', 'a CLAIMED financing cannot be dispatched');
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(205), pg_temp.f('A'), repeat('x', 101))$$,
  'P0001', 'the tracking reference must be at most 100 characters', 'a tracking reference over 100 characters is refused');
reset role;
-- D was funded exactly 23 hours ago: the window is closed (now >= funded_at + 23 hours)
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('D');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(206), pg_temp.f('D'), null)$$,
  'P0001', 'the 23-hour delivery window has passed; this financing is due a refund', 'dispatch is refused 23 hours after funding');
reset role;
select is((select count(*)::int from public.stock_movements where order_id = pg_temp.o('A')), 0,
  'nothing was consumed by the refusals');

-- A was funded 22h59 ago (usually the previous Lagos calendar day): the calendar day no longer matters
update public.monvelo_financings set funded_at = now() - interval '22 hours 59 minutes' where id = pg_temp.f('A');
select lives_ok($$select pg_temp.dispatch('DA', 8, 210, 'A')$$, 'the LM dispatches A, funded 22h59 ago (allowed)');
select is(pg_temp.r('DA'), jsonb_build_object('financing_id', pg_temp.f('A'), 'order_id', pg_temp.o('A'), 'order_status', 'IN_TRANSIT'),
  'the reply names the financing, the order and IN_TRANSIT');
select is((select status from public.orders where id = pg_temp.o('A')), 'IN_TRANSIT', 'A''s order is IN_TRANSIT');
select is((select status from public.monvelo_financings where id = pg_temp.f('A')), 'FUNDED', 'A stays FUNDED');
select is((select string_agg(kind || ':' || quantity::text || ':' || (recorded_by = pg_temp.u(8))::text, ',')
             from public.stock_movements where order_id = pg_temp.o('A')),
  'SALE_DISPATCH:12.000:true', 'one SALE_DISPATCH movement of 12, recorded by the LM');
select is((select string_agg(distinct status, ',') from public.stock_reservations where order_id = pg_temp.o('A')), 'CONSUMED',
  'A''s reservations are consumed');
-- A, B, C and D each reserved 12; A's 12 left the batch
select is((select quantity::text || '/' || quantity_reserved::text from public.inventory_batches
            where warehouse_id = '70000000-0000-0000-0000-000000000001' and batch_number = 'FIXTURE'),
  '99988.000/36.000', 'the batch: 100000 -> 99988 on hand, 36 still reserved for B, C and D');
select is(pg_temp.dispatch('DA2', 8, 210, 'A'), pg_temp.r('DA'), 'the replay returns the first reply');
select is((select count(*)::int from public.stock_movements where order_id = pg_temp.o('A')), 1, 'and consumes nothing more');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select throws_ok($$select public.dispatch_monvelo_financing(pg_temp.k(211), pg_temp.f('A'), null)$$,
  'P0001', 'this order is not waiting for dispatch', 'a second dispatch with a new key is refused');
reset role;
select ok((select after ->> 'tracking_reference' = 'WAYBILL-A'
             and after::text !~ ('80000000-0000-0000-0000-00000000002|82000000-')
             and tenant_id = pg_temp.t1()
             from public.audit_logs where operation = 'dispatch_monvelo_financing' and entity_id = pg_temp.f('A')::text),
  'the dispatch audit keeps the tracking reference and names no agent or pledge');
-- the ZSM of the zone dispatches B (fulfilment_can_dispatch)
select lives_ok($$select pg_temp.dispatch('DB', 1, 212, 'B')$$, 'the zone''s ZSM dispatches B');

-- ── start_monvelo_delivery ──────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(300), null, pg_temp.f('A'))$$,
  '42501', 'this operation must come through its gateway', 'start without the proof is refused');
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(301), 'wrong', pg_temp.f('A'))$$,
  '42501', 'this operation must come through its gateway', 'start with a wrong proof is refused');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(302), 'test-gw-secret', pg_temp.f('A'))$$,
  '42501', 'not permitted to deliver this order', 'the TENANT_ADMIN has no delivery path');
select pg_temp.act_as(pg_temp.u(21), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(303), 'test-gw-secret', pg_temp.f('A'))$$,
  '42501', null, 'the agent''s member has no delivery path');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(304), 'test-gw-secret', pg_temp.f('C'))$$,
  'P0001', 'only a dispatched, funded financing takes a delivery code', 'a CLAIMED financing takes no code');
reset role;

select lives_ok($$select pg_temp.start('S1', 3, 310, 'A')$$, 'the TM of the territory starts A''s delivery code');
select ok((pg_temp.r('S1') ->> 'code') ~ '^[0-9]{6}$' and (pg_temp.r('S1') ->> 'replayed')::boolean = false,
  'the first call returns a 6-digit code');
select is(pg_temp.r('S1') ->> 'destination_phone', (select phone_number from public.profiles where id = pg_temp.u(10)),
  'the code goes to the owner''s verified profile phone');
select isnt(pg_temp.r('S1') ->> 'destination_phone', '+234803111001', 'not the shop''s contact number');
select ok(abs(extract(epoch from (pg_temp.r('S1') ->> 'expires_at')::timestamptz - (now() + interval '10 minutes'))) < 1,
  'it expires in 10 minutes');
select is((select row(c.purpose, c.financing_id = pg_temp.f('A'), c.issued_by = pg_temp.u(3), c.tenant_id = pg_temp.t1(),
                      c.repayment_id is null, c.failed_attempts, c.consumed_at is null,
                      c.code_hash <> pg_temp.r('S1') ->> 'code', c.code_hash = extensions.crypt(pg_temp.r('S1') ->> 'code', c.code_hash))::text
             from public.monvelo_owner_challenges c where c.id = (pg_temp.r('S1') ->> 'challenge_id')::uuid),
  '(DELIVERY,t,t,t,t,0,t,t,t)', 'one DELIVERY challenge, hashed, by the TM');
select is(pg_temp.start('S1R', 3, 310, 'A'), (pg_temp.r('S1') - 'code' - 'replayed') || '{"replayed": true}'::jsonb,
  'the replay returns the same challenge with no code');
select ok((select bool_and(after::text !~ ('code_hash|' || (pg_temp.r('S1') ->> 'code'))) from public.audit_logs
            where operation = 'start_monvelo_delivery')
      and (select bool_and(response::text !~ (pg_temp.r('S1') ->> 'code')) from public.idempotency_logs
            where operation = 'start_monvelo_delivery'),
  'neither the audit nor the stored reply holds the code or its hash');
select lives_ok($$select pg_temp.start('S2', 3, 311, 'A')$$, 'a second code');
select lives_ok($$select pg_temp.start('S3', 8, 312, 'A')$$, 'a third code, by the LM (courier path)');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(313), 'test-gw-secret', pg_temp.f('A'))$$,
  'P0001', 'too many codes requested for this delivery; try again later', 'a fourth code in an hour is refused');
reset role;

-- ── confirm_monvelo_delivery: refusals ──────────────────────────────────
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok(format($$select public.confirm_monvelo_delivery(pg_temp.k(400), %L, %L)$$,
                        pg_temp.r('S3') ->> 'challenge_id', pg_temp.r('S3') ->> 'code'),
  '42501', 'not permitted to deliver this order', 'R20: the right code from someone with no delivery path is refused');
select pg_temp.act_as(pg_temp.u(21), pg_temp.t1());
select throws_ok(format($$select public.confirm_monvelo_delivery(pg_temp.k(401), %L, %L)$$,
                        pg_temp.r('S3') ->> 'challenge_id', pg_temp.r('S3') ->> 'code'),
  '42501', null, 'and from the agent''s member');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok(format($$select public.confirm_monvelo_delivery(pg_temp.k(402), %L, '12ab')$$, pg_temp.r('S3') ->> 'challenge_id'),
  'P0001', 'the delivery code must be 6 digits', 'a malformed code is refused');
reset role;

-- S1: five wrong codes lock it, and then even the right one is LOCKED
select is(pg_temp.confirm('W1', 3, 410, 'S1', pg_temp.wrong('S1')), '{"confirmed": false, "reason": "INVALID"}'::jsonb,
  'a wrong code is INVALID');
select pg_temp.confirm('W' || n, 3, 410 + n, 'S1', pg_temp.wrong('S1')) from generate_series(2, 4) n;
select is(pg_temp.confirm('W5', 3, 415, 'S1', pg_temp.wrong('S1')), '{"confirmed": false, "reason": "LOCKED"}'::jsonb,
  'the fifth wrong code is LOCKED');
select is((select failed_attempts from public.monvelo_owner_challenges where id = (pg_temp.r('S1') ->> 'challenge_id')::uuid), 5,
  'the counter committed five failures');
select is(pg_temp.confirm('W6', 3, 416, 'S1'), '{"confirmed": false, "reason": "LOCKED"}'::jsonb,
  'the right code on a locked challenge is LOCKED');
select is((select count(*)::int from public.audit_logs where operation = 'MONVELO_DELIVERY_CODE_FAILED'), 5,
  'each failure is audited');
-- S2 expired
update public.monvelo_owner_challenges set expires_at = now() - interval '1 second'
 where id = (pg_temp.r('S2') ->> 'challenge_id')::uuid;
select is(pg_temp.confirm('E1', 3, 420, 'S2'), '{"confirmed": false, "reason": "EXPIRED"}'::jsonb,
  'the right code after expiry is EXPIRED');
select is((select status from public.monvelo_financings where id = pg_temp.f('A')), 'FUNDED', 'A is still FUNDED');
select is((select count(*)::int from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('A')), 0,
  'and nothing is booked');

-- ── the 23-hour window, on B ────────────────────────────────────────────
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('B');
select pg_temp.act_as(pg_temp.u(9), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(429), 'test-gw-secret', pg_temp.f('B'))$$,
  'P0001', 'the 23-hour delivery window has passed; this financing is due a refund', 'no code 23 hours after funding');
reset role;
update public.monvelo_financings set funded_at = now() - interval '22 hours 59 minutes' where id = pg_temp.f('B');
select lives_ok($$select pg_temp.start('SB', 9, 430, 'B')$$, 'a code is allowed 22h59 after funding');
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('B');
select pg_temp.act_as(pg_temp.u(9), pg_temp.t1());
select throws_ok(format($$select public.confirm_monvelo_delivery(pg_temp.k(432), %L, %L)$$,
                        pg_temp.r('SB') ->> 'challenge_id', pg_temp.r('SB') ->> 'code'),
  'P0001', 'the 23-hour delivery window has passed; this financing is due a refund', 'no confirmation 23 hours after funding');
reset role;
update public.monvelo_financings set funded_at = now() - interval '22 hours 59 minutes' where id = pg_temp.f('B');

-- ── B delivered at 0 bps ────────────────────────────────────────────────
select is(pg_temp.confirm('CB', 9, 431, 'SB') ->> 'confirmed', 'true', 'a DSA of the territory confirms B with the code');
select is((select string_agg(entry_type || ':' || amount::text, ',') from public.monvelo_tenant_ledger_entries
            where financing_id = pg_temp.f('B')),
  'FUNDED_GROSS:48000.00', 'at 0 bps: one FUNDED_GROSS and no FEE');

-- ── A delivered at 200 bps ──────────────────────────────────────────────
insert into public.monvelo_tenant_fee_terms (tenant_id, fee_bps, valid_from, recorded_by)
values (pg_temp.t1(), 200, public.monvelo_today(), pg_temp.u(6));
select is(public.monvelo_fee_bps_at(pg_temp.t1(), public.monvelo_today()), 200, 'today''s fee terms: 200 bps');
select is(pg_temp.confirm('CA', 3, 440, 'S3'),
  jsonb_build_object('confirmed', true, 'due_at', ((public.monvelo_today() + 31)::timestamp at time zone 'Africa/Lagos')),
  'the right code confirms A; due at the end of the Lagos day 30 days after delivery');
select is((select row(status, delivered_at = now(), due_at = ((public.monvelo_today() + 31)::timestamp at time zone 'Africa/Lagos'),
                      outstanding)::text
             from public.monvelo_financings where id = pg_temp.f('A')),
  '(DELIVERED,t,t,48000.00)', 'A is DELIVERED now, with due_at and outstanding = principal');
select is(((select due_at from public.monvelo_financings where id = pg_temp.f('A')) at time zone 'Africa/Lagos')::text,
  (public.monvelo_today() + 31)::text || ' 00:00:00', 'due_at is Lagos midnight closing day 30');
select is((select status from public.orders where id = pg_temp.o('A')), 'DELIVERED', 'A''s order is DELIVERED');
select ok((select consumed_at is not null from public.monvelo_owner_challenges where id = (pg_temp.r('S3') ->> 'challenge_id')::uuid),
  'the challenge is consumed');
select is((select string_agg(entry_type || ':' || amount::text || ':' || (business_date = public.monvelo_today())::text, ','
                             order by entry_type desc)
             from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('A')),
  'FUNDED_GROSS:48000.00:true,FEE:-960.00:true', 'one FUNDED_GROSS 48000.00 and one FEE -960.00 on today''s Lagos date');
select is(pg_temp.confirm('CA2', 3, 440, 'S3'), pg_temp.r('CA'), 'the replay returns the first reply');
select is(pg_temp.confirm('CA3', 3, 441, 'S3') ->> 'confirmed', 'true', 'the spent challenge under a new key says confirmed');
select is((select count(*)::int from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('A')), 2,
  'and the ledger is not doubled');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.start_monvelo_delivery(pg_temp.k(450), 'test-gw-secret', pg_temp.f('A'))$$,
  'P0001', 'only a dispatched, funded financing takes a delivery code', 'a DELIVERED financing takes no new code');
reset role;
select ok((select bool_and(after::text !~ ('80000000-0000-0000-0000-00000000002|82000000-|funder|pledge|claimed_by'))
             from public.audit_logs
            where operation in ('dispatch_monvelo_financing', 'start_monvelo_delivery', 'confirm_monvelo_delivery',
                                'MONVELO_DELIVERY_CODE_FAILED')),
  'no audit row written here names the agent, its member or its pledge');

-- ── readers ─────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('A')), 2,
  'the TENANT_ADMIN reads both of A''s ledger rows');
select throws_ok('select count(*) from public.monvelo_owner_challenges', '42501', null,
  'the TENANT_ADMIN cannot read the challenges');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok('select count(*) from public.monvelo_owner_challenges', '42501', null, 'nor can the TM who issued them');
select pg_temp.act_as(pg_temp.u(10), null);
select throws_ok('select count(*) from public.monvelo_owner_challenges', '42501', null, 'nor can the shop owner');
reset role;
select throws_ok($$delete from public.monvelo_owner_challenges where id = (pg_temp.r('S1') ->> 'challenge_id')::uuid$$,
  'P0001', 'Monvelo records are never deleted', 'a challenge is never deleted');

select * from finish();
rollback;
