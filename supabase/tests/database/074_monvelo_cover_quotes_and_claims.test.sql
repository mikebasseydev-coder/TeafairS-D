-- Addendum A8 Task 3 (§6.1, §6.2, §6.4): the agent's yield quote
-- (monvelo_quote_agent_yield, internal), the agent's read model
-- (get_monvelo_offer_cover), the claim acknowledging the quoted yield and
-- locking the cover and the brand terms, a hold's allow re-quoting, funding
-- paying exactly the locked net rebate (claim and late routes), and the
-- request refusing a brand whose rebate is below the storage premium.
begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

-- A8 fix pass: this file's MOCK insurer counts as an underwriter (mock insurers allowed here)
update public.monvelo_platform_settings set allow_mock_insurers = true;

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

-- A6 §19: one agent funds several 48000 financings here, more than the 100000
-- open exposure ceiling; this file is not about the cap (065 is), so the
-- ceiling is raised for this transaction only
create or replace function public.monvelo_open_exposure_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 100000000.00::numeric(15,2) $$;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 10 owner of S1 and S2
-- 06 MONVELO_FINANCE · 09 MONVELO_OPERATOR
-- agent members: 21 P (S1's preferred agent, "ADE, BISI O.", ...0011) · 22 N ("CHIOMA NNE OKAFOR", ...0022)
--                28 a stranger
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 5, 6, 7, 9, 10, 21, 22, 28]) n;
update public.profiles set platform_role = 'MONVELO_FINANCE'  where id = '20000000-0000-0000-0000-000000000006';
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000009';

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
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
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

-- P about 400 m and N about 600 m north of the shops at (3.35, 6.60)
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
  $$ select ('d7400000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.pl(n integer) returns uuid language sql as
  $$ select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.pl(integer), pg_temp.t1()
  to authenticated;
create temp table ord (n text primary key, id uuid);
create temp table fin (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on ord, fin, res to authenticated;
create function pg_temp.o(p_n text) returns uuid language sql as $$ select id from ord where n = p_n $$;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
grant execute on function pg_temp.o(text), pg_temp.f(text), pg_temp.r(text) to authenticated;
-- the ASA places 12 Purerigin 200 ml (4000 each: 48000) for shop p_shop and requests its financing
create function pg_temp.raise(p_n text, p_key integer, p_shop integer default 1) returns uuid
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
-- the agent claims, acknowledging p_yield (default: the yield its read model shows now)
create function pg_temp.claim(p_key integer, p_agent integer, p_fin text, p_yield integer default null) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.claim_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent),
         coalesce(p_yield, (select o.net_yield_bps from public.get_monvelo_offer_cover(pg_temp.f(p_fin), pg_temp.ag(p_agent)) o)));
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
-- a member of agent p_agent starts the funding payment; kept as p_n
create function pg_temp.start(p_n text, p_key integer, p_agent integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.start_monvelo_funding(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
-- what Paystack's Verify returns for a transfer
create function pg_temp.v(p_name text, p_acct text, p_channel text default 'bank_transfer') returns jsonb
language sql as $$
  select jsonb_build_object('status', 'success', 'channel', p_channel,
    'authorization', jsonb_build_object('channel', p_channel, 'sender_bank', 'Guaranty Trust Bank',
                                        'sender_name', p_name, 'sender_bank_account_number', p_acct))
$$;
-- settle as the gateway would (service_role); the result is kept as p_n
create function pg_temp.settle(p_n text, p_event text, p_payment text, p_status text, p_minor bigint, p_verified jsonb)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  v := public.settle_monvelo_funding(p_event, coalesce(pg_temp.r(p_payment) ->> 'reference', p_payment), p_status,
                                     p_minor, 'NGN', p_verified, 'T-' || p_n);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.pid(p_n text) returns uuid language sql as $$ select (pg_temp.r(p_n) ->> 'payment_id')::uuid $$;
-- the payer check against P with one field changed
create function pg_temp.pm(p_holder text, p_sender text, p_acct text default 'XXXXXX0011', p_channel text default 'bank_transfer')
returns boolean language plpgsql as $$
declare a public.monvelo_agents;
begin
  select * into a from public.monvelo_agents where id = pg_temp.ag(21);
  a.settlement_account_name := p_holder;
  return public.monvelo_payer_matches(a, pg_temp.v(p_sender, p_acct, p_channel));
end; $$;
create function pg_temp.lapse(p_fin text) returns void language plpgsql as $$
begin
  update public.monvelo_financings set claim_expires_at = now() - interval '1 second' where id = pg_temp.f(p_fin);
  perform public.monvelo_sweep_offers();
end; $$;

-- ── A8 fixtures ─────────────────────────────────────────────────────────
-- 05: a second ASA of Allen (a market maker for holds the raiser 04 cannot decide)
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005', 'ASA', null,
   '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
-- an approved STORAGE product at 100 bps a 30-day block; S2 holds a verified policy (₦1,000,000); S1 none
set local session_replication_role = replica;
insert into public.monvelo_insurers (id, code, legal_name, naicom_licence_no, api_provider, created_by) values
  ('a8000000-0000-0000-0000-000000000001', 'MOCK', 'Mock Insurance', 'NAICOM-074', 'MOCK', pg_temp.u(9));
insert into public.monvelo_insurance_products (id, insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from, status,
  proposed_by, approved_by, approved_at) values
  ('a8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'STORAGE', 100, 1000,
   public.monvelo_today() - 1, 'APPROVED', pg_temp.u(9), pg_temp.u(6), now());
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at) values
  ('a8000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000002', 'Leadway', 'SME-074', true, true,
   1000000, true, current_date - 10, current_date + 300, '71000000-0000-0000-0000-000000000002/c.pdf', pg_temp.u(4),
   'c0000000-0000-0000-0000-000000000002', 'VERIFIED', pg_temp.u(9), now());
-- brands for the pure quote tests: B 5 %/30 d, C 10 %/31 d, D 10 %/60 d, E 0.5 %/30 d
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at)
select pg_temp.t1(), b, r, d, 1000, public.monvelo_today() - 1, 'APPROVED', pg_temp.u(1), pg_temp.u(3), now()
  from (values ('Brand B', 500, 30), ('Brand C', 1000, 31), ('Brand D', 1000, 60), ('Brand E', 50, 30)) v (b, r, d);
