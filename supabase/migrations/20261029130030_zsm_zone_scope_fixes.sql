-- Addendum A6 §18.3, plan Task 1e, fix round 1 (review of 20261029130020).
--
-- 1. No orphaned zones (controller ruling): a zone with no ACTIVE covering
--    ZSM (zsm_id null, or its ZSM not an ACTIVE ZSM of the tenant) stays
--    within reach of every ACTIVE ZSM of the tenant. A zone is out of a ZSM's
--    reach only while ANOTHER ACTIVE ZSM covers it. The internal helper
--    zsm_reach_zone_ids gives that reach; zsm_zone_ids keeps its strict
--    coverage meaning for the Task 1d objects (invites, territory, area and
--    zone edits, chat rooms), which this round does not change.
-- 2. Audit rows of upload_slots, web_commissions and chat moderation are
--    zoned: by the slot's ticket or order, the commission's order, and the
--    channel's zone or territory; a row whose payload names a ticket, order
--    or channel in another ZSM's zone is hidden even after the object is gone.
-- 3. upsert_web_referral_code: a ZSM issues or edits codes only for itself,
--    for agents whose territory, area or zone is within reach, or for another
--    ZSM sharing a covered zone; anyone else is 42501.
-- 4. set_web_pos_venue: a terminal with no territory is zoned by its POS
--    agent's territory.
-- 5. TMs (user ruling 2026-10-30): a TM reads only audit rows whose object
--    lies in one of the TM's territories (same object keying as for ZSMs);
--    zone-less audit rows are no longer visible to TMs.
--
-- Functions are recreated from their live definitions with the same
-- signatures; CREATE OR REPLACE keeps their grants.

-- ── 1. reach ────────────────────────────────────────────────────────────

-- The zones an ACTIVE ZSM of the tenant may act in: those they cover, and
-- those no other ACTIVE ZSM of the tenant covers. Empty for anyone else.
create function public.zsm_reach_zone_ids(p_tenant_id uuid, p_profile_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select z.id
    from public.zones z
   where z.tenant_id = p_tenant_id
     and exists (select 1 from public.tenant_users me
                  where me.tenant_id = p_tenant_id
                    and me.profile_id = p_profile_id
                    and me.role = 'ZSM'
                    and me.status = 'ACTIVE')
     and (z.zsm_id = p_profile_id
          or not exists (select 1 from public.tenant_users cov
                          where cov.tenant_id = z.tenant_id
                            and cov.profile_id = z.zsm_id
                            and cov.role = 'ZSM'
                            and cov.status = 'ACTIVE'));
$$;
revoke all on function public.zsm_reach_zone_ids(uuid, uuid) from public, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.zsm_covers_territory(p_tenant_id uuid, p_profile_id uuid, p_territory_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.territories t
     where t.tenant_id = p_tenant_id
       and t.id = p_territory_id
       and t.zone_id in (select public.zsm_reach_zone_ids(p_tenant_id, p_profile_id)));
$function$;

CREATE OR REPLACE FUNCTION public.my_zsm_territory_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select t.id
    from (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]) as tenant_id) mt
    cross join lateral public.zsm_reach_zone_ids(mt.tenant_id, (select auth.uid())) as r (zone_id)
    join public.territories t on t.tenant_id = mt.tenant_id and t.zone_id = r.zone_id;
$function$;

