-- Addendum A6 §22 (user decisions 2026-11-03): field agents decide holds.
--
-- Replaces §20.2 decision 1 (the ZSM and the ASA decide):
--   1. the deciders are the ZSA of the request's zone (its tenant_users.zone_id)
--      and the ASA of its area;
--   2. a ZSM whose reach (§18.3) covers the zone oversees the hold read-only;
--   3. when no field agent is eligible (none ACTIVE, or each is the raiser or a
--      member of the held agent, R78), the ZSMs in reach decide; live, so the
--      fallback ends once an eligible field agent is ACTIVE;
--   4. the agent's recruiter (monvelo_agents.recruited_by) is not barred.
--
--   monvelo_hold_market_makers(t, area, raiser, agent)  recreated: the deciders.
--                                                       monvelo_notify_hold and
--                                                       decide_monvelo_claim_hold use it
--                                                       unchanged, so notices go to deciders
--   monvelo_hold_viewers(t, area, raiser, agent)         new, internal: deciders + ZSMs in reach
--   monvelo_claim_hold_rows, list_monvelo_claim_holds,
--   get_monvelo_claim_hold                              dropped and recreated: + can_decide,
--                                                       filtered on the viewers; grants unchanged
--   decide_monvelo_claim_hold                           recreated from 20261031121000: the
--                                                       ZSA joins the roles; nothing else changes
--
-- No table, table grant or RLS policy changes.

