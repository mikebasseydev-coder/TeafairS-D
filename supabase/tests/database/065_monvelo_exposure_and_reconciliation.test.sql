-- Addendum A6 §19 (2026-11-02) — the agent's open exposure cap
-- (monvelo_open_exposure_ceiling, monvelo_agent_open_exposure, the check in
-- monvelo_claim_refusal), the pledge restored when a REFUND_DUE financing's
-- refund is confirmed (apply_monvelo_refund), and the lender reconciliation
-- summary (get_lender_reconciliation_summary).
begin;
create extension if not exists pgtap with schema extensions;

select plan(72);

-- The limits are ₦1,000,000 and ₦3,000,000 (20261031121100, user 2026-11-03);
-- the next assertion proves the shipped values. The scenarios below are sized
-- to the 1:3 ratio at the original ₦100,000 / ₦300,000, so this transaction
-- pins those figures (as 061-064 pin a high ceiling); every message reads the
-- ceiling, so the text follows the pinned value.
select is(public.monvelo_open_exposure_ceiling()::text || ' / ' || public.monvelo_allowance_ceiling()::text, '1000000.00 / 3000000.00', 'shipped: the ceiling 1000000.00 and the market-maker limit 3000000.00');
create or replace function public.monvelo_open_exposure_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 100000.00::numeric(15,2) $$;
create or replace function public.monvelo_allowance_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 300000.00::numeric(15,2) $$;

-- A6 Task 6b: placing an order reserves stock. This file is not about stock,
-- so every ordered line finds ample stock in its order's fulfilment warehouse.
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

-- ── fixtures (as postgres): TEAFAIR (T1) and SUREACH (T2) ───────────────
-- T1: zone 1 Lagos > territory 1 Ikeja > areas 1 Allen, 2 Opebi; zone 2 Ogun > territory 2 Abeokuta > area 3 Kuto
-- T2: zone 3 > territory 3 > area 4 Wuse
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 08 LM (under 18 CSM)
-- 10 owner of S1 and S2 · 11 ZSA (zone 1)
-- agents (member = same number): 21 P (real fundings, restoration) · 31 X (the cap) · 32 Y (another lender)
--                                41 Q and 42 R (the summary)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 7, 8, 10, 11, 18, 21, 31, 32, 41, 42]) n;

update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'Ogun', 'OG'),
  ('30000000-0000-0000-0000-000000000003', '5eac0000-0000-4000-8000-000000000001', 'Abuja', 'FC');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000002', 'Abeokuta'),
  ('40000000-0000-0000-0000-000000000003', '5eac0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000003', 'Central');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen'),
  ('60000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Opebi'),
  ('60000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000002', 'Kuto'),
  ('60000000-0000-0000-0000-000000000004', '5eac0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000003', 'Wuse');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000018', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000018', 'CLIENT_SERVICE_MANAGER', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000011', 'ZSA', '30000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

-- Tiger tea, 1000 a unit at trade, any quantity: a 2000 request is two units
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, nafdac_number, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TIGER-1', 'Tiger tea', 'Tiger', 'Beverages', 'A7-1001', 1200, 1000);
insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
update public.monvelo_tenant_settings set limit_growth_bps = 0, max_limit = null, default_cure_days = 0
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001';
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 1000, 30, 1000, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now()),
  ('7eaf0000-0000-4000-8000-000000000001', 'Tiger', 500, 30, 500, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');

-- every agent about 400 m north of the shops at (3.35, 6.60)
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, nm, 'OPAY', 'OP-' || n, '+23480311100' || lpad(n::text, 2, '0'),
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
       '012345' || lpad(n::text, 4, '0'), lpad(n::text, 4, '0'), '058', holder, 'K' || n,
       '20000000-0000-0000-0000-000000000004', 'ACTIVE', 5000000, 200000
  from (values (21, 'POS 21', 'ADE, BISI O.'), (31, 'POS 31', 'EZE, OBI K.'), (32, 'POS 32', 'UDO, IMA'),
               (41, 'Lender Q', 'KANU, NNEKA'), (42, 'Lender R', 'BELLO, SANI')) v (n, nm, holder);
insert into public.monvelo_agent_members (agent_id, profile_id)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from unnest(array[21, 31, 32, 41, 42]) n;
-- P pledges 500000 and X 100000 for Allen today
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), amt, amt, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from (values (21, 500000), (31, 100000)) v (n, amt);

