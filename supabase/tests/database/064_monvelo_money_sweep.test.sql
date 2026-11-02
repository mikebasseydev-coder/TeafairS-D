-- Addendum A6 §4.4, §5 step 10 (Monvelo Step 3, Task 5) — the money sweep
-- (monvelo_sweep_money: refund due 23 hours after funding, the one late
-- charge, unconfirmed repayments) and Monvelo refunds (apply_monvelo_refund),
-- with apply_paystack_refund leaving MV- payments alone (R47).
begin;
create extension if not exists pgtap with schema extensions;

select plan(75);

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

-- A6 §19: one agent funds several 48000 financings here, more than the 100000
-- open exposure ceiling; this file is not about the cap (065 is), so the
-- ceiling is raised for this transaction only
create or replace function public.monvelo_open_exposure_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 100000000.00::numeric(15,2) $$;

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 08 LM (under 18 CSM)
-- 10 owner of S1 and S2 · 06 MONVELO_OPERATOR · agent members: 21 of P ("ADE, BISI O.", ...0011)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 6, 7, 8, 10, 18, 21, 22]) n;
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

-- a second TEAFAIR brand for the two-line late charge: Tiger tea, any quantity
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, nafdac_number, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TIGER-1', 'Tiger tea', 'Tiger', 'Beverages', 'A7-1001', 1200, 1000);

insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
update public.monvelo_tenant_settings set limit_growth_bps = 0, max_limit = null, default_cure_days = 0
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001';
-- Purerigin: 10 % rebate, 30 days, 10 % late charge (A6 §5); Tiger: 5 %, 30 days, 5 %
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 1000, 30, 1000, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now()),
  ('7eaf0000-0000-4000-8000-000000000001', 'Tiger', 500, 30, 500, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');

insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
values ('80000000-0000-0000-0000-000000000021', 'POS 21', 'OPAY', 'OP-21', '+2348031110021',
        extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
        '0123450011', '0011', '058', 'ADE, BISI O.', 'K21',
        '20000000-0000-0000-0000-000000000004', 'ACTIVE', 5000000, 200000);
insert into public.monvelo_agent_members (agent_id, profile_id) values
  ('80000000-0000-0000-0000-000000000021', '20000000-0000-0000-0000-000000000021');
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by) values
  ('82000000-0000-0000-0000-000000000021', '7eaf0000-0000-4000-8000-000000000001', '80000000-0000-0000-0000-000000000021',
   '60000000-0000-0000-0000-000000000001', public.monvelo_today(), 5000000, 5000000, '20000000-0000-0000-0000-000000000021');

-- S1 and S2, both enrolled in Allen, owner 10
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text, preferred_agent_id) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1', null),
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
  $$ select ('d6400000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag() returns uuid language sql as $$ select '80000000-0000-0000-0000-000000000021'::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.s(n integer) returns uuid language sql as
  $$ select ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(), pg_temp.t1(), pg_temp.s(integer)
  to authenticated;
create temp table fin (n text primary key, id uuid, ref text);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on fin, res to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.ref(p_n text) returns text language sql as $$ select ref from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
create function pg_temp.rp(p_n text) returns uuid language sql as $$ select (r ->> 'repayment_id')::uuid from res where n = p_n $$;
create function pg_temp.ord(p_n text) returns uuid language sql as
  $$ select order_id from public.monvelo_financings where id = pg_temp.f(p_n) $$;
grant execute on function pg_temp.f(text), pg_temp.ref(text), pg_temp.r(text), pg_temp.rp(text), pg_temp.ord(text)
  to authenticated;

-- the agent's verified transfer (F1), from P's account or from someone else's
create function pg_temp.paid(p_sender text) returns jsonb language sql as $$
  select jsonb_build_object('status', 'success', 'channel', 'bank_transfer',
    'authorization', jsonb_build_object('channel', 'bank_transfer', 'sender_bank', 'Guaranty Trust Bank',
                                        'sender_name', p_sender, 'sender_bank_account_number', 'XXXXXX0011')) $$;

-- a trade order on shop p_shop (default: 12 Purerigin 200 ml, 48000), its
-- financing requested by the ASA, claimed by P and its payment started; the
-- payment reference is kept
create function pg_temp.started(p_n text, p_key integer, p_shop integer, p_lines jsonb default null) returns text
language plpgsql as $$
declare v_o uuid; v_f uuid; v_ref text;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), pg_temp.s(p_shop), coalesce(p_lines,
          jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 12)))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform pg_temp.act_as(pg_temp.u(21), null);
  perform public.claim_monvelo_financing(pg_temp.k(p_key + 2), v_f, pg_temp.ag());
  v_ref := public.start_monvelo_funding(pg_temp.k(p_key + 3), v_f, pg_temp.ag()) ->> 'reference';
  perform set_config('role', 'postgres', true);
  insert into fin values (p_n, v_f, v_ref);
  return v_ref;
