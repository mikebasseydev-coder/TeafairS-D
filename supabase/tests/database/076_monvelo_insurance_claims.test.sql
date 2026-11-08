-- Addendum A8 Task 5 (§5.5, §5.6, §6.3, §6.4): loss claims. report_monvelo_loss
-- (who, when, how much), file_monvelo_insurance_claim (waits for an accepted
-- declaration; CLAIM_FILE), settlement through the insurer's webhook
-- (settle_monvelo_insurance_claim) or by hand (record_monvelo_claim_settlement):
-- a STORAGE settlement closes the financing CLOSED_BY_CLAIM, waives the late
-- charge and frees the agent's exposure; a shortfall is flagged; an open
-- STORAGE claim pauses the late charge; a full repayment withdraws it; a
-- settlement after that is ignored and flagged. Tenants read GIT claims only.
--
-- Amounts are on this fixture's 48000 trade order (Task 4 ruling): 12000
-- repaid, a 10 % late charge of 3600, so the claim is for 36000.
begin;
create extension if not exists pgtap with schema extensions;

select plan(28);

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

create or replace function public.monvelo_open_exposure_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 100000000.00::numeric(15,2) $$;

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 08 LM (under 18 CSM)
-- 10 owner of S1 and S2 · 06 MONVELO_FINANCE · 09 MONVELO_OPERATOR
-- agent members: 21 P (S1's preferred agent, "ADE, BISI O.", ...0011) · 22 N ("CHIOMA NNE OKAFOR", ...0022)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 6, 7, 8, 9, 10, 11, 18, 21, 22]) n;
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
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen'),
  ('60000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Ojota');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000018', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000018', 'CLIENT_SERVICE_MANAGER', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000011', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000, git_cover_enabled = false;
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
insert into public.monvelo_agent_members (agent_id, profile_id)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), 500000, 500000, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;

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

-- the insurer, a STORAGE product (100 bps a block) and a GIT product (75 bps a
-- shipment); S2 holds a verified policy, S1 none
set local session_replication_role = replica;
insert into public.monvelo_insurers (id, code, legal_name, naicom_licence_no, api_provider, created_by) values
  ('a8000000-0000-0000-0000-000000000001', 'MOCK', 'Mock Insurance', 'NAICOM-076', 'MOCK', '20000000-0000-0000-0000-000000000009');
insert into public.monvelo_insurance_products (id, insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from, status,
  proposed_by, approved_by, approved_at) values
  ('a8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'STORAGE', 100, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now()),
  ('a8000000-0000-0000-0000-000000000004', 'a8000000-0000-0000-0000-000000000001', 'GIT', 75, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now());
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at) values
  ('a8000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000002', 'Leadway', 'SME-076', true, true,
   1000000, true, current_date - 10, current_date + 300, '71000000-0000-0000-0000-000000000002/c.pdf',
   '20000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000002', 'VERIFIED',
   '20000000-0000-0000-0000-000000000009', now());
set local session_replication_role = origin;

-- ── helpers ─────────────────────────────────────────────────────────────
create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d7600000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.t1() to authenticated;
create temp table fin (n text primary key, id uuid, o uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on fin, res to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.o(p_n text) returns uuid language sql as $$ select o from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
grant execute on function pg_temp.f(text), pg_temp.o(text), pg_temp.r(text) to authenticated;

-- raise, claim, fund: a FUNDED 48000 financing for shop p_shop, funded by agent p_agent
create function pg_temp.funded(p_n text, p_key integer, p_shop integer, p_agent integer) returns uuid
language plpgsql as $$
declare v_o uuid; v_f uuid; v_p jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid,
          jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 12))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  perform public.claim_monvelo_financing(pg_temp.k(p_key + 2), v_f, pg_temp.ag(p_agent),
            (select c.net_yield_bps from public.get_monvelo_offer_cover(v_f, pg_temp.ag(p_agent)) c));
  v_p := public.start_monvelo_funding(pg_temp.k(p_key + 3), v_f, pg_temp.ag(p_agent));
  perform set_config('role', 'postgres', true);
  perform public.settle_monvelo_funding('charge.success', v_p ->> 'reference', 'success', 4800000, 'NGN',
    jsonb_build_object('status', 'success', 'channel', 'bank_transfer',
      'authorization', jsonb_build_object('channel', 'bank_transfer', 'sender_bank', 'Guaranty Trust Bank',
        'sender_name', case p_agent when 21 then 'ADE, BISI O.' else 'CHIOMA NNE OKAFOR' end,
        'sender_bank_account_number', case p_agent when 21 then 'XXXXXX0011' else 'XXXXXX0022' end)),
    'T-' || p_n);
  insert into fin values (p_n, v_f, v_o);
  return v_f;
