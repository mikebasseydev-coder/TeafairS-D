-- A6 §19.4, §20, §21.2; audit finding G1: get_monvelo_agent_exposure, the
-- agent's exposure meter, and the internal monvelo_agent_day_used.
-- Members of the agent and Monvelo staff read it; every tenant role is 42501.
begin;
create extension if not exists pgtap with schema extensions;

select plan(39);

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 04 ASA · 07 TENANT_ADMIN
-- 31 member of A · 32 member of B (unprovisioned) · 33 member of A's rival C and of D
-- 34 MONVELO_OPERATOR · 35 a REVOKED member of A · 36 a profile with no role at all
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 4, 7, 31, 32, 33, 34, 35, 36]) n;
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000034';

insert into public.tenant_users (tenant_id, profile_id, role, status, is_primary) values
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', 'ACTIVE', true),
  ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', 'ACTIVE', true);

create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(c text) returns uuid language sql as
  $$ select ('81000000-0000-0000-0000-' || lpad((ascii(c) - 64)::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.ag(text), pg_temp.t1() to authenticated;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- the meter as one line, read as p_user
create function pg_temp.meter(p_user integer, p_agent text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  select string_agg(concat_ws('|', e.open_exposure, e.platform_ceiling, e.allowance_ceiling, e.remaining_room,
                              e.active_commitments_count, e.personal_daily_limit, e.per_financing_limit,
                              e.today_utilized_limit, e.today_remaining_limit), ';')
    into v
    from public.get_monvelo_agent_exposure(case when p_agent is null then null else pg_temp.ag(p_agent) end) e;
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
create function pg_temp.call_sql(p_agent text) returns text language sql as $$
  select case when p_agent is null then 'select * from public.get_monvelo_agent_exposure()'
              else format('select * from public.get_monvelo_agent_exposure(%L)', pg_temp.ag(p_agent)) end $$;
grant execute on function pg_temp.meter(integer, text), pg_temp.call_sql(text) to authenticated;

-- agents, members and financings straight in (no state machine, no FKs)
set local session_replication_role = replica;
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
values
  (pg_temp.ag('A'), 'POS A', 'OPAY', 'OP-A', '+2348031110001', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography,
   'a', '0123450001', '0001', '058', 'HOLDER A', 'KA', pg_temp.u(4), 'ACTIVE', 600000, 200000),
  (pg_temp.ag('C'), 'POS C', 'OPAY', 'OP-C', '+2348031110003', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography,
   'a', '0123450003', '0003', '058', 'HOLDER C', 'KC', pg_temp.u(4), 'SUSPENDED', 900000, 100000),
  (pg_temp.ag('D'), 'POS D', 'OPAY', 'OP-D', '+2348031110004', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography,
   'a', '0123450004', '0004', '058', 'HOLDER D', 'KD', pg_temp.u(4), 'ACTIVE', 0, 0);
-- B is registered without caps: the columns' defaults (§21.2)
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status)
values
  (pg_temp.ag('B'), 'POS B', 'OPAY', 'OP-B', '+2348031110002', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography,
   'a', '0123450002', '0002', '058', 'HOLDER B', 'KB', pg_temp.u(4), 'ACTIVE');
insert into public.monvelo_agent_members (agent_id, profile_id, status) values
  (pg_temp.ag('A'), pg_temp.u(31), 'ACTIVE'),
  (pg_temp.ag('B'), pg_temp.u(32), 'ACTIVE'),
  (pg_temp.ag('C'), pg_temp.u(33), 'ACTIVE'),
  (pg_temp.ag('D'), pg_temp.u(33), 'ACTIVE'),
  (pg_temp.ag('A'), pg_temp.u(35), 'REVOKED');

create temp sequence synseq;
create function pg_temp.syn(p_status text, p_agent text, p_principal numeric, p_outstanding numeric default null,
                            p_funded_at timestamptz default now()) returns uuid
language plpgsql as $$
declare
  v_id     uuid := gen_random_uuid();
  v_seq    integer := nextval('synseq');
  v_ref    text := 'MV-EXPOSE' || chr(65 + v_seq / 26) || chr(65 + v_seq % 26);
  v_funded boolean := p_status not in ('OFFERED', 'HELD', 'CLAIMED');
begin
  insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
    principal, supply_date, status, approval_required, funder_agent_id, paystack_reference, funded_at, outstanding,
    claimed_by_agent_id, claimed_by, claim_expires_at, pledge_id)
  values (v_id, pg_temp.t1(), v_ref, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
          pg_temp.u(4), p_principal, public.monvelo_today(), p_status, false,
          case when v_funded then pg_temp.ag(p_agent) end,
          case when v_funded then v_ref || '-1' end,
          case when v_funded then p_funded_at end,
          p_outstanding,
          case when p_status = 'CLAIMED' then pg_temp.ag(p_agent) end,
          case when p_status = 'CLAIMED' then pg_temp.u(31) end,
          case when p_status = 'CLAIMED' then now() + interval '15 minutes' end,
          case when p_status = 'CLAIMED' then gen_random_uuid() end);
  if p_status = 'HELD' then
    insert into public.monvelo_claim_holds (tenant_id, financing_id, agent_id, claimed_by, blocks,
      exposure_before, exposure_after, pledge_remaining, expires_at)
    values (pg_temp.t1(), v_id, pg_temp.ag(p_agent), pg_temp.u(31), '{EXPOSURE_CAP}', 0, p_principal, 1000000,
            now() + interval '15 minutes');
  end if;
  return v_id;
end; $$;

-- A: counts toward exposure        FUNDED 300000 today, DELIVERED 200000 (50000 left, funded 2 days ago),
--                                  CLAIMED 100000, HELD 70000
--    counts nothing                REFUND_DUE 400000 funded today (R63), REPAID 99000 today,
--                                  OFFERED 10000, a LAPSED hold's request back OFFERED
--    another agent's               C: FUNDED 250000 today
select pg_temp.syn('FUNDED', 'A', 300000);
select pg_temp.syn('DELIVERED', 'A', 200000, 50000, now() - interval '2 days');
select pg_temp.syn('CLAIMED', 'A', 100000);
select pg_temp.syn('HELD', 'A', 70000);
select pg_temp.syn('REFUND_DUE', 'A', 400000);
select pg_temp.syn('REPAID_WITHIN_WINDOW', 'A', 99000, 0);
select pg_temp.syn('OFFERED', 'A', 10000);
select pg_temp.syn('FUNDED', 'C', 250000);
set local session_replication_role = origin;

-- ── shape and security ──────────────────────────────────────────────────
select has_function('public', 'get_monvelo_agent_exposure', array['uuid'], 'get_monvelo_agent_exposure(uuid) exists');
select is((select pg_get_function_arguments('public.get_monvelo_agent_exposure(uuid)'::regprocedure)),
  'p_agent_id uuid DEFAULT NULL::uuid', 'one parameter, p_agent_id, defaulting to null');
select is((select pg_get_function_result('public.get_monvelo_agent_exposure(uuid)'::regprocedure)),
  'TABLE(agent_id uuid, agent_status text, open_exposure numeric, platform_ceiling numeric, allowance_ceiling numeric, '
  'remaining_room numeric, active_commitments_count bigint, personal_daily_limit numeric, per_financing_limit numeric, '
  'today_utilized_limit numeric, today_remaining_limit numeric)', 'the meter''s columns');
select ok((select prosecdef and provolatile = 's' and proconfig @> array['search_path=public, pg_temp']
             from pg_proc where oid = 'public.get_monvelo_agent_exposure(uuid)'::regprocedure),
  'SECURITY DEFINER, STABLE (read only), search_path pinned');
select ok(has_function_privilege('authenticated', 'public.get_monvelo_agent_exposure(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.get_monvelo_agent_exposure(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.get_monvelo_agent_exposure(uuid)', 'execute'),
  'granted to authenticated only');
select ok(not has_function_privilege('authenticated', 'public.monvelo_agent_day_used(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_agent_day_used(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_agent_day_used(uuid)', 'execute'),
  'monvelo_agent_day_used has no API grant');

-- ── the internal figures ────────────────────────────────────────────────
select is(public.monvelo_agent_open_exposure(pg_temp.ag('A')), 520000.00::numeric,
  'A''s exposure: 300000 FUNDED + 50000 outstanding + 100000 CLAIMED + 70000 HELD; REFUND_DUE, REPAID and OFFERED count nothing');
select is(public.monvelo_agent_day_used(pg_temp.ag('A')), 569000.00::numeric,
  'A''s day (check 8): 100000 CLAIMED + 70000 HELD + 300000 and 99000 funded today (repaid still filled the day); not REFUND_DUE (R63), not the DELIVERED funded 2 days ago');
select is(public.monvelo_agent_open_exposure(pg_temp.ag('B')) || '|' || public.monvelo_agent_day_used(pg_temp.ag('B')),
  '0.00|0.00', 'B has nothing open and nothing today');

-- one column of the meter, read as p_user
create function pg_temp.col(p_user integer, p_agent text, p_col text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), pg_temp.t1());
  execute format('select string_agg(%I::text, '';'') from public.get_monvelo_agent_exposure(%L)', p_col,
                 case when p_agent is null then null else pg_temp.ag(p_agent) end) into v;
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
grant execute on function pg_temp.col(integer, text, text) to authenticated;

