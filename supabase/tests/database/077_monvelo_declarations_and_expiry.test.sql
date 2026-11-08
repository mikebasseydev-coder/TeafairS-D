-- Addendum A8 Task 6 (§6.4, §7.1, §7.2): the declarations outbox
-- (claim_monvelo_declarations, complete_monvelo_declaration), what an
-- insurer's answer does to the cover (accepted; a rejected storage
-- declaration cancels or recovers the premium and tops the agent's rebate
-- back up), the operator's MANUAL path (record_monvelo_declaration_outcome),
-- the stale-declaration sweep and the shop-policy expiry sweep.
--
-- Amounts on the fixture's 48000 order (Task 4 ruling): the storage premium is 480.00.
begin;
create extension if not exists pgtap with schema extensions;

select plan(40);

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
  from unnest(array[1, 3, 4, 6, 7, 8, 9, 10, 12, 18, 21, 22]) n;
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
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000012', 'ZSA', '30000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true);
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
  ('a8000000-0000-0000-0000-000000000001', 'MOCK', 'Mock Insurance', 'NAICOM-077', 'MOCK', '20000000-0000-0000-0000-000000000009');
insert into public.monvelo_insurance_products (id, insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from, status,
  proposed_by, approved_by, approved_at) values
  ('a8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'STORAGE', 100, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now()),
  ('a8000000-0000-0000-0000-000000000004', 'a8000000-0000-0000-0000-000000000001', 'GIT', 75, 1000,
   public.monvelo_today() - 1, 'APPROVED', '20000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000006', now());
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at) values
  ('a8000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000002', 'Leadway', 'SME-077', true, true,
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
  $$ select ('d7700000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
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

create function pg_temp.delivered(p_n text, p_key integer) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.funded(p_n, p_key, 1, 21);
  perform pg_temp.dispatch(p_n, p_key + 5);
  perform pg_temp.deliver(p_n, p_key + 6);
  return v;
end; $$;
create function pg_temp.decl(p_n text) returns uuid language sql as
  $$ select id from public.monvelo_insurance_declarations where kind = 'STORAGE_DECLARE' and subject_id = pg_temp.f(p_n) $$;
grant execute on function pg_temp.decl(text) to authenticated;
create temp table d (n text primary key, id uuid);
grant select on d to authenticated;

-- ── 1. the claim batch (2) ──────────────────────────────────────────────
insert into d select 'X' || n, public.monvelo_enqueue_declaration(pg_temp.t1(), 'GIT_DECLARE',
         'a8000000-0000-0000-0000-000000000001', 'monvelo_order_git_cover', gen_random_uuid(), jsonb_build_object('n', n))
  from generate_series(1, 3) n;
create temp table batch as select * from public.claim_monvelo_declarations(2) j;
select ok((select count(*) = 2 from batch)
          and (select count(*) = 2 from public.monvelo_insurance_declarations where status = 'SENDING' and attempts = 1)
          and (select bool_and(j ?& array['id', 'kind', 'insurer_code', 'api_provider', 'payload']
                               and j ->> 'insurer_code' = 'MOCK' and j ->> 'api_provider' = 'MOCK') from batch),
          'a batch of 2 of 3: SENDING, attempt 1, with the insurer''s code and adapter');
update public.monvelo_insurance_declarations set next_attempt_at = now() - interval '11 minutes'
 where id = (select (j ->> 'id')::uuid from batch order by j ->> 'id' limit 1);
select is((select count(*)::int from public.claim_monvelo_declarations(5)), 2,
          'the third PENDING row and a SENDING row stale for 10 minutes are claimed');

-- ── 2. the retry schedule (2) ───────────────────────────────────────────
update public.monvelo_insurance_declarations set attempts = 3 where id = (select id from d where n = 'X1');
select public.complete_monvelo_declaration((select id from d where n = 'X1'), 'RETRY', null, 'timeout');
select ok((select status = 'PENDING' and last_error = 'timeout'
                  and next_attempt_at between now() + interval '7 minutes 59 seconds' and now() + interval '8 minutes 1 second'
             from public.monvelo_insurance_declarations where id = (select id from d where n = 'X1')),
          'a retry after the third attempt waits 2^3 = 8 minutes');
set local session_replication_role = replica;
update public.monvelo_insurance_declarations set created_at = now() - interval '25 hours' where id = (select id from d where n = 'X2');
set local session_replication_role = origin;
select public.complete_monvelo_declaration((select id from d where n = 'X2'), 'RETRY', null, 'timeout');
select ok((select status = 'FAILED' and completed_at is not null
             from public.monvelo_insurance_declarations where id = (select id from d where n = 'X2'))
          and exists (select 1 from public.monvelo_flags where kind = 'DECLARATION_FAILED'
                                                           and details ->> 'declaration_id' = (select id from d where n = 'X2')::text),
          'past 24 hours of retries: FAILED and flagged');

-- ── 3. accepted propagates (1) ──────────────────────────────────────────
select pg_temp.delivered('A', 100);
select public.complete_monvelo_declaration(pg_temp.decl('A'), 'ACCEPTED', 'POL-A', null);
select ok((select declared_status = 'ACCEPTED' from public.monvelo_financing_cover where financing_id = pg_temp.f('A'))
          and (select status = 'ACCEPTED' and insurer_reference = 'POL-A'
                 from public.monvelo_insurance_declarations where id = pg_temp.decl('A')),
          'an accepted storage declaration marks the cover ACCEPTED');

-- ── 4. a storage declaration rejected (5) ───────────────────────────────
select pg_temp.delivered('B', 110);
select public.complete_monvelo_declaration(pg_temp.decl('B'), 'REJECTED', null, 'outside appetite');
select ok((select status = 'CANCELLED' from public.monvelo_premium_payables where financing_id = pg_temp.f('B') and kind = 'STORAGE')
          and (select declared_status = 'REJECTED' from public.monvelo_financing_cover where financing_id = pg_temp.f('B')),
          'rejected: the unpaid storage premium is cancelled and the cover REJECTED');
select ok((select amount = 480.00 and status = 'DUE' and agent_id = pg_temp.ag(21) and reason = 'DECLARATION_REJECTED'
             from public.monvelo_rebate_topups where financing_id = pg_temp.f('B')),
          'the agent''s rebate is topped back up by the premium (480.00)');
select ok(exists (select 1 from public.monvelo_flags where kind = 'DECLARATION_REJECTED' and financing_id = pg_temp.f('B'))
          and exists (select 1 from public.notifications where kind = 'MONVELO_COVER_REJECTED' and user_id = pg_temp.u(21)
                                                         and tenant_id is null)
          and exists (select 1 from public.notifications where kind = 'MONVELO_COVER_REJECTED' and user_id = pg_temp.u(9)),
          'flagged; the agent''s members (tenant-null) and the operators are told');
select ok((public.complete_monvelo_declaration(pg_temp.decl('B'), 'REJECTED', null, 'again') ->> 'ignored')::boolean
          and (select count(*) = 1 from public.monvelo_rebate_topups where financing_id = pg_temp.f('B')),
          'a second REJECTED changes nothing: one top-up');
update public.monvelo_financings set delivered_at = now() - interval '2 days' where id = pg_temp.f('B');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$ select public.report_monvelo_loss(pg_temp.k(119), pg_temp.f('B'), 'STORAGE', 'FIRE', now() - interval '1 day',
                                                      'fire', array[pg_temp.f('B')::text || '/p.jpg']) $$,
                 'P0001', 'the insurer rejected this financing''s storage cover', 'the uncovered financing takes no STORAGE claim');
reset role;

-- ── 5. rejected after the premium was paid (1) ──────────────────────────
select pg_temp.delivered('C', 120);
select pg_temp.act_as(pg_temp.u(6), null);
select public.record_monvelo_premium_paid(pg_temp.k(129),
  (select id from public.monvelo_premium_payables where financing_id = pg_temp.f('C') and kind = 'STORAGE'), 'TRF-C');
reset role;
select public.complete_monvelo_declaration(pg_temp.decl('C'), 'REJECTED', null, 'declined');
select ok((select status = 'PAID' from public.monvelo_premium_payables where financing_id = pg_temp.f('C') and kind = 'STORAGE')
          and exists (select 1 from public.monvelo_flags where kind = 'PREMIUM_RECOVERY' and financing_id = pg_temp.f('C'))
          and exists (select 1 from public.monvelo_rebate_topups where financing_id = pg_temp.f('C')),
          'already paid: the payable stays PAID, PREMIUM_RECOVERY is flagged, the agent still gets the top-up');

-- ── 6. a stale storage declaration (2) ──────────────────────────────────
select pg_temp.delivered('D', 130);
update public.monvelo_financings set delivered_at = now() - interval '25 hours' where id = pg_temp.f('D');
select is(public.monvelo_sweep_declarations(), 1, 'the sweep flags the one declaration pending 25 hours after delivery');
select ok(public.monvelo_sweep_declarations() = 0
          and (select count(*) = 1 from public.monvelo_flags where kind = 'DECLARATION_STALE' and financing_id = pg_temp.f('D')),
          'a second sweep adds no flag');

-- ── 7. the shop-policy expiry sweep (5) ─────────────────────────────────
update public.profiles set email = 'asa.allen@example.com' where id = pg_temp.u(4);
update public.profiles set email = null where id = pg_temp.u(12);
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('71000000-0000-0000-0000-000000000003', 'Shop 3', '+234803111003', pg_temp.u(10), 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 3'),
  ('71000000-0000-0000-0000-000000000004', 'Shop 4', '+234803111004', pg_temp.u(10), 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 4');
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by)
select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, pg_temp.t1(),
       ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       'x', now() + interval '1 hour', pg_temp.u(4)
  from generate_series(3, 4) n;
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id)
select c.tenant_id, c.shop_id, c.area_id, c.issued_by, now(), 'MV-SHARE-2026-10', c.id
  from public.monvelo_consent_challenges c where c.id in ('c0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004');
set local session_replication_role = replica;
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at) values
  ('a8000000-0000-0000-0000-000000000031', '71000000-0000-0000-0000-000000000003', 'Leadway', 'SME-077-3', true, true,
   1000000, true, public.monvelo_today() - 300, public.monvelo_today() - 1, '71000000-0000-0000-0000-000000000003/p.pdf',
   pg_temp.u(4), 'c0000000-0000-0000-0000-000000000003', 'VERIFIED', pg_temp.u(9), now()),
  ('a8000000-0000-0000-0000-000000000041', '71000000-0000-0000-0000-000000000004', 'Leadway', 'SME-077-4', true, true,
   1000000, true, public.monvelo_today() - 300, public.monvelo_today() + 15, '71000000-0000-0000-0000-000000000004/p.pdf',
   pg_temp.u(4), 'c0000000-0000-0000-0000-000000000004', 'VERIFIED', pg_temp.u(9), now());
