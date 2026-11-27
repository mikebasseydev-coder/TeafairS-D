-- Addendum A6 §23.1 and §23.4 (rulings 2026-11-27) — field scope, the ZSA/ASA
-- field dashboard, TM oversight, and direct pairing with fallback.
--
-- §23.1  The three kinds of people stay apart: a Monvelo agent (a platform
--        partner, monvelo_agents), the people who act for it (ACTIVE rows of
--        monvelo_agent_members) and the field activation agents (ZSA, ASA:
--        tenant memberships). New:
--          my_monvelo_field_area_ids()   the areas of the caller's ACTIVE ZSA
--                                        (every area of their zone) and ASA
--                                        (their own area) memberships, in
--                                        tenants that run Monvelo
--          my_monvelo_field_agent_ids()  the partners in that scope: recruited
--                                        by the caller, paired with a shop
--                                        enrolled in it, or pledged to it for
--                                        today or later
--        Agent visibility for field agents narrows from every ACTIVE agent on
--        the platform to those partners (plus their own recruits in any
--        status). Financing visibility widens from what they raised to every
--        financing in their scope. my_monvelo_territory_ids() is the TM's
--        territory only (ASM removed: no Monvelo role is ASM's).
--          get_monvelo_field_dashboard()          ZSA/ASA, one read of their scope
--          monvelo_field_partners_near(shop, r)   ZSA/ASA, liquidity partners to pair
--          get_monvelo_tm_oversight(p_days)       TM, per-field-agent activity in
--                                                 the territory; counts only, no
--                                                 partner is named (§16.2.2)
--
-- §23.4  A pairing is retail_shops.preferred_agent_id (platform-wide, one per
--        shop), now with a history row in monvelo_shop_pairings.
--          pair_monvelo_shop_agent(key, shop, agent)      ZSA (own zone) / ASA (own area)
--          unpair_monvelo_shop_agent(key, shop, reason)   same scope; reason 10..500
--        close_monvelo_nomination RECRUITED records a NOMINATION pairing.
--        Routing is unchanged and is the directed request: monvelo_offer gives
--        the paired partner the exclusive preferred window (10 minutes) when
--        it has pledged room for the supply date, then any partner within
--        offer_radius_m may claim. Unpairing ends the window on the shop's
--        open offers at once. Funding stays webhook-settled with the payer
--        binding; nothing here touches money.

-- ── scope helpers ───────────────────────────────────────────────────────
create or replace function public.my_monvelo_field_area_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id
    from public.tenant_users tu
    join public.monvelo_tenant_settings s on s.tenant_id = tu.tenant_id and s.enabled
    join public.areas a on a.tenant_id = tu.tenant_id and a.id = tu.area_id
   where tu.profile_id = (select auth.uid()) and tu.status = 'ACTIVE' and tu.role = 'ASA'
  union
  select a.id
    from public.tenant_users tu
    join public.monvelo_tenant_settings s on s.tenant_id = tu.tenant_id and s.enabled
    join public.territories t on t.tenant_id = tu.tenant_id and t.zone_id = tu.zone_id
    join public.areas a on a.tenant_id = t.tenant_id and a.territory_id = t.id
   where tu.profile_id = (select auth.uid()) and tu.status = 'ACTIVE' and tu.role = 'ZSA';
$$;
revoke all on function public.my_monvelo_field_area_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_monvelo_field_area_ids() to authenticated;
comment on function public.my_monvelo_field_area_ids() is
  'A6 §23.1: areas in the caller''s field scope (ZSA: every area of their zone; ASA: their area), Monvelo tenants only.';

create or replace function public.my_monvelo_field_agent_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select a.id from public.monvelo_agents a
   where a.recruited_by = (select auth.uid())
  union
  select s.preferred_agent_id
    from public.monvelo_shop_enrolments e
    join public.retail_shops s on s.id = e.shop_id
   where e.status = 'ACTIVE' and s.preferred_agent_id is not null
     and e.area_id in (select public.my_monvelo_field_area_ids())
  union
  select p.agent_id from public.monvelo_pledges p
   where p.supply_date >= public.monvelo_today()
     and p.area_id in (select public.my_monvelo_field_area_ids());
$$;
revoke all on function public.my_monvelo_field_agent_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_monvelo_field_agent_ids() to authenticated;
comment on function public.my_monvelo_field_agent_ids() is
  'A6 §23.1: partners in the caller''s field scope: their recruits, partners paired with shops enrolled in it, partners pledged to it (today on).';

-- Internal: does this ZSA/ASA membership cover the area?
create or replace function public.monvelo_field_covers_area(p_me public.tenant_users, p_area_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_me.role
    when 'ASA' then p_me.area_id is not distinct from p_area_id
    when 'ZSA' then exists (select 1 from public.areas a
                              join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
                             where a.tenant_id = p_me.tenant_id and a.id = p_area_id and t.zone_id = p_me.zone_id)
    else false
  end;
$$;
revoke all on function public.monvelo_field_covers_area(public.tenant_users, uuid) from public, anon, authenticated, service_role;

-- The TM's territory only (was TM and ASM).
create or replace function public.my_monvelo_territory_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.territory_id from public.tenant_users tu
   where tu.profile_id = (select auth.uid())
     and tu.status = 'ACTIVE'
     and tu.role = 'TM'
     and tu.territory_id is not null;
$$;

-- ── visibility ──────────────────────────────────────────────────────────
drop policy monvelo_agents_select on public.monvelo_agents;
create policy monvelo_agents_select on public.monvelo_agents
  for select to authenticated
  using (
    (select public.is_monvelo_staff())
    or id in (select public.my_monvelo_agent_ids())
    or ((select public.is_monvelo_field_agent())
        and (recruited_by = (select auth.uid())
             or (status = 'ACTIVE' and id in (select public.my_monvelo_field_agent_ids()))))
  );

drop policy monvelo_financings_select on public.monvelo_financings;
create policy monvelo_financings_select on public.monvelo_financings for select to authenticated
  using (
    shop_id in (select public.my_owned_shop_ids())
    or claimed_by_agent_id in (select public.my_monvelo_agent_ids())
    or funder_agent_id in (select public.my_monvelo_agent_ids())
    or raised_by = (select auth.uid())
    or territory_id in (select public.my_monvelo_territory_ids())
    -- A6 §23.1: the ZSA's zone and the ASA's area
    or area_id in (select public.my_monvelo_field_area_ids())
    or tenant_id in (select public.my_tenant_ids_with_role(
         array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]))
    -- a ZSM reads the financings of their zones (A6 §18.3)
    or territory_id in (select public.my_zsm_territory_ids())
    or (status = 'FUNDED' and tenant_id in (select public.my_tenant_ids_with_role(
         array['LOGISTICS_MANAGER']::public.tenant_role_enum[])))
    or (select public.is_monvelo_staff()));

-- ── pairings ────────────────────────────────────────────────────────────
create table public.monvelo_shop_pairings (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants (id) on delete restrict,
  shop_id        uuid not null references public.retail_shops (id) on delete restrict,
  area_id        uuid not null,
  agent_id       uuid not null references public.monvelo_agents (id) on delete restrict,
  source         text not null check (source in ('FIELD_PAIRING', 'NOMINATION')),
  paired_by      uuid not null references public.profiles (id) on delete restrict,
  paired_at      timestamptz not null default now(),
  unpaired_by    uuid references public.profiles (id) on delete restrict,
  unpaired_at    timestamptz,
  unpair_reason  text check (char_length(btrim(unpair_reason)) between 10 and 500),
  unique (tenant_id, id),
  foreign key (tenant_id, area_id) references public.areas (tenant_id, id) on delete restrict,
  foreign key (tenant_id, shop_id) references public.monvelo_shop_enrolments (tenant_id, shop_id) on delete restrict,
  check ((unpaired_at is null) = (unpaired_by is null)),
  check ((unpaired_at is null) = (unpair_reason is null))
);
alter table public.monvelo_shop_pairings enable row level security;
-- one open pairing per shop, as retail_shops.preferred_agent_id holds one
create unique index uq_monvelo_shop_pairings_open on public.monvelo_shop_pairings (shop_id) where unpaired_at is null;
create index idx_monvelo_shop_pairings_tenant_area on public.monvelo_shop_pairings (tenant_id, area_id);
create index idx_monvelo_shop_pairings_agent on public.monvelo_shop_pairings (agent_id);
create index idx_monvelo_shop_pairings_paired_by on public.monvelo_shop_pairings (paired_by);
create index idx_monvelo_shop_pairings_unpaired_by on public.monvelo_shop_pairings (unpaired_by);

revoke all on public.monvelo_shop_pairings from anon, authenticated;
grant select on public.monvelo_shop_pairings to authenticated;
-- a row names a partner, so tenant roles outside the field scope never read it
-- (A6 §16.2.2); the TM sees counts through get_monvelo_tm_oversight
create policy monvelo_shop_pairings_select on public.monvelo_shop_pairings for select to authenticated
  using (
    (select public.is_monvelo_staff())
    or agent_id in (select public.my_monvelo_agent_ids())
    or area_id in (select public.my_monvelo_field_area_ids())
  );

-- Internal: record that the shop is now paired with the partner, closing any
-- open pairing it replaces. Called after retail_shops.preferred_agent_id is set.
create or replace function public.monvelo_record_pairing(p_tenant_id uuid, p_shop_id uuid, p_agent_id uuid, p_source text)
returns public.monvelo_shop_pairings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_open public.monvelo_shop_pairings;
  v_area uuid;
  v_row  public.monvelo_shop_pairings;
begin
  select * into v_open from public.monvelo_shop_pairings where shop_id = p_shop_id and unpaired_at is null for update;
  if found and v_open.agent_id = p_agent_id then
    return v_open;
  end if;
  if found then
    update public.monvelo_shop_pairings
       set unpaired_by = (select auth.uid()), unpaired_at = now(), unpair_reason = 'replaced by a new pairing'
     where id = v_open.id;
  end if;
  select e.area_id into v_area from public.monvelo_shop_enrolments e
   where e.tenant_id = p_tenant_id and e.shop_id = p_shop_id;
  insert into public.monvelo_shop_pairings (tenant_id, shop_id, area_id, agent_id, source, paired_by)
  values (p_tenant_id, p_shop_id, v_area, p_agent_id, p_source, (select auth.uid()))
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.monvelo_record_pairing(uuid, uuid, uuid, text) from public, anon, authenticated, service_role;

-- ── pair_monvelo_shop_agent ─────────────────────────────────────────────
create or replace function public.pair_monvelo_shop_agent(p_idempotency_key uuid, p_shop_id uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_enrol  public.monvelo_shop_enrolments;
  v_agent  public.monvelo_agents;
  v_shop   public.retail_shops;
  v_row    public.monvelo_shop_pairings;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'pair_monvelo_shop_agent',
    jsonb_build_object('shop_id', p_shop_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_enrol from public.monvelo_shop_enrolments e
   where e.tenant_id = v_me.tenant_id and e.shop_id = p_shop_id;
  if not found or v_enrol.status <> 'ACTIVE' then
    raise exception 'this shop is not enrolled' using errcode = 'P0001';
  end if;
  if not public.monvelo_field_covers_area(v_me, v_enrol.area_id) then
    raise exception 'the shop is not in your field scope' using errcode = '42501';
  end if;
  select * into v_agent from public.monvelo_agents a where a.id = p_agent_id;
  if not found then
    raise exception 'unknown Monvelo partner' using errcode = 'P0001';
  end if;
  if v_agent.status <> 'ACTIVE' then
    raise exception 'the partner is not active' using errcode = 'P0001';
  end if;
  if v_agent.partner_kind <> 'LIQUIDITY_PARTNER' then
    raise exception 'only a liquidity partner may be paired with a shop' using errcode = '42501';
  end if;
  -- a field agent never pairs a shop with a partner they act for (as R78)
  if exists (select 1 from public.monvelo_agent_members m where m.agent_id = v_agent.id and m.profile_id = v_me.profile_id) then
    raise exception 'you may not pair a shop with a partner you belong to' using errcode = '42501';
  end if;

  select * into v_shop from public.retail_shops s where s.id = p_shop_id for update;
  if v_shop.preferred_agent_id = v_agent.id then
    raise exception 'the shop is already paired with this partner' using errcode = 'P0001';
  end if;
  if v_shop.preferred_agent_id is not null then
    raise exception 'the shop is paired with another partner; unpair it first' using errcode = 'P0001';
  end if;

  update public.retail_shops set preferred_agent_id = v_agent.id where id = v_shop.id;
  v_row := public.monvelo_record_pairing(v_me.tenant_id, v_shop.id, v_agent.id, 'FIELD_PAIRING');

  -- R19: the row names a partner, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'pair_monvelo_shop_agent', 'monvelo_shop_pairings', v_row.id::text,
                             null, to_jsonb(v_row), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'pairing_id', v_row.id, 'shop_id', v_shop.id, 'agent_id', v_agent.id, 'partner_code', v_agent.partner_code));
end;
$$;
revoke all on function public.pair_monvelo_shop_agent(uuid, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.pair_monvelo_shop_agent(uuid, uuid, uuid) to authenticated;

-- ── unpair_monvelo_shop_agent ───────────────────────────────────────────
create or replace function public.unpair_monvelo_shop_agent(p_idempotency_key uuid, p_shop_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_enrol   public.monvelo_shop_enrolments;
  v_shop    public.retail_shops;
  v_before  public.monvelo_shop_pairings;
  v_after   public.monvelo_shop_pairings;
  v_offers  integer;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'unpair_monvelo_shop_agent',
    jsonb_build_object('shop_id', p_shop_id, 'reason', v_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  if char_length(v_reason) not between 10 and 500 then
    raise exception 'give a reason of 10 to 500 characters' using errcode = 'P0001';
  end if;
  select * into v_enrol from public.monvelo_shop_enrolments e
   where e.tenant_id = v_me.tenant_id and e.shop_id = p_shop_id;
  if not found then
    raise exception 'this shop is not enrolled' using errcode = 'P0001';
  end if;
  if not public.monvelo_field_covers_area(v_me, v_enrol.area_id) then
    raise exception 'the shop is not in your field scope' using errcode = '42501';
  end if;
  select * into v_shop from public.retail_shops s where s.id = p_shop_id for update;
  if v_shop.preferred_agent_id is null then
    raise exception 'the shop is not paired' using errcode = 'P0001';
  end if;

  update public.retail_shops set preferred_agent_id = null where id = v_shop.id;
  select * into v_before from public.monvelo_shop_pairings p
   where p.shop_id = v_shop.id and p.unpaired_at is null for update;
  if found then
    update public.monvelo_shop_pairings
       set unpaired_by = v_me.profile_id, unpaired_at = now(), unpair_reason = v_reason
     where id = v_before.id
    returning * into v_after;
  end if;
  -- the fallback starts now: open offers lose the exclusive window
  update public.monvelo_financings
     set preferred_agent_id = null, preferred_window_ends_at = null
   where shop_id = v_shop.id and status = 'OFFERED' and preferred_agent_id = v_shop.preferred_agent_id;
  get diagnostics v_offers = row_count;

  -- R19: the rows name a partner, so no tenant reads them (A6 §16.2.2)
  perform public.write_audit(null, 'unpair_monvelo_shop_agent', 'retail_shops', v_shop.id::text,
    jsonb_build_object('preferred_agent_id', v_shop.preferred_agent_id, 'pairing', to_jsonb(v_before)),
    jsonb_build_object('preferred_agent_id', null, 'pairing', to_jsonb(v_after), 'offers_opened', v_offers),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'shop_id', v_shop.id, 'pairing_id', v_after.id, 'offers_opened', v_offers));
end;
$$;
revoke all on function public.unpair_monvelo_shop_agent(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.unpair_monvelo_shop_agent(uuid, uuid, text) to authenticated;

-- ── monvelo_field_partners_near ─────────────────────────────────────────
-- ZSA/ASA: ACTIVE liquidity partners near a shop enrolled in their scope, to
-- pair with it. p_radius_m defaults to 1,000 m and is capped at 5,000 m.
create or replace function public.monvelo_field_partners_near(p_shop_id uuid, p_radius_m integer default null)
returns table (agent_id uuid, business_name text, pos_network public.pos_network_enum, partner_code text, distance_m integer)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_radius integer := least(coalesce(p_radius_m, 1000), 5000);
  v_enrol  public.monvelo_shop_enrolments;
  v_loc    extensions.geography;
begin
  if v_radius <= 0 then
    raise exception 'the radius must be positive' using errcode = 'P0001';
  end if;
  select * into v_enrol from public.monvelo_shop_enrolments e
   where e.tenant_id = v_me.tenant_id and e.shop_id = p_shop_id and e.status = 'ACTIVE';
  if not found then
    raise exception 'this shop is not enrolled' using errcode = 'P0001';
  end if;
  if not public.monvelo_field_covers_area(v_me, v_enrol.area_id) then
    raise exception 'the shop is not in your field scope' using errcode = '42501';
  end if;
  select s.location::extensions.geography into v_loc from public.retail_shops s where s.id = p_shop_id;

  return query
  select a.id, a.business_name, a.pos_network, a.partner_code,
         round(extensions.st_distance(a.location, v_loc))::integer
    from public.monvelo_agents a
   where a.status = 'ACTIVE' and a.partner_kind = 'LIQUIDITY_PARTNER'
     and extensions.st_dwithin(a.location, v_loc, v_radius)
     and not exists (select 1 from public.monvelo_agent_members m
                      where m.agent_id = a.id and m.profile_id = v_me.profile_id)
   order by 5, 1
   limit 50;
end;
$$;
revoke all on function public.monvelo_field_partners_near(uuid, integer) from public, anon, authenticated, service_role;
grant execute on function public.monvelo_field_partners_near(uuid, integer) to authenticated;

-- ── get_monvelo_field_dashboard ─────────────────────────────────────────
-- One read of the caller's scope in the active tenant (ZSA: the zone; ASA:
-- the area). Read-only; figures only, except the caller's own recruits.
create or replace function public.get_monvelo_field_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_areas  uuid[];
  v_today  date := public.monvelo_today();
  v_next   date := public.monvelo_request_supply_date();
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  select coalesce(array_agg(a.id order by a.id), '{}') into v_areas
    from public.areas a
   where a.tenant_id = v_me.tenant_id and public.monvelo_field_covers_area(v_me, a.id);

  return jsonb_build_object(
    'role', v_me.role,
    'tenant_id', v_me.tenant_id,
    'zone_id', v_me.zone_id,
    'area_id', v_me.area_id,
    'area_ids', to_jsonb(v_areas),
    'today', v_today,
    'next_supply_date', v_next,
    'order_cutoff_at', public.monvelo_order_cutoff_at(v_next),
    'shops', (select jsonb_build_object(
                'enrolled', count(*),
                'paired', count(*) filter (where s.preferred_agent_id is not null),
                'unpaired', count(*) filter (where s.preferred_agent_id is null))
                from public.monvelo_shop_enrolments e
                join public.retail_shops s on s.id = e.shop_id
               where e.tenant_id = v_me.tenant_id and e.status = 'ACTIVE' and e.area_id = any (v_areas)),
    'nominations_open', (select count(*) from public.monvelo_agent_nominations n
                           join public.monvelo_shop_enrolments e on e.tenant_id = n.tenant_id and e.shop_id = n.shop_id
                          where n.tenant_id = v_me.tenant_id and n.status = 'OPEN' and e.area_id = any (v_areas)),
    'pipeline', (select coalesce(jsonb_agg(jsonb_build_object('status', x.status, 'count', x.n, 'principal', x.principal)
                                           order by x.status), '[]'::jsonb)
                   from (select f.status, count(*) as n, sum(f.principal) as principal
                           from public.monvelo_financings f
                          where f.tenant_id = v_me.tenant_id and f.area_id = any (v_areas)
                            and (f.status in ('REQUESTED', 'AWAITING_APPROVAL', 'OFFERED', 'CLAIMED', 'FUNDED',
                                              'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE', 'REFUND_DUE')
                                 or f.supply_date >= v_today - 30)
                          group by f.status) x),
    'pledged', (select coalesce(jsonb_agg(jsonb_build_object('supply_date', x.supply_date, 'pledged', x.amount,
                                                             'remaining', x.remaining) order by x.supply_date), '[]'::jsonb)
                  from (select p.supply_date, sum(p.amount) as amount, sum(p.remaining) as remaining
                          from public.monvelo_pledges p
                         where p.tenant_id = v_me.tenant_id and p.area_id = any (v_areas)
                           and p.supply_date between v_today and v_next
                         group by p.supply_date) x),
    'holds_awaiting_you', (select count(*) from public.list_monvelo_claim_holds() h
                            where h.can_decide and h.status = 'HELD'),
    'my_recruits', (select coalesce(jsonb_agg(jsonb_build_object(
                             'agent_id', a.id, 'business_name', a.business_name, 'partner_code', a.partner_code,
                             'partner_kind', a.partner_kind, 'status', a.status) order by a.created_at), '[]'::jsonb)
                      from public.monvelo_agents a where a.recruited_by = v_me.profile_id),
    'my_pairings_30d', (select jsonb_build_object(
                          'paired', count(*) filter (where p.paired_by = v_me.profile_id and p.paired_at >= now() - interval '30 days'),
                          'unpaired', count(*) filter (where p.unpaired_by = v_me.profile_id and p.unpaired_at >= now() - interval '30 days'))
                          from public.monvelo_shop_pairings p
                         where p.tenant_id = v_me.tenant_id and p.area_id = any (v_areas))
  );
end;
$$;
revoke all on function public.get_monvelo_field_dashboard() from public, anon, authenticated, service_role;
grant execute on function public.get_monvelo_field_dashboard() to authenticated;

-- ── get_monvelo_tm_oversight ────────────────────────────────────────────
-- The TM's read over the field agents working the territory: its ASAs and the
-- ZSAs of its zone, with their Monvelo activity in the territory over the last
-- p_days (1..366). Counts only: no partner is named or counted by name.
create or replace function public.get_monvelo_tm_oversight(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['TM']::public.tenant_role_enum[]);
  v_terr  public.territories;
  v_since timestamptz;
begin
  if p_days is null or p_days not between 1 and 366 then
    raise exception 'p_days must be between 1 and 366' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  select * into v_terr from public.territories t where t.tenant_id = v_me.tenant_id and t.id = v_me.territory_id;
  if not found then
    raise exception 'you have no territory' using errcode = '42501';
  end if;
  v_since := now() - make_interval(days => p_days);

  return jsonb_build_object(
    'territory_id', v_terr.id,
    'since', v_since,
    'field_agents', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'profile_id', fa.profile_id,
               'full_name', pr.full_name,
               'role', fa.role,
               'area_id', fa.area_id,
               'shops_enrolled', (select count(*) from public.monvelo_shop_enrolments e
                                    join public.areas a on a.tenant_id = e.tenant_id and a.id = e.area_id
                                   where e.tenant_id = v_me.tenant_id and a.territory_id = v_terr.id
                                     and e.recruited_by = fa.profile_id and e.created_at >= v_since),
               'partners_recruited', (select jsonb_build_object(
                                         'total', count(*),
                                         'active', count(*) filter (where ag.status = 'ACTIVE'),
                                         'pending', count(*) filter (where ag.status = 'PENDING'))
                                        from public.monvelo_agents ag
                                       where ag.recruited_by = fa.profile_id and ag.created_at >= v_since),
               'pairings', (select jsonb_build_object(
                               'paired', count(*) filter (where p.paired_by = fa.profile_id and p.paired_at >= v_since),
                               'unpaired', count(*) filter (where p.unpaired_by = fa.profile_id and p.unpaired_at >= v_since))
                              from public.monvelo_shop_pairings p
                              join public.areas a on a.tenant_id = p.tenant_id and a.id = p.area_id
                             where p.tenant_id = v_me.tenant_id and a.territory_id = v_terr.id),
               'holds_decided', (select jsonb_build_object(
                                    'allowed', count(*) filter (where h.status = 'ALLOWED'),
                                    'declined', count(*) filter (where h.status = 'DECLINED'))
                                   from public.monvelo_claim_holds h
                                   join public.monvelo_financings f on f.tenant_id = h.tenant_id and f.id = h.financing_id
                                  where h.tenant_id = v_me.tenant_id and f.territory_id = v_terr.id
                                    and h.decided_by = fa.profile_id and h.decided_at >= v_since),
               'financings_raised', (select jsonb_build_object(
                                        'total', count(*),
                                        'open', count(*) filter (where f.status in ('REQUESTED', 'AWAITING_APPROVAL', 'OFFERED',
                                                                                    'CLAIMED', 'FUNDED', 'DELIVERED',
                                                                                    'DEFAULTED_WITH_LATE_CHARGE', 'REFUND_DUE')),
                                        'principal', coalesce(sum(f.principal), 0))
                                       from public.monvelo_financings f
                                      where f.tenant_id = v_me.tenant_id and f.territory_id = v_terr.id
                                        and f.raised_by = fa.profile_id and f.created_at >= v_since))
             order by fa.role, pr.full_name, fa.profile_id), '[]'::jsonb)
        from public.tenant_users fa
        join public.profiles pr on pr.id = fa.profile_id
       where fa.tenant_id = v_me.tenant_id and fa.status = 'ACTIVE'
         and ((fa.role = 'ASA' and fa.territory_id = v_terr.id)
              or (fa.role = 'ZSA' and fa.zone_id = v_terr.zone_id)))
  );
