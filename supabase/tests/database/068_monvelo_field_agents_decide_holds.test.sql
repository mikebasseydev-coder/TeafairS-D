-- Addendum A6 §22 (user decisions 2026-11-03): field agents decide holds.
-- The ZSA of the zone and the ASA of the area decide; the ZSM in reach
-- oversees read-only and decides only when no field agent is eligible; the
-- agent's recruiter may decide; the raiser and members of the agent never.
begin;
create extension if not exists pgtap with schema extensions;

select plan(34);

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- zone 1 (Lagos) > territory 1 > areas 1 Allen, 2 Opebi · zone 2 (Ogun) > territory 2 > area 3 Kuto
-- 01 ZSM (zone 1) · 02 ZSM (zone 2) · 11 ZSA (zone 1) · 12 ZSA (zone 2)
-- 04 ASA (Allen, the usual raiser) · 05 ASA (Allen) · 06 ASA (Opebi) · 07 ASA (Kuto, added later)
-- 31 member of agent A (recruited by ZSA 11) · 32 member of agent B, whose members also include 11 and 05
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 2, 4, 5, 6, 7, 11, 12, 31, 32]) n;

create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.tu(n integer) returns uuid language sql as
  $$ select ('50000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(c text) returns uuid language sql as
  $$ select ('81000000-0000-0000-0000-' || lpad((ascii(c) - 64)::text, 12, '0'))::uuid $$;
create function pg_temp.ar(n integer) returns uuid language sql as
  $$ select ('60000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('99000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.tu(integer), pg_temp.ag(text), pg_temp.ar(integer),
  pg_temp.t1(), pg_temp.k(integer) to authenticated;

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', pg_temp.t1(), 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', pg_temp.t1(), 'Ogun', 'OG');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', pg_temp.t1(), '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', pg_temp.t1(), '30000000-0000-0000-0000-000000000002', 'Abeokuta');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  (pg_temp.ar(1), pg_temp.t1(), '40000000-0000-0000-0000-000000000001', 'Allen'),
  (pg_temp.ar(2), pg_temp.t1(), '40000000-0000-0000-0000-000000000001', 'Opebi'),
  (pg_temp.ar(3), pg_temp.t1(), '40000000-0000-0000-0000-000000000002', 'Kuto');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  (pg_temp.tu(1), pg_temp.t1(), pg_temp.u(1), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(2), pg_temp.t1(), pg_temp.u(2), 'ZSM', null, null, null, null, 'ACTIVE', true);
update public.zones set zsm_id = pg_temp.u(1) where id = '30000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = pg_temp.u(2) where id = '30000000-0000-0000-0000-000000000002';
set local session_replication_role = replica;
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  (pg_temp.tu(11), pg_temp.t1(), pg_temp.u(11), 'ZSA', '30000000-0000-0000-0000-000000000001', null, null, pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(12), pg_temp.t1(), pg_temp.u(12), 'ZSA', '30000000-0000-0000-0000-000000000002', null, null, pg_temp.tu(2), 'ACTIVE', true),
  (pg_temp.tu(4), pg_temp.t1(), pg_temp.u(4), 'ASA', null, '40000000-0000-0000-0000-000000000001', pg_temp.ar(1), pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(5), pg_temp.t1(), pg_temp.u(5), 'ASA', null, '40000000-0000-0000-0000-000000000001', pg_temp.ar(1), pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(6), pg_temp.t1(), pg_temp.u(6), 'ASA', null, '40000000-0000-0000-0000-000000000001', pg_temp.ar(2), pg_temp.tu(1), 'ACTIVE', true);

insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select pg_temp.ag(c), 'POS ' || c, 'OPAY', 'OP-' || c, '+234803111000' || n,
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography, 'a',
       '012345000' || n, '000' || n, '058', 'HOLDER ' || c, 'K' || c, pg_temp.u(11), 'ACTIVE', 5000000, 1000000
  from (values ('A', 1), ('B', 2)) v (c, n);
insert into public.monvelo_agent_members (agent_id, profile_id, status) values
  (pg_temp.ag('A'), pg_temp.u(31), 'ACTIVE'),
  (pg_temp.ag('B'), pg_temp.u(32), 'ACTIVE'),
  (pg_temp.ag('B'), pg_temp.u(11), 'ACTIVE'),
  (pg_temp.ag('B'), pg_temp.u(5), 'REVOKED');

-- a HELD request and its HELD hold, straight in
create temp table hold (n text primary key, id uuid, fin uuid);
grant select on hold to authenticated;
create temp sequence synseq;
create function pg_temp.held(p_n text, p_area integer, p_raiser integer, p_agent text) returns uuid
language plpgsql as $$
declare
  v_fin  uuid := gen_random_uuid();
  v_hold uuid := gen_random_uuid();
  v_seq  integer := nextval('synseq');
  v_shop uuid := gen_random_uuid();
  v_ord  uuid := gen_random_uuid();
begin
  -- a real shop (the view joins it) and order (decide's update re-checks the FK)
  insert into public.retail_shops (id, shop_name, contact_phone, density_category, location)
  values (v_shop, 'Shop ' || p_n, '+2348031119' || lpad(v_seq::text, 3, '0'), 'SUBURBAN',
          extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326));
  insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, retail_shop_id)
  values (v_ord, pg_temp.t1(), 'FIELD_SALES', pg_temp.tu(4), 50000, v_shop);
  insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version,
    consent_challenge_id)
  values (pg_temp.t1(), v_shop, pg_temp.ar(p_area), pg_temp.u(4), now(), 'MV-SHARE-2026-10', gen_random_uuid());
  insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
    principal, supply_date, status, approval_required)
  values (v_fin, pg_temp.t1(), 'MV-FIELDS' || chr(65 + v_seq / 26) || chr(65 + v_seq % 26), v_shop, v_ord,
          pg_temp.ar(p_area),
          case when p_area = 3 then '40000000-0000-0000-0000-000000000002'::uuid else '40000000-0000-0000-0000-000000000001'::uuid end,
          pg_temp.u(p_raiser), 50000, public.monvelo_today(), 'HELD', false);
  insert into public.monvelo_claim_holds (id, tenant_id, financing_id, agent_id, claimed_by, blocks,
    exposure_before, exposure_after, pledge_remaining, expires_at)
  values (v_hold, pg_temp.t1(), v_fin, pg_temp.ag(p_agent), pg_temp.u(31), '{EXPOSURE_CAP}', 990000, 1040000, 1000000,
          now() + interval '15 minutes');
  insert into hold values (p_n, v_hold, v_fin);
  return v_hold;