-- run p_sql as p_user, back to postgres after (for throws_ok/lives_ok)
create function pg_temp.as_sql(p_user integer, p_tenant boolean, p_agent text) returns text language sql as $$
  select format('select pg_temp.act_as(%L, %L); %s', pg_temp.u(p_user),
                case when p_tenant then pg_temp.t1() end, pg_temp.call_sql(p_agent)) $$;
grant execute on function pg_temp.as_sql(integer, boolean, text) to authenticated;

-- ── the members ─────────────────────────────────────────────────────────
select lives_ok(pg_temp.as_sql(31, true, null), 'a member inspects their own agent with no argument');
select set_config('role', 'postgres', true);
select is(pg_temp.meter(31, null),
  '520000.00|1000000.00|3000000.00|480000.00|4|600000.00|200000.00|569000.00|31000.00',
  'A''s meter: exposure, the ₦1,000,000 ceiling, the ₦3,000,000 allowance, room 480000, 4 commitments, own caps, today 569000 of 600000');
select is(pg_temp.meter(31, 'A'), pg_temp.meter(31, null), 'naming the agent gives the same meter');
select is(pg_temp.col(31, 'A', 'platform_ceiling'), '1000000.00', 'the platform ceiling is ₦1,000,000.00 (20261031121100)');
select is(pg_temp.col(31, 'A', 'platform_ceiling'), public.monvelo_open_exposure_ceiling()::text,
  'and it is read from the constant, never copied');
