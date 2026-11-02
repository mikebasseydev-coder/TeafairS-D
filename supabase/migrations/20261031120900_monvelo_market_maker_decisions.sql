-- Addendum A6 §20 (2026-11-02), Task 2: the market makers. Approved by the user 2026-11-02.
--
-- A held claim (Task 1, 20261031120800) is seen and decided by a market maker:
-- a ZSM whose reach (§18.3) covers the financing's zone, or the ASA of its
-- area, in the financing's tenant, and never the request's raiser (decision 6).
-- The market maker never sees the agent (decision 3, call 9).
--
--   monvelo_hold_market_makers(t, area, raiser)  who may see and decide (internal)
--   monvelo_claim_hold_rows(t, profile, hold)     the anonymous view (internal)
--   list_monvelo_claim_holds()                    HELD first, then the last 7 days
--   get_monvelo_claim_hold(hold)                  one hold; 42501 out of scope
--   decide_monvelo_claim_hold(key, hold, allow, reason)
--                                                 allow: every check re-run at ₦300,000
--                                                 under the agent's lock; decline: OFFERED
--   monvelo_notify_hold(hold)                     replaces Task 1's stub: MONVELO_HOLD
--   monvelo_notify_hold_decided(hold)             MONVELO_HOLD_DECIDED to the agent's members
--   monvelo_sweep_offers                          + the lapse notice; a HELD request with no
--                                                   HELD hold goes back to OFFERED
--   cancel_monvelo_financing                      + HELD (its hold ends LAPSED)
--   monvelo_open_offers                           not to a declined agent; the pledge net of holds
--   settle_monvelo_funding                        the late route checks at ₦300,000 when an
--                                                   ALLOWED hold exists (call 7)
--
-- Recreated functions keep their signatures and grants; changes are marked
-- "A6 §20". Audit rows naming the agent are tenant-null (R15).