-- other_zones: zones of my ZSM tenants that another ACTIVE ZSM covers
CREATE OR REPLACE FUNCTION public.my_zsm_out_of_zone_keys()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with my_tenants as (
    select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]) as tenant_id
  ), other_zones as (
    select z.tenant_id, z.id
      from public.zones z
     where z.tenant_id in (select tenant_id from my_tenants)
       and z.zsm_id <> (select auth.uid())
       and exists (select 1 from public.tenant_users cov
                    where cov.tenant_id = z.tenant_id
                      and cov.profile_id = z.zsm_id
                      and cov.role = 'ZSM'
                      and cov.status = 'ACTIVE')
  ), other_territories as (
    select t.tenant_id, t.id
      from public.territories t
      join other_zones z on z.tenant_id = t.tenant_id and z.id = t.zone_id
  ), other_orders as (
    select o.tenant_id, o.id
      from public.orders o
      join other_territories t on t.tenant_id = o.tenant_id and t.id = o.territory_id
  ), other_tickets as (
    select s.tenant_id, s.id
      from public.support_tickets s
      join other_territories t on t.tenant_id = s.tenant_id and t.id = s.territory_id
  )
  select 'zones:' || id from other_zones
  union all
  select 'territories:' || id from other_territories
  union all
  select 'areas:' || a.id from public.areas a
    join other_territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
  union all
  select 'territory_coverage:' || c.id from public.territory_coverage c
    join other_territories t on t.tenant_id = c.tenant_id and t.id = c.territory_id
  union all
  select 'web_pos_venues:' || v.id from public.web_pos_venues v
    join other_territories t on t.tenant_id = v.tenant_id and t.id = v.territory_id
  union all
  select 'support_tickets:' || id from other_tickets
  union all
  select 'orders:' || id from other_orders
  union all
  select 'order_fulfilments:' || id from other_orders
  union all
  select 'payments:' || p.id from public.payments p
    join other_orders o on o.tenant_id = p.tenant_id and o.id = p.order_id
  union all
  select 'web_commissions:' || c.id from public.web_commissions c
    join other_orders o on o.tenant_id = c.tenant_id and o.id = c.order_id
  union all
  select 'upload_slots:' || u.id from public.upload_slots u
    join other_tickets s on s.tenant_id = u.tenant_id and s.id = u.ticket_id
  union all
  select 'upload_slots:' || u.id from public.upload_slots u
    join other_orders o on o.tenant_id = u.tenant_id and o.id = u.order_id
  union all
  select 'chat_channels:' || c.id from public.chat_channels c
    join other_zones z on z.tenant_id = c.tenant_id and z.id = c.zone_id
  union all
  select 'chat_channels:' || c.id from public.chat_channels c
    join other_territories t on t.tenant_id = c.tenant_id and t.id = c.territory_id;
$function$;