-- S1 and S2 (no preferred agent), both enrolled in Allen, owner 10
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
  $$ select ('d6500000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.pl(n integer) returns uuid language sql as
  $$ select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t(n integer) returns uuid language sql as
  $$ select case n when 1 then '7eaf0000-0000-4000-8000-000000000001'::uuid else '5eac0000-0000-4000-8000-000000000001'::uuid end $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.pl(integer),
  pg_temp.t(integer) to authenticated;
create temp table fin (n text primary key, id uuid, ref text);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on fin, res to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.ref(p_n text) returns text language sql as $$ select ref from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
grant execute on function pg_temp.f(text), pg_temp.ref(text), pg_temp.r(text) to authenticated;
create function pg_temp.exposure(p_agent integer) returns numeric language sql as
  $$ select public.monvelo_agent_open_exposure(pg_temp.ag(p_agent)) $$;
create function pg_temp.remaining(p_agent integer) returns numeric language sql as
  $$ select remaining from public.monvelo_pledges where id = pg_temp.pl(p_agent) $$;
create function pg_temp.status(p_n text) returns text language sql as
  $$ select status from public.monvelo_financings where id = pg_temp.f(p_n) $$;

-- a fixture financing written straight to the table (triggers off): it counts
-- toward exposure and the summary exactly as a real one in that status would;
-- the caller turns triggers off around it (session_replication_role = replica)
create temp sequence synseq;
create function pg_temp.syn(p_n text, p_status text, p_agent integer, p_principal numeric,
                            p_outstanding numeric default null, p_closed boolean default false,
                            p_funded_at timestamptz default now(), p_area integer default 1) returns uuid
language plpgsql as $$
declare
  v_id     uuid := gen_random_uuid();
  v_seq    integer := nextval('synseq');
  v_ref    text := 'MV-SYNTHA' || chr(65 + v_seq / 26) || chr(65 + v_seq % 26);
  v_funded boolean := p_status not in ('OFFERED', 'CLAIMED', 'CANCELLED', 'EXPIRED');
begin
  insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
    principal, supply_date, status, approval_required, claimed_by_agent_id, claimed_by, claim_expires_at, pledge_id,
    funder_agent_id, paystack_reference, funded_at, outstanding, closed_at, cancelled_at)
  values (v_id, pg_temp.t(case when p_area = 4 then 2 else 1 end), v_ref,
          '71000000-0000-0000-0000-000000000099', gen_random_uuid(),
          ('60000000-0000-0000-0000-' || lpad(p_area::text, 12, '0'))::uuid,
          ('40000000-0000-0000-0000-' || lpad((case p_area when 1 then 1 when 2 then 1 when 3 then 2 else 3 end)::text, 12, '0'))::uuid,
          pg_temp.u(1), p_principal, public.monvelo_today(), p_status, false,
          case when p_status = 'CLAIMED' then pg_temp.ag(p_agent) end,
          case when p_status = 'CLAIMED' then pg_temp.u(p_agent) end,
          case when p_status = 'CLAIMED' then now() + interval '1 hour' end,
          case when p_status = 'CLAIMED' then pg_temp.pl(p_agent) end,
          case when v_funded then pg_temp.ag(p_agent) end,
          case when v_funded then v_ref || '-1' end,
          case when v_funded then p_funded_at end,
          p_outstanding,
          case when p_closed then now() end,
          case when p_status = 'CANCELLED' then now() end);
  insert into fin values (p_n, v_id, v_ref || '-1');
  return v_id;
end; $$;

-- the ASA places p_qty of p_sku for shop p_shop and requests its financing
create function pg_temp.raise(p_n text, p_key integer, p_shop integer, p_sku text, p_qty integer) returns uuid
language plpgsql as $$
declare v_o uuid; v_f uuid;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t(1));
  v_o := (public.place_trade_order(pg_temp.k(p_key), ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid,
          jsonb_build_array(jsonb_build_object('sku_code', p_sku, 'qty', p_qty))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into fin values (p_n, v_f, null);
  return v_f;
end; $$;
create function pg_temp.claim(p_key integer, p_agent integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.claim_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent), (select o.net_yield_bps from public.get_monvelo_offer_cover(pg_temp.f(p_fin), pg_temp.ag(p_agent)) o));
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
-- the agent's member starts the funding payment; its reference is kept
create function pg_temp.start(p_key integer, p_agent integer, p_fin text) returns text
language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.start_monvelo_funding(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent)) ->> 'reference';
  perform set_config('role', 'postgres', true);
  update fin set ref = v where n = p_fin;
  return v;