set local session_replication_role = origin;
select public.monvelo_sweep_shop_policies();
select is((select status from public.monvelo_shop_policies where id = 'a8000000-0000-0000-0000-000000000031'), 'EXPIRED',
          'a verified policy past its expiry date is EXPIRED');
select ok((select count(*) = 1 and bool_and(template = 'MONVELO_SHOP_COVER_EXPIRING' and to_email = 'asa.allen@example.com'
                                            and source_table = 'monvelo_shop_policies'
                                            and payload = jsonb_build_object('shop_name', 'Shop 4',
                                                                             'expires_on', public.monvelo_today() + 15))
             from public.email_outbox where source_id = 'a8000000-0000-0000-0000-000000000041'),
          'one email to the area''s ASA, naming only the shop and the date');
select ok(exists (select 1 from public.notifications where kind = 'MONVELO_SHOP_COVER_EXPIRING' and user_id = pg_temp.u(12)
                                                     and payload ->> 'policy_id' = 'a8000000-0000-0000-0000-000000000041')
          and exists (select 1 from public.notifications where kind = 'MONVELO_SHOP_COVER_EXPIRING' and user_id = pg_temp.u(4)),
          'the zone''s ZSA, who has no email, is notified in the app, as is the ASA');
select ok((select expiry_notice_sent_at is not null from public.monvelo_shop_policies where id = 'a8000000-0000-0000-0000-000000000041'),
          'the notice is recorded on the policy');