-- ── 5. TM audit keys (user ruling 2026-10-30) ───────────────────────────
-- The audit keys of objects in the caller's TM territories: the territory,
-- its areas, coverage rows, terminals (a terminal with no territory by its
-- agent's), tickets, orders and their fulfilments, payments, commissions and
-- photo slots, and its TERRITORY chat room. Never null. For policies.
create function public.my_tm_audit_keys()
returns setof text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with my_territories as (
    select t.tenant_id, t.id
      from public.territories t
     where t.id in (select public.my_tm_territory_ids())
  ), my_orders as (
    select o.tenant_id, o.id
      from public.orders o
      join my_territories t on t.tenant_id = o.tenant_id and t.id = o.territory_id
  ), my_tickets as (
    select s.tenant_id, s.id
      from public.support_tickets s
      join my_territories t on t.tenant_id = s.tenant_id and t.id = s.territory_id
  )
  select 'territories:' || id from my_territories
  union all
  select 'areas:' || a.id from public.areas a
    join my_territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
  union all
  select 'territory_coverage:' || c.id from public.territory_coverage c
    join my_territories t on t.tenant_id = c.tenant_id and t.id = c.territory_id
  union all
  select 'web_pos_venues:' || v.id from public.web_pos_venues v
    join my_territories t on t.tenant_id = v.tenant_id and t.id = v.territory_id
  union all
  select 'web_pos_venues:' || v.id from public.web_pos_venues v
    join public.tenant_users tu on tu.tenant_id = v.tenant_id and tu.profile_id = v.agent_id
    join my_territories t on t.tenant_id = tu.tenant_id and t.id = tu.territory_id
   where v.territory_id is null
  union all
  select 'support_tickets:' || id from my_tickets
  union all
  select 'orders:' || id from my_orders
  union all
  select 'order_fulfilments:' || id from my_orders
  union all
  select 'payments:' || p.id from public.payments p
    join my_orders o on o.tenant_id = p.tenant_id and o.id = p.order_id
  union all
  select 'web_commissions:' || c.id from public.web_commissions c
    join my_orders o on o.tenant_id = c.tenant_id and o.id = c.order_id
  union all
  select 'upload_slots:' || u.id from public.upload_slots u
    join my_tickets s on s.tenant_id = u.tenant_id and s.id = u.ticket_id
  union all
  select 'upload_slots:' || u.id from public.upload_slots u
    join my_orders o on o.tenant_id = u.tenant_id and o.id = u.order_id
  union all
  select 'chat_channels:' || c.id from public.chat_channels c
    join my_territories t on t.tenant_id = c.tenant_id and t.id = c.territory_id;
$$;
revoke all on function public.my_tm_audit_keys() from public, anon, service_role;
grant execute on function public.my_tm_audit_keys() to authenticated;

-- ── 2 and 5. audit rows ─────────────────────────────────────────────────
-- ZSM: zoned also by the ticket, order or channel the payload names (purged
-- upload slots, commissions and moderated messages keep their ticket_id,
-- order_id or channel_id there).
-- TM (user ruling 2026-10-30): only rows whose object, or the ticket, order
-- or channel in the payload, lies in one of the TM's territories. Zone-less
-- rows (tenant settings, members, brand terms, ...) are no longer shown to TMs.
alter policy audit_logs_select_zsm_tm on public.audit_logs
  using ((tenant_id in (select public.my_tenant_ids_with_role(array['TM']::public.tenant_role_enum[]))
          and ((entity_type || ':' || coalesce(entity_id, '')) in (select public.my_tm_audit_keys())
               or ('support_tickets:' || (after ->> 'ticket_id')) in (select public.my_tm_audit_keys())
               or ('orders:' || (after ->> 'order_id')) in (select public.my_tm_audit_keys())
               or ('chat_channels:' || (after ->> 'channel_id')) in (select public.my_tm_audit_keys())))
         or (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
             and (entity_type || ':' || coalesce(entity_id, '')) not in (select public.my_zsm_out_of_zone_keys())
             and coalesce('support_tickets:' || (after ->> 'ticket_id'), '-')
                   not in (select public.my_zsm_out_of_zone_keys())
             and coalesce('orders:' || (after ->> 'order_id'), '-')
                   not in (select public.my_zsm_out_of_zone_keys())
             and coalesce('chat_channels:' || (after ->> 'channel_id'), '-')
                   not in (select public.my_zsm_out_of_zone_keys())));

-- ── 3. referral codes ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_web_referral_code(p_idempotency_key uuid, p_code text, p_agent_id uuid, p_venue_id uuid, p_discount_type text, p_discount_value numeric, p_max_redemptions integer, p_expires_at timestamp with time zone, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_agent  public.tenant_users;
  v_before public.web_referral_codes;
  v_after  public.web_referral_codes;
  v_zone   uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_web_referral_code',
    jsonb_build_object('code', v_code, 'agent_id', p_agent_id, 'venue_id', p_venue_id,
                       'discount_type', p_discount_type, 'discount_value', p_discount_value,
                       'max_redemptions', p_max_redemptions, 'expires_at', p_expires_at,
                       'is_active', p_is_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_code !~ '^[A-Z0-9][A-Z0-9-]{3,31}$' then
    raise exception 'a code is 4 to 32 letters, digits or dashes' using errcode = 'P0001';
  end if;

  select * into v_agent from public.tenant_users
   where tenant_id = v_me.tenant_id and profile_id = p_agent_id
   order by (status = 'ACTIVE') desc
   limit 1;
  if not found then
    raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_agent.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM issues codes for agents in their own territory only' using errcode = '42501';
  end if;
  if p_venue_id is not null and not exists (
    select 1 from public.web_pos_venues ft
     where ft.tenant_id = v_me.tenant_id and ft.id = p_venue_id and ft.agent_id = p_agent_id
  ) then
    raise exception 'the terminal must belong to the agent' using errcode = 'P0001';
  end if;
  if p_venue_id is not null and v_agent.role <> 'POS_AGENT' then
    raise exception 'a venue-bound code needs a POS agent' using errcode = 'P0001';
  end if;
  -- a ZSM: codes for itself, for agents within reach, or for a ZSM sharing
  -- a covered zone; the zone is the venue's territory's, else the agent's
  -- territory's, area's or zone
  if v_me.role = 'ZSM' and v_agent.profile_id <> v_me.profile_id then
    if v_agent.role = 'ZSM' then
      if not exists (select public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id)
                     intersect
                     select public.zsm_zone_ids(v_me.tenant_id, v_agent.profile_id)) then
        raise exception 'this agent is not in your zones' using errcode = '42501';
      end if;
    else
      v_zone := coalesce(
        (select t.zone_id from public.web_pos_venues ft
           join public.territories t on t.tenant_id = ft.tenant_id and t.id = ft.territory_id
          where ft.tenant_id = v_me.tenant_id and ft.id = p_venue_id),
        (select t.zone_id from public.territories t
          where t.tenant_id = v_me.tenant_id and t.id = v_agent.territory_id),
        (select t.zone_id from public.areas a
           join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
          where a.tenant_id = v_me.tenant_id and a.id = v_agent.area_id),
        v_agent.zone_id);
      if v_zone is null
         or v_zone not in (select public.zsm_reach_zone_ids(v_me.tenant_id, v_me.profile_id)) then
        raise exception 'this agent is not in your zones' using errcode = '42501';
      end if;
    end if;
  end if;

  if (p_discount_type is null) <> (p_discount_value is null) then
    raise exception 'a discount needs both a type and a value' using errcode = 'P0001';
  end if;
  if p_discount_type is not null and p_discount_type not in ('PERCENT', 'FIXED') then
    raise exception 'discount type must be PERCENT or FIXED' using errcode = 'P0001';
  end if;
  if p_discount_type = 'PERCENT' and not (p_discount_value > 0 and p_discount_value <= 100) then
    raise exception 'a percentage discount is more than 0 and at most 100' using errcode = 'P0001';
  end if;
  if p_discount_type = 'FIXED' and not (p_discount_value > 0) then
    raise exception 'a fixed discount is more than 0' using errcode = 'P0001';
  end if;
  if p_max_redemptions is not null and p_max_redemptions < 1 then
    raise exception 'max_redemptions is at least 1' using errcode = 'P0001';
  end if;

  select * into v_before from public.web_referral_codes where code = v_code for update;
  if found then
    if v_before.tenant_id <> v_me.tenant_id then
      raise exception 'that code is already taken' using errcode = 'P0001';
    end if;
    if v_before.agent_id <> p_agent_id then
      raise exception 'a code''s agent never changes; deactivate it and issue a new code' using errcode = 'P0001';
    end if;
    if coalesce(p_is_active, v_before.is_active) and v_agent.status <> 'ACTIVE' then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    update public.web_referral_codes
       set venue_id        = p_venue_id,
           discount_type   = p_discount_type,
           discount_value  = p_discount_value,
           max_redemptions = p_max_redemptions,
           expires_at      = p_expires_at,
           is_active       = coalesce(p_is_active, v_before.is_active)
     where id = v_before.id
    returning * into v_after;
  else
    if v_agent.status <> 'ACTIVE' and coalesce(p_is_active, true) then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    insert into public.web_referral_codes (tenant_id, code, agent_id, venue_id, discount_type, discount_value,
                                    max_redemptions, expires_at, is_active, created_by)
    values (v_me.tenant_id, v_code, p_agent_id, p_venue_id, p_discount_type, p_discount_value,
            p_max_redemptions, p_expires_at, coalesce(p_is_active, true), v_me.profile_id)
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_web_referral_code', 'web_referral_codes', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('referral_code_id', v_after.id, 'code', v_after.code));
end;
$function$;

-- ── 4. venues: a terminal with no territory takes its agent's ───────────
CREATE OR REPLACE FUNCTION public.set_web_pos_venue(p_idempotency_key uuid, p_venue_id uuid, p_venue_channel venue_channel_enum, p_venue_name text, p_address_text text, p_state text, p_lga text, p_latitude double precision, p_longitude double precision, p_operating_hours jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me       public.tenant_users := public.assert_tenant_role(
                array['ZSM', 'TM', 'POS_AGENT']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_before   public.web_pos_venues;
  v_after    public.web_pos_venues;
  v_point    extensions.geometry;
  v_boundary extensions.geometry;
  v_zone_t   uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_web_pos_venue',
    jsonb_build_object('venue_id', p_venue_id, 'venue_channel', p_venue_channel,
                       'venue_name', p_venue_name, 'address_text', p_address_text,
                       'state', p_state, 'lga', p_lga, 'latitude', p_latitude,
                       'longitude', p_longitude, 'operating_hours', p_operating_hours));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.web_pos_venues
   where id = p_venue_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'terminal not found' using errcode = 'P0001';
  end if;
  if v_me.role = 'ZSM' then
    v_zone_t := coalesce(v_before.territory_id,
                         (select tu.territory_id from public.tenant_users tu
                           where tu.tenant_id = v_me.tenant_id and tu.profile_id = v_before.agent_id));
    if v_zone_t is not null
       and not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, v_zone_t) then
      raise exception 'a ZSM sets venues for terminals in their own zones only' using errcode = '42501';
    end if;
  end if;
  if v_me.role = 'TM' and v_before.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM sets venues for terminals in their own territory only' using errcode = '42501';
  end if;
  if v_me.role = 'POS_AGENT' and v_before.agent_id is distinct from v_me.profile_id then
    raise exception 'an agent sets the venue of their own terminals only' using errcode = '42501';
  end if;

  if p_venue_channel is null
     or coalesce(btrim(p_venue_name), '') = ''
     or coalesce(btrim(p_address_text), '') = ''
     or coalesce(btrim(p_state), '') = '' then
    raise exception 'venue type, name, address and state are required' using errcode = 'P0001';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'a valid GPS location is required' using errcode = 'P0001';
  end if;
  if p_operating_hours is not null and (
       jsonb_typeof(p_operating_hours) <> 'object'
       or exists (
         select 1 from jsonb_each(p_operating_hours) e
          where e.key not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
             or jsonb_typeof(e.value) <> 'string'
             or (e.value #>> '{}') !~ '^(closed|([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9])$')) then
    raise exception 'operating hours use mon..sun keys with "HH:MM-HH:MM" or "closed"' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326);
  select t.boundary into v_boundary from public.territories t
   where t.tenant_id = v_me.tenant_id and t.id = v_before.territory_id;
  if v_boundary is not null and not extensions.st_covers(v_boundary, v_point) then
    raise exception 'the venue lies outside the terminal''s territory' using errcode = 'P0001';
  end if;

  update public.web_pos_venues
     set venue_channel   = p_venue_channel,
         venue_name      = btrim(p_venue_name),
         address_text    = btrim(p_address_text),
         state           = btrim(p_state),
         lga             = nullif(btrim(p_lga), ''),
         location        = v_point,
         operating_hours = p_operating_hours
   where id = v_before.id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_web_pos_venue', 'web_pos_venues', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('venue_id', v_after.id));
end;
$function$;