end; $$;
-- Paystack's Verify of a transfer from the agent's own account
create function pg_temp.paid(p_agent integer) returns jsonb language sql as $$
  select jsonb_build_object('status', 'success', 'channel', 'bank_transfer',
    'authorization', jsonb_build_object('channel', 'bank_transfer', 'sender_bank', 'Guaranty Trust Bank',
      'sender_name', case p_agent when 21 then 'BISI ADE' else 'OBI EZE' end,
      'sender_bank_account_number', 'XXXXXX' || lpad(p_agent::text, 4, '0'))) $$;
create function pg_temp.settle(p_fin text, p_agent integer, p_minor bigint) returns jsonb language sql as $$
  select public.settle_monvelo_funding('charge.success', pg_temp.ref(p_fin), 'success', p_minor, 'NGN',
                                       pg_temp.paid(p_agent), 'T-' || p_fin) $$;
-- P funds 12 Purerigin 200 ml (48000) for shop p_shop
create function pg_temp.funded(p_n text, p_key integer, p_shop integer) returns text language plpgsql as $$
begin
  perform pg_temp.raise(p_n, p_key, p_shop, 'PURERIGIN-COCONUT-OIL-200ML', 12);
  perform pg_temp.claim(p_key + 2, 21, p_n);
  perform pg_temp.start(p_key + 3, 21, p_n);
  perform pg_temp.settle(p_n, 21, 4800000);
  return pg_temp.status(p_n);
end; $$;
create function pg_temp.refund(p_id text, p_n text, p_minor bigint) returns jsonb language sql as $$
  select public.apply_monvelo_refund('webhook', p_id, pg_temp.ref(p_n), p_minor, 'NGN', 'REFUND', '{"id": 1}'::jsonb) $$;
create function pg_temp.lapse(p_fin text) returns void language plpgsql as $$
begin
  update public.monvelo_financings set claim_expires_at = now() - interval '1 second' where id = pg_temp.f(p_fin);
  perform public.monvelo_sweep_offers();
end; $$;
-- the lender summary as profile p_user in tenant p_tenant
create function pg_temp.summary(p_user integer, p_tenant uuid, p_weeks integer default 12)
returns setof jsonb language plpgsql as $$
begin
  perform pg_temp.act_as(pg_temp.u(p_user), p_tenant);
  return query select to_jsonb(s) from public.get_lender_reconciliation_summary(p_weeks) s;
  perform set_config('role', 'postgres', true);
end; $$;

-- ── shape and security ──────────────────────────────────────────────────
select ok((select provolatile = 'i' from pg_proc where oid = 'public.monvelo_open_exposure_ceiling()'::regprocedure)
      and (select provolatile = 's' and proconfig @> array['search_path=public, pg_temp']
             from pg_proc where oid = 'public.monvelo_agent_open_exposure(uuid)'::regprocedure),
  'the ceiling is IMMUTABLE; the exposure is STABLE with the pinned search_path');
select ok(not has_function_privilege('authenticated', 'public.monvelo_open_exposure_ceiling()', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_open_exposure_ceiling()', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_open_exposure_ceiling()', 'execute')
      and not has_function_privilege('authenticated', 'public.monvelo_agent_open_exposure(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_agent_open_exposure(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_agent_open_exposure(uuid)', 'execute'),
  'the ceiling and the exposure have no API grant');
select ok((select prosecdef and provolatile = 's' and proconfig @> array['search_path=public, pg_temp']
             from pg_proc where oid = 'public.get_lender_reconciliation_summary(integer)'::regprocedure),
  'the summary is SECURITY DEFINER, STABLE, with the pinned search_path');
select ok(has_function_privilege('authenticated', 'public.get_lender_reconciliation_summary(integer)', 'execute')
      and not has_function_privilege('anon', 'public.get_lender_reconciliation_summary(integer)', 'execute')
      and not has_function_privilege('service_role', 'public.get_lender_reconciliation_summary(integer)', 'execute'),
  'the summary is granted to authenticated only');

