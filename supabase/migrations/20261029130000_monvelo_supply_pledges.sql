-- Addendum A6 §4.3, §7.1, §8, §16.6 (Step 2, Task 5) — Monvelo platform
-- settings, the Lagos date, supply days, pledges, the agents' totals-only
-- supply-day read and the staff-only agent proximity search.
--
--   monvelo_platform_settings  one row, platform-wide, changed only by a
--                              migration (no RPC writes it)
--   monvelo_today()            today's date in Lagos
--   monvelo_supply_days        the TM's weekly supply days per area
--   monvelo_pledges            an agent's pledged funds for one area and date
--
-- There is no cash-order threshold (user ruling 2026-10-30).

-- ── monvelo_platform_settings ───────────────────────────────────────────
create table public.monvelo_platform_settings (
  id                       boolean primary key default true check (id),
  offer_radius_m           integer not null default 1000 check (offer_radius_m between 100 and 50000),
  preferred_window_minutes integer not null default 10 check (preferred_window_minutes > 0),
  claim_minutes            integer not null default 15 check (claim_minutes > 0),
  updated_at               timestamptz not null default now()
);
alter table public.monvelo_platform_settings enable row level security;
create trigger monvelo_platform_settings_set_updated_at before update on public.monvelo_platform_settings
  for each row execute function public.set_updated_at();
insert into public.monvelo_platform_settings (id) values (true);

revoke all on public.monvelo_platform_settings from anon, authenticated;
grant select on public.monvelo_platform_settings to authenticated;
create policy monvelo_platform_settings_select on public.monvelo_platform_settings
  for select to authenticated
  using (true);

-- Internal getter for the functions that follow.
create function public.monvelo_settings()
returns public.monvelo_platform_settings
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s from public.monvelo_platform_settings s where s.id;
$$;
revoke all on function public.monvelo_settings() from public, anon, authenticated, service_role;

-- ── monvelo_today ───────────────────────────────────────────────────────
create function public.monvelo_today()
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Africa/Lagos')::date;
$$;
revoke all on function public.monvelo_today() from public, anon;
grant execute on function public.monvelo_today() to authenticated, service_role;

-- ── records are never deleted (§7.4) ────────────────────────────────────
create function public.monvelo_refuse_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '% rows are never deleted', tg_table_name using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_refuse_delete() from public, anon, authenticated, service_role;

-- ── agent location index (proximity search) ─────────────────────────────
create index idx_monvelo_agents_location on public.monvelo_agents using gist (location);

-- ── monvelo_supply_days ─────────────────────────────────────────────────
create table public.monvelo_supply_days (
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  area_id      uuid not null,
  day_of_week  integer not null check (day_of_week between 1 and 7),
  active       boolean not null default true,
  set_by       uuid not null references public.profiles (id) on delete restrict,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, area_id, day_of_week),
  foreign key (tenant_id, area_id) references public.areas (tenant_id, id) on delete restrict
);
alter table public.monvelo_supply_days enable row level security;
create index idx_monvelo_supply_days_set_by on public.monvelo_supply_days (set_by);
create trigger monvelo_supply_days_set_updated_at before update on public.monvelo_supply_days
  for each row execute function public.set_updated_at();
create trigger monvelo_supply_days_no_delete before delete on public.monvelo_supply_days
  for each row execute function public.monvelo_refuse_delete();
create trigger monvelo_supply_days_no_truncate before truncate on public.monvelo_supply_days
  for each statement execute function public.monvelo_refuse_delete();

revoke all on public.monvelo_supply_days from anon, authenticated;
grant select on public.monvelo_supply_days to authenticated;
create policy monvelo_supply_days_select on public.monvelo_supply_days
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()) or (select public.is_monvelo_staff()));

-- ── monvelo_pledges ─────────────────────────────────────────────────────
create table public.monvelo_pledges (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  agent_id     uuid not null references public.monvelo_agents (id) on delete restrict,
  area_id      uuid not null,
  supply_date  date not null,
  amount       numeric(15,2) not null check (amount > 0),
  remaining    numeric(15,2) not null check (remaining >= 0 and remaining <= amount),
  pledged_by   uuid not null references public.profiles (id) on delete restrict,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (agent_id, tenant_id, area_id, supply_date),
  foreign key (tenant_id, area_id) references public.areas (tenant_id, id) on delete restrict
);
alter table public.monvelo_pledges enable row level security;
create index idx_monvelo_pledges_area on public.monvelo_pledges (tenant_id, area_id, supply_date);
create index idx_monvelo_pledges_pledged_by on public.monvelo_pledges (pledged_by);
create trigger monvelo_pledges_set_updated_at before update on public.monvelo_pledges
  for each row execute function public.set_updated_at();
