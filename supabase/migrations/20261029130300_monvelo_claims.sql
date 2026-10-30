-- Addendum A6 §7.1, §7.3, §18.1, §18.2 (Monvelo Step 2, Task 8) — claims under
-- the allocation rule, the agent's open offers, the minute sweep, and the
-- raiser's overdue share.
--
-- Allocation (§7.1): during the preferred window only the shop's preferred
-- agent may claim; then any ACTIVE agent within offer_radius_m whose pledge for
-- the area and supply day covers the principal, within its caps. One open claim
-- per financing; a claim lasts claim_minutes and an agent whose claim lapsed
-- cannot claim that request again.
--
-- The sweep (every minute, pure SQL): lapsed claims go back to OFFERED; then a
-- request still OFFERED or AWAITING_APPROVAL at the end of its Lagos supply day,
-- or whose trade order is no longer PENDING (the stock sweep cancels unpaid trade
-- orders at the end of their supply day, A6 §18.1), is EXPIRED, and its trade
-- order is cancelled and its stock released while it is still PENDING.

-- ── monvelo_financing_claims ────────────────────────────────────────────
create table public.monvelo_financing_claims (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  financing_id uuid not null,
  agent_id     uuid not null references public.monvelo_agents (id) on delete restrict,
  claimed_by   uuid not null references public.profiles (id) on delete restrict,
  pledge_id    uuid not null,
  claimed_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  outcome      text check (outcome in ('LAPSED', 'FUNDED', 'EXPIRED')),
  ended_at     timestamptz,
  unique (tenant_id, id),
  check ((outcome is null) = (ended_at is null)),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  foreign key (tenant_id, pledge_id)    references public.monvelo_pledges (tenant_id, id) on delete restrict
);
create unique index monvelo_financing_claims_one_open on public.monvelo_financing_claims (financing_id)
  where outcome is null;
create index idx_monvelo_financing_claims_agent_fin  on public.monvelo_financing_claims (financing_id, agent_id);
create index idx_monvelo_financing_claims_financing  on public.monvelo_financing_claims (tenant_id, financing_id);
create index idx_monvelo_financing_claims_agent      on public.monvelo_financing_claims (agent_id);
create index idx_monvelo_financing_claims_claimed_by on public.monvelo_financing_claims (claimed_by);
create index idx_monvelo_financing_claims_pledge     on public.monvelo_financing_claims (tenant_id, pledge_id);

-- a claim ends once: only outcome and ended_at are ever set, and never again
create or replace function public.monvelo_financing_claims_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.outcome is null and new.outcome is not null
     and (new.id, new.tenant_id, new.financing_id, new.agent_id, new.claimed_by, new.pledge_id, new.claimed_at, new.expires_at)
         is not distinct from
         (old.id, old.tenant_id, old.financing_id, old.agent_id, old.claimed_by, old.pledge_id, old.claimed_at, old.expires_at) then
    return new;
  end if;
  raise exception 'a claim only ends, once' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_financing_claims_guard() from public, anon, authenticated, service_role;
create trigger monvelo_financing_claims_guard before update on public.monvelo_financing_claims
  for each row execute function public.monvelo_financing_claims_guard();
create trigger monvelo_financing_claims_no_delete before delete on public.monvelo_financing_claims
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_financing_claims_no_truncate before truncate on public.monvelo_financing_claims
  for each statement execute function public.monvelo_no_delete();

alter table public.monvelo_financing_claims enable row level security;
revoke all on public.monvelo_financing_claims from anon, authenticated, service_role;
grant select on public.monvelo_financing_claims to authenticated;
create policy monvelo_financing_claims_select on public.monvelo_financing_claims for select to authenticated
  using (
    agent_id in (select public.my_monvelo_agent_ids())
    or (tenant_id, financing_id) in (select f.tenant_id, f.id from public.monvelo_financings f)
    or (select public.is_monvelo_staff()));

