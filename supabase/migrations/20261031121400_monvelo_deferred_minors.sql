-- Two deferred minors from the Step 1c/2 final review (ledger
-- .superpowers/sdd/2026-10-29-monvelo-step1c-step2/progress.md:184-185), 2026-11-04.
--
-- 1. The supply-day gap. claim_monvelo_financing, decide_monvelo_claim_hold (on
--    an allow) and approve_monvelo_financing accepted a request whose Lagos
--    supply day had ended until monvelo-offer-sweep (every minute) expired it.
--    They now refuse it live, P0001 "this request's supply day has ended".
--    The day ends at midnight Lagos after supply_date, the sweep's own instant.
--      monvelo_supply_day_ended(date)   new, internal
--      monvelo_claim_refusal            recreated from its latest body (20261031120800):
--                                       the new check 1b, not on the late route (R58)
--                                       (every other check unchanged)
--      approve_monvelo_financing        recreated from 20261031120050: the check
--    The CLAIM and LATE routes of settle_monvelo_funding are unchanged (R58): an
--    agent that held the claim may still pay; the stock sweep cancels the order.
--
-- 2. Nomination reads by zone. The ZSM's read of monvelo_agent_nominations was
--    tenant-wide (Task 1e left my_monvelo_nomination_tenant_ids for Task 7,
--    which never narrowed it). A ZSM now reads a nomination only when the
--    shop's enrolment area lies in their §18.3 reach (zones they cover, plus
--    zones no ACTIVE ZSM covers), like every other zonal ZSM read (R68).
--      my_monvelo_nomination_tenant_ids  recreated: ZSA, ASA, TM only (unchanged for them)
--      my_zsm_monvelo_nomination_ids     new, authenticated (for the policy)
--      monvelo_agent_nominations_select  recreated
--    TENANT_ADMIN still reads no nomination (it names a candidate agent, §16.2.2).

-- ── 1. the supply day, live ─────────────────────────────────────────────
create or replace function public.monvelo_supply_day_ended(p_supply_date date)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select p_supply_date is null
      or now() >= ((p_supply_date + 1)::timestamp at time zone 'Africa/Lagos');
$$;
revoke execute on function public.monvelo_supply_day_ended(date) from public, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.monvelo_claim_refusal(p_fin monvelo_financings, p_agent monvelo_agents, p_member uuid, p_pledge monvelo_pledges, p_late boolean, p_exposure_ceiling numeric DEFAULT NULL::numeric)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_shop      public.retail_shops;
  v_ps        public.monvelo_platform_settings;
  v_committed numeric(15,2) := 0;
  v_today     date := public.monvelo_today();
  v_daily     numeric(15,2);
  v_ceiling   numeric(15,2) := coalesce(p_exposure_ceiling, public.monvelo_open_exposure_ceiling());
  v_exposure  numeric(15,2);