select public.monvelo_sweep_shop_policies();
select ok((select count(*) = 1 from public.email_outbox where source_id = 'a8000000-0000-0000-0000-000000000041')
          and (select count(*) = 2 from public.notifications where kind = 'MONVELO_SHOP_COVER_EXPIRING'),
          'a second run sends nothing more');

-- ── 8. the operator's MANUAL path (2) ───────────────────────────────────
-- no API role reads the outbox: its id is taken here, as postgres
insert into d values ('D', pg_temp.decl('D'));
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select throws_ok($$ select public.record_monvelo_declaration_outcome(pg_temp.k(140), (select id from d where n = 'D'), 'ACCEPTED', 'POL-D') $$,
                 '42501', null, 'a ZSA cannot record an insurer''s answer');
select pg_temp.act_as(pg_temp.u(9), null);
select public.record_monvelo_declaration_outcome(pg_temp.k(141), (select id from d where n = 'D'), 'ACCEPTED', 'POL-D');
reset role;
select ok((select declared_status = 'ACCEPTED' from public.monvelo_financing_cover where financing_id = pg_temp.f('D')),
          'the operator records it: the cover is ACCEPTED');

-- ── 9. grants and cron (2) ──────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.claim_monvelo_declarations(integer)', 'execute')
          and not has_function_privilege('authenticated', 'public.complete_monvelo_declaration(uuid,text,text,text)', 'execute')
          and has_function_privilege('service_role', 'public.claim_monvelo_declarations(integer)', 'execute')
          and has_function_privilege('service_role', 'public.complete_monvelo_declaration(uuid,text,text,text)', 'execute')
          and not has_function_privilege('authenticated', 'public.monvelo_sweep_shop_policies()', 'execute')
          and not has_function_privilege('authenticated', 'public.monvelo_sweep_declarations()', 'execute'),
          'the outbox is the declare function''s (service_role); the sweeps are cron''s');