-- ── who may see and decide a hold ───────────────────────────────────────
-- ACTIVE members of the tenant: a ZSM whose reach (zones covered, plus zones no
-- ACTIVE ZSM covers, §18.3) includes the area's zone, and the ASAs of the area;
-- never the raiser.
create or replace function public.monvelo_hold_market_makers(p_tenant_id uuid, p_area_id uuid, p_raiser uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.profile_id
    from public.tenant_users tu
    join public.areas a on a.tenant_id = p_tenant_id and a.id = p_area_id
    join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
   where tu.tenant_id = p_tenant_id
     and tu.status = 'ACTIVE'
     and tu.profile_id is distinct from p_raiser
     and ((tu.role = 'ZSM' and t.zone_id in (select public.zsm_reach_zone_ids(p_tenant_id, tu.profile_id)))
          or (tu.role = 'ASA' and tu.area_id = p_area_id));
$$;
revoke all on function public.monvelo_hold_market_makers(uuid, uuid, uuid) from public, anon, authenticated, service_role;

-- ── the anonymous view (§20.6) ──────────────────────────────────────────
-- p_hold_id null: the caller's HELD holds and those of the last 7 days; else
-- that one hold. Columns: the request, the funding side as pass or fail only
-- (call 9: no agent, no figures of the agent's), the shop's record in this
-- tenant, the outcome. within_limit is live while HELD (the agent's open
-- exposure, which counts this hold, against the ₦300,000 limit), else as
-- recorded at the hold. The shop record: repaid within the window, repaid
-- late, defaulted now (DEFAULTED_WITH_LATE_CHARGE), open now (FUNDED, DELIVERED).
create or replace function public.monvelo_claim_hold_rows(p_tenant_id uuid, p_profile_id uuid, p_hold_id uuid)
returns table (hold_id uuid, financing_reference text, shop_name text, shop_code text, area_name text,
               principal numeric(15,2), brand_lines jsonb, expires_at timestamptz, ready boolean, blocks text[],
               within_limit boolean, shop_repaid_in_window integer, shop_repaid_late integer, shop_defaulted integer,
               shop_open integer, shop_limits jsonb, status text, decided_by_name text, decided_at timestamptz,
               reason text)
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
         h.status, p.full_name, h.decided_at, h.reason
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
     and p_profile_id in (select public.monvelo_hold_market_makers(f.tenant_id, f.area_id, f.raised_by))
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
               reason text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.tenant_users := public.assert_tenant_role(array['ZSM', 'ASA']::public.tenant_role_enum[]);
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
               reason text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.tenant_users := public.assert_tenant_role(array['ZSM', 'ASA']::public.tenant_role_enum[]);
begin
  return query select * from public.monvelo_claim_hold_rows(v_me.tenant_id, v_me.profile_id, p_hold_id);
  if not found then
    raise exception 'this hold is not yours to see' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.get_monvelo_claim_hold(uuid) from public, anon;
grant execute on function public.get_monvelo_claim_hold(uuid) to authenticated;

-- ── the notices (§20.4 steps 3 and 6) ───────────────────────────────────
-- Replaces Task 1's stub. One MONVELO_HOLD per market maker in scope (never
-- the raiser), in the tenant; the hold, the reference and the expiry only.
create or replace function public.monvelo_notify_hold(p_hold_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hold public.monvelo_claim_holds;
  v_fin  public.monvelo_financings;
begin
  select * into v_hold from public.monvelo_claim_holds where id = p_hold_id;
  select * into v_fin from public.monvelo_financings where tenant_id = v_hold.tenant_id and id = v_hold.financing_id;
  insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
  select v_fin.tenant_id, mm.profile_id, 'MONVELO_HOLD', 'Monvelo claim held for you',
         'Request ' || v_fin.reference || ' is blocked only by the exposure cap. Allow or decline it by '
           || to_char(v_hold.expires_at at time zone 'Africa/Lagos', 'HH24:MI') || '.',
         jsonb_build_object('hold_id', v_hold.id, 'financing_reference', v_fin.reference, 'expires_at', v_hold.expires_at)
    from (select distinct m.profile_id
            from public.monvelo_hold_market_makers(v_fin.tenant_id, v_fin.area_id, v_fin.raised_by) m(profile_id)) mm;
end;
$$;
revoke all on function public.monvelo_notify_hold(uuid) from public, anon, authenticated, service_role;

-- The agent's ACTIVE members, tenant-null (they are not the tenant's): the
-- outcome of their hold. Never the market maker's identity.
create or replace function public.monvelo_notify_hold_decided(p_hold_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hold public.monvelo_claim_holds;
  v_fin  public.monvelo_financings;
begin
  select * into v_hold from public.monvelo_claim_holds where id = p_hold_id;
  if v_hold.id is null or v_hold.status = 'HELD' then
    return;
  end if;
  select * into v_fin from public.monvelo_financings where tenant_id = v_hold.tenant_id and id = v_hold.financing_id;
  insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
  select null, m.profile_id, 'MONVELO_HOLD_DECIDED',
         case v_hold.status when 'ALLOWED' then 'Monvelo claim allowed'
                            when 'DECLINED' then 'Monvelo claim declined'
                            else 'Monvelo claim hold ended' end,
         case v_hold.status
           when 'ALLOWED' then 'Request ' || v_fin.reference || ' is yours. Pay before '
                               || to_char(v_fin.claim_expires_at at time zone 'Africa/Lagos', 'HH24:MI') || '.'
           else 'Request ' || v_fin.reference || ' is no longer held for you.' end,
         jsonb_strip_nulls(jsonb_build_object('hold_id', v_hold.id, 'financing_id', v_fin.id, 'reference', v_fin.reference,
                                              'status', v_hold.status,
                                              'claim_expires_at', case when v_hold.status = 'ALLOWED' then v_fin.claim_expires_at end))
    from public.monvelo_agent_members m
   where m.agent_id = v_hold.agent_id and m.status = 'ACTIVE';
end;
$$;
revoke all on function public.monvelo_notify_hold_decided(uuid) from public, anon, authenticated, service_role;

-- ── decide_monvelo_claim_hold (§20.4 step 4) ────────────────────────────
-- In scope and not the raiser, else 42501. An allow needs a reason of at
-- least 10 characters (22023). Locks: the agent's advisory lock (R13), the
-- agent, the financing, the pledge, then the hold: the claim's order, with the
-- hold after the financing as in the sweep. A hold past expires_at that the
-- sweep has not reached yet is treated as lapsed.
-- Allow: every claim check re-run with the financing read as OFFERED and the
-- ceiling at monvelo_allowance_ceiling() (the held financing is counted once,
-- R67); on success HELD -> CLAIMED exactly as a claim, for the hold's member,
-- with a fresh window. A refusal raises P0001 with its text, so the hold stays
-- HELD. Decline: the hold DECLINED, the financing OFFERED (the agent is barred,
-- call 8).
create or replace function public.decide_monvelo_claim_hold(p_idempotency_key uuid, p_hold_id uuid, p_allow boolean,
                                                            p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSM', 'ASA']::public.tenant_role_enum[]);
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
     and v_me.profile_id in (select public.monvelo_hold_market_makers(f.tenant_id, f.area_id, f.raised_by));
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

-- ── monvelo_sweep_offers ────────────────────────────────────────────────
-- Recreated from 20261031120800. A6 §20 (Task 2):
--   1b. also a HELD financing with no HELD hold goes back to OFFERED (the
--       invariant: HELD iff exactly one HELD hold), and every lapse tells the
--       agent's members;
--   2.  the hold ended with its request tells the agent's members.
create or replace function public.monvelo_sweep_offers()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin     public.monvelo_financings;
  v_hold    public.monvelo_claim_holds;
  v_ended   boolean;
  v_rel     integer;
  v_lapsed  integer := 0;
  v_expired integer := 0;
begin
  -- 1. lapsed claims: back to OFFERED, with no new preferred window
  for v_fin in
    select * from public.monvelo_financings f
     where f.status = 'CLAIMED' and f.claim_expires_at <= now()
     order by f.id
       for update skip locked
  loop
    update public.monvelo_financing_claims set outcome = 'LAPSED', ended_at = now()
     where financing_id = v_fin.id and outcome is null;
    update public.monvelo_financings
       set status = 'OFFERED', claimed_by_agent_id = null, claimed_by = null, claim_expires_at = null,
           pledge_id = null, preferred_window_ends_at = null
     where id = v_fin.id;
    -- R15: the lapse names the agent, so no tenant reads it
    perform public.write_audit(null, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'CLAIMED', 'agent_id', v_fin.claimed_by_agent_id),
      jsonb_build_object('status', 'OFFERED', 'reason', 'CLAIM_LAPSED'),
      null, 'CRON', v_fin.raised_by);
    v_lapsed := v_lapsed + 1;
  end loop;

  -- 1b. A6 §20: holds nobody decided within 15 minutes, and a HELD request
  --     left with no HELD hold: back to OFFERED
  for v_fin in
    select f.* from public.monvelo_financings f
     where f.status = 'HELD'
       and (exists (select 1 from public.monvelo_claim_holds h
                     where h.financing_id = f.id and h.status = 'HELD' and h.expires_at <= now())
            or not exists (select 1 from public.monvelo_claim_holds h
                            where h.financing_id = f.id and h.status = 'HELD'))
     order by f.id
       for update of f skip locked
  loop
    v_hold := null;
    update public.monvelo_claim_holds set status = 'LAPSED', decided_at = now()
     where financing_id = v_fin.id and status = 'HELD'
    returning * into v_hold;
    update public.monvelo_financings set status = 'OFFERED', preferred_window_ends_at = null where id = v_fin.id;
    -- R15: the lapse names the agent, so no tenant reads it
    perform public.write_audit(null, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id, 'agent_id', v_hold.agent_id),
      jsonb_build_object('status', 'OFFERED', 'hold_status', 'LAPSED',
                         'reason', case when v_hold.id is null then 'NO_HELD_HOLD' else 'HOLD_LAPSED' end),
      null, 'CRON', v_fin.raised_by);
    if v_hold.id is not null then
      perform public.monvelo_notify_hold_decided(v_hold.id);
    end if;
    v_lapsed := v_lapsed + 1;
  end loop;

  -- 2. the supply day (Lagos) has ended, or the trade order is no longer PENDING
  for v_fin in
    select f.* from public.monvelo_financings f
      join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
     where f.status in ('OFFERED', 'AWAITING_APPROVAL', 'HELD')
       and (now() >= ((f.supply_date + 1)::timestamp at time zone 'Africa/Lagos') or o.status <> 'PENDING')
     order by f.id
       for update of f skip locked
  loop
    v_ended := now() >= ((v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos');
    -- A6 §20: a HELD request's hold ends with it
    if v_fin.status = 'HELD' then
      v_hold := null;
      update public.monvelo_claim_holds set status = 'LAPSED', decided_at = now()
       where financing_id = v_fin.id and status = 'HELD'
      returning * into v_hold;
      -- R15: it names the agent, so no tenant reads it
      perform public.write_audit(null, 'monvelo_sweep_offers', 'monvelo_claim_holds', v_hold.id::text,
        jsonb_build_object('status', 'HELD', 'agent_id', v_hold.agent_id, 'financing_id', v_fin.id),
        jsonb_build_object('status', 'LAPSED',
                           'reason', case when v_ended then 'SUPPLY_DAY_ENDED' else 'ORDER_NOT_PENDING' end),
        null, 'CRON', v_fin.raised_by);
      if v_hold.id is not null then
        perform public.monvelo_notify_hold_decided(v_hold.id);
      end if;
    end if;
    update public.monvelo_financings set status = 'EXPIRED' where id = v_fin.id;
    v_rel := public.monvelo_cancel_trade_order(v_fin.tenant_id, v_fin.order_id);
    perform public.write_audit(v_fin.tenant_id, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', v_fin.status),
      jsonb_build_object('status', 'EXPIRED',
                         'reason', case when v_ended then 'SUPPLY_DAY_ENDED' else 'ORDER_NOT_PENDING' end,
                         'order_cancelled', v_rel is not null, 'reservations_released', v_rel),
      null, 'CRON', v_fin.raised_by);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('lapsed', v_lapsed, 'expired', v_expired);
end;
$$;

-- ── cancel_monvelo_financing: + HELD ────────────────────────────────────
-- Recreated from 20261029130200. A6 §20.5: a HELD request may be cancelled;
-- its hold ends LAPSED (a tenant-null row, R15) and the agent is told. Lock
-- order: the financing, then its hold (as the sweep).
create or replace function public.cancel_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       public.tenant_users :=
    public.assert_tenant_role(array['ZSA', 'ASA', 'TM']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_fin      public.monvelo_financings;
  v_from     text;
  v_released integer;
  v_hold     public.monvelo_claim_holds;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'cancel_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_fin from public.monvelo_financings f
   where f.tenant_id = v_me.tenant_id and f.id = p_financing_id
     for update;
  if not found then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;
  if v_fin.raised_by is distinct from v_me.profile_id
     and not (v_me.role = 'TM' and v_me.territory_id is not distinct from v_fin.territory_id) then
    raise exception 'only the raiser or the territory''s TM cancels this financing' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' or char_length(btrim(p_reason)) > 500 then
    raise exception 'give a reason for the cancellation' using errcode = 'P0001';
  end if;
  if v_fin.status not in ('REQUESTED', 'AWAITING_APPROVAL', 'OFFERED', 'HELD') then
    raise exception 'this financing can no longer be cancelled' using errcode = 'P0001';
  end if;

  v_from := v_fin.status;
  update public.monvelo_financings
     set status = 'CANCELLED', cancelled_by = v_me.profile_id, cancelled_at = now(), cancel_reason = btrim(p_reason)
   where id = v_fin.id
  returning * into v_fin;
  -- A6 §20: the hold ends with its request
  if v_from = 'HELD' then
    update public.monvelo_claim_holds set status = 'LAPSED', decided_at = now()
     where financing_id = v_fin.id and status = 'HELD'
    returning * into v_hold;
    if v_hold.id is not null then
      perform public.write_audit(null, 'cancel_monvelo_financing', 'monvelo_claim_holds', v_hold.id::text,
        jsonb_build_object('status', 'HELD', 'agent_id', v_hold.agent_id, 'financing_id', v_fin.id),
        jsonb_build_object('status', 'LAPSED', 'reason', 'FINANCING_CANCELLED'),
        p_idempotency_key);
      perform public.monvelo_notify_hold_decided(v_hold.id);
    end if;
  end if;
  -- the trade order goes with it (A6 §18.1)
  v_released := public.monvelo_cancel_trade_order(v_fin.tenant_id, v_fin.order_id);

  perform public.write_audit(v_me.tenant_id, 'cancel_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', v_from),
    jsonb_build_object('status', v_fin.status, 'reason', v_fin.cancel_reason, 'order_id', v_fin.order_id,
                       'order_cancelled', v_released is not null, 'reservations_released', v_released),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('financing_id', v_fin.id, 'status', v_fin.status));
end;
$$;

-- ── monvelo_open_offers ─────────────────────────────────────────────────
-- Recreated from 20261029130300. A6 §20: never a request a market maker
-- declined for this agent (call 8), and the pledge is net of the agent's
-- HELD requests on that area and day (as monvelo_claim_refusal check 7).
create or replace function public.monvelo_open_offers(p_agent_id uuid)
returns table (financing_id uuid, reference text, shop_name text, shop_code text, area_name text,
               principal numeric, distance_m integer, supply_date date, preferred_until timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null
     or not exists (select 1 from public.monvelo_agent_members m
                     where m.agent_id = p_agent_id and m.profile_id = (select auth.uid()) and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  return query
  select f.id, f.reference, s.shop_name, s.shop_code, a.area_name, f.principal,
         round(extensions.st_distance(ag.location, s.location::extensions.geography))::integer,
         f.supply_date, f.preferred_window_ends_at
    from public.monvelo_financings f
    join public.monvelo_shop_enrolments e on e.tenant_id = f.tenant_id and e.shop_id = f.shop_id and e.status = 'ACTIVE'
    join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id and o.status = 'PENDING'
    join public.retail_shops s on s.id = f.shop_id
    join public.areas a on a.tenant_id = f.tenant_id and a.id = f.area_id
    join public.monvelo_agents ag on ag.id = p_agent_id and ag.status = 'ACTIVE'
    cross join public.monvelo_platform_settings ps
   where f.status = 'OFFERED'
     and f.supply_date = public.monvelo_today()
     and not exists (select 1 from public.monvelo_financings d
                      where d.shop_id = f.shop_id and d.status = 'DEFAULTED_WITH_LATE_CHARGE')
     and not exists (select 1 from public.monvelo_financing_claims c
                      where c.financing_id = f.id and c.agent_id = p_agent_id and c.outcome = 'LAPSED')
     -- A6 §20: a declined agent is barred
     and not exists (select 1 from public.monvelo_claim_holds h
                      where h.financing_id = f.id and h.agent_id = p_agent_id and h.status = 'DECLINED')
     and (
       (f.preferred_window_ends_at > now() and f.preferred_agent_id = p_agent_id)
       or ((f.preferred_window_ends_at is null or f.preferred_window_ends_at <= now())
           and (s.preferred_agent_id = p_agent_id
                or extensions.st_dwithin(ag.location, s.location::extensions.geography, ps.offer_radius_m))
           and exists (
             select 1 from public.monvelo_pledges p
              where p.tenant_id = f.tenant_id and p.agent_id = p_agent_id
                and p.area_id = f.area_id and p.supply_date = f.supply_date
                and p.remaining - (select coalesce(sum(o2.principal), 0) from public.monvelo_financings o2
                                    where o2.tenant_id = p.tenant_id
                                      and ((o2.pledge_id = p.id and o2.status = 'CLAIMED')
                                           -- A6 §20: and what the agent's holds there would take
                                           or (o2.status = 'HELD' and o2.area_id = p.area_id
                                               and o2.supply_date = p.supply_date
                                               and exists (select 1 from public.monvelo_claim_holds h2
                                                            where h2.financing_id = o2.id and h2.status = 'HELD'
                                                              and h2.agent_id = p_agent_id))))
                    >= f.principal)))
   order by 7, f.offered_at, f.id;
end;
$$;

-- ── settle_monvelo_funding: an allowance survives a late payment ────────
-- Recreated from 20261031120050 (R17; 20261031120500 only commented it). A6 §20
-- (call 7): on the LATE route, when this agent holds an ALLOWED hold on this
-- financing, the refusal checks the caps against monvelo_allowance_ceiling().
-- Nothing else changes; the route still never holds (call 5).
CREATE OR REPLACE FUNCTION public.settle_monvelo_funding(p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb, p_transaction_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  -- (event, reference) is the at-most-once key
  v_key      uuid := md5('monvelo:' || p_event || ':' || p_reference)::uuid;
  v_source   public.audit_source_enum := case when p_event = 'sweep' then 'CRON' else 'WEBHOOK' end;
  v_matches  integer;
  v_payment  public.payments;
  v_fin      public.monvelo_financings;
  v_order    public.orders;
  v_agent    public.monvelo_agents;
  v_pledge   public.monvelo_pledges;
  v_age      interval;
  v_target   public.payment_status_enum;
  v_prior    jsonb;
  v_currency text;
  v_auth     jsonb := coalesce(p_verified -> 'authorization', '{}'::jsonb);
  v_payer    jsonb;
  v_reason   text;
  v_route    text;
  v_line     record;
  v_terms    public.monvelo_brand_terms;
  v_today    date := public.monvelo_today();
  v_payable  public.monvelo_rebate_payables;
  v_total    numeric(15,2) := 0;
  v_outcome  text;
begin
  if p_status = 'reversed' then
    raise exception 'reversed is applied as a refund' using errcode = 'P0001';
  end if;

  select count(*) into v_matches from public.payments
   where paystack_reference = p_reference and monvelo_financing_id is not null;
  if v_matches <> 1 then
    -- not marked processed: a payment row that lands later can still settle
    perform public.write_audit(null, 'MONVELO_UNKNOWN_REFERENCE', 'payments', p_reference, null,
      jsonb_build_object('event', p_event, 'reference', p_reference, 'matches', v_matches),
      null, v_source);
    return jsonb_build_object('outcome', 'unknown_reference');
  end if;

  -- age decides abandoned and the non-final statuses, as settle_paystack_payment
  select * into v_payment from public.payments
   where paystack_reference = p_reference and monvelo_financing_id is not null;
  v_age := now() - v_payment.created_at;
  v_target := case
                when p_status = 'success' then 'SUCCESS'
                when p_status in ('failed', 'abandoned') and v_age >= interval '2 hours' then 'FAILED'
                when p_status in ('ongoing', 'pending', 'processing', 'queued')
                     and v_age > interval '72 hours' then 'FAILED'
              end;
  if v_target is null then
    if p_event = 'sweep' then
      update public.payments set last_swept_at = now() where id = v_payment.id;
    end if;
    return jsonb_build_object('outcome', 'not_final', 'status', p_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'settle_monvelo_funding',
    jsonb_build_object('event', p_event, 'reference', p_reference));
  if v_prior is not null then
    return v_prior;
  end if;

  -- R13: the agent's advisory lock first, as in claim_monvelo_financing, so a
  -- late funding queues behind the agent's claims and other fundings. Taken on
  -- every route: the route is known only after the row locks, and taking it
  -- after them would reverse the claim's lock order. The agent never changes on
  -- a payment, so the unlocked read above is safe.
  perform pg_advisory_xact_lock(hashtextextended('monvelo_agent:' || v_payment.monvelo_agent_id::text, 0));

  -- payment, financing, then order
  select * into v_payment from public.payments where id = v_payment.id for update;
  select * into v_fin from public.monvelo_financings
   where tenant_id = v_payment.tenant_id and id = v_payment.monvelo_financing_id for update;
  select * into v_order from public.orders
   where tenant_id = v_fin.tenant_id and id = v_fin.order_id for update;
  select * into v_agent from public.monvelo_agents where id = v_payment.monvelo_agent_id;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');

  -- already decided, or a status that cannot follow the one recorded
  if v_payment.payment_status = v_target
     or v_payment.payment_status = 'REFUNDED'
     or (v_payment.payment_status = 'SUCCESS' and v_target = 'FAILED') then
    if v_payment.payment_status <> v_target then
      perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_STATUS_CONFLICT', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', v_payment.payment_status),
        jsonb_build_object('verified_status', p_status, 'event', p_event),
        v_key, v_source, v_payment.teafair_agent_id);
    end if;
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'unchanged', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  update public.payments
     set payment_status = v_target, gateway_response_payload = p_verified
   where id = v_payment.id;
  perform public.write_audit(v_payment.tenant_id, 'settle_monvelo_funding', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', v_target, 'event', p_event),
    v_key, v_source, v_payment.teafair_agent_id);

  if v_target = 'FAILED' then
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'failed', 'payment_id', v_payment.id, 'payment_status', 'FAILED'));
  end if;

  -- what the staff reviewing a flag need about the money; flags are staff-only
  v_payer := jsonb_build_object('payment_id', v_payment.id, 'reference', p_reference, 'event', p_event,
    'transaction_id', p_transaction_id, 'amount_minor', p_amount_minor, 'currency', p_currency,
    'channel', coalesce(v_auth ->> 'channel', p_verified ->> 'channel'),
    'sender_bank', v_auth ->> 'sender_bank', 'sender_name', v_auth ->> 'sender_name',
    'sender_account', v_auth ->> 'sender_bank_account_number');

  -- 1. the amount and currency
  if p_amount_minor is distinct from (v_fin.principal * 100)::bigint or p_currency is distinct from v_currency then
    perform public.monvelo_raise_flag('AMOUNT_MISMATCH', v_fin.id, v_agent.id,
      v_payer || jsonb_build_object('expected_minor', (v_fin.principal * 100)::bigint, 'expected_currency', v_currency));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'mismatch', 'payment_id', v_payment.id, 'financing_id', v_fin.id));
  end if;

  -- 2. the payer (F1)
  if not public.monvelo_payer_matches(v_agent, p_verified) then
    perform public.monvelo_raise_flag('PAYER_MISMATCH', v_fin.id, v_agent.id, v_payer);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'payer_mismatch', 'payment_id', v_payment.id, 'financing_id', v_fin.id));
  end if;

  -- 3. still fundable by this agent: its own claim, or (R2) an unclaimed request
  --    inside its supply day that the agent's pledge still covers
  if v_order.status is distinct from 'PENDING' then
    v_reason := 'ORDER_NOT_PENDING';
  elsif v_fin.status = 'CLAIMED' and v_fin.claimed_by_agent_id = v_agent.id then
    v_route := 'CLAIM';
    select * into v_pledge from public.monvelo_pledges
     where tenant_id = v_fin.tenant_id and id = v_fin.pledge_id for update;
    -- R17: the agent and the member who started the payment are still ACTIVE
    if v_agent.status <> 'ACTIVE' then
      v_reason := 'the agent is not active';
    elsif not exists (select 1 from public.monvelo_agent_members m
                       where m.agent_id = v_agent.id and m.profile_id = v_payment.monvelo_started_by
                         and m.status = 'ACTIVE') then
      v_reason := 'not an active member of this agent';
    elsif v_pledge.id is null or v_pledge.remaining < v_fin.principal then
      v_reason := 'PLEDGE_EXHAUSTED';
    end if;
  elsif v_fin.status = 'OFFERED'
        and not exists (select 1 from public.monvelo_financing_claims c
                         where c.financing_id = v_fin.id and c.outcome is null)
        and now() < ((v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos') then
    v_route := 'LATE';
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = v_agent.id
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
     order by p.created_at, p.id
     limit 1
       for update;
    -- R10: every claim check but the claim itself, for the member who started
    -- this payment (R12: payments.monvelo_started_by); the pledge check is net
    -- of the agent's other open claims
    -- A6 §20 (call 7): an allowance for this agent and financing survives a late payment
    v_reason := public.monvelo_claim_refusal(v_fin, v_agent, v_payment.monvelo_started_by, v_pledge, true,
      case when exists (select 1 from public.monvelo_claim_holds h
                         where h.financing_id = v_fin.id and h.agent_id = v_agent.id and h.status = 'ALLOWED')
           then public.monvelo_allowance_ceiling() end);
  else
    v_reason := case
                  when v_fin.status = 'CLAIMED' then 'CLAIMED_BY_ANOTHER_AGENT'
                  when v_fin.status = 'OFFERED' then 'SUPPLY_DAY_ENDED'
                  else 'FINANCING_' || v_fin.status
                end;
  end if;

  -- every brand must still have approved terms to lock
  if v_reason is null then
    for v_line in
      select l.brand from public.monvelo_financing_lines l
       where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id
    loop
      if (public.monvelo_terms_at(v_fin.tenant_id, v_line.brand, v_today)).id is null then
        v_reason := 'NO_TERMS';
      end if;
    end loop;
  end if;

  if v_reason is not null then
    perform public.monvelo_raise_flag('LATE_PAYMENT', v_fin.id, v_agent.id,
      v_payer || jsonb_build_object('reason', v_reason, 'financing_status', v_fin.status));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'late_payment', 'payment_id', v_payment.id, 'financing_id', v_fin.id));
  end if;

  -- FUNDED, in this one transaction
  update public.monvelo_financings
     set status = 'FUNDED', funder_agent_id = v_agent.id, paystack_reference = p_reference, funded_at = now(),
         pledge_id = v_pledge.id
   where id = v_fin.id;
  update public.monvelo_financing_claims set outcome = 'FUNDED', ended_at = now()
   where financing_id = v_fin.id and outcome is null;

  update public.monvelo_financing_lines l
     set (terms_id, rebate_bps, interest_free_days, late_charge_bps, terms_locked_at) =
         (select t.id, t.rebate_bps, t.interest_free_days, t.late_charge_bps, now()
            from public.monvelo_terms_at(l.tenant_id, l.brand, v_today) t)
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  update public.monvelo_pledges set remaining = remaining - v_fin.principal where id = v_pledge.id;

  update public.orders set status = 'PAID' where id = v_order.id;

  select coalesce(sum(round(l.amount * l.rebate_bps / 10000.0, 2)), 0) into v_total
    from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;
  insert into public.monvelo_rebate_payables (tenant_id, financing_id, agent_id, amount, due_at, status)
  values (v_fin.tenant_id, v_fin.id, v_agent.id, v_total, now() + interval '24 hours', 'DUE')
  returning * into v_payable;
  insert into public.monvelo_rebate_payable_lines (payable_id, brand_key, amount)
  select v_payable.id, l.brand_key, round(l.amount * l.rebate_bps / 10000.0, 2)
    from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  -- audited on the raiser; no agent, pledge or payer in the row (§16.2.2)
  perform public.write_audit(v_fin.tenant_id, 'settle_monvelo_funding', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', v_fin.status),
    jsonb_build_object('status', 'FUNDED', 'payment_id', v_payment.id, 'order_id', v_order.id,
                       'principal', v_fin.principal, 'event', p_event),
    v_key, v_source, v_fin.raised_by);
  perform public.write_audit(v_fin.tenant_id, 'settle_monvelo_funding', 'orders', v_order.id::text,
    jsonb_build_object('status', 'PENDING'),
    jsonb_build_object('status', 'PAID', 'payment_id', v_payment.id, 'event', p_event),
    v_key, v_source, v_fin.raised_by);

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'funded', 'payment_id', v_payment.id, 'financing_id', v_fin.id, 'route', v_route,
    'payable_id', v_payable.id, 'rebate', v_total));
end;
$function$;
revoke all on function public.settle_monvelo_funding(text, text, text, bigint, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.settle_monvelo_funding(text, text, text, bigint, text, jsonb, text) to service_role;