end; $$;

-- H1 Allen, raised by ASA 04, agent A (recruited by ZSA 11)
-- H2 Opebi, raised by ZSA 11
-- H3 Kuto (zone 2), raised by ZSA 12; no ASA in Kuto
-- H4 Allen, raised by ASA 04, agent B (ZSA 11 a member, ASA 05 a revoked member)
-- H5 Kuto, raised by ZSA 12 (for the live fallback)
select pg_temp.held('H1', 1, 4, 'A');
select pg_temp.held('H2', 2, 11, 'A');
select pg_temp.held('H3', 3, 12, 'A');
select pg_temp.held('H4', 1, 4, 'B');
select pg_temp.held('H5', 3, 12, 'A');
set local session_replication_role = origin;

create function pg_temp.h(p_n text) returns uuid language sql as $$ select id from hold where n = p_n $$;
grant execute on function pg_temp.h(text) to authenticated;

-- the deciders and viewers of a hold, as sorted user numbers
create function pg_temp.who(p_fn text, p_n text) returns text language plpgsql as $$
declare v text;
begin
  execute format($f$
    select string_agg(right(x::text, 2), ',' order by x)
      from public.%I(%L, (select f.area_id from public.monvelo_financings f where f.id = (select fin from hold where n = %L)),
                         (select f.raised_by from public.monvelo_financings f where f.id = (select fin from hold where n = %L)),
                         (select h.agent_id from public.monvelo_claim_holds h where h.id = (select id from hold where n = %L))) x
  $f$, p_fn, pg_temp.t1(), p_n, p_n, p_n) into v;
  return v;