-- ── A. the open exposure cap (agent X) ──────────────────────────────────
select is(pg_temp.exposure(31), 0::numeric, 'X has no open exposure');
set local session_replication_role = replica; select pg_temp.syn('XC', 'CLAIMED', 31, 10000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 10000::numeric, 'a CLAIMED financing counts its principal');
set local session_replication_role = replica; select pg_temp.syn('XF', 'FUNDED', 31, 20000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 30000::numeric, 'a FUNDED financing counts its principal');
set local session_replication_role = replica; select pg_temp.syn('XD', 'DELIVERED', 31, 30000, 30000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 60000::numeric, 'a DELIVERED financing counts what is outstanding');
set local session_replication_role = replica; select pg_temp.syn('XL', 'DEFAULTED_WITH_LATE_CHARGE', 31, 20000, 22000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 80000::numeric,
  'a DEFAULTED_WITH_LATE_CHARGE financing counts at most its principal: the late charge consumes no room');
set local session_replication_role = replica; select pg_temp.syn('XR', 'REFUND_DUE', 31, 10000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 80000::numeric, 'R63: a REFUND_DUE financing counts nothing (its fulfilment failed)');
set local session_replication_role = replica; select pg_temp.syn('XO', 'OFFERED', 31, 50000); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('XW', 'REPAID_WITHIN_WINDOW', 31, 50000, 0, true); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('XP', 'REPAID_LATE', 31, 50000, 0, true); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('XK', 'REFUND_DUE', 31, 50000, null, true); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('XX', 'CANCELLED', 31, 50000); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('YF', 'FUNDED', 32, 50000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 80000::numeric,
  'OFFERED, repaid, closed REFUND_DUE, CANCELLED and another agent''s financings do not count');
set local session_replication_role = replica; select pg_temp.syn('XF2', 'FUNDED', 31, 19000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 99000::numeric, 'fixture: X holds 99000 open');

select pg_temp.raise('E1', 100, 2, 'TIGER-1', 2);
select is((select principal from public.monvelo_financings where id = pg_temp.f('E1')), 2000.00::numeric(15,2),
  'fixture: E1 asks for 2000');
-- A6 §20: blocked only by the cap and within ₦300,000, the claim is held, not
-- refused (066 covers holds); nobody decides, so the hold lapses
select is(pg_temp.claim(102, 31, 'E1') ->> 'held', 'true', '99000 open + a 2000 claim passes the cap: held (A6 §20)');
set local session_replication_role = replica;
update public.monvelo_claim_holds set created_at = now() - interval '16 minutes', expires_at = now() - interval '1 minute'
 where financing_id = pg_temp.f('E1');
set local session_replication_role = origin;
select public.monvelo_sweep_offers();
select is(pg_temp.status('E1') || ':' || (select count(*) from public.monvelo_financing_claims where financing_id = pg_temp.f('E1')),
  'OFFERED:0', 'the hold lapses: E1 is OFFERED with no claim');

-- a part repayment on XD frees room
set local session_replication_role = replica;
update public.monvelo_financings set outstanding = 29000 where id = pg_temp.f('XD');
set local session_replication_role = origin;
select is(pg_temp.exposure(31), 98000::numeric, 'a part repayment frees room: 98000');
select is(pg_temp.claim(103, 31, 'E1') ->> 'status', 'CLAIMED', '98000 open + a 2000 claim succeeds');
select is(pg_temp.exposure(31), 100000::numeric, 'and the claim counts: 100000');

-- XD repaid in full frees all of it
set local session_replication_role = replica;
update public.monvelo_financings set status = 'REPAID_WITHIN_WINDOW', outstanding = 0, closed_at = now()
 where id = pg_temp.f('XD');
set local session_replication_role = origin;
select is(pg_temp.exposure(31), 71000::numeric, 'REPAID frees all of it: 71000');

-- the late route over the cap: X claims E2, starts paying, the claim lapses,
-- X's exposure reaches 99000, and the money lands
select pg_temp.raise('E2', 110, 2, 'TIGER-1', 2);
select pg_temp.claim(112, 31, 'E2');
select pg_temp.start(113, 31, 'E2');
select pg_temp.lapse('E2');
select is(pg_temp.status('E2') || ':' || pg_temp.exposure(31), 'OFFERED:71000.00', 'fixture: E2 lapsed to OFFERED');
set local session_replication_role = replica; select pg_temp.syn('XF3', 'FUNDED', 31, 28000); set local session_replication_role = origin;
select is(pg_temp.exposure(31), 99000::numeric, 'fixture: X holds 99000 open again');
select is(pg_temp.settle('E2', 31, 200000) ->> 'outcome', 'late_payment', 'the late route over the cap is a late payment');
select is((select string_agg(kind || ':' || (details ->> 'reason'), ',') from public.monvelo_flags where financing_id = pg_temp.f('E2')),
  'LATE_PAYMENT:this request would take your open exposure above ₦100,000', 'flagged with the cap''s reason');
