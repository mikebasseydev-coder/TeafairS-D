-- Addendum A8 Task 4 (§6.2, §7.2): GIT cover declared at dispatch (the
-- tenant's cover, a GIT premium payable, a GIT_PREMIUM ledger line, a
-- GIT_DECLARE declaration), storage cover at delivery for AUTO_POLICY
-- financings (a STORAGE premium payable, declared_status PENDING, a
-- STORAGE_DECLARE declaration), a refund that keeps GIT, Teafair's finance
-- recording premiums and top-ups paid, and what the tenant reads.
--
-- Ruling (Task 4): the brief sized its examples on a 200000 principal; this
-- fixture's trade order is 12 x 4000 = 48000 (whole packs), so GIT at 75 bps
-- is 360.00 and STORAGE at 100 bps one block is 480.00.
begin;
create extension if not exists pgtap with schema extensions;

select plan(23);

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
  ('a8000000-0000-0000-0000-000000000001', 'MOCK', 'Mock Insurance', 'NAICOM-075', 'MOCK', '20000000-0000-0000-0000-000000000009');
insert into public.monvelo_insurance_products (id, insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from, status,
  proposed_by, approved_by, approved_at) values
  ('a8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'STORAGE', 100, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now()),
  ('a8000000-0000-0000-0000-000000000004', 'a8000000-0000-0000-0000-000000000001', 'GIT', 75, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now());
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at) values
  ('a8000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000002', 'Leadway', 'SME-075', true, true,
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
  $$ select ('d7500000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
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

-- ── 1. GIT off: dispatch writes no cover (1) ─────────────────────────────
select pg_temp.funded('G0', 100, 1, 21);
select pg_temp.dispatch('G0', 105);
select ok(not exists (select 1 from public.monvelo_order_git_cover where financing_id = pg_temp.f('G0'))
          and not exists (select 1 from public.monvelo_premium_payables where financing_id = pg_temp.f('G0'))
          and not exists (select 1 from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('G0'))
          and not exists (select 1 from public.monvelo_insurance_declarations where tenant_id = pg_temp.t1()),
          'GIT off: dispatch writes no cover, payable, ledger line or declaration');

-- ── 2. GIT on: cover, payable, ledger line, declaration (6) ──────────────
update public.monvelo_tenant_settings set git_cover_enabled = true where tenant_id = pg_temp.t1();
select pg_temp.funded('G1', 110, 1, 21);
select pg_temp.dispatch('G1', 115);
select ok((select insured_value = 48000 and premium = 360.00 and rate_bps = 75 and declared_status = 'PENDING'
                  and product_id = 'a8000000-0000-0000-0000-000000000004' and order_id = pg_temp.o('G1')
             from public.monvelo_order_git_cover where financing_id = pg_temp.f('G1')),
          'GIT on: the order is covered at its principal, 75 bps = 360.00');
select ok((select amount = 360.00 and status = 'DUE' and insurer_id = 'a8000000-0000-0000-0000-000000000001'
                  and due_at between now() + interval '23 hours 59 minutes' and now() + interval '24 hours 1 minute'
             from public.monvelo_premium_payables where financing_id = pg_temp.f('G1') and kind = 'GIT'),
          'a GIT premium payable of 360.00 is due in 24 hours');
select ok((select amount = -360.00 and business_date = public.monvelo_today()
             from public.monvelo_tenant_ledger_entries where financing_id = pg_temp.f('G1') and entry_type = 'GIT_PREMIUM'),
          'the tenant ledger carries GIT_PREMIUM -360.00 on the Lagos dispatch day');
select is((select count(*)::int from public.monvelo_insurance_declarations
            where kind = 'GIT_DECLARE' and status = 'PENDING' and subject_table = 'monvelo_order_git_cover'
              and subject_id = pg_temp.o('G1')), 1, 'one GIT_DECLARE declaration is PENDING');
select ok((select payload ?& array['financing_reference', 'order_id', 'insured_value', 'premium', 'dispatched_at',
                                   'tracking_reference']
                  and payload ->> 'tracking_reference' = 'WAYBILL-G1'
                  and (payload ->> 'premium')::numeric = 360.00
             from public.monvelo_insurance_declarations where kind = 'GIT_DECLARE' and subject_id = pg_temp.o('G1')),
          'the GIT payload carries the reference, order, value, premium, time and waybill');
select ok((select not (payload ?| array['phone', 'shop_name', 'contact_phone', 'account_number',
                                        'settlement_account_number', 'address'])
             from public.monvelo_insurance_declarations where kind = 'GIT_DECLARE' and subject_id = pg_temp.o('G1')),
          'the GIT payload names no phone, shop name or account');

-- ── 3. STORAGE at delivery (5) ───────────────────────────────────────────
select pg_temp.deliver('G1', 120);
select ok((select amount = 480.00 and status = 'DUE' and insurer_id = 'a8000000-0000-0000-0000-000000000001'
                  and due_at between now() + interval '23 hours 59 minutes' and now() + interval '24 hours 1 minute'
             from public.monvelo_premium_payables where financing_id = pg_temp.f('G1') and kind = 'STORAGE'),
          'an AUTO_POLICY financing delivered: a STORAGE premium payable of 480.00 due in 24 hours');
select is((select declared_status from public.monvelo_financing_cover where financing_id = pg_temp.f('G1')), 'PENDING',
          'its cover is declared PENDING');
select is((select count(*)::int from public.monvelo_insurance_declarations
            where kind = 'STORAGE_DECLARE' and status = 'PENDING' and subject_table = 'monvelo_financing_cover'
              and subject_id = pg_temp.f('G1')), 1, 'one STORAGE_DECLARE declaration is PENDING');
select ok((select (d.payload ->> 'sum_insured')::numeric = 48000 and (d.payload ->> 'premium')::numeric = 480.00
                  and (d.payload ->> 'cover_from')::timestamptz = f.delivered_at
                  and (d.payload ->> 'cover_to')::timestamptz = f.due_at
                  and d.payload ->> 'area_id' = f.area_id::text
                  and d.payload ->> 'financing_reference' = f.reference
                  and not (d.payload ?| array['phone', 'shop_name', 'agent_id', 'settlement_account_number'])
             from public.monvelo_insurance_declarations d join public.monvelo_financings f on f.id = d.subject_id
            where d.kind = 'STORAGE_DECLARE' and d.subject_id = pg_temp.f('G1')),
          'the STORAGE payload: reference, sum insured, premium, cover dates, area; no lender or contact');
select pg_temp.funded('G3', 130, 2, 22);
select pg_temp.dispatch('G3', 135);
select pg_temp.deliver('G3', 140);
select ok((select cover_kind = 'SHOP_POLICY' and declared_status = 'NOT_DUE'
             from public.monvelo_financing_cover where financing_id = pg_temp.f('G3'))
          and not exists (select 1 from public.monvelo_premium_payables where financing_id = pg_temp.f('G3') and kind = 'STORAGE')
          and not exists (select 1 from public.monvelo_insurance_declarations
                           where kind = 'STORAGE_DECLARE' and subject_id = pg_temp.f('G3')),
          'a SHOP_POLICY financing delivered: no storage payable or declaration');

-- ── 4. a refund keeps GIT (3) ────────────────────────────────────────────
select pg_temp.funded('G2', 150, 2, 22);
select pg_temp.dispatch('G2', 155);
update public.monvelo_financings set funded_at = now() - interval '23 hours' where id = pg_temp.f('G2');
select public.monvelo_sweep_money();
select is((select status from public.monvelo_financings where id = pg_temp.f('G2')), 'REFUND_DUE',
          'undelivered 23 hours after funding: REFUND_DUE');
select ok((select status = 'DUE' from public.monvelo_premium_payables where financing_id = pg_temp.f('G2') and kind = 'GIT')
          and exists (select 1 from public.monvelo_tenant_ledger_entries
                       where financing_id = pg_temp.f('G2') and entry_type = 'GIT_PREMIUM' and amount = -360.00),
          'the GIT payable stays DUE and its ledger line stays');
select ok(not exists (select 1 from public.monvelo_premium_payables where financing_id = pg_temp.f('G2') and kind = 'STORAGE'),
          'no STORAGE payable exists for a refund');

-- ── 5. premiums and top-ups paid (6) ─────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select throws_ok($$ select public.record_monvelo_premium_paid(pg_temp.k(200), pg_temp.git_payable('G1'), 'TRF-1') $$,
                 '42501', null, 'a ZSM cannot record a premium paid');
select pg_temp.act_as(pg_temp.u(9), null);
select throws_ok($$ select public.record_monvelo_premium_paid(pg_temp.k(201), pg_temp.git_payable('G1'), 'TRF-1') $$,
                 '42501', null, 'nor can an operator');
select pg_temp.act_as(pg_temp.u(6), null);
select is(public.record_monvelo_premium_paid(pg_temp.k(202), pg_temp.git_payable('G1'), 'TRF-1') ->> 'status', 'PAID',
          'finance records it PAID');
select throws_ok($$ select public.record_monvelo_premium_paid(pg_temp.k(203), pg_temp.git_payable('G1'), 'TRF-2') $$,
                 'P0001', null, 'a second payment is refused');
reset role;
set local session_replication_role = replica;
insert into public.monvelo_rebate_topups (id, tenant_id, financing_id, agent_id, amount, reason, due_at) values
  ('a8000000-0000-0000-0000-000000000009', pg_temp.t1(), pg_temp.f('G1'), pg_temp.ag(21), 480, 'DECLARATION_REJECTED',
   now() + interval '24 hours');
set local session_replication_role = origin;
select pg_temp.act_as(pg_temp.u(6), null);
select is(public.record_monvelo_topup_paid(pg_temp.k(204), 'a8000000-0000-0000-0000-000000000009', 'TRF-3') ->> 'status',
          'PAID', 'finance records a rebate top-up PAID');
select ok((select status = 'PAID' and paid_reference = 'TRF-3' and paid_by = pg_temp.u(6)
             from public.monvelo_rebate_topups where id = 'a8000000-0000-0000-0000-000000000009'),
          'the top-up carries the reference and who paid it');
reset role;

-- ── 6. the tenant reads GIT only (2) ─────────────────────────────────────
select pg_temp.act_as(pg_temp.u(18), pg_temp.t1());
select ok((select count(*) from public.monvelo_order_git_cover) = 3
          and (select count(*) from public.monvelo_tenant_ledger_entries where entry_type = 'GIT_PREMIUM') = 3,
          'the CSM reads the GIT covers and their GIT_PREMIUM ledger lines');
select is((select count(*)::int from public.monvelo_premium_payables), 0, 'and no premium payable');
reset role;

select * from finish();
rollback;