create trigger monvelo_pledges_no_delete before delete on public.monvelo_pledges
  for each row execute function public.monvelo_refuse_delete();
create trigger monvelo_pledges_no_truncate before truncate on public.monvelo_pledges
  for each statement execute function public.monvelo_refuse_delete();

revoke all on public.monvelo_pledges from anon, authenticated;
grant select on public.monvelo_pledges to authenticated;
create policy monvelo_pledges_select on public.monvelo_pledges
  for select to authenticated
  using (agent_id in (select public.my_monvelo_agent_ids()) or (select public.is_monvelo_staff()));

-- ── set_monvelo_supply_day ──────────────────────────────────────────────
create function public.set_monvelo_supply_day(
  p_idempotency_key uuid, p_area_id uuid, p_day_of_week integer, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_area   public.areas;
  v_before public.monvelo_supply_days;
  v_after  public.monvelo_supply_days;
begin
  select * into v_area from public.areas
   where id = p_area_id and tenant_id = v_me.tenant_id;
  if not found or v_me.role <> 'TM' or v_area.territory_id is distinct from v_me.territory_id then
    raise exception 'supply days are set by the TM of the area''s territory' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_supply_day',
    jsonb_build_object('area_id', p_area_id, 'day_of_week', p_day_of_week, 'active', p_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_day_of_week is null or p_day_of_week not between 1 and 7 or p_active is null then
    raise exception 'a weekday from 1 (Monday) to 7 and an active flag are required' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_supply_days
   where tenant_id = v_me.tenant_id and area_id = p_area_id and day_of_week = p_day_of_week
   for update;

  insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by)
  values (v_me.tenant_id, p_area_id, p_day_of_week, p_active, v_me.profile_id)
  on conflict (tenant_id, area_id, day_of_week) do update
    set active = excluded.active, set_by = excluded.set_by
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_supply_day', 'monvelo_supply_days',
                             p_area_id::text || ':' || p_day_of_week::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('area_id', p_area_id, 'day_of_week', p_day_of_week, 'active', v_after.active));