select is(pg_temp.status('E2') || ':' || pg_temp.remaining(31), 'OFFERED:100000.00', 'E2 stays OFFERED; X''s pledge is untouched');
select is(pg_temp.refund('RF-E2', 'E2', 200000) - 'payment_id',
  '{"outcome": "refunded", "payment_status": "REFUNDED", "financing_status": "OFFERED", "financing_closed": false, "reason": "REFUND"}'::jsonb,
  'staff refund the late payment; nothing closes');
select is(pg_temp.remaining(31), 100000.00::numeric, 'and X''s pledge is still untouched');

-- ── B. the pledge restored on refund confirmation (agent P) ────────────
select is(pg_temp.funded('RD', 200, 1) || pg_temp.funded('RE', 210, 1), 'FUNDED' || 'FUNDED', 'P funds RD and RE');
select is(pg_temp.remaining(21) || ':' || pg_temp.exposure(21), '404000.00:96000.00', 'P''s pledge -> 404000; exposure 96000');

-- the daily cap: P may fund 90000 a day, and RD and RE were funded today
update public.monvelo_agents set per_financing_cap = 50000, daily_cap = 90000 where id = pg_temp.ag(21);
select pg_temp.raise('DC', 220, 2, 'PURERIGIN-COCONUT-OIL-200ML', 12);
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok(format('select public.claim_monvelo_financing(%L, %L, %L, (select o.net_yield_bps from public.get_monvelo_offer_cover(%L, %L) o))', pg_temp.k(222), pg_temp.f('DC'), pg_temp.ag(21), pg_temp.f('DC'), pg_temp.ag(21)),
  'P0001', 'this request would pass your daily cap', 'fixture: RD and RE fill P''s daily cap');
reset role;

update public.monvelo_financings set funded_at = now() - interval '23 hours' where id in (pg_temp.f('RD'), pg_temp.f('RE'));
select public.monvelo_sweep_money();
select is(pg_temp.status('RD') || pg_temp.status('RE') || ':' || pg_temp.remaining(21),
  'REFUND_DUE' || 'REFUND_DUE' || ':404000.00', 'the sweep makes both REFUND_DUE and restores no pledge');
select is(pg_temp.exposure(21), 0::numeric, 'R63: REFUND_DUE frees the exposure at the sweep');
-- RD back to "funded today", RE two days ago
set local session_replication_role = replica;
update public.monvelo_financings set funded_at = now() where id = pg_temp.f('RD');
update public.monvelo_financings set funded_at = now() - interval '2 days' where id = pg_temp.f('RE');
set local session_replication_role = origin;
select is(pg_temp.claim(223, 21, 'DC') ->> 'status', 'CLAIMED',
  'R63: the daily cap frees at the sweep too (RD, funded today, no longer counts)');
select pg_temp.lapse('DC');

insert into res values ('RF-1', pg_temp.refund('RF-1', 'RD', 4800000));
select is(pg_temp.r('RF-1') - 'payment_id',
  '{"outcome": "refunded", "payment_status": "REFUNDED", "financing_status": "REFUND_DUE", "financing_closed": true, "reason": "REFUND"}'::jsonb,
  'the refund of RD''s funding closes it');
select is(pg_temp.remaining(21), 452000.00::numeric, 'P''s pledge rises by RD''s principal');
select is(pg_temp.exposure(21), 0::numeric, 'the refund changes no exposure (already freed at the sweep)');
select is((select count(*)::int from public.audit_logs where operation = 'apply_monvelo_refund' and entity_type = 'monvelo_pledges'
              and entity_id = pg_temp.pl(21)::text), 1, 'one pledge audit row');
select is((select row(a.tenant_id is null, a.after ->> 'agent_id', a.after ->> 'pledge_id', a.after ->> 'amount',
                      a.after ->> 'financing_id', a.before ->> 'remaining', a.after ->> 'remaining')::text
             from public.audit_logs a where a.operation = 'apply_monvelo_refund' and a.entity_type = 'monvelo_pledges'
              and a.entity_id = pg_temp.pl(21)::text),
  row(true, pg_temp.ag(21)::text, pg_temp.pl(21)::text, '48000.00', pg_temp.f('RD')::text, '404000.00', '452000.00')::text,
  'it is tenant-null and names the agent, the pledge and the amount (R15)');