end; $$;
-- the LM dispatches
create function pg_temp.dispatch(p_n text, p_key integer) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
  v := public.dispatch_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_n), 'WAYBILL-' || p_n);
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
-- the TM takes the owner's code and confirms it
create function pg_temp.deliver(p_n text, p_key integer) returns jsonb language plpgsql as $$
declare v_s jsonb; v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
  v_s := public.start_monvelo_delivery(pg_temp.k(p_key), 'test-gw-secret', pg_temp.f(p_n));
  v := public.confirm_monvelo_delivery(pg_temp.k(p_key + 1), (v_s ->> 'challenge_id')::uuid, v_s ->> 'code');
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
create function pg_temp.git_payable(p_n text) returns uuid language sql as
  $$ select id from public.monvelo_premium_payables where financing_id = pg_temp.f(p_n) and kind = 'GIT' $$;
grant execute on function pg_temp.git_payable(text) to authenticated;

-- delivered two days ago, so a loss "yesterday" falls inside the cover
create function pg_temp.delivered(p_n text, p_key integer, p_shop integer, p_agent integer) returns uuid
language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.funded(p_n, p_key, p_shop, p_agent);
  perform pg_temp.dispatch(p_n, p_key + 5);
  perform pg_temp.deliver(p_n, p_key + 6);
  update public.monvelo_financings set delivered_at = now() - interval '2 days' where id = v;
  return v;