-- ── who decides ─────────────────────────────────────────────────────────
create or replace function public.monvelo_hold_market_makers(p_tenant_id uuid, p_area_id uuid, p_raiser uuid,
                                                             p_agent_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with req as (
    select t.zone_id
      from public.areas a
      join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
     where a.tenant_id = p_tenant_id and a.id = p_area_id
  ), eligible as (
    -- ACTIVE, never the raiser (decision 6), never a member of the held agent (R78)
    select tu.profile_id, tu.role, tu.zone_id, tu.area_id
      from public.tenant_users tu
     where tu.tenant_id = p_tenant_id
       and tu.status = 'ACTIVE'
       and tu.profile_id is distinct from p_raiser
       and not exists (select 1 from public.monvelo_agent_members m
                        where m.agent_id = p_agent_id and m.profile_id = tu.profile_id)
  ), field as (
    -- §22.1 decision 1: the zone's ZSA and the area's ASA
    select e.profile_id from eligible e, req
     where (e.role = 'ZSA' and e.zone_id = req.zone_id)
        or (e.role = 'ASA' and e.area_id = p_area_id)
  )
  select profile_id from field
  union
  -- §22.1 decision 3: the ZSMs in reach, only when no field agent can decide
  select e.profile_id from eligible e, req
   where e.role = 'ZSM'
     and req.zone_id in (select public.zsm_reach_zone_ids(p_tenant_id, e.profile_id))
     and not exists (select 1 from field);
$$;
revoke all on function public.monvelo_hold_market_makers(uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;
comment on function public.monvelo_hold_market_makers(uuid, uuid, uuid, uuid) is
  'A6 §22: who decides a hold: the ZSA of the zone and the ASA of the area, else the ZSMs in reach; never the raiser or a member of the held agent.';

-- ── who sees ────────────────────────────────────────────────────────────
create or replace function public.monvelo_hold_viewers(p_tenant_id uuid, p_area_id uuid, p_raiser uuid,
                                                       p_agent_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.monvelo_hold_market_makers(p_tenant_id, p_area_id, p_raiser, p_agent_id)
  union
  -- §22.1 decision 2: the ZSMs in reach oversee, read-only (same bars)
  select tu.profile_id
    from public.tenant_users tu
    join public.areas a on a.tenant_id = p_tenant_id and a.id = p_area_id
    join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
   where tu.tenant_id = p_tenant_id
     and tu.status = 'ACTIVE'
     and tu.role = 'ZSM'
     and tu.profile_id is distinct from p_raiser
     and not exists (select 1 from public.monvelo_agent_members m
                      where m.agent_id = p_agent_id and m.profile_id = tu.profile_id)
     and t.zone_id in (select public.zsm_reach_zone_ids(p_tenant_id, tu.profile_id));
$$;
revoke all on function public.monvelo_hold_viewers(uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;
comment on function public.monvelo_hold_viewers(uuid, uuid, uuid, uuid) is
  'A6 §22: who sees a hold: its deciders and the ZSMs in reach (read-only); never the raiser or a member of the held agent.';

-- ── the anonymous view, + can_decide ────────────────────────────────────
drop function public.list_monvelo_claim_holds();
drop function public.get_monvelo_claim_hold(uuid);
drop function public.monvelo_claim_hold_rows(uuid, uuid, uuid);

-- Recreated from 20261031121000: + can_decide (HELD, not past expiry, and the
-- caller decides); filtered on the viewers.
create or replace function public.monvelo_claim_hold_rows(p_tenant_id uuid, p_profile_id uuid, p_hold_id uuid)
returns table (hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text,
               principal numeric(15,2), brand_lines jsonb, expires_at timestamptz, ready boolean, blocks text[],
               within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer,
               shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamptz,
               reason text, can_decide boolean)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select h.id, f.reference, s.shop_name, s.shop_code, a.area_name, f.principal,
         coalesce((select jsonb_agg(jsonb_build_object('brand', l.brand, 'amount', l.amount) order by l.brand_key)
                     from public.monvelo_financing_lines l
                    where l.tenant_id = f.tenant_id and l.financing_id = f.id), '[]'::jsonb),
         h.expires_at,
         h.status = 'ALLOWED',
         h.blocks,
         case when h.status = 'HELD'
              then public.monvelo_agent_open_exposure(h.agent_id) <= public.monvelo_allowance_ceiling()
              else h.exposure_after <= public.monvelo_allowance_ceiling() end,
         r.in_window, r.late, r.defaulted, r.open_now,
         coalesce((select jsonb_agg(jsonb_build_object('brand_key', sl.brand_key, 'limit', sl.limit_amount,
                                                       'status', sl.status) order by sl.brand_key)
                     from public.monvelo_shop_limits sl
                    where sl.tenant_id = f.tenant_id and sl.shop_id = f.shop_id), '[]'::jsonb),
         h.status, p.full_name, h.decided_at, h.reason,
         h.status = 'HELD' and h.expires_at > now()
           and p_profile_id in (select public.monvelo_hold_market_makers(f.tenant_id, f.area_id, f.raised_by, h.agent_id))
    from public.monvelo_claim_holds h
    join public.monvelo_financings f on f.tenant_id = h.tenant_id and f.id = h.financing_id
    join public.retail_shops s on s.id = f.shop_id
    join public.areas a on a.tenant_id = f.tenant_id and a.id = f.area_id
    left join public.profiles p on p.id = h.decided_by
    cross join lateral (
      select count(*) filter (where x.status = 'REPAID_WITHIN_WINDOW')::integer as in_window,
             count(*) filter (where x.status = 'REPAID_LATE')::integer as late,
             count(*) filter (where x.status = 'DEFAULTED_WITH_LATE_CHARGE')::integer as defaulted,
             count(*) filter (where x.status in ('FUNDED', 'DELIVERED'))::integer as open_now
        from public.monvelo_financings x
       where x.tenant_id = f.tenant_id and x.shop_id = f.shop_id) r
   where h.tenant_id = p_tenant_id
     and p_profile_id in (select public.monvelo_hold_viewers(f.tenant_id, f.area_id, f.raised_by, h.agent_id))
     and case when p_hold_id is null then h.status = 'HELD' or h.created_at >= now() - interval '7 days'
              else h.id = p_hold_id end
   order by (h.status = 'HELD') desc, h.created_at desc, h.id;
$$;
revoke all on function public.monvelo_claim_hold_rows(uuid, uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.list_monvelo_claim_holds()
returns table (hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text,
               principal numeric(15,2), brand_lines jsonb, expires_at timestamptz, ready boolean, blocks text[],
               within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer,
               shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamptz,
               reason text, can_decide boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA', 'ZSM']::public.tenant_role_enum[]);
begin
  return query select * from public.monvelo_claim_hold_rows(v_me.tenant_id, v_me.profile_id, null);
end;
$$;
revoke all on function public.list_monvelo_claim_holds() from public, anon;
grant execute on function public.list_monvelo_claim_holds() to authenticated;

create or replace function public.get_monvelo_claim_hold(p_hold_id uuid)
returns table (hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text,
               principal numeric(15,2), brand_lines jsonb, expires_at timestamptz, ready boolean, blocks text[],
               within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer,
               shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamptz,
               reason text, can_decide boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA', 'ZSM']::public.tenant_role_enum[]);
begin
  return query select * from public.monvelo_claim_hold_rows(v_me.tenant_id, v_me.profile_id, p_hold_id);
  if not found then
    raise exception 'this hold is not yours to see' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.get_monvelo_claim_hold(uuid) from public, anon;
grant execute on function public.get_monvelo_claim_hold(uuid) to authenticated;

-- ── decide_monvelo_claim_hold ───────────────────────────────────────────
-- Recreated from 20261031121000; only the role list changes (the ZSA joins).
-- The scope check is monvelo_hold_market_makers, so a ZSM who is only
-- overseeing gets 42501 "this hold is not yours to decide".
create or replace function public.decide_monvelo_claim_hold(p_idempotency_key uuid, p_hold_id uuid, p_allow boolean,
                                                            p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA', 'ZSM']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_reason  text := nullif(btrim(p_reason), '');
  v_hold    public.monvelo_claim_holds;
  v_fin     public.monvelo_financings;
  v_offered public.monvelo_financings;
  v_agent   public.monvelo_agents;
  v_pledge  public.monvelo_pledges;
  v_ps      public.monvelo_platform_settings;
  v_refusal text;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'decide_monvelo_claim_hold',
    jsonb_build_object('hold_id', p_hold_id, 'allow', p_allow, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  -- in scope, never the raiser (decision 6); an unknown hold looks the same
  select h.* into v_hold from public.monvelo_claim_holds h
    join public.monvelo_financings f on f.tenant_id = h.tenant_id and f.id = h.financing_id
   where h.id = p_hold_id and h.tenant_id = v_me.tenant_id
     and v_me.profile_id in (select public.monvelo_hold_market_makers(f.tenant_id, f.area_id, f.raised_by, h.agent_id));
  if v_hold.id is null then
    raise exception 'this hold is not yours to decide' using errcode = '42501';
  end if;

  if p_allow is null then
    raise exception 'allow or decline' using errcode = '22023';
  end if;
  if p_allow and (v_reason is null or char_length(v_reason) < 10) then
    raise exception 'give a reason of at least 10 characters to allow' using errcode = '22023';
  end if;
  if char_length(v_reason) > 1000 then
    raise exception 'the reason is longer than 1000 characters' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('monvelo_agent:' || v_hold.agent_id::text, 0));
  select * into v_agent from public.monvelo_agents a where a.id = v_hold.agent_id for update;
  select * into v_fin from public.monvelo_financings f
   where f.tenant_id = v_hold.tenant_id and f.id = v_hold.financing_id for update;
  if p_allow then
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = v_agent.id
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
       for update;
  end if;
  select * into v_hold from public.monvelo_claim_holds where id = v_hold.id for update;

  if v_hold.status <> 'HELD' or v_fin.status <> 'HELD' then
    raise exception 'this hold has already been decided' using errcode = 'P0001';
  end if;
  if v_hold.expires_at <= now() then
    raise exception 'this hold has lapsed' using errcode = 'P0001';
  end if;

  if not p_allow then
    update public.monvelo_claim_holds
       set status = 'DECLINED', decided_by = v_me.profile_id, decided_at = now(), reason = v_reason
     where id = v_hold.id
    returning * into v_hold;
    update public.monvelo_financings set status = 'OFFERED', preferred_window_ends_at = null where id = v_fin.id;

    -- R15: the row names the agent, so no tenant reads it
    perform public.write_audit(null, 'decide_monvelo_claim_hold', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id, 'agent_id', v_hold.agent_id),
      jsonb_build_object('status', 'OFFERED', 'hold_status', 'DECLINED', 'reason', v_reason),
      p_idempotency_key);
    perform public.monvelo_notify_hold_decided(v_hold.id);

    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'status', 'DECLINED', 'hold_id', v_hold.id, 'financing_reference', v_fin.reference));
  end if;

  -- allow: every check but the ₦100,000 cap, under the agent's lock (§20.4 step 4)
  v_offered := v_fin;
  v_offered.status := 'OFFERED';
  v_refusal := public.monvelo_claim_refusal(v_offered, v_agent, v_hold.claimed_by, v_pledge, false,
                                            public.monvelo_allowance_ceiling());
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;

  update public.monvelo_claim_holds
     set status = 'ALLOWED', decided_by = v_me.profile_id, decided_at = now(), reason = v_reason
   where id = v_hold.id
  returning * into v_hold;

  select * into v_ps from public.monvelo_platform_settings;
  update public.monvelo_financings
     set status = 'CLAIMED', claimed_by_agent_id = v_hold.agent_id, claimed_by = v_hold.claimed_by,
         claim_expires_at = now() + make_interval(mins => v_ps.claim_minutes),
         pledge_id = v_pledge.id, preferred_window_ends_at = null
   where id = v_fin.id
  returning * into v_fin;
  insert into public.monvelo_financing_claims (tenant_id, financing_id, agent_id, claimed_by, pledge_id, expires_at)
  values (v_fin.tenant_id, v_fin.id, v_hold.agent_id, v_hold.claimed_by, v_pledge.id, v_fin.claim_expires_at);

  -- R15: the row names the agent and its pledge, so no tenant reads it
  perform public.write_audit(null, 'decide_monvelo_claim_hold', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id),
    jsonb_build_object('status', 'CLAIMED', 'hold_status', 'ALLOWED', 'agent_id', v_hold.agent_id,
                       'pledge_id', v_pledge.id, 'claim_expires_at', v_fin.claim_expires_at, 'reason', v_reason),
    p_idempotency_key);
  perform public.monvelo_notify_hold_decided(v_hold.id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'status', 'ALLOWED', 'hold_id', v_hold.id, 'financing_reference', v_fin.reference,
    'claim_expires_at', v_fin.claim_expires_at));
end;
$$;
revoke all on function public.decide_monvelo_claim_hold(uuid, uuid, boolean, text) from public, anon;
grant execute on function public.decide_monvelo_claim_hold(uuid, uuid, boolean, text) to authenticated;
