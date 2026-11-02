-- Addendum A6 §20 (2026-11-02), Task 1: the hold. Approved by the user 2026-11-02.
--
-- A claim blocked only by the ₦100,000 open exposure cap (§19.4), that would
-- pass with the agent's open exposure at most monvelo_allowance_ceiling()
-- (₦300,000), is held for 15 minutes instead of refused. While it is HELD no
-- other agent can claim the financing (decision 5). Task 2 adds the market
-- makers' list, view and decision, and the notices.
--
--   monvelo_financings.status          + HELD; the guard: OFFERED -> HELD;
--                                        HELD -> CLAIMED, OFFERED, CANCELLED, EXPIRED
--   monvelo_claim_holds                insert-only apart from the one final move;
--                                        RLS on, no policy, nothing granted
--   monvelo_allowance_ceiling()        one constant, 300000.00, ungranted
--   monvelo_notify_hold(hold)          a no-op stub here; Task 2 fills it
--   monvelo_agent_open_exposure        + the agent's HELD financings at principal (call 4)
--   monvelo_brand_exposure             + HELD: a held request still uses the shop's limit
--   monvelo_claim_refusal              + p_exposure_ceiling (dropped and recreated);
--                                        a DECLINED hold bars the agent; HELD counts
--                                        in the pledge and the daily cap
--   claim_monvelo_financing            holds instead of refusing (§20.4 step 2)
--   monvelo_sweep_offers               lapses holds at expires_at; the supply-day
--                                        end and a cancelled trade order end a
--                                        HELD request as an OFFERED one, hold LAPSED
--
-- Every function is recreated from its latest definition with only the changes
-- marked "A6 §20". Grants are unchanged. No RLS policy changes. Audit rows
-- naming the agent are tenant-null (R15).

-- ── the status ───────────────────────────────────────────────────────────
alter table public.monvelo_financings drop constraint monvelo_financings_status_check;
alter table public.monvelo_financings add constraint monvelo_financings_status_check check (status in (
  'REQUESTED', 'AWAITING_APPROVAL', 'OFFERED', 'HELD', 'CLAIMED', 'FUNDED', 'DELIVERED',
  'REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE', 'REPAID_LATE', 'EXPIRED',
  'CANCELLED', 'REFUND_DUE'));