select ok(exists (select 1 from cron.job where jobname = 'monvelo-shop-policy-sweep' and schedule = '0 5 * * *')
          and exists (select 1 from cron.job where jobname = 'monvelo-declaration-sweep' and schedule = '*/15 * * * *'),
          'the two sweeps are scheduled');

-- ── 10. Task 7: a MANUAL insurer's row waits for the operator (2) ────────
select public.complete_monvelo_declaration((select id from d where n = 'X3'), 'MANUAL', null, null);
select ok((select status = 'PENDING' and next_attempt_at = 'infinity'::timestamptz
             from public.monvelo_insurance_declarations where id = (select id from d where n = 'X3'))
          and not exists (select 1 from public.claim_monvelo_declarations(50) j where (j ->> 'id')::uuid = (select id from d where n = 'X3')),
          'MANUAL: back to PENDING, never claimed again, waiting for record_monvelo_declaration_outcome');
select ok(exists (select 1 from cron.job where jobname = 'monvelo-insurance-declare' and schedule = '* * * * *'
                                         and command like '%invoke_system_function(''monvelo-insurance-declare''%'),
          'monvelo-insurance-declare runs every minute');

-- ── 11. Task 8: insurer events, recorded and applied once (9) ───────────
set local session_replication_role = replica;
insert into public.monvelo_insurers (id, code, legal_name, naicom_licence_no, api_provider, created_by) values
  ('a8000000-0000-0000-0000-000000000005', 'OTHER', 'Other Insurance', 'NAICOM-077-O', 'MOCK', pg_temp.u(9));
