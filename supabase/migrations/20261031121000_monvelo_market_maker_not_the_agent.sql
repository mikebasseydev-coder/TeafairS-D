-- Addendum A6 §20, final review 2026-11-02 (R78): the market maker never
-- belongs to the held agent.
--
-- add_monvelo_member lets an operator add any verified profile to an agent,
-- tenant staff included, and monvelo_hold_market_makers excluded only the
-- raiser. A ZSM or ASA who is a member of the held agent could therefore be
-- told of the hold, see it and allow or decline it: four eyes in name only.
-- Now anyone with a membership row in the hold's agent, ACTIVE or REVOKED, is
-- not a market maker for that hold (a revoked member can be made ACTIVE again).
--
--   monvelo_hold_market_makers(t, area, raiser, agent)  + p_agent_id; the
--                                                         3-argument form is dropped
--   monvelo_claim_hold_rows, monvelo_notify_hold,
--   decide_monvelo_claim_hold                            recreated from
--                                                         20261031120900, passing the
--                                                         hold's agent; nothing else changes
--
-- Grants are unchanged. A member who is out of scope gets 42501, exactly as
-- any other out-of-scope caller, so the refusal reveals nothing.

create or replace function public.monvelo_hold_market_makers(p_tenant_id uuid, p_area_id uuid, p_raiser uuid,
                                                             p_agent_id uuid)
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
     -- R78: never a member (ACTIVE or REVOKED) of the held agent
     and not exists (select 1 from public.monvelo_agent_members m
                      where m.agent_id = p_agent_id and m.profile_id = tu.profile_id)
     and ((tu.role = 'ZSM' and t.zone_id in (select public.zsm_reach_zone_ids(p_tenant_id, tu.profile_id)))
          or (tu.role = 'ASA' and tu.area_id = p_area_id));
$$;
revoke all on function public.monvelo_hold_market_makers(uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;

-- Recreated from 20261031120900. R78: the helper gets the hold's agent.
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
     and p_profile_id in (select public.monvelo_hold_market_makers(f.tenant_id, f.area_id, f.raised_by, h.agent_id))
     and case when p_hold_id is null then h.status = 'HELD' or h.created_at >= now() - interval '7 days'
              else h.id = p_hold_id end
   order by (h.status = 'HELD') desc, h.created_at desc, h.id;
$$;
revoke all on function public.monvelo_claim_hold_rows(uuid, uuid, uuid) from public, anon, authenticated, service_role;

-- Recreated from 20261031120900. R78: the helper gets the hold's agent.
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
            from public.monvelo_hold_market_makers(v_fin.tenant_id, v_fin.area_id, v_fin.raised_by, v_hold.agent_id) m(profile_id)) mm;
end;
$$;
revoke all on function public.monvelo_notify_hold(uuid) from public, anon, authenticated, service_role;

-- Recreated from 20261031120900. R78: the helper gets the hold's agent.
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

drop function public.monvelo_hold_market_makers(uuid, uuid, uuid);