select is(pg_temp.refund('RF-1', 'RD', 4800000), pg_temp.r('RF-1'), 'the same refund id again replays the first reply');
select is(pg_temp.refund('RF-2', 'RD', 4800000) ->> 'reason', 'payment_not_success', 'another refund id is a conflict');
select is(pg_temp.remaining(21) || ':' || (select count(*) from public.audit_logs where operation = 'apply_monvelo_refund'
                                              and entity_type = 'monvelo_pledges' and entity_id = pg_temp.pl(21)::text),
  '452000.00:1', 'a redelivered refund restores once');

-- RE: its pledge's supply day has passed
set local session_replication_role = replica;
update public.monvelo_pledges set supply_date = public.monvelo_today() - 1 where id = pg_temp.pl(21);
set local session_replication_role = origin;
select is(pg_temp.refund('RF-3', 'RE', 4800000) ->> 'financing_closed', 'true', 'the refund of RE''s funding closes it');
select is(pg_temp.remaining(21) || ':' || pg_temp.exposure(21), '500000.00:0.00',
  'P''s pledge is restored although its supply day has passed; no exposure is left');
set local session_replication_role = replica;
update public.monvelo_pledges set supply_date = public.monvelo_today() where id = pg_temp.pl(21);
set local session_replication_role = origin;

-- EF: a live financing's funding refunded restores nothing
select is(pg_temp.funded('EF', 230, 1), 'FUNDED', 'P funds EF');
select is(pg_temp.refund('RF-4', 'EF', 4800000) ->> 'financing_closed', 'false', 'EF''s funding is refunded while FUNDED');
select is(pg_temp.remaining(21) || ':' || (select count(*) from public.audit_logs where operation = 'apply_monvelo_refund'
                                              and entity_type = 'monvelo_pledges' and entity_id = pg_temp.pl(21)::text),
  '452000.00:2', 'a live financing''s refund restores nothing (FUNDING_REFUNDED is for staff)');

-- R62: the sweep finds EF's funding already refunded and closes it at once;
-- the refund was confirmed, so the pledge has the principal back, once
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('EF');
select public.monvelo_sweep_money();
select is(pg_temp.status('EF') || ':' || (select closed_at is not null from public.monvelo_financings where id = pg_temp.f('EF'))
          || ':' || pg_temp.remaining(21) || ':' || pg_temp.exposure(21),
  'REFUND_DUE:true:500000.00:0.00', 'the sweep closes EF and restores P''s pledge (R62)');
select is((select row(count(*), bool_and(a.tenant_id is null and a.source = 'CRON'),
                      max(a.after ->> 'agent_id'), max(a.after ->> 'amount'), max(a.after ->> 'financing_id'))::text
             from public.audit_logs a where a.operation = 'monvelo_sweep_money' and a.entity_type = 'monvelo_pledges'
              and a.entity_id = pg_temp.pl(21)::text),
  row(1, true, pg_temp.ag(21)::text, '48000.00', pg_temp.f('EF')::text)::text,
  'one tenant-null CRON audit row names the agent, the amount and the financing');
select public.monvelo_sweep_money();
select is(pg_temp.remaining(21) || ':' || (select count(*) from public.audit_logs where operation = 'monvelo_sweep_money'
                                              and entity_type = 'monvelo_pledges' and entity_id = pg_temp.pl(21)::text),
  '500000.00:1', 'a second sweep restores nothing');

-- ── C. the lender reconciliation summary ───────────────────────────────
-- Q: this week Q1 (Allen, DELIVERED 10000, 6000 outstanding, 4000 repaid), Q2
-- (Opebi, refunded 20000), Q3 (Kuto, zone 2: FUNDED 30000), Q4 (T2: DEFAULTED
-- 40000, 44000 outstanding), Q8 (Allen, 8000, Monday 00:00 Lagos); last week
-- Q5 (5000) and Q7 (7000, Sunday 23:59 Lagos); twelve weeks back Q6 (6000).
-- R: R1 (Allen, 7000) and R2 (T2, 9000) this week.
create temp table wk as
  select (date_trunc('week', now() at time zone 'Africa/Lagos'))::date as mon,
         (date_trunc('week', now() at time zone 'Africa/Lagos')) at time zone 'Africa/Lagos' as mon_at;