set local session_replication_role = origin;
select ok(public.record_monvelo_insurer_event('MOCK', 'evt-a', '{"type": "x"}')
          and not public.record_monvelo_insurer_event('MOCK', 'evt-a', '{"type": "x"}'),
          'an event is new once, then a duplicate');
select ok(public.record_monvelo_insurer_event('OTHER', 'evt-a', '{}'), 'the same event id from another insurer is its own');
select ok(public.get_monvelo_insurer_provider('MOCK') = 'MOCK' and public.get_monvelo_insurer_provider('NOPE') is null,
          'the provider lookup answers for a known insurer and is null otherwise');
select ok((public.apply_monvelo_insurer_event('MOCK', 'evt-b', 'policy.renewed', '{}') ->> 'ignored')::boolean
          and (public.apply_monvelo_insurer_event('MOCK', 'evt-b', 'policy.renewed', '{}') ->> 'duplicate')::boolean,
          'an unknown type is recorded and ignored; its repeat is a duplicate');
insert into d select 'Y', public.monvelo_enqueue_declaration(pg_temp.t1(), 'GIT_DECLARE',
  'a8000000-0000-0000-0000-000000000001', 'monvelo_order_git_cover', gen_random_uuid(), '{}');
select throws_ok(format($q$ select public.apply_monvelo_insurer_event('OTHER', 'evt-c', 'declaration.accepted',
                                    jsonb_build_object('declaration_id', %L)) $q$, (select id from d where n = 'Y')),
                 'P0001', 'declaration not found', 'another insurer cannot answer this declaration');
select ok(public.record_monvelo_insurer_event('OTHER', 'evt-c', '{}'), 'and the refused event was not recorded');
select public.apply_monvelo_insurer_event('MOCK', 'evt-d', 'declaration.accepted',
  jsonb_build_object('declaration_id', (select id from d where n = 'Y'), 'insurer_reference', 'POL-Y'));
select ok((select status = 'ACCEPTED' and insurer_reference = 'POL-Y'
             from public.monvelo_insurance_declarations where id = (select id from d where n = 'Y')),
          'the declaring insurer''s acceptance lands');
-- a filed STORAGE claim on A (accepted cover), then the insurer's review and settlement
update public.monvelo_financings set delivered_at = now() - interval '2 days' where id = pg_temp.f('A');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
insert into res select 'claimA', public.report_monvelo_loss(pg_temp.k(300), pg_temp.f('A'), 'STORAGE', 'FIRE',
  now() - interval '1 day', 'fire', array[pg_temp.f('A')::text || '/p.jpg']);
select pg_temp.act_as(pg_temp.u(9), null);
select public.file_monvelo_insurance_claim(pg_temp.k(301), (pg_temp.r('claimA') ->> 'claim_id')::uuid);
reset role;
select public.apply_monvelo_insurer_event('MOCK', 'evt-e', 'claim.under_review',
  jsonb_build_object('claim_reference', pg_temp.r('claimA') ->> 'reference', 'insurer_reference', 'INS-CL-A'));
select ok((select status = 'UNDER_REVIEW' and insurer_claim_reference = 'INS-CL-A'
             from public.monvelo_insurance_claims where id = (pg_temp.r('claimA') ->> 'claim_id')::uuid),
          'claim.under_review moves the claim and keeps the insurer''s reference');
select public.apply_monvelo_insurer_event('MOCK', 'evt-f', 'claim.settled',
  jsonb_build_object('claim_reference', pg_temp.r('claimA') ->> 'reference', 'settled_amount', '48000.00',
                     'payout_reference', 'PO-A'));