end; $$;
-- ... and funded by P's verified transfer of 48000
create function pg_temp.funded(p_n text, p_key integer, p_shop integer, p_lines jsonb default null) returns text
language plpgsql as $$
begin
  perform pg_temp.started(p_n, p_key, p_shop, p_lines);
  perform public.settle_monvelo_funding('charge.success', pg_temp.ref(p_n), 'success', 4800000, 'NGN',
                                        pg_temp.paid('BISI ADE'), 'T-' || p_n);
  return (select status from public.monvelo_financings where id = pg_temp.f(p_n));
end; $$;
-- the LM dispatches
create function pg_temp.dispatched(p_n text, p_key integer) returns void language plpgsql as $$
begin
  perform pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
  perform public.dispatch_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_n), null);
  perform set_config('role', 'postgres', true);
end; $$;
-- ... and the TM delivers with the owner's code
create function pg_temp.delivered(p_n text, p_key integer, p_shop integer, p_lines jsonb default null) returns text
language plpgsql as $$
declare v_start jsonb;
begin
  perform pg_temp.funded(p_n, p_key, p_shop, p_lines);
  perform pg_temp.dispatched(p_n, p_key + 4);
  perform pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
  v_start := public.start_monvelo_delivery(pg_temp.k(p_key + 5), 'test-gw-secret', pg_temp.f(p_n));
  perform public.confirm_monvelo_delivery(pg_temp.k(p_key + 6), (v_start ->> 'challenge_id')::uuid, v_start ->> 'code');
  perform set_config('role', 'postgres', true);
  return (select status from public.monvelo_financings where id = pg_temp.f(p_n));
end; $$;
-- P's member records a repayment
create function pg_temp.rec(p_n text, p_key integer, p_fin text, p_amount numeric) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(21), null);
  v := public.record_monvelo_repayment(pg_temp.k(p_key), 'test-gw-secret', pg_temp.f(p_fin), pg_temp.ag(), p_amount);
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v);
  return v;
end; $$;
-- ... and confirms it with the owner's code
create function pg_temp.conf(p_key integer, p_rec text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(21), null);
  v := public.confirm_monvelo_repayment(pg_temp.k(p_key), (pg_temp.r(p_rec) ->> 'challenge_id')::uuid, pg_temp.r(p_rec) ->> 'code');
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
create function pg_temp.fin_state(p_n text) returns text language sql as $$
  select row(status, outstanding, late_charge_amount, closed_at is not null)::text
    from public.monvelo_financings where id = pg_temp.f(p_n) $$;
create function pg_temp.pay_status(p_n text) returns text language sql as $$
  select payment_status::text from public.payments where paystack_reference = pg_temp.ref(p_n) $$;
create function pg_temp.refund(p_id text, p_n text, p_minor bigint, p_reason text default 'REFUND') returns jsonb
language sql as $$
  select public.apply_monvelo_refund('webhook', p_id, pg_temp.ref(p_n), p_minor, 'NGN', p_reason, '{"id": 1}'::jsonb) $$;

-- ── shape and security ──────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.monvelo_sweep_money()', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_sweep_money()', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_sweep_money()', 'execute'),
  'the sweep has no API grant');
select ok(has_function_privilege('service_role', 'public.apply_monvelo_refund(text,text,text,bigint,text,text,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'public.apply_monvelo_refund(text,text,text,bigint,text,text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.apply_monvelo_refund(text,text,text,bigint,text,text,jsonb)', 'execute'),
  'the refund is for service_role only');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=public, pg_temp']) from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname in ('monvelo_sweep_money', 'apply_monvelo_refund'))
      and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('monvelo_sweep_money', 'apply_monvelo_refund')) = 2,
  'both are SECURITY DEFINER with the pinned search_path');