-- ── claim_monvelo_financing ─────────────────────────────────────────────
create or replace function public.claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prior     jsonb;
  v_fin       public.monvelo_financings;
  v_agent     public.monvelo_agents;
  v_shop      public.retail_shops;
  v_ps        public.monvelo_platform_settings;
  v_pledge    public.monvelo_pledges;
  v_committed numeric(15,2);
  v_today     date := public.monvelo_today();
  v_daily     numeric(15,2);
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

  -- the agent row is locked first so one agent's claims queue for its caps
  select * into v_agent from public.monvelo_agents a where a.id = p_agent_id for update;
  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id for update;

  -- 1. still open, and its trade order still PENDING
  if v_fin.id is null or v_fin.status <> 'OFFERED'
     or not exists (select 1 from public.orders o
                     where o.tenant_id = v_fin.tenant_id and o.id = v_fin.order_id and o.status = 'PENDING') then
    raise exception 'this request is no longer open' using errcode = 'P0001';
  end if;

  -- 2. the agent; 3. the enrolment
  if v_agent.status <> 'ACTIVE' then
    raise exception 'the agent is not active' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = v_fin.tenant_id and e.shop_id = v_fin.shop_id and e.status = 'ACTIVE') then
    raise exception 'the shop is no longer enrolled' using errcode = 'P0001';
  end if;

  -- the platform hard freeze (A6 §18.2): funding is new credit too
  if exists (select 1 from public.monvelo_financings f
              where f.shop_id = v_fin.shop_id and f.status = 'DEFAULTED_WITH_LATE_CHARGE') then
    raise exception 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared'
      using errcode = 'P0001';
  end if;

  -- 4. one claim per agent per request
  if exists (select 1 from public.monvelo_financing_claims c
              where c.financing_id = v_fin.id and c.agent_id = p_agent_id and c.outcome = 'LAPSED') then
    raise exception 'your claim on this request lapsed; another agent may claim it' using errcode = 'P0001';
  end if;

  -- 5. the preferred window
  if v_fin.preferred_window_ends_at > now() and v_fin.preferred_agent_id is distinct from p_agent_id then
    raise exception 'the shop''s preferred agent has first claim until %',
      to_char(v_fin.preferred_window_ends_at at time zone 'Africa/Lagos', 'HH24:MI') using errcode = 'P0001';
  end if;

  -- 6. distance: the shop's preferred agent is exempt
  select * into v_ps from public.monvelo_platform_settings;
  select * into v_shop from public.retail_shops s where s.id = v_fin.shop_id;
  if v_shop.preferred_agent_id is distinct from p_agent_id
     and not extensions.st_dwithin(v_agent.location, v_shop.location::extensions.geography, v_ps.offer_radius_m) then
    raise exception 'this shop is outside your area' using errcode = 'P0001';
  end if;

  -- 7. the agent's pledge for the area and day, less what its other claims hold
  select * into v_pledge from public.monvelo_pledges p
   where p.tenant_id = v_fin.tenant_id and p.agent_id = p_agent_id
     and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
     for update;
  if found then
    select coalesce(sum(f.principal), 0) into v_committed from public.monvelo_financings f
     where f.tenant_id = v_pledge.tenant_id and f.pledge_id = v_pledge.id and f.status = 'CLAIMED' and f.id <> v_fin.id;
  end if;
  if v_pledge.id is null or v_pledge.remaining - v_committed < v_fin.principal then
    raise exception 'pledge enough funds for this area and day first' using errcode = 'P0001';
  end if;

  -- 8. caps: per financing, and per Lagos day (claimed now plus funded today)
  if v_fin.principal > v_agent.per_financing_cap then
    raise exception 'this request is above your per-financing cap' using errcode = 'P0001';
  end if;
  select coalesce(sum(f.principal) filter (where f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent_id), 0)
       + coalesce(sum(f.principal) filter (where f.funder_agent_id = p_agent_id
                                             and (f.funded_at at time zone 'Africa/Lagos')::date = v_today), 0)
    into v_daily
    from public.monvelo_financings f
   where f.claimed_by_agent_id = p_agent_id or f.funder_agent_id = p_agent_id;
  if v_daily + v_fin.principal > v_agent.daily_cap then
    raise exception 'this request would pass your daily cap' using errcode = 'P0001';
  end if;

  update public.monvelo_financings
     set status = 'CLAIMED', claimed_by_agent_id = p_agent_id, claimed_by = v_uid,
         claim_expires_at = now() + make_interval(mins => v_ps.claim_minutes),
         pledge_id = v_pledge.id, preferred_window_ends_at = null
   where id = v_fin.id
  returning * into v_fin;
  insert into public.monvelo_financing_claims (tenant_id, financing_id, agent_id, claimed_by, pledge_id, expires_at)
  values (v_fin.tenant_id, v_fin.id, p_agent_id, v_uid, v_pledge.id, v_fin.claim_expires_at);

  perform public.write_audit(v_fin.tenant_id, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'OFFERED'),
    jsonb_build_object('status', v_fin.status, 'agent_id', p_agent_id, 'pledge_id', v_pledge.id,
                       'claim_expires_at', v_fin.claim_expires_at),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'claim_expires_at', v_fin.claim_expires_at, 'principal', v_fin.principal));
