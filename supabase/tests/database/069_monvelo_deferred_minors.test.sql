-- Two deferred minors (Step 1c/2 final review, 2026-11-04):
-- A. claims, hold allows and TM approvals refuse a request whose Lagos supply
--    day has ended, live, before monvelo-offer-sweep expires it; the late
--    funding route is untouched (R58);
-- B. a ZSM reads a nomination only when its shop's enrolment area lies in
--    their §18.3 reach.
begin;
create extension if not exists pgtap with schema extensions;

select plan(21);

-- ── fixtures (as postgres), tenant TEAFAIR plus NESTLE ──────────────────
-- zone 1 Lagos (ZSM 01) > territory 1 > area 1 · zone 2 Ogun (ZSM 02) > territory 2 > area 2
-- · zone 3 Oyo (no ZSM) > territory 3 > area 3
-- 03 TM (territory 1) · 11 ZSA (zone 1) · 04 ASA (area 1) · 08 TENANT_ADMIN
-- · 21 NESTLE ZSM · 31 member of agent A
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 2, 3, 4, 8, 11, 21, 31]) n;

create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.tu(n integer) returns uuid language sql as
  $$ select ('50000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ar(n integer) returns uuid language sql as
  $$ select ('60000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.tr(n integer) returns uuid language sql as
  $$ select ('40000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.zn(n integer) returns uuid language sql as
  $$ select ('30000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('99000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.t2() returns uuid language sql as $$ select '10000000-0000-0000-0000-000000000009'::uuid $$;
create function pg_temp.agent() returns uuid language sql as $$ select '81000000-0000-0000-0000-000000000001'::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.tu(integer), pg_temp.ar(integer), pg_temp.tr(integer),
  pg_temp.zn(integer), pg_temp.k(integer), pg_temp.t1(), pg_temp.t2(), pg_temp.agent() to authenticated;

insert into public.tenants (id, name, code) values (pg_temp.t2(), 'Nestle Nigeria', 'NESTLE_069');
insert into public.zones (id, tenant_id, zone_name, state_code) values
  (pg_temp.zn(1), pg_temp.t1(), 'Lagos', 'LA'),
  (pg_temp.zn(2), pg_temp.t1(), 'Ogun', 'OG'),
  (pg_temp.zn(3), pg_temp.t1(), 'Oyo', 'OY'),
  (pg_temp.zn(9), pg_temp.t2(), 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  (pg_temp.tr(1), pg_temp.t1(), pg_temp.zn(1), 'Ikeja'),
  (pg_temp.tr(2), pg_temp.t1(), pg_temp.zn(2), 'Abeokuta'),
  (pg_temp.tr(3), pg_temp.t1(), pg_temp.zn(3), 'Ibadan');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  (pg_temp.ar(1), pg_temp.t1(), pg_temp.tr(1), 'Allen'),
  (pg_temp.ar(2), pg_temp.t1(), pg_temp.tr(2), 'Kuto'),
  (pg_temp.ar(3), pg_temp.t1(), pg_temp.tr(3), 'Bodija');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  (pg_temp.tu(1), pg_temp.t1(), pg_temp.u(1), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(2), pg_temp.t1(), pg_temp.u(2), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(21), pg_temp.t2(), pg_temp.u(21), 'ZSM', null, null, null, null, 'ACTIVE', true);
update public.zones set zsm_id = pg_temp.u(1) where id = pg_temp.zn(1);
update public.zones set zsm_id = pg_temp.u(2) where id = pg_temp.zn(2);
update public.zones set zsm_id = pg_temp.u(21) where id = pg_temp.zn(9);
set local session_replication_role = replica;
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  (pg_temp.tu(3), pg_temp.t1(), pg_temp.u(3), 'TM', pg_temp.zn(1), pg_temp.tr(1), null, pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(11), pg_temp.t1(), pg_temp.u(11), 'ZSA', pg_temp.zn(1), null, null, pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(4), pg_temp.t1(), pg_temp.u(4), 'ASA', null, pg_temp.tr(1), pg_temp.ar(1), pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(8), pg_temp.t1(), pg_temp.u(8), 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true);

insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
values (pg_temp.agent(), 'POS A', 'OPAY', 'OP-069', '+2348031110691',
        extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography, 'a',
        '0123450691', '0691', '058', 'HOLDER A', 'K069', pg_temp.u(11), 'ACTIVE', 5000000, 1000000);
insert into public.monvelo_agent_members (agent_id, profile_id, status) values (pg_temp.agent(), pg_temp.u(31), 'ACTIVE');

-- a shop enrolled in an area, a PENDING trade order and a financing, straight in
create temp table fin (n text primary key, id uuid, shop uuid);
grant select on fin to authenticated;
create temp sequence finseq;
create function pg_temp.fin(p_n text, p_area integer, p_status text, p_supply date) returns uuid
language plpgsql as $$
declare
  v_fin  uuid := gen_random_uuid();
  v_seq  integer := nextval('finseq');
  v_shop uuid := gen_random_uuid();
  v_ord  uuid := gen_random_uuid();
begin
  insert into public.retail_shops (id, shop_name, contact_phone, density_category, location)
  values (v_shop, 'Shop ' || p_n, '+2348031169' || lpad(v_seq::text, 3, '0'), 'SUBURBAN',
          extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326));
  insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, retail_shop_id)
  values (v_ord, pg_temp.t1(), 'FIELD_SALES', pg_temp.tu(4), 50000, v_shop);
  insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version,
    consent_challenge_id)
  values (pg_temp.t1(), v_shop, pg_temp.ar(p_area), pg_temp.u(4), now(), 'MV-SHARE-2026-10', gen_random_uuid());
  insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
    principal, supply_date, status, approval_required)
  values (v_fin, pg_temp.t1(), 'MV-DEFMIN' || chr(65 + v_seq / 26) || chr(65 + v_seq % 26), v_shop, v_ord,
          pg_temp.ar(p_area), pg_temp.tr(p_area), pg_temp.u(4), 50000, p_supply, p_status, p_status = 'AWAITING_APPROVAL');
  insert into fin values (p_n, v_fin, v_shop);
  return v_fin;
end; $$;

-- F1 OFFERED, yesterday · F2 OFFERED, today · F3 AWAITING_APPROVAL, yesterday
-- · F4 HELD with a live hold, yesterday
select pg_temp.fin('F1', 1, 'OFFERED', public.monvelo_today() - 1);
select pg_temp.fin('F2', 1, 'OFFERED', public.monvelo_today());
select pg_temp.fin('F3', 1, 'AWAITING_APPROVAL', public.monvelo_today() - 1);
select pg_temp.fin('F4', 1, 'HELD', public.monvelo_today() - 1);
insert into public.monvelo_claim_holds (id, tenant_id, financing_id, agent_id, claimed_by, blocks,
  exposure_before, exposure_after, pledge_remaining, expires_at)
values ('82000000-0000-0000-0000-000000000004', pg_temp.t1(), (select id from fin where n = 'F4'), pg_temp.agent(),
        pg_temp.u(31), '{EXPOSURE_CAP}', 990000, 1040000, 1000000, now() + interval '15 minutes');

-- nominations: N1 area 1 (zone 1) · N2 area 2 (zone 2) · N3 area 3 (zone 3, no ZSM),
-- each on its own shop enrolled in that area (no financing)
create function pg_temp.nominate(n integer) returns void language plpgsql as $$
declare v_shop uuid := gen_random_uuid();
begin
  insert into public.retail_shops (id, shop_name, contact_phone, density_category, location)
  values (v_shop, 'Nominated ' || n, '+2348031179' || lpad(n::text, 3, '0'), 'SUBURBAN',
          extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326));
  insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version,
    consent_challenge_id)
  values (pg_temp.t1(), v_shop, pg_temp.ar(n), pg_temp.u(4), now(), 'MV-SHARE-2026-10', gen_random_uuid());
  insert into public.monvelo_agent_nominations (id, tenant_id, shop_id, nominated_name, nominated_phone_last4, pos_network, raised_by)
  values (('83000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, pg_temp.t1(), v_shop, 'Nominee ' || n,
          '000' || n, 'OPAY', pg_temp.u(4));
  insert into fin values ('S' || n, null, v_shop);
end; $$;
select pg_temp.nominate(n) from unnest(array[1, 2, 3]) n;
set local session_replication_role = origin;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
grant execute on function pg_temp.f(text) to authenticated;
-- the nominations the caller reads, as sorted numbers
create function pg_temp.noms() returns text language sql as $$
  select coalesce(string_agg(right(id::text, 1), ',' order by id), '') from public.monvelo_agent_nominations $$;
grant execute on function pg_temp.noms() to authenticated;

-- ── A. the supply day, live ─────────────────────────────────────────────
select has_function('public', 'monvelo_supply_day_ended', array['date'], 'monvelo_supply_day_ended exists');
select ok(not has_function_privilege('authenticated', 'public.monvelo_supply_day_ended(date)', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_supply_day_ended(date)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_supply_day_ended(date)', 'execute'),
  'it is internal');
select is(public.monvelo_supply_day_ended(public.monvelo_today()), false, 'today''s supply day has not ended');
select is(public.monvelo_supply_day_ended(public.monvelo_today() - 1), true, 'yesterday''s has');
select is(public.monvelo_supply_day_ended(null), true, 'a missing supply date counts as ended (fail closed)');

select pg_temp.act_as(pg_temp.u(31), pg_temp.t1());
select throws_ok(format($$select public.claim_monvelo_financing(%L, %L, %L, (select o.net_yield_bps from public.get_monvelo_offer_cover(%L, %L) o))$$, pg_temp.k(1), pg_temp.f('F1'), pg_temp.agent(), pg_temp.f('F1'), pg_temp.agent()),
  'P0001', 'this request''s supply day has ended',
  'a claim on yesterday''s request still OFFERED (the sweep has not run) is refused at once');
select throws_ok(format($$select public.claim_monvelo_financing(%L, %L, %L, (select o.net_yield_bps from public.get_monvelo_offer_cover(%L, %L) o))$$, pg_temp.k(2), pg_temp.f('F2'), pg_temp.agent(), pg_temp.f('F2'), pg_temp.agent()),
  'P0001', 'pledge enough funds for this area and day first',
  'today''s request passes the supply-day check and meets the next one');
reset role;
select is((select status from public.monvelo_financings where id = pg_temp.f('F1')), 'OFFERED',
  'the refused request is left for the sweep');

select isnt(public.monvelo_claim_refusal(
    (select f from public.monvelo_financings f where f.id = pg_temp.f('F1')),
    (select a from public.monvelo_agents a where a.id = pg_temp.agent()), pg_temp.u(31), null::public.monvelo_pledges, true),
  'this request''s supply day has ended', 'the late funding route has no supply-day bound (R58)');

select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok(format($$select public.approve_monvelo_financing(%L, %L)$$, pg_temp.k(3), pg_temp.f('F3')),
  'P0001', 'this request''s supply day has ended', 'the TM cannot approve yesterday''s request awaiting approval');
reset role;
select is((select status from public.monvelo_financings where id = pg_temp.f('F3')), 'AWAITING_APPROVAL',
  'and it stays for the sweep');

select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select throws_ok(format($$select public.decide_monvelo_claim_hold(%L, %L, true, %L)$$, pg_temp.k(4),
    '82000000-0000-0000-0000-000000000004', 'the shop pays back reliably'),
  'P0001', 'this request''s supply day has ended', 'a market maker cannot allow a hold on yesterday''s request');
select is(public.decide_monvelo_claim_hold(pg_temp.k(5), '82000000-0000-0000-0000-000000000004', false, null) ->> 'status',
  'DECLINED', 'declining it still works (it frees the request)');
reset role;

-- ── B. nominations by zone ──────────────────────────────────────────────
select has_function('public', 'my_zsm_monvelo_nomination_ids', '{}'::text[], 'my_zsm_monvelo_nomination_ids exists');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is(pg_temp.noms(), '1,3', 'ZSM 01 reads zone 1''s nomination and the uncovered zone 3''s, not zone 2''s');
select pg_temp.act_as(pg_temp.u(2), pg_temp.t1());
select is(pg_temp.noms(), '2,3', 'ZSM 02 reads zone 2''s and zone 3''s');
reset role;
update public.zones set zsm_id = pg_temp.u(1) where id = pg_temp.zn(3);
select pg_temp.act_as(pg_temp.u(2), pg_temp.t1());
select is(pg_temp.noms(), '2', 'once zone 3 has a ZSM, ZSM 02 no longer reads it (live)');
reset role;
set local session_replication_role = replica; -- the fixture's challenge ids are synthetic
update public.monvelo_shop_enrolments set status = 'WITHDRAWN', withdrawn_at = now()
 where shop_id = (select shop from fin where n = 'S1');
set local session_replication_role = origin;
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is(pg_temp.noms(), '1,3', 'a withdrawn enrolment keeps its nomination in its zone');
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select is(pg_temp.noms(), '1,2,3', 'a ZSA still reads the tenant''s nominations (unchanged)');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select is(pg_temp.noms(), '', 'the TENANT_ADMIN reads none (they name a candidate agent)');
select pg_temp.act_as(pg_temp.u(21), pg_temp.t2());
select is(pg_temp.noms(), '', 'another tenant''s ZSM reads none');
reset role;

select * from finish();
rollback;
