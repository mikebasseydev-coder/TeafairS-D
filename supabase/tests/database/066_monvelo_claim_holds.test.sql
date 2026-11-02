-- Addendum A6 §20 (2026-11-02) — the market-maker allowance.
-- Section A (Task 1): the hold. A claim blocked only by the ₦100,000 open
-- exposure cap, that would pass at monvelo_allowance_ceiling() (₦300,000), is
-- held for 15 minutes, exclusively (HELD); every other refusal stands. The
-- offers sweep lapses a hold at 15 minutes, and the supply-day expiry and the
-- stock sweep's cancellation end a HELD request as they end an OFFERED one.
begin;
create extension if not exists pgtap with schema extensions;

select plan(57);

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

-- ── fixtures (as postgres): TEAFAIR (T1) ────────────────────────────────
-- zone 1 Lagos > territory 1 Ikeja > area 1 Allen
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 08 LM (under 18 CSM)
-- 10 owner of S1..S7 · 11 ZSA (zone 1)
-- agents (member = same number):
--   31 X (90000 open; the hold, its lapse)  32 Y (another agent)  33 Z (290000 open)
--   34 D (the daily cap)  35 W (two holds)  36 S (a short pledge)  37 U (suspended)
--   38 F (the freeze)  39 V (declined)  40 E (the supply day and the stock sweep)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 7, 8, 10, 11, 18, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]) n;

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
  ('50000000-0000-0000-0000-000000000011', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000011', 'ZSA', '30000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

-- Tiger tea, 1000 a unit at trade: a 20000 request is 20 units
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, nafdac_number, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TIGER-1', 'Tiger tea', 'Tiger', 'Beverages', 'A7-1001', 1200, 1000);
insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
update public.monvelo_tenant_settings set limit_growth_bps = 0, max_limit = null, default_cure_days = 0
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001';
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Tiger', 500, 30, 500, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');

-- every agent about 400 m north of the shops at (3.35, 6.60)
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'POS ' || n, 'OPAY', 'OP-' || n, '+23480311100' || lpad(n::text, 2, '0'),
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
       '012345' || lpad(n::text, 4, '0'), lpad(n::text, 4, '0'), '058', 'HOLDER ' || n, 'K' || n,
       '20000000-0000-0000-0000-000000000004', 'ACTIVE', 5000000, 200000
  from generate_series(31, 40) n;
insert into public.monvelo_agent_members (agent_id, profile_id)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(31, 40) n;
-- each pledges 1000000 for Allen today; S only 10000
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), case n when 36 then 10000 else 1000000 end, case n when 36 then 10000 else 1000000 end,
       ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(31, 40) n;

-- S1..S7 (no preferred agent), enrolled in Allen, owner 10; S7 is frozen later
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text, preferred_agent_id)
select ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'Shop ' || n, '+23480311100' || n,
       '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street ' || n, null
  from generate_series(1, 7) n;
update public.retail_shops set shop_code = 'SH-AAAAA' || chr(65 + right(id::text, 1)::int) where id::text like '71000000-%';
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by)
select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000004'
  from generate_series(1, 7) n;
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
  $$ select ('d6600000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.t1() to authenticated;
create temp table fin (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on fin, res to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
grant execute on function pg_temp.f(text), pg_temp.r(text) to authenticated;
create function pg_temp.exposure(p_agent integer) returns numeric language sql as
  $$ select public.monvelo_agent_open_exposure(pg_temp.ag(p_agent)) $$;
create function pg_temp.status(p_n text) returns text language sql as
  $$ select status from public.monvelo_financings where id = pg_temp.f(p_n) $$;
create function pg_temp.hold_status(p_n text) returns text language sql as
  $$ select string_agg(status, ',' order by created_at) from public.monvelo_claim_holds where financing_id = pg_temp.f(p_n) $$;
create function pg_temp.holds_of(p_agent integer) returns integer language sql as
  $$ select count(*)::int from public.monvelo_claim_holds where agent_id = pg_temp.ag(p_agent) $$;

-- a fixture financing written straight to the table (the caller turns triggers
-- off around it): it counts toward exposure as a real one in that status would
create temp sequence synseq;
create function pg_temp.syn(p_n text, p_status text, p_agent integer, p_principal numeric,
                            p_shop integer default 99) returns uuid
language plpgsql as $$
declare
  v_id     uuid := gen_random_uuid();
  v_seq    integer := nextval('synseq');
  v_ref    text := 'MV-SYNTHB' || chr(65 + v_seq / 26) || chr(65 + v_seq % 26);
  v_funded boolean := p_status not in ('OFFERED', 'CLAIMED', 'CANCELLED', 'EXPIRED');
begin
  insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
    principal, supply_date, status, approval_required, funder_agent_id, paystack_reference, funded_at, outstanding)
  values (v_id, pg_temp.t1(), v_ref,
          ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid, gen_random_uuid(),
          '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
          pg_temp.u(1), p_principal, public.monvelo_today(), p_status, false,
          case when v_funded then pg_temp.ag(p_agent) end,
          case when v_funded then v_ref || '-1' end,
          case when v_funded then now() end,
          case when p_status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then p_principal end);
  insert into fin values (p_n, v_id);
  return v_id;
end; $$;

-- the ASA places p_qty Tiger tea for shop p_shop and requests its financing
create function pg_temp.raise(p_n text, p_key integer, p_shop integer, p_qty integer) returns uuid
language plpgsql as $$
declare v_o uuid; v_f uuid;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid,
          jsonb_build_array(jsonb_build_object('sku_code', 'TIGER-1', 'qty', p_qty))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into fin values (p_n, v_f);
  return v_f;
end; $$;
create function pg_temp.claim(p_key integer, p_agent integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.claim_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent));
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
create function pg_temp.claim_sql(p_key integer, p_agent integer, p_fin text) returns text language sql as $$
  select format('select public.claim_monvelo_financing(%L, %L, %L)', pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent)) $$;