select is((select schedule || ' ' || command from cron.job where jobname = 'monvelo-money-sweep'),
  '*/5 * * * * select public.monvelo_sweep_money()', 'the job monvelo-money-sweep runs every 5 minutes');
select is(public.monvelo_delivery_cutoff('2026-11-01 10:00:00+01'::timestamptz), '2026-11-02 09:00:00+01'::timestamptz,
  'R46: one cutoff, 23 hours after funding');
select ok(not has_function_privilege('authenticated', 'public.monvelo_delivery_cutoff(timestamptz)', 'execute')
      and pg_get_functiondef('public.monvelo_assert_delivery_day(public.monvelo_financings)'::regprocedure)
          like '%monvelo_delivery_cutoff(p_fin.funded_at)%',
  'the cutoff is internal and the delivery-day check uses it');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'monvelo_flags_kind_check') like '%FUNDING_REFUNDED%',
  'flags accept FUNDING_REFUNDED');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select throws_ok($$select public.monvelo_sweep_money()$$, '42501', null, 'authenticated cannot run the sweep');
select throws_ok($$select public.apply_monvelo_refund('webhook', 'x', 'MV-AAAAAAAA-1', 100, 'NGN', 'REFUND', '{}')$$,
  '42501', null, 'authenticated cannot apply a Monvelo refund');
reset role;

-- ── the financings ──────────────────────────────────────────────────────
-- RD, RU, RT, EF funded (RT dispatched); LA, LB, LC, PR delivered (LC on two
-- brands: 30000 Purerigin 100 ml at 1000 bps + 18000 Tiger at 500 bps); PM
-- paid from the wrong account (still CLAIMED); RV a payment only started
select is(pg_temp.funded('RD', 100, 1) || pg_temp.funded('RU', 110, 1) || pg_temp.funded('RT', 120, 1)
          || pg_temp.funded('EF', 130, 2),
  'FUNDED' || 'FUNDED' || 'FUNDED' || 'FUNDED', 'RD, RU, RT and EF are FUNDED');
select pg_temp.dispatched('RT', 125);
select is(pg_temp.delivered('LA', 200, 2) || pg_temp.delivered('LB', 210, 2) || pg_temp.delivered('PR', 230, 2)
          || pg_temp.delivered('LC', 220, 1, jsonb_build_array(
               jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-100ML', 'qty', 12),
               jsonb_build_object('sku_code', 'TIGER-1', 'qty', 18))),
  'DELIVERED' || 'DELIVERED' || 'DELIVERED' || 'DELIVERED', 'LA, LB, PR and LC are DELIVERED');
-- R54 fixtures: CL (to be closed) with a repayment left PENDING; SP with a PENDING
-- repayment and a later one by the same recorder, confirmed
select is(pg_temp.delivered('CL', 240, 2) || pg_temp.delivered('SP', 250, 2), 'DELIVERED' || 'DELIVERED',
  'CL and SP are DELIVERED');
select pg_temp.rec('PC', 410, 'CL', 1000);
select pg_temp.rec('S1', 411, 'SP', 1000);
select pg_temp.rec('S2', 412, 'SP', 1000);
select is(pg_temp.conf(413, 'S2') ->> 'confirmed', 'true', 'S2 is confirmed; S1 stays PENDING');
select is((select string_agg(brand_key || ':' || amount || ':' || late_charge_bps, ',' order by brand_key)
             from public.monvelo_financing_lines where financing_id = pg_temp.f('LC')),
  'purerigin:30000.00:1000,tiger:18000.00:500', 'LC has two lines with their own late-charge terms');
select pg_temp.started('PM', 300, 1);
select is(public.settle_monvelo_funding('charge.success', pg_temp.ref('PM'), 'success', 4800000, 'NGN',
                                        pg_temp.paid('JOHN DOE'), 'T-PM') ->> 'outcome',
  'payer_mismatch', 'PM was paid from another account');
select pg_temp.started('RV', 310, 2);