end;
$$;
revoke all on function public.claim_monvelo_financing(uuid, uuid, uuid) from public, anon;
grant execute on function public.claim_monvelo_financing(uuid, uuid, uuid) to authenticated;

-- ── monvelo_open_offers: what an agent could claim now ──────────────────
-- Today's OFFERED requests with an ACTIVE enrolment and a PENDING trade order,
-- for a shop that is not frozen, that this agent has not let lapse, and either
-- in this agent's own preferred window, or past any window and within reach
-- (the shop's preferred agent, or within the radius) with enough pledged.
-- Never the owner's name or phone.
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
                                    where o2.tenant_id = p.tenant_id and o2.pledge_id = p.id and o2.status = 'CLAIMED')
                    >= f.principal)))
   order by 7, f.offered_at, f.id;
end;
$$;
revoke all on function public.monvelo_open_offers(uuid) from public, anon;
grant execute on function public.monvelo_open_offers(uuid) to authenticated;

-- ── monvelo_sweep_offers: every minute ──────────────────────────────────
create or replace function public.monvelo_sweep_offers()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin     public.monvelo_financings;
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
    perform public.write_audit(v_fin.tenant_id, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'CLAIMED', 'agent_id', v_fin.claimed_by_agent_id),
      jsonb_build_object('status', 'OFFERED', 'reason', 'CLAIM_LAPSED'),
      null, 'CRON', v_fin.raised_by);
    v_lapsed := v_lapsed + 1;
  end loop;

  -- 2. the supply day (Lagos) has ended, or the trade order is no longer PENDING
  for v_fin in
    select f.* from public.monvelo_financings f
      join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
     where f.status in ('OFFERED', 'AWAITING_APPROVAL')
       and (now() >= ((f.supply_date + 1)::timestamp at time zone 'Africa/Lagos') or o.status <> 'PENDING')
     order by f.id
       for update of f skip locked
  loop
    v_ended := now() >= ((v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos');
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
revoke all on function public.monvelo_sweep_offers() from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('monvelo-offer-sweep', '* * * * *', $$select public.monvelo_sweep_offers()$$);

-- ── request_monvelo_financing: plus the raiser's overdue share (§7.3) ───
-- Recreated from its live definition (20261029130200); signature and grants unchanged.
create or replace function public.request_monvelo_financing(p_idempotency_key uuid, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me        public.tenant_users :=
    public.assert_tenant_role(array['ZSA', 'ASA', 'TM']::public.tenant_role_enum[]);
  v_prior     jsonb;
  v_settings  public.monvelo_tenant_settings;
  v_overdue   numeric(15,2);
  v_book      numeric(15,2);
  v_order     public.orders;
  v_enrol     public.monvelo_shop_enrolments;
  v_area      public.areas;
  v_on_beat   boolean;
  v_today     date := public.monvelo_today();
  v_cleared   timestamptz;
  v_resume    date;
  v_brand     record;
  v_terms     public.monvelo_brand_terms;
  v_limit     public.monvelo_shop_limits;
  v_reset     numeric(15,2);
  v_approval  boolean := false;
  v_brands    text[] := '{}';
  v_keys      text[] := '{}';
  v_amounts   numeric[] := '{}';
  v_ref       text;
  v_fin       public.monvelo_financings;
  i           integer;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_monvelo_financing',
    jsonb_build_object('order_id', p_order_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- 1. the tenant lends through Monvelo
  select * into v_settings from public.monvelo_tenant_settings where tenant_id = v_me.tenant_id;
  if not found or not v_settings.enabled then
    raise exception 'Monvelo is not switched on for this tenant' using errcode = 'P0001';
  end if;

  -- 2. a PENDING trade order of the tenant; 3. raised by the caller
  select * into v_order from public.orders o
   where o.tenant_id = v_me.tenant_id and o.id = p_order_id
     for update;
  if not found or v_order.channel <> 'FIELD_SALES' or v_order.status <> 'PENDING' then
    raise exception 'only a pending trade order can be financed' using errcode = 'P0001';
  end if;
  if v_order.teafair_agent_id is distinct from v_me.profile_id then
    raise exception 'only the order''s raiser requests its financing' using errcode = '42501';
  end if;

  -- §7.3: a raiser whose PAR30 (outstanding over 30 days past due, over the
  -- outstanding of everything they raised that has been delivered) passes 10%
  -- raises nothing new, with any tenant, until it drops
  select coalesce(sum(coalesce(f.outstanding, f.principal))
                    filter (where f.status = 'DEFAULTED_WITH_LATE_CHARGE' and f.due_at <= now() - interval '30 days'), 0),
         coalesce(sum(coalesce(f.outstanding, f.principal)), 0)
    into v_overdue, v_book
    from public.monvelo_financings f
   where f.raised_by = v_me.profile_id and f.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE');
  if v_book > 0 and v_overdue * 10 > v_book then
    raise exception 'more than 10%% of the Monvelo credit you raised is over 30 days overdue; you can raise new requests once it drops'
      using errcode = 'P0001';
  end if;

  -- new app work (A6 §18.4): the order's state must be on for the app, platform and brand
  perform public.assert_state_app_operational(v_me.tenant_id, v_order.territory_id);

  -- 4. one live financing per order
  if exists (select 1 from public.monvelo_financings f
              where f.tenant_id = v_me.tenant_id and f.order_id = v_order.id
                and f.status not in ('CANCELLED', 'EXPIRED')) then
    raise exception 'this order already has a Monvelo financing' using errcode = 'P0001';
  end if;

  -- 5. the shop is enrolled with the owner's consent
  select * into v_enrol from public.monvelo_shop_enrolments e
   where e.tenant_id = v_me.tenant_id and e.shop_id = v_order.retail_shop_id;
  if not found or v_enrol.status <> 'ACTIVE' then
    raise exception 'the shop is not enrolled in Monvelo' using errcode = 'P0001';
  end if;

  -- 6. on the caller's beat: the ASA's own area, the ZSA's zone, the TM's territory
  select * into v_area from public.areas a where a.tenant_id = v_me.tenant_id and a.id = v_enrol.area_id;
  v_on_beat := case v_me.role
    when 'ASA' then v_me.area_id is not distinct from v_area.id
    when 'ZSA' then exists (select 1 from public.territories t
                             where t.tenant_id = v_me.tenant_id and t.id = v_area.territory_id
                               and t.zone_id = v_me.zone_id)
    else v_me.territory_id is not distinct from v_area.territory_id
  end;
  if not v_on_beat then
    raise exception 'the shop is not on your beat' using errcode = '42501';
  end if;

  -- 7. the order belongs to the area's territory
  if v_order.territory_id is distinct from v_area.territory_id then
    raise exception 'the order was placed in another territory' using errcode = 'P0001';
  end if;

  -- 8. the owner's own phone is verified
  if not exists (select 1 from public.retail_shops s
                   join public.profiles p on p.id = s.owner_id
                   join auth.users u on u.id = p.id
                  where s.id = v_order.retail_shop_id
                    and p.phone_number is not null and u.phone_confirmed_at is not null) then
    raise exception 'the shop owner has no verified phone' using errcode = 'P0001';
  end if;

  -- 9. today (Lagos) is a supply day for the area
  if not exists (select 1 from public.monvelo_supply_days d
                  where d.tenant_id = v_me.tenant_id and d.area_id = v_area.id
                    and d.day_of_week = extract(isodow from v_today)::int and d.active) then
    raise exception 'today is not a supply day for this area' using errcode = 'P0001';
  end if;

  -- the shop's last cleared default, with any tenant (A6 §18.2): each tenant
  -- applies its own cure days and restart limit to it
  select max(coalesce(f.closed_at, f.updated_at)) into v_cleared
    from public.monvelo_financings f
   where f.shop_id = v_order.retail_shop_id and f.status = 'REPAID_LATE';

  -- 10. every brand of the order, or none of it
  for v_brand in
    select min(p.brand) as brand, lower(btrim(p.brand)) as brand_key, sum(i2.line_total) as amount
      from public.order_items i2
      join public.central_products p on p.tenant_id = i2.tenant_id and p.sku_code = i2.sku_code
     where i2.tenant_id = v_me.tenant_id and i2.order_id = v_order.id
     group by lower(btrim(p.brand))
     order by lower(btrim(p.brand))
  loop
    v_terms := public.monvelo_terms_at(v_me.tenant_id, v_brand.brand, v_today);
    if v_terms.id is null then
      raise exception '% has no approved Monvelo terms', v_brand.brand using errcode = 'P0001';
    end if;

    -- the platform hard freeze: read across tenants, named to none
    if exists (select 1 from public.monvelo_financings f
                where f.shop_id = v_order.retail_shop_id and f.status = 'DEFAULTED_WITH_LATE_CHARGE') then
      raise exception 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared'
        using errcode = 'P0001';
    end if;

    -- the brand's cure rule
    if v_cleared is not null then
      v_resume := (v_cleared at time zone 'Africa/Lagos')::date + v_settings.default_cure_days;
      if v_today < v_resume then
        raise exception '% credit resumes on %', v_brand.brand, to_char(v_resume, 'YYYY-MM-DD') using errcode = 'P0001';
      end if;
    end if;

    v_limit := public.monvelo_shop_limit_for(v_me.tenant_id, v_order.retail_shop_id, v_brand.brand_key);
    -- after a cure the limit restarts at post_default_limit_bps of the opening
    -- limit, once per cleared default
    if v_cleared is not null and not exists (
         select 1 from public.monvelo_shop_limit_events e
          where e.tenant_id = v_me.tenant_id and e.shop_id = v_order.retail_shop_id
            and e.brand_key = v_brand.brand_key and e.kind = 'RESET' and e.created_at >= v_cleared) then
      v_reset := round(v_settings.opening_limit * v_settings.post_default_limit_bps / 10000.0, 2);
      insert into public.monvelo_shop_limit_events (tenant_id, shop_id, brand_key, kind, old_limit, new_limit)
      values (v_me.tenant_id, v_order.retail_shop_id, v_brand.brand_key, 'RESET', v_limit.limit_amount, v_reset);
      update public.monvelo_shop_limits
         set limit_amount = v_reset, status = 'ACTIVE'
       where tenant_id = v_me.tenant_id and shop_id = v_order.retail_shop_id and brand_key = v_brand.brand_key
      returning * into v_limit;
    end if;

    -- above the limit: the TM approves (§7.2)
    if public.monvelo_brand_exposure(v_me.tenant_id, v_order.retail_shop_id, v_brand.brand_key, null)
       + v_brand.amount > v_limit.limit_amount then
      v_approval := true;
    end if;

    v_brands := v_brands || v_brand.brand;
    v_keys := v_keys || v_brand.brand_key;
    v_amounts := v_amounts || v_brand.amount;
  end loop;

  if coalesce(array_length(v_keys, 1), 0) = 0 then
    raise exception 'only a pending trade order can be financed' using errcode = 'P0001';
  end if;

  -- a fresh reference: a collision is about one in 10^12, so three draws suffice
  for i in 1 .. 3 loop
    v_ref := public.monvelo_draw_reference();
    exit when not exists (select 1 from public.monvelo_financings f where f.reference = v_ref);
  end loop;

  insert into public.monvelo_financings (tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
                                         principal, supply_date, status, approval_required)
  values (v_me.tenant_id, v_ref, v_order.retail_shop_id, v_order.id, v_area.id, v_area.territory_id, v_me.profile_id,
          v_order.total_amount, v_today, 'REQUESTED', v_approval)
  returning * into v_fin;

  for i in 1 .. array_length(v_keys, 1) loop
    insert into public.monvelo_financing_lines (tenant_id, financing_id, brand, brand_key, amount)
    values (v_me.tenant_id, v_fin.id, v_brands[i], v_keys[i], v_amounts[i]);
  end loop;

  if v_approval then
    update public.monvelo_financings set status = 'AWAITING_APPROVAL' where id = v_fin.id returning * into v_fin;
  else
    v_fin := public.monvelo_offer(v_fin.id);
  end if;

  perform public.write_audit(v_me.tenant_id, 'request_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    null,
    jsonb_build_object('reference', v_fin.reference, 'order_id', v_fin.order_id, 'shop_id', v_fin.shop_id,
                       'principal', v_fin.principal, 'status', v_fin.status, 'approval_required', v_approval,
                       'preferred_agent_id', v_fin.preferred_agent_id,
                       'lines', (select jsonb_agg(jsonb_build_object('brand', b, 'amount', a))
                                   from unnest(v_brands, v_amounts) as x (b, a))),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'principal', v_fin.principal, 'approval_required', v_approval));
end;
$$;
revoke all on function public.request_monvelo_financing(uuid, uuid) from public, anon;
grant execute on function public.request_monvelo_financing(uuid, uuid) to authenticated;