grant execute on function pg_temp.claim_sql(integer, integer, text) to authenticated;

-- ── shape and security ──────────────────────────────────────────────────
select has_table('public', 'monvelo_claim_holds', 'monvelo_claim_holds exists');
select is(public.monvelo_allowance_ceiling(), 300000.00::numeric, 'the market-maker limit is one constant: 300000.00');
select ok((select provolatile = 'i' from pg_proc where oid = 'public.monvelo_allowance_ceiling()'::regprocedure)
      and not has_function_privilege('authenticated', 'public.monvelo_allowance_ceiling()', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_allowance_ceiling()', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_allowance_ceiling()', 'execute'),
  'the limit is IMMUTABLE and has no API grant');
select ok((select relrowsecurity from pg_class where oid = 'public.monvelo_claim_holds'::regclass)
      and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'monvelo_claim_holds')
      and not exists (select 1 from information_schema.role_table_grants
                       where table_schema = 'public' and table_name = 'monvelo_claim_holds'
                         and grantee in ('anon', 'authenticated', 'service_role'))
      and not exists (select 1 from information_schema.role_column_grants
                       where table_schema = 'public' and table_name = 'monvelo_claim_holds'
                         and grantee in ('anon', 'authenticated', 'service_role')),
  'holds: RLS on, no policy, nothing granted');
select ok(to_regprocedure('public.monvelo_claim_refusal(public.monvelo_financings,public.monvelo_agents,uuid,public.monvelo_pledges,boolean,numeric)') is not null
      and to_regprocedure('public.monvelo_claim_refusal(public.monvelo_financings,public.monvelo_agents,uuid,public.monvelo_pledges,boolean)') is null
      and (select pronargdefaults = 1 from pg_proc
            where oid = 'public.monvelo_claim_refusal(public.monvelo_financings,public.monvelo_agents,uuid,public.monvelo_pledges,boolean,numeric)'::regprocedure)
      and not has_function_privilege('authenticated',
            'public.monvelo_claim_refusal(public.monvelo_financings,public.monvelo_agents,uuid,public.monvelo_pledges,boolean,numeric)', 'execute'),
  'the refusal gains a trailing p_exposure_ceiling with a default, and no API grant');
select ok(to_regprocedure('public.monvelo_notify_hold(uuid)') is not null
      and not has_function_privilege('authenticated', 'public.monvelo_notify_hold(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_notify_hold(uuid)', 'execute'),
  'monvelo_notify_hold is internal');

-- ── held_when_only_the_exposure_cap_blocks (X: 90000 open) ─────────────
set local session_replication_role = replica; select pg_temp.syn('X0', 'FUNDED', 31, 90000); set local session_replication_role = origin;
select pg_temp.raise('H1', 100, 1, 20);
insert into res values ('H1', pg_temp.claim(102, 31, 'H1'));
select is(pg_temp.r('H1') ->> 'held', 'true', 'X at 90000 claiming 20000: the reply is held');
select is(pg_temp.status('H1') || ':' || pg_temp.hold_status('H1'), 'HELD:HELD', 'the financing and its one hold are HELD');
select is((select blocks::text || ':' || exposure_before || ':' || exposure_after || ':' || (agent_id = pg_temp.ag(31))
                  || ':' || (claimed_by = pg_temp.u(31)) || ':' || (decided_by is null) || ':' || (tenant_id = pg_temp.t1())
             from public.monvelo_claim_holds where financing_id = pg_temp.f('H1')),
  '{EXPOSURE_CAP}:90000.00:110000.00:true:true:true:true', 'the hold records the block and the figures');