set local session_replication_role = replica; select pg_temp.syn('Q1', 'DELIVERED', 41, 10000, 6000, false, now(), 1); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q2', 'REFUND_DUE', 41, 20000, null, true, now(), 2); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q3', 'FUNDED', 41, 30000, null, false, now(), 3); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q4', 'DEFAULTED_WITH_LATE_CHARGE', 41, 40000, 44000, false, now(), 4); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q5', 'FUNDED', 41, 5000, null, false, now() - interval '7 days', 1); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q6', 'FUNDED', 41, 6000, null, false, (select mon_at from wk) - interval '12 weeks' + interval '1 hour', 1); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q7', 'FUNDED', 41, 7000, null, false, (select mon_at from wk) - interval '1 minute', 1); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('Q8', 'FUNDED', 41, 8000, null, false, (select mon_at from wk), 1); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('R1', 'FUNDED', 42, 7000, null, false, now(), 1); set local session_replication_role = origin;
set local session_replication_role = replica; select pg_temp.syn('R2', 'FUNDED', 42, 9000, null, false, now(), 4); set local session_replication_role = origin;
set local session_replication_role = replica;
insert into public.monvelo_repayments (tenant_id, financing_id, amount, recorded_by, status, challenge_id, confirmed_at, ended_at) values
  (pg_temp.t(1), pg_temp.f('Q1'), 4000, pg_temp.u(41), 'CONFIRMED', gen_random_uuid(), now(), now()),
  (pg_temp.t(1), pg_temp.f('Q1'), 1000, pg_temp.u(41), 'PENDING', gen_random_uuid(), null, null),
  (pg_temp.t(1), pg_temp.f('Q1'), 500, pg_temp.u(41), 'REJECTED', gen_random_uuid(), null, now());
insert into public.monvelo_rebate_payables (tenant_id, financing_id, agent_id, amount, due_at, status) values
  (pg_temp.t(1), pg_temp.f('Q1'), pg_temp.ag(41), 1000, now(), 'DUE'),
  (pg_temp.t(1), pg_temp.f('Q2'), pg_temp.ag(41), 2000, now(), 'CANCELLED'),
  (pg_temp.t(1), pg_temp.f('Q3'), pg_temp.ag(41), 3000, now(), 'DUE'),
  (pg_temp.t(2), pg_temp.f('Q4'), pg_temp.ag(41), 4000, now(), 'DUE');
set local session_replication_role = origin;
create function pg_temp.refs(variadic p_n text[]) returns jsonb language sql as
  $$ select jsonb_agg(ref order by ref) from fin where n = any (p_n) $$;

-- the agent's own member: its own rows only, across both tenants
create temp table q as select s as j from pg_temp.summary(41, null) s;
create temp table q13 as select s as j from pg_temp.summary(41, null, 13) s;
reset role;
select is((select count(*)::int from q), 2, 'Q''s member gets two weeks of rows');
select is((select count(*)::int from q where j ->> 'agent_id' <> pg_temp.ag(41)::text), 0, 'all of them Q''s own');
select is((select j - 'mv_references' from q where (j ->> 'week_start')::date = (select mon from wk)),
  jsonb_build_object('agent_id', pg_temp.ag(41), 'agent_name', 'Lender Q', 'week_start', (select mon from wk),
                     'capital_funded', 108000.00, 'outstanding', 50000.00, 'repaid', 4000.00, 'refunded', 20000.00,
                     'rebates_owed', 8000.00, 'rebates_paid', 0.00,
                     'closed_by_claim_amount', 0.00, 'late_charge_waived', 0.00),
  'this week''s totals: funded, outstanding, confirmed repayments, refunded, rebates owed and paid');
select is((select j -> 'mv_references' from q where (j ->> 'week_start')::date = (select mon from wk)),
  pg_temp.refs('Q1', 'Q2', 'Q3', 'Q4', 'Q8'), 'this week''s funding references, sorted, including the second tenant''s');
select is((select (j ->> 'capital_funded')::numeric || ':' || (j -> 'mv_references')::text from q
            where (j ->> 'week_start')::date = (select mon from wk) - 7),
  '12000.00:' || pg_temp.refs('Q5', 'Q7')::text, 'last week: Q5 and Q7');
select ok((select bool_or(j -> 'mv_references' ? pg_temp.ref('Q8') and (j ->> 'week_start')::date = (select mon from wk))
               and bool_or(j -> 'mv_references' ? pg_temp.ref('Q7') and (j ->> 'week_start')::date = (select mon from wk) - 7)
             from q),
  'the week boundary: Monday 00:00 Lagos is this week, Sunday 23:59 the week before');