set local session_replication_role = origin;

create function pg_temp.set_product(p_status text) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.monvelo_insurance_products
     set status = p_status, withdrawn_at = case when p_status = 'WITHDRAWN' then now() end
   where id = 'a8000000-0000-0000-0000-000000000002';
  set local session_replication_role = origin;
end; $$;
create function pg_temp.set_policy(p_status text) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.monvelo_shop_policies
     set status = p_status, withdrawn_at = case when p_status = 'WITHDRAWN' then now() end
   where id = 'a8000000-0000-0000-0000-000000000003';
  set local session_replication_role = origin;
end; $$;
create function pg_temp.set_rebate(p_bps integer) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.monvelo_brand_terms set rebate_bps = p_bps where tenant_id = pg_temp.t1() and brand = 'Purerigin';
  set local session_replication_role = origin;
end; $$;

-- an OFFERED financing straight in, with brand lines, for the quote alone
create temp sequence qseq;
create function pg_temp.qfin(p_n text, p_shop integer, p_lines jsonb) returns uuid language plpgsql as $$
declare v_o uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_total numeric;
        v_seq integer := nextval('qseq');
begin
  select sum((l ->> 'amount')::numeric) into v_total from jsonb_array_elements(p_lines) l;
  set local session_replication_role = replica;
  insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, retail_shop_id)
  values (v_o, pg_temp.t1(), 'FIELD_SALES', '50000000-0000-0000-0000-000000000004', v_total,
          ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid);
  insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
    principal, supply_date, status, approval_required)
  values (v_f, pg_temp.t1(), 'MV-QUOTEX' || chr(65 + v_seq / 26) || chr(65 + v_seq % 26),
          ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid, v_o,
          '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', pg_temp.u(4),
          v_total, public.monvelo_today(), 'OFFERED', false);
  insert into public.monvelo_financing_lines (tenant_id, financing_id, brand, brand_key, amount)
  select pg_temp.t1(), v_f, l ->> 'brand', lower(l ->> 'brand'), (l ->> 'amount')::numeric
    from jsonb_array_elements(p_lines) l;
  set local session_replication_role = origin;
  insert into fin values (p_n, v_f);
  return v_f;
end; $$;
create function pg_temp.q(p_n text) returns jsonb language sql as
  $$ select public.monvelo_quote_agent_yield(pg_temp.f(p_n)) $$;