-- the clock: RD and RT funded 23 hours ago, RU 22h59 ago; LA, LB and LC past
-- due (LB with 28000 left); PR not yet due, with repayments 25 h and 23 h old
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id in (pg_temp.f('RD'), pg_temp.f('RT'));
update public.monvelo_financings set funded_at = now() - interval '22 hours 59 minutes' where id = pg_temp.f('RU');
update public.monvelo_financings set due_at = now() - interval '1 second' where id in (pg_temp.f('LA'), pg_temp.f('LB'), pg_temp.f('LC'));
update public.monvelo_financings set outstanding = 28000 where id = pg_temp.f('LB');
select pg_temp.rec('P25', 400, 'PR', 1000);
select pg_temp.rec('P23', 401, 'PR', 1000);
set local session_replication_role = replica;
update public.monvelo_repayments set recorded_at = now() - interval '25 hours' where id = pg_temp.rp('P25');
update public.monvelo_repayments set recorded_at = now() - interval '23 hours' where id = pg_temp.rp('P23');
set local session_replication_role = origin;

-- ── the sweep ───────────────────────────────────────────────────────────
select is(public.monvelo_sweep_money(),
  '{"refund_due": 2, "late_charged": 3, "repayments_expired": 1, "repayments_superseded": 0}'::jsonb,
  'two refunds due, three late charges, one repayment expired');

-- refund due: RD (paid, not dispatched)
select is(pg_temp.fin_state('RD'), '(REFUND_DUE,,0.00,f)', 'RD funded 23 hours ago and undelivered is REFUND_DUE');
select is((select status from public.orders where id = pg_temp.ord('RD')), 'CANCELLED', 'its order is CANCELLED');
select is((select string_agg(distinct status || ':' || coalesce(close_reason, ''), ',') from public.stock_reservations
            where order_id = pg_temp.ord('RD')), 'RELEASED:CANCELLED', 'its reservations are released');
select is((select quantity_reserved from public.inventory_batches
            where sku_code = 'PURERIGIN-COCONUT-OIL-200ML' and batch_number = 'FIXTURE'),
          (select sum(quantity) from public.stock_reservations
            where sku_code = 'PURERIGIN-COCONUT-OIL-200ML' and status = 'RESERVED'),
  'the batch holds only what is still reserved');
select is((select status from public.monvelo_rebate_payables where financing_id = pg_temp.f('RD')), 'CANCELLED',
  'the payable is CANCELLED');
select is((select string_agg(t.kind || ':' || t.priority || ':' || (t.order_id = pg_temp.ord('RD'))::text, ',')
             from public.support_tickets t where t.system_key = 'monvelo-refund:' || pg_temp.f('RD')),
  'SYSTEM:HIGH:true', 'one HIGH system ticket on RD''s order');
select is((select status || ':' || (resolved_at is null)::text from public.support_tickets
            where system_key = 'monvelo-refund:' || pg_temp.f('RD')), 'OPEN:true', 'R56: it is OPEN until the refund lands');
select is((select string_agg(m.body, '|') from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'monvelo-refund:' || pg_temp.f('RD')),
  'Refund the funding of ' || pg_temp.ref('RD') || ' in Paystack.', 'the ticket names the MV- reference to refund');

-- 22h59: untouched
select is(pg_temp.fin_state('RU') || (select status from public.orders where id = pg_temp.ord('RU'))
          || (select status from public.monvelo_rebate_payables where financing_id = pg_temp.f('RU')),
  '(FUNDED,,0.00,f)PAIDDUE', 'RU funded 22h59 ago is untouched');
select is((select count(*)::int from public.support_tickets where system_key = 'monvelo-refund:' || pg_temp.f('RU')), 0,
  'and has no ticket');

-- refund due after dispatch: RT; the consumed stock comes back through record_order_return
select is(pg_temp.fin_state('RT') || (select status from public.orders where id = pg_temp.ord('RT')),
  '(REFUND_DUE,,0.00,f)CANCELLED', 'RT, dispatched but undelivered, is REFUND_DUE and its order CANCELLED');
select is((select string_agg(distinct status, ',') from public.stock_reservations where order_id = pg_temp.ord('RT')),
  'CONSUMED', 'its stock stays consumed until it is returned');
select is((select string_agg(m.body, '|') from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'monvelo-refund:' || pg_temp.f('RT')),
  'Refund the funding of ' || pg_temp.ref('RT') || ' in Paystack. The stock was dispatched: record its return.',
  'the ticket asks for the return as well');