begin
  -- the caller is an ACTIVE member of the agent
  if p_member is null or p_agent.id is null
     or not exists (select 1 from public.monvelo_agent_members m
                     where m.agent_id = p_agent.id and m.profile_id = p_member and m.status = 'ACTIVE') then
    return 'not an active member of this agent';
  end if;

  -- 1. still open, and its trade order still PENDING
  if p_fin.id is null or p_fin.status <> 'OFFERED'
     or not exists (select 1 from public.orders o
                     where o.tenant_id = p_fin.tenant_id and o.id = p_fin.order_id and o.status = 'PENDING') then
    return 'this request is no longer open';
  end if;

  -- 1b. the request's Lagos supply day has not ended (deferred minor, 2026-11-04):
  --     live, so the minute before monvelo-offer-sweep expires it is closed too.
  --     Not on the late route: a funding that arrives late is R58's business.
  if not p_late and public.monvelo_supply_day_ended(p_fin.supply_date) then
    return 'this request''s supply day has ended';
  end if;

  -- 2. the agent; 3. the enrolment
  if p_agent.status <> 'ACTIVE' then
    return 'the agent is not active';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = p_fin.tenant_id and e.shop_id = p_fin.shop_id and e.status = 'ACTIVE') then
    return 'the shop is no longer enrolled';
  end if;

  -- the platform hard freeze (A6 §18.2): funding is new credit too
  if exists (select 1 from public.monvelo_financings f
              where f.shop_id = p_fin.shop_id and f.status = 'DEFAULTED_WITH_LATE_CHARGE') then
    return 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared';
  end if;

  -- 4. one claim per agent per request (the claim itself; not on the late route)
  if not p_late and exists (select 1 from public.monvelo_financing_claims c
                             where c.financing_id = p_fin.id and c.agent_id = p_agent.id and c.outcome = 'LAPSED') then
    return 'your claim on this request lapsed; another agent may claim it';
  end if;
  -- A6 §20 (call 8): a declined hold bars that agent from that request
  if not p_late and exists (select 1 from public.monvelo_claim_holds h
                             where h.financing_id = p_fin.id and h.agent_id = p_agent.id and h.status = 'DECLINED') then
    return 'a market maker declined your claim on this request';
  end if;

  -- 5. the preferred window (the claim itself; not on the late route)
  if not p_late and p_fin.preferred_window_ends_at > now() and p_fin.preferred_agent_id is distinct from p_agent.id then
    return 'the shop''s preferred agent has first claim until '
           || to_char(p_fin.preferred_window_ends_at at time zone 'Africa/Lagos', 'HH24:MI');
  end if;

  -- 6. distance: the shop's preferred agent is exempt
  select * into v_ps from public.monvelo_platform_settings;
  select * into v_shop from public.retail_shops s where s.id = p_fin.shop_id;
  if v_shop.preferred_agent_id is distinct from p_agent.id
     and not extensions.st_dwithin(p_agent.location, v_shop.location::extensions.geography, v_ps.offer_radius_m) then
    return 'this shop is outside your area';
  end if;

  -- 7. the agent's pledge for the area and day, less what its other claims hold;
  --    A6 §20: and what its other holds on that area and day would take
  if p_pledge.id is not null then
    select coalesce(sum(f.principal), 0) into v_committed from public.monvelo_financings f
     where f.tenant_id = p_pledge.tenant_id and f.id <> p_fin.id
       and ((f.pledge_id = p_pledge.id and f.status = 'CLAIMED')
            or (f.status = 'HELD' and f.area_id = p_pledge.area_id and f.supply_date = p_pledge.supply_date
                and exists (select 1 from public.monvelo_claim_holds h
                             where h.financing_id = f.id and h.status = 'HELD' and h.agent_id = p_pledge.agent_id)));
  end if;
  if p_pledge.id is null or p_pledge.remaining - v_committed < p_fin.principal then
    return 'pledge enough funds for this area and day first';
  end if;

  -- 8. caps: per financing, and per Lagos day (claimed or held now plus funded
  --    today); A6 §19, R63: a REFUND_DUE financing no longer fills the day
  if p_fin.principal > p_agent.per_financing_cap then
    return 'this request is above your per-financing cap';
  end if;
  select coalesce(sum(f.principal) filter (where f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent.id), 0)
       + coalesce(sum(f.principal) filter (where f.funder_agent_id = p_agent.id
                                             and (f.funded_at at time zone 'Africa/Lagos')::date = v_today
                                             and f.status <> 'REFUND_DUE'), 0)
    into v_daily
    from public.monvelo_financings f
   where f.claimed_by_agent_id = p_agent.id or f.funder_agent_id = p_agent.id;
  -- A6 §20: the agent's other HELD financings count like CLAIMED ones
  v_daily := v_daily + coalesce((select sum(f.principal)
                                   from public.monvelo_financings f
                                   join public.monvelo_claim_holds h on h.financing_id = f.id and h.status = 'HELD'
                                  where f.status = 'HELD' and h.agent_id = p_agent.id and f.id <> p_fin.id), 0);
  if v_daily + p_fin.principal > p_agent.daily_cap then
    return 'this request would pass your daily cap';
  end if;

  -- A6 §19: the open exposure cap, across every tenant. A6 §20: the ceiling may
  -- be the market makers' limit; p_fin itself, held for this agent, is counted
  -- once (as p_fin.principal). Always the last check.
  v_exposure := public.monvelo_agent_open_exposure(p_agent.id);
  if exists (select 1 from public.monvelo_claim_holds h
              where h.financing_id = p_fin.id and h.status = 'HELD' and h.agent_id = p_agent.id) then
    v_exposure := v_exposure - p_fin.principal;
  end if;
  if v_exposure + p_fin.principal > v_ceiling then
    return 'this request would take your open exposure above ₦' || to_char(v_ceiling, 'FM999,999,999,990');
  end if;

  return null;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.approve_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['TM']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_fin   public.monvelo_financings;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_fin from public.monvelo_financings f
   where f.tenant_id = v_me.tenant_id and f.id = p_financing_id
     for update;
  if not found then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;
  if v_fin.territory_id is distinct from v_me.territory_id then
    raise exception 'only the territory''s TM approves this financing' using errcode = '42501';
  end if;
  if v_fin.status <> 'AWAITING_APPROVAL' then
    raise exception 'only a financing awaiting approval can be approved' using errcode = 'P0001';
  end if;
  -- deferred minor (2026-11-04): live, not only at the minute sweep
  if public.monvelo_supply_day_ended(v_fin.supply_date) then
    raise exception 'this request''s supply day has ended' using errcode = 'P0001';
  end if;

  update public.monvelo_financings
     set approved_by = v_me.profile_id, approved_at = now()
   where id = v_fin.id;
  v_fin := public.monvelo_offer(v_fin.id);

  perform public.write_audit(v_me.tenant_id, 'approve_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'AWAITING_APPROVAL'),
    jsonb_build_object('status', v_fin.status, 'approved_by', v_fin.approved_by),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('financing_id', v_fin.id, 'status', v_fin.status));
end;
$function$
;

-- ── 2. nominations by zone ──────────────────────────────────────────────
create or replace function public.my_monvelo_nomination_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.tenant_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role in ('ZSA', 'ASA', 'TM');
$$;

-- The nominations whose shop is enrolled (in the nomination's tenant) in an
-- area of a territory the calling ZSM reaches. A withdrawn enrolment keeps its
-- area, so a nomination never drops out of its zone.
create or replace function public.my_zsm_monvelo_nomination_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select n.id
    from public.monvelo_agent_nominations n
    join public.monvelo_shop_enrolments e on e.tenant_id = n.tenant_id and e.shop_id = n.shop_id
    join public.areas a on a.tenant_id = e.tenant_id and a.id = e.area_id
   where a.territory_id in (select public.my_zsm_territory_ids());
$$;
revoke execute on function public.my_zsm_monvelo_nomination_ids() from public, anon, service_role;
grant execute on function public.my_zsm_monvelo_nomination_ids() to authenticated;

drop policy monvelo_agent_nominations_select on public.monvelo_agent_nominations;
create policy monvelo_agent_nominations_select on public.monvelo_agent_nominations
  for select to authenticated
  using (
    tenant_id in (select public.my_monvelo_nomination_tenant_ids())
    or id in (select public.my_zsm_monvelo_nomination_ids())
    or shop_id in (select public.my_owned_shop_ids())
    or (select public.is_monvelo_staff())
  );