select pg_temp.qfin('Q1', 1, '[{"brand": "Purerigin", "amount": 48000}]');
select pg_temp.qfin('Q2', 2, '[{"brand": "Purerigin", "amount": 48000}]');
select pg_temp.qfin('Q3', 1, '[{"brand": "Brand C", "amount": 48000}]');
select pg_temp.qfin('Q4', 1, '[{"brand": "Brand D", "amount": 48000}]');
select pg_temp.qfin('Q5', 1, '[{"brand": "Purerigin", "amount": 24000}, {"brand": "Brand C", "amount": 24000}]');
select pg_temp.qfin('Q6', 1, '[{"brand": "Purerigin", "amount": 33333.33}, {"brand": "Brand B", "amount": 66666.67}]');
select pg_temp.qfin('Q7', 1, '[{"brand": "Brand E", "amount": 48000}]');

-- ── 1. the quote (10) ───────────────────────────────────────────────────
select ok(pg_temp.q('Q1') @> '{"cover_kind": "AUTO_POLICY", "blocks": 1, "storage_rate_bps": 100, "gross_rebate": 4800,
                              "storage_premium": 480, "net_rebate": 4320, "net_yield_bps": 900, "net_yield_percent": 9.00}',
          'uninsured: 10 % rebate less a 1 % premium is 9.00 %');
select ok(pg_temp.q('Q2') @> '{"cover_kind": "SHOP_POLICY", "storage_premium": 0, "net_rebate": 4800, "net_yield_bps": 1000}'
          and pg_temp.q('Q2') ->> 'shop_policy_id' = 'a8000000-0000-0000-0000-000000000003',
          'a verified shop is exempt: the full 10.00 %');
select ok(pg_temp.q('Q3') @> '{"blocks": 2, "storage_premium": 960}', 'a 31-day period is two 30-day blocks');
select ok(pg_temp.q('Q4') @> '{"blocks": 2, "storage_premium": 960}', 'a 60-day period is two blocks');
select ok(pg_temp.q('Q5') @> '{"blocks": 1, "storage_premium": 480}', 'the shortest period across the brands decides');
select ok(pg_temp.q('Q6') @> '{"gross_rebate": 6666.66, "storage_premium": 1000.00, "net_rebate": 5666.66, "net_yield_bps": 566}',
          'two brands, rounded per line');
select is((select sum((l ->> 'net_rebate')::numeric) from jsonb_array_elements(pg_temp.q('Q6') -> 'lines') l),
          (pg_temp.q('Q6') ->> 'net_rebate')::numeric, 'the brand lines add up to the cent');
select ok((pg_temp.q('Q6') ->> 'net_yield_bps')::numeric
          <= (pg_temp.q('Q6') ->> 'net_rebate')::numeric * 10000 / 100000, 'the shown yield never exceeds the paid one');
select pg_temp.set_product('WITHDRAWN');
select ok(pg_temp.q('Q1') @> '{"cover_kind": "NONE", "storage_premium": 0, "net_rebate": 4800, "net_yield_bps": 1000}',
          'no approved product: no cover, the full rebate');
select pg_temp.set_product('APPROVED');
select throws_ok($$ select pg_temp.q('Q7') $$, 'P0001',
                 'rebate below storage premium for brand Brand E; verify the shop''s cover',
                 'a brand whose rebate is below the premium is refused');

-- ── 2. the agent's read model (3) ───────────────────────────────────────
select pg_temp.raise('F1', 100, 1);
select pg_temp.act_as(pg_temp.u(21), null);
select results_eq($$ select cover_label, gross_rebate, storage_premium, net_rebate, net_yield_bps, net_yield_percent
                      from public.get_monvelo_offer_cover(pg_temp.f('F1'), pg_temp.ag(21)) $$,
                  $$ values ('AUTO_POLICY'::text, 4800.00::numeric(15,2), 480.00::numeric(15,2), 4320.00::numeric(15,2),
                             900, 9.00::numeric(5,2)) $$,
                  'the agent sees the cover label and its net yield, nothing of the policy');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok($$ select * from public.get_monvelo_offer_cover(pg_temp.f('F1'), pg_temp.ag(21)) $$, '42501', null,
                 'a TENANT_ADMIN cannot read an agent''s quote');
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$ select * from public.get_monvelo_offer_cover(pg_temp.f('F1'), pg_temp.ag(21)) $$, '42501', null,
                 'a member of another agent cannot read it in that agent''s name');
reset role;

-- ── 3. the claim acknowledges the yield and locks the cover (4) ──────────
select throws_ok($$ select pg_temp.claim(110, 21, 'F1', 1000) $$, 'P0001', 'cover changed; review the new yield',
                 'a claim at a yield other than the quote is refused');
select ok((select status from public.monvelo_financings where id = pg_temp.f('F1')) = 'OFFERED'
          and not exists (select 1 from public.monvelo_financing_cover where financing_id = pg_temp.f('F1')),
          'nothing is written');