insert into res values ('RT-order', to_jsonb(pg_temp.ord('RT')));
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select is(jsonb_array_length(public.record_order_return(pg_temp.k(126), (pg_temp.r('RT-order') #>> '{}')::uuid,
            '[{"sku_code": "PURERIGIN-COCONUT-OIL-200ML", "qty": 12}]'::jsonb) -> 'movements'), 1,
  'the LM records the return of RT''s stock');
reset role;

-- the late charge
select is(pg_temp.fin_state('LA'), '(DEFAULTED_WITH_LATE_CHARGE,52800.00,4800.00,f)',
  'LA: 48000 outstanding at 1000 bps, a late charge of 4800, 52800 outstanding');
select is(pg_temp.fin_state('LB'), '(DEFAULTED_WITH_LATE_CHARGE,30800.00,2800.00,f)',
  'LB: 28000 outstanding, a late charge of 2800');
select is(pg_temp.fin_state('LC'), '(DEFAULTED_WITH_LATE_CHARGE,51900.00,3900.00,f)',
  'LC: 3000 + 900 = 3900 over its two lines');
select is(pg_temp.fin_state('PR'), '(DELIVERED,48000.00,0.00,f)', 'PR, not yet due, has no charge');

-- unconfirmed repayments
select is((select status || ':' || (ended_at is not null)::text from public.monvelo_repayments where id = pg_temp.rp('P25')),
  'EXPIRED:true', 'the repayment pending 25 h is EXPIRED');
select is((select status from public.monvelo_repayments where id = pg_temp.rp('P23')), 'PENDING',
  'the one pending 23 h is untouched');
select is((select string_agg(kind || ':' || (agent_id = pg_temp.ag())::text || ':' || (details ->> 'repayment_id'), ',')
             from public.monvelo_flags where financing_id = pg_temp.f('PR')),
  'REPAYMENT_UNCONFIRMED:true:' || pg_temp.rp('P25'), 'one REPAYMENT_UNCONFIRMED flag');
select is((select string_agg(t.kind || ':' || t.priority || ':' || (t.order_id = pg_temp.ord('PR'))::text, ',')
             from public.support_tickets t where t.system_key = 'monvelo-repayment:' || pg_temp.rp('P25')),
  'SYSTEM:HIGH:true', 'one HIGH system ticket on PR''s order');
select is((select count(*)::int from public.support_tickets where system_key = 'monvelo-repayment:' || pg_temp.rp('P23')), 0,
  'none for the 23 h repayment');
select ok((select bool_and(m.body !~ ('ADE|BISI|POS 21|80000000-|82000000-|20000000-0000-0000-0000-00000000002'))
             from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key like 'monvelo-refund:%' or t.system_key like 'monvelo-repayment:%'),
  'no sweep ticket names the agent, its pledge or its member');

-- a second sweep adds nothing
select is(public.monvelo_sweep_money(),
  '{"refund_due": 0, "late_charged": 0, "repayments_expired": 0, "repayments_superseded": 0}'::jsonb,
  'a second sweep does nothing');
select is(pg_temp.fin_state('LA') || pg_temp.fin_state('LB'),
  '(DEFAULTED_WITH_LATE_CHARGE,52800.00,4800.00,f)(DEFAULTED_WITH_LATE_CHARGE,30800.00,2800.00,f)',
  'the late charge is applied once');
select is((select count(*)::int from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'monvelo-refund:' || pg_temp.f('RD')), 1, 'RD''s ticket got no second message');

-- the sweep's audit rows (R15)
select ok((select bool_and(a.tenant_id = pg_temp.t1() and a.source = 'CRON'
                           and coalesce(a.before::text, '') || a.after::text !~ '80000000-|82000000-|20000000-0000-0000-0000-00000000002')
             from public.audit_logs a where a.operation = 'monvelo_sweep_money' and a.entity_type = 'monvelo_financings')
      and (select count(*) from public.audit_logs where operation = 'monvelo_sweep_money' and entity_type = 'monvelo_financings') = 2,
  'the two REFUND_DUE rows are the tenant''s, as CRON, and name no lender');
select ok((select bool_and(a.tenant_id is null) from public.audit_logs a
            where a.operation = 'monvelo_sweep_money' and a.entity_type in ('monvelo_rebate_payables', 'monvelo_repayments'))
      and (select count(*) from public.audit_logs
            where operation = 'monvelo_sweep_money' and entity_type in ('monvelo_rebate_payables', 'monvelo_repayments')) = 3,
  'the payable and repayment rows name the agent, so no tenant reads them');

-- ── R47: apply_paystack_refund leaves an MV- payment alone ──────────────
select is(public.apply_paystack_refund('webhook', 'RF-WEB', pg_temp.ref('RD'), 4800000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'monvelo_reference', 'the web refund returns monvelo_reference for an MV- payment');
select is(pg_temp.pay_status('RD'), 'SUCCESS', 'and writes nothing to the payment');
select is((select count(*)::int from public.idempotency_logs where key = md5('paystack-refund:RF-WEB')::uuid), 0,
  'nor takes the refund''s key');
select is((select count(*)::int from public.audit_logs where operation = 'PAYSTACK_MONVELO_REFERENCE'
              and after ->> 'reference' = pg_temp.ref('RD')), 1, 'it leaves one audit row');

-- ── apply_monvelo_refund ────────────────────────────────────────────────
insert into res values ('RF-1', pg_temp.refund('RF-1', 'RD', 4800000));
select is(pg_temp.r('RF-1') - 'payment_id',
  '{"outcome": "refunded", "payment_status": "REFUNDED", "financing_status": "REFUND_DUE", "financing_closed": true, "reason": "REFUND"}'::jsonb,
  'the refund of RD''s funding is applied');
select is(pg_temp.pay_status('RD') || pg_temp.fin_state('RD'), 'REFUNDED(REFUND_DUE,,0.00,t)',
  'the payment is REFUNDED and RD is closed');
-- R56: the refund ticket is resolved, with a system message
select is((select status || ':' || (resolved_at is not null)::text from public.support_tickets
            where system_key = 'monvelo-refund:' || pg_temp.f('RD')), 'RESOLVED:true', 'R56: RD''s refund ticket is RESOLVED');
select is((select m.body || ':' || m.sender_type from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'monvelo-refund:' || pg_temp.f('RD') order by m.created_at desc, m.id desc limit 1),
  'Refund received in Paystack; financing closed.:SYSTEM', 'with a SYSTEM message saying why');
select is(pg_temp.refund('RF-1', 'RD', 4800000), pg_temp.r('RF-1'), 'the same refund id again replays the first reply');
select is((select count(*)::int from public.audit_logs where operation = 'apply_monvelo_refund' and entity_type = 'payments'
              and entity_id = (select id::text from public.payments where paystack_reference = pg_temp.ref('RD'))), 1,
  'the refund was applied once');
select is(pg_temp.refund('RF-2', 'RD', 4800000) ->> 'reason', 'payment_not_success',
  'another refund id on a refunded payment is a conflict');

-- a payer-mismatch payment's refund: the financing stays CLAIMED
select is(pg_temp.refund('RF-3', 'PM', 4800000) ->> 'outcome', 'refunded', 'PM''s payment is refunded');
select is(pg_temp.pay_status('PM') || pg_temp.fin_state('PM'), 'REFUNDED(CLAIMED,,0.00,f)',
  'the payment is REFUNDED and the financing stays CLAIMED');

-- a partial refund changes no status; over-refunds and unknown references conflict
select is(pg_temp.refund('RF-4', 'RT', 100000) ->> 'outcome', 'partial', 'a partial refund of RT');
select is(pg_temp.pay_status('RT') || pg_temp.fin_state('RT'), 'SUCCESS(REFUND_DUE,,0.00,f)', 'changes no status');
select is((select status from public.support_tickets where system_key = 'monvelo-refund:' || pg_temp.f('RT')), 'OPEN',
  'and RT''s refund ticket stays OPEN');
select is(pg_temp.refund('RF-5', 'RT', 4800001) ->> 'reason', 'over_refund', 'more than was paid is a conflict');
select is(public.apply_monvelo_refund('sweep', 'RF-6', 'MV-ZZZZZZZZ-1', 100, 'NGN', 'REFUND', '{}') ->> 'reason',
  'unknown_reference', 'an unknown reference is a conflict');

-- a reversal of a payment never confirmed: REFUNDED, the financing untouched
select is(pg_temp.refund('reversal:' || pg_temp.ref('RV'), 'RV', 4800000, 'REVERSAL') ->> 'outcome', 'refunded',
  'a reversal of RV''s started payment');
select is(pg_temp.pay_status('RV') || pg_temp.fin_state('RV'), 'REFUNDED(CLAIMED,,0.00,f)', 'is REFUNDED; RV stays CLAIMED');

-- EF: its funding refunded while still FUNDED is flagged; the sweep later closes it with no ticket
select is(pg_temp.refund('RF-7', 'EF', 4800000) - 'payment_id',
  '{"outcome": "refunded", "payment_status": "REFUNDED", "financing_status": "FUNDED", "financing_closed": false, "reason": "REFUND"}'::jsonb,
  'EF''s funding refunded before its window closed');
select is((select string_agg(kind, ',') from public.monvelo_flags where financing_id = pg_temp.f('EF')), 'FUNDING_REFUNDED',
  'is flagged for the operator');
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('EF');
select is(public.monvelo_sweep_money() ->> 'refund_due', '1', 'the sweep moves EF');
select is(pg_temp.fin_state('EF') || (select count(*) from public.support_tickets
                                       where system_key = 'monvelo-refund:' || pg_temp.f('EF'))::text,
  '(REFUND_DUE,,0.00,t)0', 'to REFUND_DUE, closed at once (already refunded), with no ticket');

-- the refund's audit rows (R15)
select ok((select bool_and(tenant_id is null) from public.audit_logs
            where operation in ('apply_monvelo_refund', 'MONVELO_REFUND_CONFLICT', 'MONVELO_PARTIAL_REFUND')
              and entity_type = 'payments')
      and (select bool_and(a.tenant_id = pg_temp.t1()
                           and coalesce(a.before::text, '') || a.after::text !~ '80000000-|82000000-|20000000-0000-0000-0000-00000000002')
             from public.audit_logs a where a.operation = 'apply_monvelo_refund' and a.entity_type = 'monvelo_financings')
      and (select count(*) from public.audit_logs
            where operation = 'apply_monvelo_refund' and entity_type = 'monvelo_financings') = 1,
  'payment rows are written with tenant null; the closure row is the tenant''s and names no lender');

-- ── R54: the sweep expires orphaned repayments quietly ─────────────────
-- CL is closed with PC still PENDING; SP's S1 is followed by S2, confirmed by the
-- same recorder; PR's P23 is a genuine unconfirmed repayment. All 25 h old.
update public.monvelo_financings set status = 'REPAID_WITHIN_WINDOW', outstanding = 0, closed_at = now()
 where id = pg_temp.f('CL');
set local session_replication_role = replica;
update public.monvelo_repayments set recorded_at = now() - interval '25 hours'
 where id in (pg_temp.rp('PC'), pg_temp.rp('S1'), pg_temp.rp('P23'));
set local session_replication_role = origin;
select is(public.monvelo_sweep_money(),
  '{"refund_due": 0, "late_charged": 0, "repayments_expired": 1, "repayments_superseded": 2}'::jsonb,
  'R54: one genuine expiry, two orphans');
select is((select string_agg(status, ',' order by recorded_at) from public.monvelo_repayments
            where id in (pg_temp.rp('PC'), pg_temp.rp('S1'), pg_temp.rp('P23'))), 'EXPIRED,EXPIRED,EXPIRED',
  'all three are EXPIRED');
select is((select count(*)::int from public.monvelo_flags where financing_id in (pg_temp.f('CL'), pg_temp.f('SP')))
          + (select count(*)::int from public.support_tickets
              where system_key in ('monvelo-repayment:' || pg_temp.rp('PC'), 'monvelo-repayment:' || pg_temp.rp('S1'))), 0,
  'the closed financing''s and the superseded repayment raise no flag and no ticket');
select is((select count(*)::int from public.monvelo_flags where kind = 'REPAYMENT_UNCONFIRMED' and details ->> 'repayment_id' = pg_temp.rp('P23')::text)
          + (select count(*)::int from public.support_tickets where system_key = 'monvelo-repayment:' || pg_temp.rp('P23') and priority = 'HIGH'),
  2, 'the genuine one still gets its flag and its HIGH ticket');
select is((select string_agg(a.after ->> 'reason', ',' order by a.after ->> 'reason') from public.audit_logs a
            where a.operation = 'monvelo_sweep_money' and a.entity_type = 'monvelo_repayments' and a.tenant_id is null
              and a.entity_id in (pg_temp.rp('PC')::text, pg_temp.rp('S1')::text)),
  'FINANCING_CLOSED,SUPERSEDED', 'each orphan has one audit row, tenant null, with its reason');

select * from finish();
rollback;