select is(pg_temp.col(31, null, 'agent_id') || ':' || pg_temp.col(31, null, 'agent_status'), pg_temp.ag('A')::text || ':ACTIVE',
  'the row names the agent and its status');

-- §21.2: an agent registered without caps reads 0.00, so it cannot claim until staff set them
select is(pg_temp.meter(32, null),
  '0.00|1000000.00|3000000.00|1000000.00|0|0.00|0.00|0.00|0.00',
  'B, unprovisioned: daily and per-financing limits 0.00, nothing left today, full room under the ceiling');
select is(pg_temp.col(32, null, 'personal_daily_limit'), '0.00', 'unprovisioned personal_daily_limit defaults to 0.00 (§21.2)');
select is((select daily_cap || '|' || per_financing_cap from public.monvelo_agents where id = pg_temp.ag('B')),
  '0.00|0.00', 'the 0.00 comes from monvelo_agents, whose caps default to 0 (no limits table)');

-- the day's room never goes below zero
set local session_replication_role = replica;
select pg_temp.syn('FUNDED', 'A', 50000);
set local session_replication_role = origin;
select is(pg_temp.col(31, 'A', 'today_remaining_limit'), '0.00', 'over the daily cap, today''s remaining limit is 0.00, not negative');
select is(pg_temp.col(31, 'A', 'today_utilized_limit'), '619000.00', 'and the use is reported as it is');