select ok((select expires_at = now() + interval '15 minutes' and id = (pg_temp.r('H1') ->> 'hold_id')::uuid
                  and expires_at = (pg_temp.r('H1') ->> 'expires_at')::timestamptz
             from public.monvelo_claim_holds where financing_id = pg_temp.f('H1')),
  'it lasts 15 minutes; the reply carries its id and expiry');
select is((select count(*)::int from public.monvelo_financing_claims where financing_id = pg_temp.f('H1')), 0,
  'a hold is not a claim');
select is((select count(*)::int from public.audit_logs
            where entity_id = pg_temp.f('H1')::text and operation = 'claim_monvelo_financing'
              and after ->> 'status' = 'HELD' and tenant_id is null), 1,
  'one tenant-null audit row records the hold');
select is(pg_temp.claim(102, 31, 'H1'), pg_temp.r('H1'), 'the same key replays the held reply');

-- ── held_counts_toward_exposure ─────────────────────────────────────────
select is(pg_temp.exposure(31), 110000::numeric, 'a HELD financing counts toward its agent''s exposure at principal');

-- ── the_hold_is_exclusive (Y) ───────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(32), null);
select throws_ok(pg_temp.claim_sql(110, 32, 'H1'), 'P0001', 'this request is no longer open',
  'another agent cannot claim a HELD request');
select is((select count(*)::int from public.monvelo_open_offers(pg_temp.ag(32)) o where o.financing_id = pg_temp.f('H1')), 0,
  'the open offers do not list it');
reset role;

-- ── refused_above_300000 (Z: 290000 open) ───────────────────────────────
set local session_replication_role = replica; select pg_temp.syn('Z0', 'FUNDED', 33, 290000); set local session_replication_role = origin;
select pg_temp.raise('R1', 120, 2, 20);
select pg_temp.act_as(pg_temp.u(33), null);
select throws_ok(pg_temp.claim_sql(122, 33, 'R1'), 'P0001', 'this request would take your open exposure above ₦100,000',
  '290000 open + 20000 passes 300000: refused as today');
reset role;
select is(pg_temp.status('R1') || ':' || pg_temp.holds_of(33), 'OFFERED:0', 'no hold');

-- ── daily_cap_is_never_held (D) ─────────────────────────────────────────
set local session_replication_role = replica; select pg_temp.syn('D0', 'FUNDED', 34, 10000); set local session_replication_role = origin;
update public.monvelo_agents set per_financing_cap = 25000, daily_cap = 25000 where id = pg_temp.ag(34);
select pg_temp.raise('D1', 130, 3, 20);
select pg_temp.act_as(pg_temp.u(34), null);
select throws_ok(pg_temp.claim_sql(132, 34, 'D1'), 'P0001', 'this request would pass your daily cap',
  'the daily cap alone (exposure fine) is refused as today');
reset role;
select is(pg_temp.status('D1') || ':' || pg_temp.holds_of(34), 'OFFERED:0', 'no hold');
set local session_replication_role = replica; select pg_temp.syn('D00', 'FUNDED', 34, 85000); set local session_replication_role = origin;
update public.monvelo_agents set per_financing_cap = 100000, daily_cap = 100000 where id = pg_temp.ag(34);
select is(pg_temp.exposure(34), 95000::numeric, 'fixture: D holds 95000 open, all funded today');
select pg_temp.act_as(pg_temp.u(34), null);
select throws_ok(pg_temp.claim_sql(133, 34, 'D1'), 'P0001', 'this request would pass your daily cap',
  'both caps block: refused with the daily cap''s message');
reset role;
select is(pg_temp.status('D1') || ':' || pg_temp.holds_of(34), 'OFFERED:0', 'still no hold');

-- ── other_refusals_are_never_held (S, U, F: 90000 open each) ───────────
set local session_replication_role = replica;
select pg_temp.syn('S0', 'FUNDED', 36, 90000), pg_temp.syn('U0', 'FUNDED', 37, 90000), pg_temp.syn('F0', 'FUNDED', 38, 90000);
set local session_replication_role = origin;
select pg_temp.raise('O1', 140, 4, 20);
select pg_temp.act_as(pg_temp.u(36), null);
select throws_ok(pg_temp.claim_sql(142, 36, 'O1'), 'P0001', 'pledge enough funds for this area and day first',
  'a short pledge is refused as today');