end; $$;
-- the funder's member records and confirms a repayment with the owner's code
create function pg_temp.repay(p_n text, p_key integer, p_agent integer, p_amount numeric) returns jsonb
language plpgsql as $$
declare v_r jsonb; v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v_r := public.record_monvelo_repayment(pg_temp.k(p_key), 'test-gw-secret', pg_temp.f(p_n), pg_temp.ag(p_agent), p_amount);
  v := public.confirm_monvelo_repayment(pg_temp.k(p_key + 1), (v_r ->> 'challenge_id')::uuid, v_r ->> 'code');
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
-- report a loss as p_user
create function pg_temp.report(p_n text, p_key integer, p_user integer, p_kind text, p_peril text,
                               p_at timestamptz default now() - interval '1 day', p_paths text[] default null)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  v := public.report_monvelo_loss(pg_temp.k(p_key), pg_temp.f(p_n), p_kind, p_peril, p_at, 'stock lost',
         coalesce(p_paths, array[pg_temp.f(p_n)::text || '/photo.jpg']));
  perform set_config('role', 'postgres', true);
  insert into res values ('claim-' || p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.c(p_n text) returns uuid language sql as $$ select (pg_temp.r('claim-' || p_n) ->> 'claim_id')::uuid $$;
grant execute on function pg_temp.c(text) to authenticated;
-- run one call as the operator
create function pg_temp.op(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(9), null);
  execute p_sql into v;
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
create function pg_temp.set_product(p_status text) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.monvelo_insurance_products set status = p_status,
         withdrawn_at = case when p_status = 'WITHDRAWN' then now() end
   where id = 'a8000000-0000-0000-0000-000000000002';
  set local session_replication_role = origin;
end; $$;
create temp table snap (n text primary key, v numeric);

-- G: GIT cover, dispatched, never delivered (REFUND_DUE)
update public.monvelo_tenant_settings set git_cover_enabled = true where tenant_id = pg_temp.t1();
select pg_temp.funded('G', 100, 2, 22);
select pg_temp.dispatch('G', 105);
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('G');
-- dispatched an hour ago (inside one transaction now() never moves)
set local session_replication_role = replica;
update public.monvelo_order_git_cover set created_at = now() - interval '1 hour' where financing_id = pg_temp.f('G');
set local session_replication_role = origin;
select public.monvelo_sweep_money();
update public.monvelo_tenant_settings set git_cover_enabled = false where tenant_id = pg_temp.t1();
-- every financing is raised before A defaults: a default freezes the shop's new credit
-- B: funded only. C: no cover (no product at its claim). D: the shop's own policy. E, F: AUTO_POLICY.
select pg_temp.delivered('A', 110, 1, 21);
select pg_temp.funded('B', 120, 1, 21);
select pg_temp.set_product('WITHDRAWN');
select pg_temp.delivered('C', 130, 1, 21);
select pg_temp.set_product('APPROVED');
select pg_temp.delivered('D', 140, 2, 22);
select pg_temp.delivered('E', 230, 1, 21);
select pg_temp.delivered('F', 250, 1, 21);
-- A: 12000 repaid, then past due with the late charge
select pg_temp.repay('A', 118, 21, 12000);
update public.monvelo_financings set due_at = now() - interval '1 hour' where id = pg_temp.f('A');
select public.monvelo_sweep_money();

-- ── 1. report rules (8) ─────────────────────────────────────────────────
select throws_ok($$ select pg_temp.report('A', 200, 11, 'STORAGE', 'FIRE') $$, '42501', null,
                 'an ASA of another area cannot report this shop''s loss');
select throws_ok($$ select pg_temp.report('B', 201, 4, 'STORAGE', 'FIRE') $$, 'P0001', null,
                 'STORAGE on a FUNDED financing is refused');
select throws_ok($$ select pg_temp.report('A', 202, 4, 'STORAGE', 'FIRE', now() - interval '3 days') $$, 'P0001', null,
                 'an incident before delivery is refused');
select throws_ok($$ select pg_temp.report('C', 203, 4, 'STORAGE', 'FIRE') $$, 'P0001', null,
                 'STORAGE on a financing with no cover is refused');
select throws_ok($$ select pg_temp.report('A', 204, 4, 'STORAGE', 'FIRE', now() - interval '1 day', array['elsewhere/x.jpg']) $$,
                 'P0001', null, 'evidence outside the financing''s folder is refused');
select is(pg_temp.report('A', 205, 4, 'STORAGE', 'BURGLARY') ->> 'status', 'REPORTED', 'the area''s ASA reports a burglary');
select throws_ok($$ select pg_temp.report('A', 206, 4, 'STORAGE', 'FIRE') $$, 'P0001', null,
                 'a second open claim is refused');
select pg_temp.report('G', 207, 8, 'GIT', 'THEFT_IN_TRANSIT', now() - interval '1 minute');
select ok((select status = 'REPORTED' and payee_kind = 'TENANT' and payee_agent_id is null and claimed_amount = 48000
                  and insurer_id = 'a8000000-0000-0000-0000-000000000001'
             from public.monvelo_insurance_claims where id = pg_temp.c('G')),
          'the LM reports a GIT loss on a REFUND_DUE financing, payable to the tenant, for the insured value');

-- ── 2. the claimed amount (1) ───────────────────────────────────────────
select ok((select c.claimed_amount = 36000 and c.payee_kind = 'AGENT' and c.payee_agent_id = pg_temp.ag(21)
                  and f.late_charge_amount = 3600 and f.status = 'DEFAULTED_WITH_LATE_CHARGE'
             from public.monvelo_insurance_claims c join public.monvelo_financings f on f.id = c.financing_id
            where c.id = pg_temp.c('A')),
          'STORAGE claims the unpaid principal (48000 - 12000), not the late charge; the agent is the payee');

-- ── 3. filing waits for an accepted declaration (3) ─────────────────────
select throws_ok(format('select pg_temp.op(%L)',
                        format('select public.file_monvelo_insurance_claim(pg_temp.k(210), %L)', pg_temp.c('A'))),
                 'P0001', 'the insurer has not accepted this cover''s declaration yet',
                 'a declaration still PENDING: filing is refused');
update public.monvelo_financing_cover set declared_status = 'ACCEPTED' where financing_id = pg_temp.f('A');
select is(pg_temp.op(format('select public.file_monvelo_insurance_claim(pg_temp.k(211), %L)', pg_temp.c('A'))) ->> 'status',
          'FILED', 'accepted: the operator files it');
select ok((select count(*) = 1 from public.monvelo_insurance_declarations
            where kind = 'CLAIM_FILE' and subject_id = pg_temp.c('A'))
          and (select d.payload -> 'payee' ->> 'settlement_account_number' = '0123450011'
                      and d.payload ->> 'claim_reference' = c.reference and d.payload ->> 'policy_kind' = 'STORAGE'
                      and (d.payload ->> 'claimed_amount')::numeric = 36000
                      and not (d.payload ?| array['shop_name', 'phone'])
                 from public.monvelo_insurance_declarations d join public.monvelo_insurance_claims c on c.id = d.subject_id
                where d.kind = 'CLAIM_FILE' and d.subject_id = pg_temp.c('A')),
          'one CLAIM_FILE, paying the agent''s settlement account, naming no shop or phone');

-- ── 4. the insurer settles: CLOSED_BY_CLAIM (6) ─────────────────────────
insert into snap select 'exposure', public.monvelo_agent_open_exposure(pg_temp.ag(21));
insert into snap select 'counted', least(outstanding, principal) from public.monvelo_financings where id = pg_temp.f('A');
select is(public.settle_monvelo_insurance_claim('MOCK', (select reference from public.monvelo_insurance_claims
                                                          where id = pg_temp.c('A')), 36000, 'PO-A') ->> 'status',
          'SETTLED', 'the insurer settles a FILED claim directly');
select ok((select status = 'SETTLED' and settled_amount = 36000 and payout_reference = 'PO-A' and shortfall = 0
                  and settled_at is not null
             from public.monvelo_insurance_claims where id = pg_temp.c('A')), 'the claim records the settlement');
select ok((select status = 'CLOSED_BY_CLAIM' and outstanding = 0 and closed_at is not null
             from public.monvelo_financings where id = pg_temp.f('A')),
          'the financing is CLOSED_BY_CLAIM with nothing outstanding');
select is((select late_charge_waived from public.monvelo_insurance_claims where id = pg_temp.c('A')), 3600.00::numeric(15,2),
          'the late charge is waived and recorded on the claim');
select is(public.monvelo_agent_open_exposure(pg_temp.ag(21)),
          ((select v from snap where n = 'exposure') - (select v from snap where n = 'counted'))::numeric(15,2),
          'the agent''s open exposure is freed');
select pg_temp.act_as(pg_temp.u(21), null);
select ok((select sum(closed_by_claim_amount) = 36000 and sum(late_charge_waived) = 3600
             from public.get_lender_reconciliation_summary(4)),
          'the lender summary shows the claim amount and the waived charge');
reset role;

-- ── 5. a shop-policy claim settled short (2) ────────────────────────────
select pg_temp.report('D', 220, 4, 'STORAGE', 'FIRE');
select ok(pg_temp.op(format('select public.file_monvelo_insurance_claim(pg_temp.k(221), %L)', pg_temp.c('D'))) ->> 'status' = 'FILED'
          and not exists (select 1 from public.monvelo_insurance_declarations where subject_id = pg_temp.c('D')),
          'a shop-policy claim is filed by hand, with no declaration');
select pg_temp.op(format('select public.record_monvelo_claim_settlement(pg_temp.k(222), %L, 30000, %L)', pg_temp.c('D'), 'PO-D'));
select ok((select status = 'CLOSED_BY_CLAIM' from public.monvelo_financings where id = pg_temp.f('D'))
          and (select shortfall = 18000 from public.monvelo_insurance_claims where id = pg_temp.c('D'))
          and exists (select 1 from public.monvelo_flags where kind = 'CLAIM_SHORTFALL' and financing_id = pg_temp.f('D')),
          'settled 30000 of 48000: still closed, the 18000 shortfall flagged');

-- ── 6. an open claim pauses the late charge (2) ─────────────────────────
select pg_temp.report('E', 240, 4, 'STORAGE', 'FIRE');
update public.monvelo_financings set due_at = now() - interval '1 hour' where id = pg_temp.f('E');
select public.monvelo_sweep_money();
select ok((select late_charge_amount = 0 and status = 'DELIVERED' from public.monvelo_financings where id = pg_temp.f('E')),
          'past due with an open STORAGE claim: no late charge');
update public.monvelo_financing_cover set declared_status = 'ACCEPTED' where financing_id = pg_temp.f('E');
select pg_temp.op(format('select public.file_monvelo_insurance_claim(pg_temp.k(241), %L)', pg_temp.c('E')));
select pg_temp.op(format('select public.set_monvelo_claim_status(pg_temp.k(242), %L, %L, %L)', pg_temp.c('E'), 'REJECTED', 'INS-E'));
select public.monvelo_sweep_money();
select ok((select late_charge_amount = 4800 and status = 'DEFAULTED_WITH_LATE_CHARGE'
             from public.monvelo_financings where id = pg_temp.f('E')),
          'the claim rejected: the next sweep applies the late charge');

-- ── 7. repaid in full withdraws the claim (3) ───────────────────────────
select pg_temp.report('F', 260, 4, 'STORAGE', 'FIRE');
select pg_temp.repay('F', 261, 21, 48000);
select is((select status from public.monvelo_insurance_claims where id = pg_temp.c('F')), 'WITHDRAWN',
          'a full repayment withdraws the open STORAGE claim');
select ok((public.settle_monvelo_insurance_claim('MOCK', (select reference from public.monvelo_insurance_claims
                                                           where id = pg_temp.c('F')), 48000, 'PO-F') ->> 'ignored')::boolean,
          'a settlement that arrives afterwards is ignored');
select ok(exists (select 1 from public.monvelo_flags where kind = 'CLAIM_SETTLED_AFTER_CLOSE' and financing_id = pg_temp.f('F'))
          and (select status = 'REPAID_WITHIN_WINDOW' from public.monvelo_financings where id = pg_temp.f('F'))
          and (select status = 'WITHDRAWN' from public.monvelo_insurance_claims where id = pg_temp.c('F')),
          'it is flagged, and neither the financing nor the claim changes');

-- ── 8. privacy and grants (3) ───────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select ok((select count(*) from public.monvelo_insurance_claims where kind = 'STORAGE') = 0
          and (select count(*) from public.monvelo_insurance_claims where kind = 'GIT') = 1,
          'a TENANT_ADMIN reads the GIT claim and no STORAGE claim');
reset role;
select ok((select count(*) filter (where a.tenant_id is not null) = 0 and count(*) >= 4
             from public.audit_logs a join public.monvelo_insurance_claims c on c.id::text = a.entity_id
            where a.entity_type = 'monvelo_insurance_claims' and c.kind = 'STORAGE'),
          'STORAGE claims are audited, and no such row carries a tenant');
select ok(not has_function_privilege('authenticated', 'public.settle_monvelo_insurance_claim(text,text,numeric,text)', 'execute')
          and not has_function_privilege('anon', 'public.settle_monvelo_insurance_claim(text,text,numeric,text)', 'execute')
          and has_function_privilege('service_role', 'public.settle_monvelo_insurance_claim(text,text,numeric,text)', 'execute'),
          'only service_role settles through the webhook path');

select * from finish();
rollback;