select ok((select c.status = 'SETTLED' and c.settled_amount = 48000 and f.status = 'CLOSED_BY_CLAIM'
             from public.monvelo_insurance_claims c join public.monvelo_financings f on f.id = c.financing_id
            where c.id = (pg_temp.r('claimA') ->> 'claim_id')::uuid),
          'claim.settled closes the financing CLOSED_BY_CLAIM');
select ok(not has_function_privilege('authenticated', 'public.record_monvelo_insurer_event(text,text,jsonb)', 'execute')
          and not has_function_privilege('authenticated', 'public.apply_monvelo_insurer_event(text,text,text,jsonb)', 'execute')
          and not has_function_privilege('authenticated', 'public.get_monvelo_insurer_provider(text)', 'execute')
          and has_function_privilege('service_role', 'public.apply_monvelo_insurer_event(text,text,text,jsonb)', 'execute')
          and has_function_privilege('service_role', 'public.get_monvelo_insurer_provider(text)', 'execute'),
          'the webhook''s RPCs are service_role only');

-- ── 12. Task 9: who may upload cover documents (4) ──────────────────────
create function pg_temp.can(p_user integer, p_tenant uuid, p_purpose text, p_subject uuid) returns boolean
language plpgsql as $$
declare v boolean;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), p_tenant);
  v := public.can_upload_monvelo_cover(p_purpose, p_subject);
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
select ok(pg_temp.can(4, pg_temp.t1(), 'SHOP_POLICY', '71000000-0000-0000-0000-000000000001')
          and pg_temp.can(12, pg_temp.t1(), 'SHOP_POLICY', '71000000-0000-0000-0000-000000000001'),
          'the area''s ASA and the zone''s ZSA may upload a shop''s policy');
select ok(not pg_temp.can(8, pg_temp.t1(), 'SHOP_POLICY', '71000000-0000-0000-0000-000000000001')
          and not pg_temp.can(7, pg_temp.t1(), 'SHOP_POLICY', '71000000-0000-0000-0000-000000000001')
          and not pg_temp.can(9, null, 'SHOP_POLICY', '71000000-0000-0000-0000-000000000001'),
          'the LM, the TENANT_ADMIN and an operator may not');
select ok(pg_temp.can(4, pg_temp.t1(), 'CLAIM_EVIDENCE', pg_temp.f('B'))
          and pg_temp.can(8, pg_temp.t1(), 'CLAIM_EVIDENCE', pg_temp.f('B'))
          and pg_temp.can(9, null, 'CLAIM_EVIDENCE', pg_temp.f('B'))
          and not pg_temp.can(7, pg_temp.t1(), 'CLAIM_EVIDENCE', pg_temp.f('B'))
          and not pg_temp.can(4, pg_temp.t1(), 'OTHER', pg_temp.f('B'))
          and not pg_temp.can(4, pg_temp.t1(), 'CLAIM_EVIDENCE', gen_random_uuid()),
          'loss evidence: the reporters report_monvelo_loss allows, and nobody for an unknown purpose or financing');
select ok(has_function_privilege('authenticated', 'public.can_upload_monvelo_cover(text,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.can_upload_monvelo_cover(text,uuid)', 'execute'),
          'the check is the gateway''s, on the caller''s JWT');

-- ── 13. final review: an operator resolves a FAILED declaration (2) ─────
select ok((public.complete_monvelo_declaration((select id from d where n = 'X2'), 'ACCEPTED', 'late', null) ->> 'ignored')::boolean,
          'the declare function cannot reopen a FAILED declaration');
select pg_temp.act_as(pg_temp.u(9), null);
select public.record_monvelo_declaration_outcome(pg_temp.k(400), (select id from d where n = 'X2'), 'ACCEPTED', 'POL-BY-HAND');
reset role;
select ok((select status = 'ACCEPTED' and insurer_reference = 'POL-BY-HAND'
             from public.monvelo_insurance_declarations where id = (select id from d where n = 'X2')),
          'an operator records the insurer''s answer on a FAILED declaration');

select * from finish();
rollback;