-- Recreated from 20261031120000. A6 §20: OFFERED -> HELD; HELD -> CLAIMED
-- (allowed), OFFERED (declined or lapsed), CANCELLED or EXPIRED.
create or replace function public.monvelo_financings_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'REQUESTED' then
      raise exception 'a financing is created as REQUESTED' using errcode = 'P0001';
    end if;
    return new;
  end if;

  if (new.id, new.tenant_id, new.reference, new.shop_id, new.order_id, new.area_id, new.territory_id, new.raised_by,
      new.principal, new.supply_date, new.created_at)
     is distinct from
     (old.id, old.tenant_id, old.reference, old.shop_id, old.order_id, old.area_id, old.territory_id, old.raised_by,
      old.principal, old.supply_date, old.created_at) then
    raise exception 'a financing''s identity never changes' using errcode = 'P0001';
  end if;

  if new.status <> old.status and not (
       (old.status = 'REQUESTED' and new.status in ('OFFERED', 'AWAITING_APPROVAL', 'CANCELLED'))
    or (old.status = 'AWAITING_APPROVAL' and new.status in ('OFFERED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'OFFERED' and new.status in ('HELD', 'CLAIMED', 'CANCELLED', 'EXPIRED', 'FUNDED'))
    or (old.status = 'HELD' and new.status in ('CLAIMED', 'OFFERED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'CLAIMED' and new.status in ('OFFERED', 'FUNDED'))
    or (old.status = 'FUNDED' and new.status in ('DELIVERED', 'REFUND_DUE'))
    or (old.status = 'DELIVERED' and new.status in ('REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE'))
    or (old.status = 'DEFAULTED_WITH_LATE_CHARGE' and new.status = 'REPAID_LATE')) then
    raise exception 'a financing cannot move from % to %', old.status, new.status using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- ── the market makers' limit: a migration changes it ────────────────────
create or replace function public.monvelo_allowance_ceiling()
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select 300000.00::numeric(15,2);
$$;
revoke all on function public.monvelo_allowance_ceiling() from public, anon, authenticated, service_role;
comment on function public.monvelo_allowance_ceiling() is
  'A6 §20: the most a market maker may allow one agent to have open across Monvelo, in naira. A migration changes it.';

-- ── monvelo_claim_holds ─────────────────────────────────────────────────
-- One row per hold. The figures (exposure, pledge) are for Monvelo staff and
-- the audit only (call 9): no API role reads this table; market makers read
-- through Task 2's RPCs and the agent through its claim reply.
create table public.monvelo_claim_holds (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  financing_id     uuid not null,
  agent_id         uuid not null references public.monvelo_agents (id) on delete restrict,
  claimed_by       uuid not null references public.profiles (id) on delete restrict,
  blocks           text[] not null check (cardinality(blocks) > 0 and blocks <@ array['EXPOSURE_CAP']::text[]),
  exposure_before  numeric(15,2) not null,
  exposure_after   numeric(15,2) not null,
  pledge_remaining numeric(15,2) not null,
  created_at       timestamptz not null default now(),
  expires_at       timestamptz not null,
  status           text not null default 'HELD' check (status in ('HELD', 'ALLOWED', 'DECLINED', 'LAPSED')),
  decided_by       uuid references public.profiles (id) on delete restrict,
  decided_at       timestamptz,
  reason           text check (char_length(reason) <= 1000),
  unique (tenant_id, id),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  check (expires_at > created_at),
  -- a market maker decides ALLOWED and DECLINED; a lapse has no decider
  check ((status in ('ALLOWED', 'DECLINED')) = (decided_by is not null)),
  check ((status = 'HELD') = (decided_at is null))
);
create unique index monvelo_claim_holds_one_held on public.monvelo_claim_holds (financing_id) where status = 'HELD';
create index idx_monvelo_claim_holds_fin_agent  on public.monvelo_claim_holds (financing_id, agent_id);
create index idx_monvelo_claim_holds_fin_fk     on public.monvelo_claim_holds (tenant_id, financing_id);
create index idx_monvelo_claim_holds_agent_held on public.monvelo_claim_holds (agent_id) where status = 'HELD';
create index idx_monvelo_claim_holds_agent      on public.monvelo_claim_holds (agent_id);
create index idx_monvelo_claim_holds_claimed_by on public.monvelo_claim_holds (claimed_by);
create index idx_monvelo_claim_holds_decided_by on public.monvelo_claim_holds (decided_by);
create index idx_monvelo_claim_holds_expiry     on public.monvelo_claim_holds (expires_at) where status = 'HELD';

-- inserted HELD; moves once, HELD -> ALLOWED | DECLINED | LAPSED, setting only
-- status, decided_by, decided_at and reason
create or replace function public.monvelo_claim_holds_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'HELD' then
      raise exception 'a hold is created HELD' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if old.status = 'HELD' and new.status in ('ALLOWED', 'DECLINED', 'LAPSED')
     and (new.id, new.tenant_id, new.financing_id, new.agent_id, new.claimed_by, new.blocks, new.exposure_before,
          new.exposure_after, new.pledge_remaining, new.created_at, new.expires_at)
         is not distinct from
         (old.id, old.tenant_id, old.financing_id, old.agent_id, old.claimed_by, old.blocks, old.exposure_before,
          old.exposure_after, old.pledge_remaining, old.created_at, old.expires_at) then
    return new;
  end if;
  raise exception 'a hold only ends, once' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_claim_holds_guard() from public, anon, authenticated, service_role;
create trigger monvelo_claim_holds_guard before insert or update on public.monvelo_claim_holds
  for each row execute function public.monvelo_claim_holds_guard();
create trigger monvelo_claim_holds_no_delete before delete on public.monvelo_claim_holds
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_claim_holds_no_truncate before truncate on public.monvelo_claim_holds
  for each statement execute function public.monvelo_no_delete();

alter table public.monvelo_claim_holds enable row level security;
revoke all on public.monvelo_claim_holds from anon, authenticated, service_role;
comment on table public.monvelo_claim_holds is
  'A6 §20: claims held for a market maker. RLS on, no policy, nothing granted: read through SECURITY DEFINER RPCs only.';

-- ── the notice: Task 2 replaces this stub ───────────────────────────────
create or replace function public.monvelo_notify_hold(p_hold_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- A6 §20 Task 2: one notice per in-scope market maker except the raiser
  return;
end;
$$;
revoke all on function public.monvelo_notify_hold(uuid) from public, anon, authenticated, service_role;

-- ── what one agent has open ─────────────────────────────────────────────
-- Recreated from 20261031120700. A6 §20 (call 4): a HELD financing counts at
-- its principal for the agent of its open hold, so two holds never pass
-- ₦300,000 together.
create or replace function public.monvelo_agent_open_exposure(p_agent_id uuid)
returns numeric(15,2)
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(sum(case
           when f.status in ('CLAIMED', 'FUNDED', 'HELD') then f.principal
           else least(f.outstanding, f.principal)
         end), 0)::numeric(15,2)
    from public.monvelo_financings f
   where (f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent_id)
      or (f.funder_agent_id = p_agent_id
          and f.status in ('FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE'))
      -- A6 §20: held for this agent
      or (f.status = 'HELD'
          and exists (select 1 from public.monvelo_claim_holds h
                       where h.financing_id = f.id and h.status = 'HELD' and h.agent_id = p_agent_id));
$$;
revoke all on function public.monvelo_agent_open_exposure(uuid) from public, anon, authenticated, service_role;
comment on function public.monvelo_agent_open_exposure(uuid) is
  'A6 §19, §20: the agent''s open exposure: CLAIMED, HELD (its open hold) and FUNDED at principal; DELIVERED and DEFAULTED_WITH_LATE_CHARGE at least(outstanding, principal). REFUND_DUE counts nothing (R63).';

-- ── monvelo_brand_exposure: a HELD request still uses the shop's limit ──
-- Recreated from 20261031120200. A6 §20: HELD joins the live statuses, as
-- OFFERED and CLAIMED, so a hold never frees room on the shop's limit.
create or replace function public.monvelo_brand_exposure(p_tenant_id uuid, p_shop_id uuid, p_brand_key text, p_exclude uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(case
           when f.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')
             then round(coalesce(f.outstanding, f.principal) * l.amount / f.principal, 2)
           else l.amount
         end), 0)
    from public.monvelo_financing_lines l
    join public.monvelo_financings f on f.tenant_id = l.tenant_id and f.id = l.financing_id
   where f.tenant_id = p_tenant_id and f.shop_id = p_shop_id and l.brand_key = p_brand_key
     and f.status in ('AWAITING_APPROVAL', 'OFFERED', 'HELD', 'CLAIMED', 'FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')
     and f.id is distinct from p_exclude;
$$;
revoke all on function public.monvelo_brand_exposure(uuid, uuid, text, uuid) from public, anon, authenticated, service_role;

-- ── monvelo_claim_refusal: + p_exposure_ceiling ─────────────────────────
-- Recreated from 20261031120700. A new trailing parameter changes the
-- signature, so the old one is dropped; both callers (claim_monvelo_financing
-- and the late route of settle_monvelo_funding) pass five arguments and
-- resolve to the default. A6 §20:
--   * check 4 also refuses an agent a market maker declined on this request;
--   * check 7 (the pledge) and check 8 (the day) count the agent's other HELD
--     financings like CLAIMED ones (never p_fin itself: Task 2's allow passes
--     the held row read as OFFERED);
--   * the exposure check takes coalesce(p_exposure_ceiling,
--     monvelo_open_exposure_ceiling()) and leaves out p_fin when it is held
--     for this agent. It stays the LAST check, so a refusal that is the
--     exposure message means nothing else failed.
drop function public.monvelo_claim_refusal(public.monvelo_financings, public.monvelo_agents, uuid,
                                           public.monvelo_pledges, boolean);
create function public.monvelo_claim_refusal(
  p_fin              public.monvelo_financings,
  p_agent            public.monvelo_agents,
  p_member           uuid,
  p_pledge           public.monvelo_pledges,
  p_late             boolean,
  p_exposure_ceiling numeric default null
)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
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
$$;
revoke all on function public.monvelo_claim_refusal(public.monvelo_financings, public.monvelo_agents, uuid,
                                                    public.monvelo_pledges, boolean, numeric)
  from public, anon, authenticated, service_role;

-- ── claim_monvelo_financing: holds instead of refusing ──────────────────
-- Recreated from 20261031120050. A6 §20 (§20.4 step 2): after the existing
-- locks, a refusal that is the exposure message (the last check, so nothing
-- else failed) is re-run at monvelo_allowance_ceiling(). If that passes, the
-- claim is held: a monvelo_claim_holds row, the financing OFFERED -> HELD (its
-- preferred window ends, call 8), a tenant-null audit row (R15), the market
-- makers' notice, and the reply {held, hold_id, expires_at}. An agent whose
-- hold on this request lapsed is not held again (call 8). Anything else is
-- refused as before.
create or replace function public.claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_hold     constant interval := interval '15 minutes';
  v_uid      uuid := (select auth.uid());
  v_prior    jsonb;
  v_fin      public.monvelo_financings;
  v_agent    public.monvelo_agents;
  v_ps       public.monvelo_platform_settings;
  v_pledge   public.monvelo_pledges;
  v_refusal  text;
  v_exposure numeric(15,2);
  v_hold     public.monvelo_claim_holds;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.monvelo_agent_members m
                  where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'claim_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- R13: one agent's claims and late fundings queue on one advisory lock, taken
  -- before any row lock; then the agent row, so its caps are read once at a time
  perform pg_advisory_xact_lock(hashtextextended('monvelo_agent:' || p_agent_id::text, 0));
  select * into v_agent from public.monvelo_agents a where a.id = p_agent_id for update;
  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id for update;
  if v_fin.id is not null then
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = p_agent_id
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
       for update;
  end if;

  v_refusal := public.monvelo_claim_refusal(v_fin, v_agent, v_uid, v_pledge, false);

  -- A6 §20: blocked only by the exposure cap, and within the market makers' limit
  if v_refusal like 'this request would take your open exposure above %'
     and public.monvelo_claim_refusal(v_fin, v_agent, v_uid, v_pledge, false, public.monvelo_allowance_ceiling()) is null then
    if exists (select 1 from public.monvelo_claim_holds h
                where h.financing_id = v_fin.id and h.agent_id = p_agent_id and h.status = 'LAPSED') then
      raise exception 'this request was already held for you' using errcode = 'P0001';
    end if;

    v_exposure := public.monvelo_agent_open_exposure(p_agent_id);
    insert into public.monvelo_claim_holds (tenant_id, financing_id, agent_id, claimed_by, blocks,
                                            exposure_before, exposure_after, pledge_remaining, expires_at)
    values (v_fin.tenant_id, v_fin.id, p_agent_id, v_uid, array['EXPOSURE_CAP'],
            v_exposure, v_exposure + v_fin.principal, v_pledge.remaining, now() + c_hold)
    returning * into v_hold;
    update public.monvelo_financings
       set status = 'HELD', preferred_window_ends_at = null
     where id = v_fin.id
    returning * into v_fin;

    -- R15: the row names the agent, so no tenant reads it
    perform public.write_audit(null, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'OFFERED'),
      jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id, 'agent_id', p_agent_id, 'blocks', v_hold.blocks,
                         'exposure_before', v_hold.exposure_before, 'exposure_after', v_hold.exposure_after,
                         'pledge_remaining', v_hold.pledge_remaining, 'expires_at', v_hold.expires_at),
      p_idempotency_key);

    perform public.monvelo_notify_hold(v_hold.id);

    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'held', true, 'hold_id', v_hold.id, 'expires_at', v_hold.expires_at,
      'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status, 'principal', v_fin.principal));
  end if;

  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;

  select * into v_ps from public.monvelo_platform_settings;
  update public.monvelo_financings
     set status = 'CLAIMED', claimed_by_agent_id = p_agent_id, claimed_by = v_uid,
         claim_expires_at = now() + make_interval(mins => v_ps.claim_minutes),
         pledge_id = v_pledge.id, preferred_window_ends_at = null
   where id = v_fin.id
  returning * into v_fin;
  insert into public.monvelo_financing_claims (tenant_id, financing_id, agent_id, claimed_by, pledge_id, expires_at)
  values (v_fin.tenant_id, v_fin.id, p_agent_id, v_uid, v_pledge.id, v_fin.claim_expires_at);

  -- R15: the row names the agent and its pledge, so no tenant reads it
  perform public.write_audit(null, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'OFFERED'),
    jsonb_build_object('status', v_fin.status, 'agent_id', p_agent_id, 'pledge_id', v_pledge.id,
                       'claim_expires_at', v_fin.claim_expires_at),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'claim_expires_at', v_fin.claim_expires_at, 'principal', v_fin.principal));
end;
$$;

-- ── monvelo_sweep_offers: lapses holds ──────────────────────────────────
-- Recreated from 20261031120050. A6 §20:
--   1b. a HELD financing whose hold passed expires_at: the hold LAPSED, the
--       financing back to OFFERED (no new preferred window), a tenant-null row;
--       counted in "lapsed" with the claims, so the reply's shape is unchanged;
--   2.  the supply-day end and a trade order no longer PENDING (the stock
--       sweep's cancellation) end a HELD request as an OFFERED one (EXPIRED),
--       and its hold LAPSED with a tenant-null row.
-- Lock order: the financing, then its hold (the claim's order).
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

  -- 1b. A6 §20: holds nobody decided within 15 minutes: back to OFFERED
  for v_fin in
    select f.* from public.monvelo_financings f
     where f.status = 'HELD'
       and exists (select 1 from public.monvelo_claim_holds h
                    where h.financing_id = f.id and h.status = 'HELD' and h.expires_at <= now())
     order by f.id
       for update of f skip locked
  loop
    update public.monvelo_claim_holds set status = 'LAPSED', decided_at = now()
     where financing_id = v_fin.id and status = 'HELD'
    returning * into v_hold;
    update public.monvelo_financings set status = 'OFFERED', preferred_window_ends_at = null where id = v_fin.id;
    -- R15: the lapse names the agent, so no tenant reads it
    perform public.write_audit(null, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id, 'agent_id', v_hold.agent_id),
      jsonb_build_object('status', 'OFFERED', 'hold_status', 'LAPSED', 'reason', 'HOLD_LAPSED'),
      null, 'CRON', v_fin.raised_by);
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
      update public.monvelo_claim_holds set status = 'LAPSED', decided_at = now()
       where financing_id = v_fin.id and status = 'HELD'
      returning * into v_hold;
      -- R15: it names the agent, so no tenant reads it
      perform public.write_audit(null, 'monvelo_sweep_offers', 'monvelo_claim_holds', v_hold.id::text,
        jsonb_build_object('status', 'HELD', 'agent_id', v_hold.agent_id, 'financing_id', v_fin.id),
        jsonb_build_object('status', 'LAPSED',
                           'reason', case when v_ended then 'SUPPLY_DAY_ENDED' else 'ORDER_NOT_PENDING' end),
        null, 'CRON', v_fin.raised_by);
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