reset role;
update public.monvelo_agents set status = 'SUSPENDED' where id = pg_temp.ag(37);
select pg_temp.act_as(pg_temp.u(37), null);
select throws_ok(pg_temp.claim_sql(143, 37, 'O1'), 'P0001', 'the agent is not active',
  'a suspended agent is refused as today');
reset role;
select pg_temp.raise('F1', 150, 7, 20);
set local session_replication_role = replica; select pg_temp.syn('F7', 'DEFAULTED_WITH_LATE_CHARGE', 38, 5000, 7); set local session_replication_role = origin;
select pg_temp.act_as(pg_temp.u(38), null);
select throws_ok(pg_temp.claim_sql(152, 38, 'F1'), 'P0001',
  'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared',
  'the default freeze is refused as today');
reset role;
select is(pg_temp.status('O1') || ':' || pg_temp.status('F1') || ':' || (pg_temp.holds_of(36) + pg_temp.holds_of(37) + pg_temp.holds_of(38)),
  'OFFERED:OFFERED:0', 'none of them is held');

-- ── two_holds_respect_300000 (W: 100000 open; Review Focus 3) ──────────
set local session_replication_role = replica; select pg_temp.syn('W0', 'FUNDED', 35, 100000); set local session_replication_role = origin;
select pg_temp.raise('T1', 160, 5, 150);
select is(pg_temp.claim(162, 35, 'T1') ->> 'held', 'true', 'W at 100000 claiming 150000 is held (250000)');
select pg_temp.raise('T2', 170, 6, 60);
select pg_temp.act_as(pg_temp.u(35), null);
select throws_ok(pg_temp.claim_sql(172, 35, 'T2'), 'P0001', 'this request would take your open exposure above ₦100,000',
  'a second claim of 60000 would pass 300000 with the first hold counted: refused');
reset role;
select is(pg_temp.exposure(35) || ':' || pg_temp.holds_of(35) || ':' || pg_temp.status('T2'), '250000.00:1:OFFERED',
  'one hold, 250000 open, T2 still OFFERED');

-- ── a_hold_lapses_at_15_minutes (X) ─────────────────────────────────────
set local session_replication_role = replica;
update public.monvelo_claim_holds set created_at = now() - interval '16 minutes', expires_at = now() - interval '1 minute'
 where financing_id = pg_temp.f('H1');
set local session_replication_role = origin;
select public.monvelo_sweep_offers();
select is(pg_temp.status('H1') || ':' || pg_temp.hold_status('H1'), 'OFFERED:LAPSED', 'the sweep lapses the hold; H1 is OFFERED');
select ok((select decided_by is null and decided_at is not null from public.monvelo_claim_holds where financing_id = pg_temp.f('H1')),
  'a lapse has no decider');
select is((select count(*)::int || ':' || count(*) filter (where tenant_id is null) from public.audit_logs
            where entity_id = pg_temp.f('H1')::text and operation = 'monvelo_sweep_offers'),
  '1:1', 'one audit row for the lapse, tenant-null');
select is(pg_temp.exposure(31), 90000::numeric, 'the lapsed hold no longer counts');
select pg_temp.act_as(pg_temp.u(31), null);
select throws_ok(pg_temp.claim_sql(104, 31, 'H1'), 'P0001', 'this request was already held for you',
  'the same agent, still blocked by the cap, is not held again');
reset role;
select is(pg_temp.hold_status('H1'), 'LAPSED', 'no second hold');
set local session_replication_role = replica;
update public.monvelo_financings set status = 'REPAID_WITHIN_WINDOW', outstanding = 0, closed_at = now() where id = pg_temp.f('X0');
set local session_replication_role = origin;
select is(pg_temp.claim(105, 31, 'H1') ->> 'status', 'CLAIMED', 'with the cap passing on its own, X claims H1');

-- ── a_declined_agent_is_barred (V) ──────────────────────────────────────
select pg_temp.raise('V1', 180, 2, 20);
set local session_replication_role = replica;
insert into public.monvelo_claim_holds (tenant_id, financing_id, agent_id, claimed_by, blocks, exposure_before, exposure_after,
                                        pledge_remaining, expires_at, status, decided_by, decided_at, reason)
values (pg_temp.t1(), pg_temp.f('V1'), pg_temp.ag(39), pg_temp.u(39), '{EXPOSURE_CAP}', 90000, 110000, 1000000,
        now() + interval '15 minutes', 'DECLINED', pg_temp.u(1), now(), null);
