-- Task 5 fix round 1: monvelo_supply_days_near admits only the members of an
-- ACTIVE agent (my_monvelo_agent_ids filters on membership only). Recreated
-- from the live definition; signature and grants unchanged.
create or replace function public.monvelo_supply_days_near(p_agent_id uuid, p_days integer default 7)
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
  if not exists (select 1 from public.monvelo_agents a where a.id = p_agent_id and a.status = 'ACTIVE') then
    raise exception 'your Monvelo agent is not active' using errcode = '42501';
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