end; $$;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- can_decide of a hold in p_user's list (null when the hold is not listed)
create function pg_temp.listed(p_user integer, p_n text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  select string_agg(l.can_decide::text, ',') into v from public.list_monvelo_claim_holds() l where l.hold_id = pg_temp.h(p_n);
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
create function pg_temp.get_sql(p_user integer, p_n text) returns text language sql as $$
  select format('select pg_temp.act_as(%L, %L); select * from public.get_monvelo_claim_hold(%L)',
                pg_temp.u(p_user), pg_temp.t1(), pg_temp.h(p_n)) $$;
create function pg_temp.decide_sql(p_user integer, p_key integer, p_n text, p_allow boolean, p_reason text) returns text
language sql as $$
  select format('select pg_temp.act_as(%L, %L); select public.decide_monvelo_claim_hold(%L, %L, %L, %L)',
                pg_temp.u(p_user), pg_temp.t1(), pg_temp.k(p_key), pg_temp.h(p_n), p_allow, p_reason) $$;
create function pg_temp.decide(p_user integer, p_key integer, p_n text, p_allow boolean, p_reason text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  v := public.decide_monvelo_claim_hold(pg_temp.k(p_key), pg_temp.h(p_n), p_allow, p_reason);
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
grant execute on function pg_temp.listed(integer, text), pg_temp.get_sql(integer, text),
  pg_temp.decide_sql(integer, integer, text, boolean, text), pg_temp.decide(integer, integer, text, boolean, text)
  to authenticated;

-- ── shape ───────────────────────────────────────────────────────────────
select has_function('public', 'monvelo_hold_viewers', array['uuid', 'uuid', 'uuid', 'uuid'], 'monvelo_hold_viewers exists');
select ok(not has_function_privilege('authenticated', 'public.monvelo_hold_viewers(uuid, uuid, uuid, uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.monvelo_hold_market_makers(uuid, uuid, uuid, uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_hold_viewers(uuid, uuid, uuid, uuid)', 'execute'),
  'both helpers are internal');
select ok(has_function_privilege('authenticated', 'public.list_monvelo_claim_holds()', 'execute')
      and has_function_privilege('authenticated', 'public.get_monvelo_claim_hold(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.decide_monvelo_claim_hold(uuid, uuid, boolean, text)', 'execute')
      and not has_function_privilege('anon', 'public.list_monvelo_claim_holds()', 'execute'),
  'the three RPCs keep their grants');
select ok((select pg_get_function_result('public.list_monvelo_claim_holds()'::regprocedure) like '%reason text, can_decide boolean)')
      and (select pg_get_function_result('public.get_monvelo_claim_hold(uuid)'::regprocedure) like '%reason text, can_decide boolean)'),
  'the view ends with can_decide');

-- ── who decides, who sees ───────────────────────────────────────────────
select is(pg_temp.who('monvelo_hold_market_makers', 'H1'), '05,11',
  'H1 (Allen, raised by ASA 04): the zone''s ZSA 11 (who recruited the agent) and Allen''s other ASA 05 decide; not the ZSM');
select is(pg_temp.who('monvelo_hold_viewers', 'H1'), '01,05,11', 'H1 is seen by the deciders and the zone''s ZSM 01');
select is(pg_temp.who('monvelo_hold_market_makers', 'H2'), '06',
  'H2 (Opebi, raised by ZSA 11): the raiser is barred; Opebi''s ASA 06 decides');
select is(pg_temp.who('monvelo_hold_market_makers', 'H3'), '02',
  'H3 (Kuto, raised by ZSA 12, no ASA): no field agent is eligible, so the zone''s ZSM 02 decides');
select is(pg_temp.who('monvelo_hold_viewers', 'H3'), '02', 'and sees it');
select is(pg_temp.who('monvelo_hold_market_makers', 'H4'), '01',
  'H4 (agent B has ZSA 11 as a member and ASA 05 as a revoked one; 04 raised): no field agent is eligible, the ZSM 01 decides');
select ok(pg_temp.who('monvelo_hold_viewers', 'H4') !~ '(04|05|11)', 'and the barred field agents do not even see it');

-- ── the ZSM oversees H1 read-only ───────────────────────────────────────
select is(pg_temp.listed(1, 'H1'), 'false', 'the ZSM lists H1 with can_decide false');
select lives_ok(pg_temp.get_sql(1, 'H1'), 'the ZSM opens H1');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.decide_sql(1, 1, 'H1', false, null), '42501', 'this hold is not yours to decide',
  'the ZSM cannot decline H1');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.decide_sql(1, 2, 'H1', true, 'I know this shop well'), '42501', 'this hold is not yours to decide',
  'nor allow it');