set local session_replication_role = origin;
select pg_temp.act_as(pg_temp.u(39), null);
select throws_ok(pg_temp.claim_sql(182, 39, 'V1'), 'P0001', 'a market maker declined your claim on this request',
  'a declined agent may not claim the request again');
reset role;

-- ── supply_day_end_lapses_the_hold (E; Review Focus 1) ─────────────────
set local session_replication_role = replica; select pg_temp.syn('E0', 'FUNDED', 40, 90000); set local session_replication_role = origin;
select pg_temp.raise('SD', 190, 3, 20);
select is(pg_temp.claim(192, 40, 'SD') ->> 'held', 'true', 'fixture: E holds SD');
set local session_replication_role = replica;
update public.monvelo_financings set supply_date = public.monvelo_today() - 1 where id = pg_temp.f('SD');
set local session_replication_role = origin;
select public.monvelo_sweep_offers();
select is(pg_temp.status('SD') || ':' || pg_temp.hold_status('SD') || ':'
          || (select o.status from public.orders o join public.monvelo_financings f on f.order_id = o.id where f.id = pg_temp.f('SD')),
  'EXPIRED:LAPSED:CANCELLED', 'its supply day ended: EXPIRED as an OFFERED one, the hold LAPSED, the order cancelled');

-- ── stock_sweep_ends_the_hold (E; Review Focus 2) ──────────────────────
select pg_temp.raise('SS', 200, 4, 20);
select is(pg_temp.claim(202, 40, 'SS') ->> 'held', 'true', 'fixture: E holds SS');
set local session_replication_role = replica;
update public.stock_reservations r set expires_at = now() - interval '1 second'
  from public.monvelo_financings f where f.id = pg_temp.f('SS') and r.order_id = f.order_id;
set local session_replication_role = origin;
select ok(public.stock_reservation_sweep() >= 1, 'the stock sweep cancels SS''s unpaid trade order');
select public.monvelo_sweep_offers();
select is(pg_temp.status('SS') || ':' || pg_temp.hold_status('SS') || ':'
          || (select after ->> 'reason' from public.audit_logs
               where entity_id = pg_temp.f('SS')::text and operation = 'monvelo_sweep_offers' and after ->> 'status' = 'EXPIRED'),
  'EXPIRED:LAPSED:ORDER_NOT_PENDING', 'SS leaves HELD as an OFFERED one would; the hold LAPSED');

-- ── holds_are_private ───────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'a TENANT_ADMIN cannot read holds');
select pg_temp.act_as(pg_temp.u(18), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'a CSM cannot read holds');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'a ZSM cannot read holds');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'a TM cannot read holds');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'an LM cannot read holds');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'an ASA cannot read holds');
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'a ZSA cannot read holds');
select pg_temp.act_as(pg_temp.u(35), null);
select throws_ok($$select count(*) from public.monvelo_claim_holds$$, '42501', null, 'the agent''s own member cannot read holds');
reset role;
select is((select count(*)::int from public.audit_logs a, generate_series(31, 40) n
            where a.tenant_id is not null
              and (coalesce(a.before::text, '') || coalesce(a.after::text, '')) like '%' || pg_temp.ag(n)::text || '%'), 0,
  'no audit row naming an agent carries a tenant id');

-- ── the_hold_row_is_insert_only ─────────────────────────────────────────
select throws_ok(format($$update public.monvelo_claim_holds set agent_id = %L where financing_id = %L$$, pg_temp.ag(32), pg_temp.f('T1')),
  'P0001', null, 'a HELD hold''s identity never changes');
select throws_ok(format($$update public.monvelo_claim_holds set status = 'HELD', decided_at = null where financing_id = %L$$, pg_temp.f('SD')),
  'P0001', null, 'a LAPSED hold never moves again');
select lives_ok(format($$update public.monvelo_claim_holds set status = 'DECLINED', decided_by = %L, decided_at = now()
                          where financing_id = %L$$, pg_temp.u(1), pg_temp.f('T1')),
  'the one final move HELD -> DECLINED is allowed');
select throws_ok(format($$update public.monvelo_claim_holds set status = 'LAPSED' where financing_id = %L$$, pg_temp.f('T1')),
  'P0001', null, 'and only once');
select throws_ok(format($$delete from public.monvelo_claim_holds where financing_id = %L$$, pg_temp.f('T1')),
  'P0001', 'Monvelo records are never deleted', 'a hold is never deleted');

select * from finish();
rollback;
