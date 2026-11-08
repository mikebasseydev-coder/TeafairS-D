-- Addendum A8 Task 10: one AUTO_POLICY financing from request to
-- CLOSED_BY_CLAIM through every A8 piece (quote, claim lock, net rebate, GIT
-- at dispatch, storage at delivery, the declarations outbox, a loss filed and
-- settled through the insurer's path), and what each party can see at the
-- end. A second financing, for a shop with its own verified policy, pays no
-- premium. Amounts on the fixture's 48000 order (Task 4 ruling): rebate 4800,
-- storage premium 480 (net 4320, yield 9.00 %), GIT premium 360.
begin;
create extension if not exists pgtap with schema extensions;

select plan(13);

-- A8 fix pass: this file's MOCK insurer counts as an underwriter (mock insurers allowed here)
update public.monvelo_platform_settings set allow_mock_insurers = true;

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
  from unnest(array[1, 3, 4, 6, 7, 8, 9, 10, 18, 21, 22]) n;
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
       public.monvelo_today(), 150000, 150000, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
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
  ('a8000000-0000-0000-0000-000000000001', 'MOCK', 'Mock Insurance', 'NAICOM-078', 'MOCK', '20000000-0000-0000-0000-000000000009');
insert into public.monvelo_insurance_products (id, insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from, status,
  proposed_by, approved_by, approved_at) values
  ('a8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'STORAGE', 100, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now()),
  ('a8000000-0000-0000-0000-000000000004', 'a8000000-0000-0000-0000-000000000001', 'GIT', 75, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now());
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at) values
  ('a8000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000002', 'Leadway', 'SME-078', true, true,
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
  $$ select ('d7800000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
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

create temp table e2e (n text primary key, v text);
grant select, insert on e2e to authenticated;
update public.monvelo_tenant_settings set git_cover_enabled = true where tenant_id = pg_temp.t1();

-- ── E1: S1 has no policy (AUTO_POLICY), funded by P (agent 21) ───────────
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
insert into e2e select 'order', public.place_trade_order(pg_temp.k(100), '71000000-0000-0000-0000-000000000001',
  jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 12))) ->> 'order_id';
insert into e2e select 'fin', public.request_monvelo_financing(pg_temp.k(101), (select v::uuid from e2e where n = 'order'))
  ->> 'financing_id';
reset role;
insert into fin select 'E1', (select v::uuid from e2e where n = 'fin'), (select v::uuid from e2e where n = 'order');
select pg_temp.act_as(pg_temp.u(21), null);
select is((select net_yield_bps from public.get_monvelo_offer_cover(pg_temp.f('E1'), pg_temp.ag(21))), 900,
          'the agent is quoted 9.00 %: 10 % rebate less the 1 % storage premium');
select public.claim_monvelo_financing(pg_temp.k(102), pg_temp.f('E1'), pg_temp.ag(21), 900);
insert into e2e select 'pay', public.start_monvelo_funding(pg_temp.k(103), pg_temp.f('E1'), pg_temp.ag(21)) ->> 'reference';
reset role;
select public.settle_monvelo_funding('charge.success', (select v from e2e where n = 'pay'), 'success', 4800000, 'NGN',
  jsonb_build_object('status', 'success', 'channel', 'bank_transfer',
    'authorization', jsonb_build_object('channel', 'bank_transfer', 'sender_bank', 'Guaranty Trust Bank',
      'sender_name', 'ADE, BISI O.', 'sender_bank_account_number', 'XXXXXX0011')), 'T-E1');
select is((select amount from public.monvelo_rebate_payables where financing_id = pg_temp.f('E1')), 4320.00::numeric(15,2),
          'funding owes the agent the net rebate it acknowledged');

select pg_temp.dispatch('E1', 110);
select ok((select amount = 360 from public.monvelo_premium_payables where financing_id = pg_temp.f('E1') and kind = 'GIT')
          and (select amount = -360 from public.monvelo_tenant_ledger_entries
                where financing_id = pg_temp.f('E1') and entry_type = 'GIT_PREMIUM'),
          'dispatch: the tenant''s GIT premium is payable and in its ledger');
select pg_temp.deliver('E1', 120);
select is((select amount from public.monvelo_premium_payables where financing_id = pg_temp.f('E1') and kind = 'STORAGE'),
          480.00::numeric(15,2), 'delivery: the storage premium is payable to the insurer');

-- the declare function's round: both declarations accepted by the MOCK insurer
create temp table round1 as select * from public.claim_monvelo_declarations(20) j;
select public.complete_monvelo_declaration((j ->> 'id')::uuid, 'ACCEPTED', 'POL-' || (j ->> 'kind'), null) from round1;
select ok((select count(*) = 2 from round1)
          and (select declared_status = 'ACCEPTED' from public.monvelo_financing_cover where financing_id = pg_temp.f('E1'))
          and (select declared_status = 'ACCEPTED' from public.monvelo_order_git_cover where financing_id = pg_temp.f('E1')),
          'the GIT and storage declarations go out and are accepted');

-- a fire, reported by the area's ASA, filed by the operator, settled by the insurer
update public.monvelo_financings set delivered_at = now() - interval '2 days' where id = pg_temp.f('E1');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
insert into e2e select 'claim', public.report_monvelo_loss(pg_temp.k(130), pg_temp.f('E1'), 'STORAGE', 'FIRE',
  now() - interval '1 day', 'the shop burned', array[pg_temp.f('E1')::text || '/fire.jpg']) ->> 'claim_id';
select pg_temp.act_as(pg_temp.u(9), null);
select public.file_monvelo_insurance_claim(pg_temp.k(131), (select v::uuid from e2e where n = 'claim'));
reset role;
create temp table round2 as select * from public.claim_monvelo_declarations(20) j;
select public.complete_monvelo_declaration((j ->> 'id')::uuid, 'ACCEPTED', 'INS-CLAIM-1', null) from round2;
select ok((select count(*) = 1 and bool_and(j ->> 'kind' = 'CLAIM_FILE') from round2)
          and (select status = 'FILED' and insurer_claim_reference = 'INS-CLAIM-1'
                 from public.monvelo_insurance_claims where id = (select v::uuid from e2e where n = 'claim')),
          'the claim goes out as CLAIM_FILE and the insurer acknowledges it');
select public.settle_monvelo_insurance_claim('MOCK',
  (select reference from public.monvelo_insurance_claims where id = (select v::uuid from e2e where n = 'claim')),
  48000.00, 'PAYOUT-1');

select ok((select status = 'CLOSED_BY_CLAIM' and outstanding = 0 from public.monvelo_financings where id = pg_temp.f('E1')),
          'the settlement closes the financing CLOSED_BY_CLAIM with nothing outstanding');
select is(public.monvelo_agent_open_exposure(pg_temp.ag(21)), 0.00::numeric(15,2), 'the agent''s exposure is free again');
select pg_temp.act_as(pg_temp.u(21), null);
select ok((select sum(capital_funded) = 48000 and sum(closed_by_claim_amount) = 48000
             from public.get_lender_reconciliation_summary(2)),
          'the lender''s summary: 48000 funded, 48000 closed by claim');
reset role;
select is((select array_agg(distinct entry_type order by entry_type) from public.monvelo_tenant_ledger_entries
            where financing_id = pg_temp.f('E1')), array['FUNDED_GROSS', 'GIT_PREMIUM'],
          'the tenant''s ledger holds the funded gross and its GIT premium; no storage premium, no claim money');

-- what the tenant can see names no lender
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from (
             select to_jsonb(c)::text t from public.monvelo_insurance_claims c
             union all select to_jsonb(g)::text from public.monvelo_order_git_cover g
             union all select to_jsonb(l)::text from public.monvelo_tenant_ledger_entries l
             union all select to_jsonb(p)::text from public.monvelo_premium_payables p
             union all select to_jsonb(a)::text from public.audit_logs a) x
            where t like '%' || pg_temp.ag(21)::text || '%' or t like '%' || pg_temp.u(21)::text || '%'), 0,
          'the TENANT_ADMIN reads no row naming the agent or its member');
reset role;
select is((select count(*)::int from public.audit_logs
            where tenant_id is not null
              and (coalesce(after::text, '') like '%' || pg_temp.ag(21)::text || '%'
                   or coalesce(before::text, '') like '%' || pg_temp.ag(21)::text || '%')), 0,
          'no tenant audit row names the agent');

-- ── E2: S2 has a verified policy: the full yield, no storage premium ─────
select pg_temp.funded('E2', 200, 2, 22);
select pg_temp.dispatch('E2', 210);
select pg_temp.deliver('E2', 220);
select ok((select cover_kind = 'SHOP_POLICY' and net_rebate = 4800 from public.monvelo_financing_cover where financing_id = pg_temp.f('E2'))
          and not exists (select 1 from public.monvelo_premium_payables where financing_id = pg_temp.f('E2') and kind = 'STORAGE')
          and not exists (select 1 from public.monvelo_insurance_declarations
                           where kind = 'STORAGE_DECLARE' and subject_id = pg_temp.f('E2')),
          'a shop with its own verified policy: 10.00 % to the agent, no storage premium or declaration');

select * from finish();
rollback;