select set_config('role', 'postgres', true);

-- ── field agents decide H1 ──────────────────────────────────────────────
select is(pg_temp.listed(11, 'H1'), 'true', 'the ZSA lists H1 with can_decide true');
select is(pg_temp.listed(5, 'H1'), 'true', 'so does Allen''s other ASA');
select is(pg_temp.listed(4, 'H1'), null, 'the raiser does not see H1');
select is(pg_temp.listed(6, 'H1'), null, 'Opebi''s ASA does not see an Allen hold');
select is(pg_temp.listed(12, 'H1'), null, 'zone 2''s ZSA does not see a zone 1 hold');
select is(pg_temp.listed(2, 'H1'), null, 'zone 2''s ZSM does not see a zone 1 hold');
select throws_ok(pg_temp.get_sql(6, 'H1'), '42501', 'this hold is not yours to see', 'Opebi''s ASA cannot open H1');
select set_config('role', 'postgres', true);
select is(pg_temp.decide(11, 3, 'H1', false, 'not this time') ->> 'status', 'DECLINED',
  'the ZSA who recruited the agent declines H1 (the recruiter is not barred)');
select is((select status || ':' || decided_by::text from public.monvelo_claim_holds where id = pg_temp.h('H1')),
  'DECLINED:' || pg_temp.u(11)::text, 'the hold records the ZSA');
select is(pg_temp.listed(1, 'H1'), 'false', 'decided, the ZSM still sees it, read-only');
select is(pg_temp.listed(11, 'H1'), 'false', 'and a decided hold is no longer decidable by anyone');

-- ── H2: a ZSA raiser is barred ──────────────────────────────────────────
select is(pg_temp.listed(11, 'H2'), null, 'the ZSA who raised H2 does not see it');
select is(pg_temp.listed(6, 'H2'), 'true', 'Opebi''s ASA decides it');

-- ── H3: the ZSM steps in ────────────────────────────────────────────────
select is(pg_temp.listed(2, 'H3'), 'true', 'with no field agent eligible, zone 2''s ZSM lists H3 as decidable');
select is(pg_temp.decide(2, 4, 'H3', false, null) ->> 'status', 'DECLINED', 'and declines it');

-- ── H5: the fallback is live ────────────────────────────────────────────
select is(pg_temp.listed(2, 'H5'), 'true', 'H5: the ZSM may decide while Kuto has no ASA');
set local session_replication_role = replica;
insert into public.tenant_users (tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary)
values (pg_temp.t1(), pg_temp.u(7), 'ASA', null, '40000000-0000-0000-0000-000000000002', pg_temp.ar(3), pg_temp.tu(2), 'ACTIVE', true);
set local session_replication_role = origin;
select is(pg_temp.who('monvelo_hold_market_makers', 'H5'), '07', 'once Kuto has an ACTIVE ASA, that ASA decides H5');
select is(pg_temp.listed(2, 'H5'), 'false', 'and the ZSM is back to read-only');
select throws_ok(pg_temp.decide_sql(2, 5, 'H5', false, null), '42501', 'this hold is not yours to decide',
  'so the ZSM can no longer decide H5');
select set_config('role', 'postgres', true);

select * from finish();
rollback;