select is((select count(*)::int || ':' || bool_or(j -> 'mv_references' ? pg_temp.ref('Q6'))::text from q13), '3:true',
  'p_weeks 13 reaches back to Q6; 12 does not');
select pg_temp.act_as(pg_temp.u(41), null);
select throws_ok($$select * from public.get_lender_reconciliation_summary(0)$$, '22023', null, 'p_weeks 0 is refused');
select throws_ok($$select * from public.get_lender_reconciliation_summary(53)$$, '22023', null, 'p_weeks 53 is refused');
reset role;

-- the ZSA: their zone in their active tenant
create temp table z as select s as j from pg_temp.summary(11, pg_temp.t(1)) s;
reset role;
select is((select (j ->> 'capital_funded')::numeric || ':' || (j -> 'mv_references')::text from z
            where j ->> 'agent_id' = pg_temp.ag(41)::text and (j ->> 'week_start')::date = (select mon from wk)),
  '38000.00:' || pg_temp.refs('Q1', 'Q2', 'Q8')::text, 'the ZSA sees Q''s zone-1 fundings in T1 only');
select ok((select bool_or(j -> 'mv_references' ? pg_temp.ref('R1')) from z)
      and not (select bool_or(j -> 'mv_references' ?| array[pg_temp.ref('Q3'), pg_temp.ref('Q4'), pg_temp.ref('R2')]) from z),
  'every lender in the zone, nothing from zone 2 or the other tenant');

-- the ASA: their area
create temp table a as select s as j from pg_temp.summary(4, pg_temp.t(1)) s;
reset role;
select is((select (j ->> 'capital_funded')::numeric || ':' || (j -> 'mv_references')::text from a
            where j ->> 'agent_id' = pg_temp.ag(41)::text and (j ->> 'week_start')::date = (select mon from wk)),
  '18000.00:' || pg_temp.refs('Q1', 'Q8')::text, 'the ASA sees Allen only');
select ok((select bool_or(j -> 'mv_references' ? pg_temp.ref('R1')) from a)
      and not (select bool_or(j -> 'mv_references' ?| array[pg_temp.ref('Q2'), pg_temp.ref('Q3'), pg_temp.ref('Q4')]) from a),
  'not Opebi, Kuto or the other tenant');

-- an agent member who is also a ZSA sees their agent's rows (live)
insert into public.monvelo_agent_members (agent_id, profile_id) values (pg_temp.ag(42), pg_temp.u(11));
create temp table zr as select s as j from pg_temp.summary(11, pg_temp.t(1)) s;
reset role;
select is((select jsonb_agg(distinct j ->> 'agent_id') from zr) || (select jsonb_agg(r order by r) from zr, jsonb_array_elements_text(j -> 'mv_references') r),
  jsonb_build_array(pg_temp.ag(42)) || pg_temp.refs('R1', 'R2'), 'an agent member who is also a ZSA sees their agent''s rows, both tenants');
update public.monvelo_agent_members set status = 'REVOKED' where agent_id = pg_temp.ag(42) and profile_id = pg_temp.u(11);
create temp table zr2 as select s as j from pg_temp.summary(11, pg_temp.t(1)) s;
reset role;
select ok((select bool_or(j ->> 'agent_id' = pg_temp.ag(41)::text) from zr2), 'revoked, they are back to their zone');

-- everyone else
select pg_temp.act_as(pg_temp.u(3), pg_temp.t(1));
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'a TM is refused');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t(1));
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'a ZSM is refused');
select pg_temp.act_as(pg_temp.u(18), pg_temp.t(1));
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'a CSM is refused');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t(1));
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'a TENANT_ADMIN is refused');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t(1));
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'an LM is refused');
select pg_temp.act_as(pg_temp.u(10), null);
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'a shop owner is refused');
reset role;
set local role anon;
select throws_ok($$select * from public.get_lender_reconciliation_summary()$$, '42501', null, 'anon is refused');
reset role;

-- what it never says
select ok((select bool_and(j::text !~* '71000000-|shop|street|\+234|20000000-0000-0000-0000-000000000010|purerigin|tiger|7eaf0000|5eac0000|allen|opebi|kuto|wuse|ikeja|lagos')
             from (select j from q union all select j from z union all select j from a) x),
  'no shop, owner, phone, brand, tenant id or place name in the output');

select * from finish();
rollback;