-- a member of two agents names one
select throws_ok(pg_temp.as_sql(33, true, null),
  '22023', 'you belong to more than one Monvelo agent: name the agent', 'a member of two agents must name one');
select set_config('role', 'postgres', true);
select is(pg_temp.meter(33, 'C'), '250000.00|1000000.00|3000000.00|750000.00|1|900000.00|100000.00|250000.00|650000.00',
  'C''s member reads C');
select is(pg_temp.col(33, 'C', 'agent_status'), 'SUSPENDED', 'a suspended agent''s member still reads the meter (repayments go on)');
select is(pg_temp.meter(33, 'D'), '0.00|1000000.00|3000000.00|1000000.00|0|0.00|0.00|0.00|0.00', 'and D');

-- ── everyone else: 42501 ────────────────────────────────────────────────
select throws_ok(pg_temp.as_sql(31, true, 'B'),
  '42501', 'Unauthorized access to agent exposure metrics', 'a member of A cannot read B');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(33, true, 'A'),
  '42501', 'Unauthorized access to agent exposure metrics', 'a member of other agents cannot read A');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(35, true, 'A'),
  '42501', 'Unauthorized access to agent exposure metrics', 'a REVOKED member cannot read A');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(1, true, 'A'),
  '42501', 'Unauthorized access to agent exposure metrics', 'a ZSM cannot read an agent (§20.2 decision 3: a market maker never sees the agent)');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(1, true, null),
  '42501', 'Unauthorized access to agent exposure metrics', 'a ZSM with no argument: a member of no agent');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(4, true, 'A'),
  '42501', 'Unauthorized access to agent exposure metrics', 'the ASA who recruited A cannot read it');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(7, true, 'A'),
  '42501', 'Unauthorized access to agent exposure metrics', 'a TENANT_ADMIN cannot read an agent (§16.2.2)');
select set_config('role', 'postgres', true);
select throws_ok(pg_temp.as_sql(36, false, 'A'),
  '42501', 'Unauthorized access to agent exposure metrics', 'a profile with no role cannot read an agent');
select set_config('role', 'postgres', true);
select throws_ok(format('select pg_temp.act_as(%L, %L); select * from public.get_monvelo_agent_exposure(%L)',
                        pg_temp.u(31), pg_temp.t1(), gen_random_uuid()),
  '42501', 'Unauthorized access to agent exposure metrics', 'an unknown agent is refused the same way (no existence oracle)');
select set_config('role', 'postgres', true);
select throws_ok($q$ select set_config('role', 'authenticated', true), set_config('request.jwt.claims', '{"role":"authenticated"}', true);
                     select * from public.get_monvelo_agent_exposure() $q$,
  '42501', 'Unauthorized access to agent exposure metrics', 'no signed-in user: refused');
select set_config('role', 'postgres', true);
select throws_ok($q$ select set_config('role', 'anon', true); select * from public.get_monvelo_agent_exposure() $q$,
  '42501', null, 'anon has no EXECUTE');
select set_config('role', 'postgres', true);

-- ── Monvelo staff ───────────────────────────────────────────────────────
select is(pg_temp.meter(34, 'A'), pg_temp.meter(31, 'A'), 'a MONVELO_OPERATOR reads any agent, the same figures');
select is(pg_temp.meter(34, 'B'), pg_temp.meter(32, 'B'), 'and B');
select is(pg_temp.col(34, 'Z', 'agent_id'), null, 'staff naming an agent that does not exist get no row');
select throws_ok(pg_temp.as_sql(34, false, null),
  '42501', 'Unauthorized access to agent exposure metrics', 'staff are members of no agent: they must name one');
select set_config('role', 'postgres', true);

select * from finish();
rollback;