end;
$$;
revoke all on function public.get_monvelo_tm_oversight(integer) from public, anon, authenticated, service_role;
grant execute on function public.get_monvelo_tm_oversight(integer) to authenticated;

-- ── close_monvelo_nomination, recreated from its live definition ────────
-- New: a RECRUITED close records a NOMINATION pairing. Nothing else changes.
CREATE OR REPLACE FUNCTION public.close_monvelo_nomination(p_idempotency_key uuid, p_nomination_id uuid, p_agent_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agent_nominations;
  v_after  public.monvelo_agent_nominations;
  v_agent  public.monvelo_agents;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'close_monvelo_nomination',
    jsonb_build_object('nomination_id', p_nomination_id, 'agent_id', p_agent_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_status is null or p_status not in ('RECRUITED', 'DECLINED') then
    raise exception 'a nomination closes as RECRUITED or DECLINED' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_agent_nominations
   where id = p_nomination_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'unknown nomination' using errcode = 'P0001';
  end if;
  if v_before.status <> 'OPEN' then
    raise exception 'this nomination is already closed' using errcode = 'P0001';
  end if;

  if p_status = 'RECRUITED' then
    if p_agent_id is null then
      raise exception 'the recruited agent is required' using errcode = 'P0001';
    end if;
    select * into v_agent from public.monvelo_agents where id = p_agent_id;
    if not found then
      raise exception 'unknown Monvelo agent' using errcode = 'P0001';
    end if;
    if v_agent.status <> 'ACTIVE' then
      raise exception 'the agent is not active yet' using errcode = 'P0001';
    end if;
    if v_agent.pos_network is distinct from v_before.pos_network then
      raise exception 'the agent is on a different network' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.monvelo_shop_enrolments e
                    where e.tenant_id = v_me.tenant_id and e.shop_id = v_before.shop_id and e.status = 'ACTIVE') then
      raise exception 'this shop is not enrolled' using errcode = 'P0001';
    end if;
    update public.retail_shops set preferred_agent_id = p_agent_id where id = v_before.shop_id;
    -- A6 §23.4: the recruited nomination is a pairing, with its history row
    perform public.monvelo_record_pairing(v_me.tenant_id, v_before.shop_id, p_agent_id, 'NOMINATION');
  elsif p_agent_id is not null then
    raise exception 'a declined nomination has no agent' using errcode = 'P0001';
  end if;

  update public.monvelo_agent_nominations
     set status = p_status, recruited_agent_id = case when p_status = 'RECRUITED' then p_agent_id end
   where id = p_nomination_id
  returning * into v_after;

  -- R19: the row names an agent, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'close_monvelo_nomination', 'monvelo_agent_nominations', p_nomination_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'nomination_id', p_nomination_id, 'status', v_after.status, 'recruited_agent_id', v_after.recruited_agent_id));
end;
$function$;