select pg_temp.claim(111, 21, 'F1');
select ok((select cover_kind = 'AUTO_POLICY' and storage_premium = 480 and net_rebate = 4320 and declared_status = 'NOT_DUE'
             from public.monvelo_financing_cover where financing_id = pg_temp.f('F1')),
          'the claim locks the AUTO_POLICY cover');
select ok((select rebate_bps = 1000 and interest_free_days = 30 and terms_id is not null and net_rebate = 4320
             from public.monvelo_financing_line_cover where financing_id = pg_temp.f('F1')),
          'and the brand terms per line');

-- ── 4. a quote that changes inside the window; funding pays the lock (3) ─
select pg_temp.raise('F2', 120, 2);
select pg_temp.set_policy('WITHDRAWN');
select throws_ok($$ select pg_temp.claim(125, 22, 'F2', 1000) $$, 'P0001', 'cover changed; review the new yield',
                 'the shop''s policy withdrawn after the agent read 10.00 %: the claim is refused');
select pg_temp.set_policy('VERIFIED');
select pg_temp.claim(126, 22, 'F2', 1000);
select pg_temp.set_rebate(500);
select pg_temp.start('P2', 127, 22, 'F2');
select pg_temp.settle('S2', 'charge.success', 'P2', 'success', 4800000, pg_temp.v('CHIOMA NNE OKAFOR', 'XXXXXX0022'));
select pg_temp.set_rebate(1000);
select is((select amount from public.monvelo_rebate_payables where financing_id = pg_temp.f('F2')), 4800.00::numeric(15,2),
          'a brand term changed after the claim: funding still pays the locked 10 %');
select ok((select l.rebate_bps = 1000 and l.terms_locked_at = c.locked_at
             from public.monvelo_financing_lines l join public.monvelo_financing_cover c using (financing_id)
            where l.financing_id = pg_temp.f('F2')), 'the lines carry the terms locked at claim');

-- ── 5. the late route quotes at funding (1) ──────────────────────────────
select pg_temp.start('P1', 112, 21, 'F1');
select pg_temp.lapse('F1');
select pg_temp.set_product('WITHDRAWN');
select pg_temp.settle('S1', 'charge.success', 'P1', 'success', 4800000, pg_temp.v('ADE, BISI O.', 'XXXXXX0011'));
select pg_temp.set_product('APPROVED');
select ok((select p.amount = 4800 and c.cover_kind = 'NONE'
             from public.monvelo_rebate_payables p join public.monvelo_financing_cover c using (financing_id)
            where p.financing_id = pg_temp.f('F1')),
          'a lapsed claim funded late is quoted again at funding');

-- ── 6. the request and the old signature (3) ────────────────────────────
select hasnt_function('public', 'claim_monvelo_financing', array['uuid', 'uuid', 'uuid'],
                      'the claim without an acknowledged yield is gone');
select pg_temp.set_rebate(50);
select throws_ok($$ select pg_temp.raise('F5', 150, 1) $$, 'P0001',
                 'rebate below storage premium for brand Purerigin; verify the shop''s cover',
                 'the request names the brand whose rebate is below the premium');
select lives_ok($$ select pg_temp.raise('F6', 160, 2) $$, 'the same order for a verified shop is requested');
select pg_temp.set_rebate(1000);

-- ── 7. a hold's allow re-quotes (3) ──────────────────────────────────────
create or replace function public.monvelo_open_exposure_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 1000.00::numeric(15,2) $$;
select pg_temp.raise('F7', 170, 2);
insert into res select 'H7', pg_temp.claim(175, 22, 'F7');
select ok((select (r ->> 'held')::boolean from res where n = 'H7')
          and (select quoted_net_yield_bps = 1000 from public.monvelo_claim_holds where id = (pg_temp.r('H7') ->> 'hold_id')::uuid),
          'a held claim keeps the yield the agent acknowledged');
select pg_temp.set_policy('WITHDRAWN');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select throws_ok($$ select public.decide_monvelo_claim_hold(pg_temp.k(176), (pg_temp.r('H7') ->> 'hold_id')::uuid, true,
                      'known shop, good record') $$, 'P0001', 'cover changed; the agent must claim again',
                 'an allow whose quote moved is refused');
reset role;
select pg_temp.set_policy('VERIFIED');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select is(public.decide_monvelo_claim_hold(pg_temp.k(177), (pg_temp.r('H7') ->> 'hold_id')::uuid, true,
            'known shop, good record') ->> 'status', 'ALLOWED', 'an allow at the same quote locks the cover');
reset role;

select * from finish();
rollback;