end;
$$;
revoke all on function public.set_monvelo_supply_day(uuid, uuid, integer, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_monvelo_supply_day(uuid, uuid, integer, boolean) to authenticated, service_role;

-- ── pledge_monvelo_funds ────────────────────────────────────────────────
create function public.pledge_monvelo_funds(
  p_idempotency_key uuid, p_agent_id uuid, p_area_id uuid, p_supply_date date, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_prior   jsonb;
  v_status  text;
  v_area    public.areas;
  v_before  public.monvelo_pledges;
  v_after   public.monvelo_pledges;
  v_amount  numeric(15,2);
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_agent_id is null or not exists (select 1 from public.my_monvelo_agent_ids() m(id) where m.id = p_agent_id) then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'pledge_monvelo_funds',
    jsonb_build_object('agent_id', p_agent_id, 'area_id', p_area_id,
                       'supply_date', p_supply_date, 'amount', p_amount));
  if v_prior is not null then
    return v_prior;
  end if;

  select a.status into v_status from public.monvelo_agents a where a.id = p_agent_id;
  if v_status is distinct from 'ACTIVE' then
    raise exception 'the agent is not active' using errcode = 'P0001';
  end if;

  if p_amount is null or p_amount <= 0 or p_supply_date is null or p_area_id is null then
    raise exception 'an area, a supply date and a positive amount are required' using errcode = 'P0001';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'an area, a supply date and a positive amount are required' using errcode = 'P0001';
  end if;

  select * into v_area from public.areas where id = p_area_id;
  if not found then
    raise exception 'area not found' using errcode = 'P0001';
  end if;
  if not coalesce((select ts.enabled from public.monvelo_tenant_settings ts
                    where ts.tenant_id = v_area.tenant_id), false) then
    raise exception 'Monvelo is not enabled for this area''s tenant' using errcode = 'P0001';
  end if;

  if p_supply_date < public.monvelo_today()
     or not exists (select 1 from public.monvelo_supply_days d
                     where d.tenant_id = v_area.tenant_id and d.area_id = p_area_id
                       and d.day_of_week = extract(isodow from p_supply_date)::int and d.active) then
    raise exception 'that date is not a supply day for this area' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_pledges
   where agent_id = p_agent_id and tenant_id = v_area.tenant_id
     and area_id = p_area_id and supply_date = p_supply_date
   for update;

  if not found then
    insert into public.monvelo_pledges (tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
    values (v_area.tenant_id, p_agent_id, p_area_id, p_supply_date, v_amount, v_amount, v_uid)
    returning * into v_after;
  else
    if v_before.remaining + (v_amount - v_before.amount) < 0 then
      raise exception 'a pledge cannot drop below what is already funded' using errcode = 'P0001';
    end if;
    update public.monvelo_pledges
       set amount = v_amount,
           remaining = v_before.remaining + (v_amount - v_before.amount),
           pledged_by = v_uid
     where id = v_before.id
    returning * into v_after;
  end if;

  perform public.write_audit(v_area.tenant_id, 'pledge_monvelo_funds', 'monvelo_pledges', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('pledge_id', v_after.id, 'amount', v_after.amount, 'remaining', v_after.remaining));
end;
$$;
revoke all on function public.pledge_monvelo_funds(uuid, uuid, uuid, date, numeric) from public, anon, authenticated, service_role;
grant execute on function public.pledge_monvelo_funds(uuid, uuid, uuid, date, numeric) to authenticated, service_role;

-- ── monvelo_supply_days_near ────────────────────────────────────────────
-- An agent's upcoming supply days, with the COUNT of enrolled shops within the
-- offer radius. Totals only: no shop rows, names or locations (§16.6).
create function public.monvelo_supply_days_near(p_agent_id uuid, p_days integer default 7)
returns table (area_id uuid, area_name text, supply_date date, shop_count integer)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_days   integer := least(greatest(coalesce(p_days, 7), 1), 14);
  v_radius integer := (public.monvelo_settings()).offer_radius_m;
begin
  if (select auth.uid()) is null
     or p_agent_id is null
     or not exists (select 1 from public.my_monvelo_agent_ids() m(id) where m.id = p_agent_id) then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  return query
  select ar.id, ar.area_name, d.day, count(s.id)::integer
    from generate_series(public.monvelo_today(), public.monvelo_today() + (v_days - 1), interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    join public.monvelo_supply_days sd
      on sd.active and sd.day_of_week = extract(isodow from d.day)::int
    join public.areas ar on ar.tenant_id = sd.tenant_id and ar.id = sd.area_id
    join public.monvelo_tenant_settings ts on ts.tenant_id = ar.tenant_id and ts.enabled
    join public.monvelo_agents ag on ag.id = p_agent_id
    join public.monvelo_shop_enrolments e
      on e.tenant_id = ar.tenant_id and e.area_id = ar.id and e.status = 'ACTIVE'
    join public.retail_shops s on s.id = e.shop_id
   where extensions.st_dwithin(ag.location, s.location::extensions.geography, v_radius)
   group by ar.id, ar.area_name, d.day
   order by d.day, ar.area_name;
end;
$$;
revoke all on function public.monvelo_supply_days_near(uuid, integer) from public, anon, authenticated, service_role;
grant execute on function public.monvelo_supply_days_near(uuid, integer) to authenticated, service_role;

-- ── monvelo_agents_near ─────────────────────────────────────────────────
-- Monvelo staff only: the ACTIVE agents near a shop. Never a phone number,
-- a name or an account (§16.6): the agent id, the network and the distance.
create function public.monvelo_agents_near(p_shop_id uuid, p_radius_m integer default null)
returns table (agent_id uuid, pos_network public.pos_network_enum, distance_m integer)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_radius integer;
  v_loc    extensions.geography;
begin
  if (select auth.uid()) is null or not (select public.is_monvelo_staff()) then
    raise exception 'agent search is for Monvelo staff' using errcode = '42501';
  end if;

  v_radius := least(coalesce(p_radius_m, (public.monvelo_settings()).offer_radius_m), 50000);
  if v_radius <= 0 then
    raise exception 'the radius must be positive' using errcode = 'P0001';
  end if;

  select s.location::extensions.geography into v_loc from public.retail_shops s where s.id = p_shop_id;
  if v_loc is null then
    raise exception 'shop not found' using errcode = 'P0001';
  end if;

  return query
  select a.id, a.pos_network, round(extensions.st_distance(a.location, v_loc))::integer
    from public.monvelo_agents a
   where a.status = 'ACTIVE'
     and extensions.st_dwithin(a.location, v_loc, v_radius)
   order by 3, 1
   limit 200;
end;
$$;
revoke all on function public.monvelo_agents_near(uuid, integer) from public, anon, authenticated, service_role;
grant execute on function public.monvelo_agents_near(uuid, integer) to authenticated, service_role;
