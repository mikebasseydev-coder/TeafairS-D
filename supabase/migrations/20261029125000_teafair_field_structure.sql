-- Addendum A6 §17 (Task 1d): the Teafair field structure.
--
-- * Zones are states: zones.state_code -> ng_states, one zone per state per
--   tenant; zone_name stays a display name. Existing zones are backfilled by
--   state name and the migration fails, naming them, on any zone it cannot
--   match. It never guesses.
-- * One ZSM, many zones: zones.zsm_id is the source of truth for a ZSM's
--   coverage. A ZSM's tenant_users row carries no zone_id. Every function
--   that scoped a ZSM by tenant_users.zone_id is recreated from its live
--   definition so "the ZSM's zone" becomes "one of zsm_zone_ids"; a function
--   that needs one zone uses the zone of the object in hand.
-- Signatures and grants of recreated functions are unchanged.

-- ── 1. zones.state_code ─────────────────────────────────────────────────
alter table public.zones
  add column state_code text references public.ng_states (code) on delete restrict;

-- Internal: fills state_code by exact (case-insensitive) state name and
-- fails loudly on any zone left without a state or on two zones of one
-- tenant naming the same state. Kept as a function so 056 can prove the
-- failure path.
create function public.zone_state_backfill()
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_bad text;
begin
  update public.zones z
     set state_code = s.code
    from public.ng_states s
   where z.state_code is null
     and lower(btrim(z.zone_name)) = lower(s.name);

  select string_agg(format('%s (zone %s, tenant %s)', z.zone_name, z.id, z.tenant_id), '; '
                    order by z.tenant_id, z.zone_name)
    into v_bad
    from public.zones z
   where z.state_code is null;
  if v_bad is not null then
    raise exception 'zones whose name matches no Nigerian state: %', v_bad
      using errcode = 'P0001',
            hint = 'rename each zone to its state''s name (ng_states.name), then run the migration again';
  end if;

  select string_agg(format('tenant %s, state %s: %s', d.tenant_id, d.state_code, d.names), '; ')
    into v_bad
    from (select z.tenant_id, z.state_code, string_agg(z.zone_name, ', ' order by z.zone_name) as names
            from public.zones z
           group by z.tenant_id, z.state_code
          having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'two zones of one tenant match the same state: %', v_bad using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.zone_state_backfill() from public, anon, authenticated, service_role;

select public.zone_state_backfill();

alter table public.zones
  alter column state_code set not null,
  add constraint zones_tenant_id_state_code_key unique (tenant_id, state_code);
create index idx_zones_state_code on public.zones (state_code);

-- ── 2. a ZSM's membership carries no zone ───────────────────────────────
alter table public.tenant_users drop constraint tenant_users_zsm_has_zone;

do $$
declare
  v_lost text;
begin
  -- each ACTIVE ZSM's old zone takes them as zsm_id where it has none
  -- (the zones_check_manager trigger requires an ACTIVE ZSM)
  update public.zones z
     set zsm_id = x.profile_id
    from (select distinct on (tu.tenant_id, tu.zone_id) tu.tenant_id, tu.zone_id, tu.profile_id
            from public.tenant_users tu
           where tu.role = 'ZSM' and tu.status = 'ACTIVE' and tu.zone_id is not null
           order by tu.tenant_id, tu.zone_id, tu.created_at, tu.id) x
   where z.tenant_id = x.tenant_id and z.id = x.zone_id and z.zsm_id is null;

  select string_agg(format('ZSM %s (tenant %s, zone %s)', tu.profile_id, tu.tenant_id, tu.zone_id), '; ')
    into v_lost
    from public.tenant_users tu
    join public.zones z on z.tenant_id = tu.tenant_id and z.id = tu.zone_id
   where tu.role = 'ZSM' and z.zsm_id is distinct from tu.profile_id;
  if v_lost is not null then
    raise notice 'ZSMs whose old zone has another zsm_id (set zones.zsm_id to give them coverage): %', v_lost;
  end if;

  update public.tenant_users set zone_id = null where role = 'ZSM' and zone_id is not null;
end;
$$;

alter table public.tenant_users
  add constraint tenant_users_zsm_no_zone check (role <> 'ZSM' or zone_id is null);

-- ── 3. coverage helpers ─────────────────────────────────────────────────
-- The zones of a tenant whose zsm_id is the profile, given an ACTIVE ZSM
-- membership there (A6 §17.1).
create function public.zsm_zone_ids(p_tenant_id uuid, p_profile_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select z.id
    from public.zones z
   where z.tenant_id = p_tenant_id
     and z.zsm_id = p_profile_id
     and exists (select 1 from public.tenant_users tu
                  where tu.tenant_id = p_tenant_id
                    and tu.profile_id = p_profile_id
                    and tu.role = 'ZSM'
                    and tu.status = 'ACTIVE');
$$;
revoke all on function public.zsm_zone_ids(uuid, uuid) from public, anon, authenticated, service_role;

-- The caller's zones in their active tenant, for policies.
create function public.my_zsm_zone_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.zsm_zone_ids(public.jwt_tenant_id(), (select auth.uid()));
$$;
revoke all on function public.my_zsm_zone_ids() from public, anon, service_role;
grant execute on function public.my_zsm_zone_ids() to authenticated;

-- Chat: every zone of a staff member (a ZSM's covered zones; otherwise the
-- zone of their territory). Internal.
create function public.chat_staff_zone_ids(p_tenant uuid, p_profile uuid)
returns setof uuid
language sql
stable
set search_path = public, pg_temp
as $$
  select z.zone_id
    from public.tenant_users tu
    cross join lateral public.zsm_zone_ids(tu.tenant_id, tu.profile_id) as z(zone_id)
   where tu.tenant_id = p_tenant and tu.profile_id = p_profile
     and tu.status = 'ACTIVE' and tu.role = 'ZSM'
  union
  select t.zone_id
    from public.tenant_users tu
    join public.territories t on t.tenant_id = tu.tenant_id and t.id = tu.territory_id
   where tu.tenant_id = p_tenant and tu.profile_id = p_profile
     and tu.status = 'ACTIVE' and tu.role in ('TM', 'ASM', 'DSM', 'DSA');
$$;
revoke all on function public.chat_staff_zone_ids(uuid, uuid) from public, anon, authenticated, service_role;

-- ── 4. recreated from their live definitions ────────────────────────────

-- chat_staff_zone: kept for one-zone callers; a ZSM has a single staff zone
-- only while they cover exactly one zone (never an arbitrary one of several).
CREATE OR REPLACE FUNCTION public.chat_staff_zone(p_tenant uuid, p_profile uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case when tu.role = 'ZSM'
              then (select case when count(*) = 1 then (array_agg(z.zone_id))[1] end
                      from public.zsm_zone_ids(tu.tenant_id, tu.profile_id) as z(zone_id))
              else t.zone_id end
    from public.tenant_users tu
    left join public.territories t on t.tenant_id = tu.tenant_id and t.id = tu.territory_id
   where tu.tenant_id = p_tenant
     and tu.profile_id = p_profile
     and tu.status = 'ACTIVE'
     and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA');
$function$;

-- my_chat_channel_ids: a multi-zone ZSM is in every ZONE channel and every
-- TERRITORY room of their zones.
CREATE OR REPLACE FUNCTION public.my_chat_channel_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with me as (
    select tu.tenant_id, tu.profile_id, tu.role, tu.territory_id
      from public.tenant_users tu
     where tu.profile_id = (select auth.uid())
       and tu.status = 'ACTIVE'
       and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA')
  ),
  my_zones as (
    select me.tenant_id, me.role, z.zone_id
      from me
      cross join lateral public.chat_staff_zone_ids(me.tenant_id, me.profile_id) as z(zone_id)
  )
  -- TERRITORY: own room
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'TERRITORY' and c.territory_id = me.territory_id
   where me.role <> 'ZSM'
  union
  -- TERRITORY: a ZSM sees every room in their zones
  select c.id
    from my_zones mz
    join public.territories t on t.tenant_id = mz.tenant_id and t.zone_id = mz.zone_id
    join public.chat_channels c
      on c.tenant_id = t.tenant_id and c.channel_type = 'TERRITORY' and c.territory_id = t.id
   where mz.role = 'ZSM'
  union
  -- ZONE: the zone's ZSM and TMs
  select c.id
    from my_zones mz join public.chat_channels c
      on c.tenant_id = mz.tenant_id and c.channel_type = 'ZONE' and c.zone_id = mz.zone_id
   where mz.role in ('ZSM', 'TM')
  union
  -- ANNOUNCEMENT: every staff member
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'ANNOUNCEMENT'
  union
  -- DIRECT: only the two participants
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'DIRECT' and c.direct_low_id = me.profile_id
  union
  select c.id
    from me join public.chat_channels c
      on c.tenant_id = me.tenant_id and c.channel_type = 'DIRECT' and c.direct_high_id = me.profile_id;
$function$;

-- get_or_create_direct_channel: the zone rules compare zone sets
CREATE OR REPLACE FUNCTION public.get_or_create_direct_channel(p_idempotency_key uuid, p_target_profile_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(
              array['ZSM', 'TM', 'ASM', 'DSM', 'DSA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_target  public.tenant_users;
  v_my_zones    uuid[];
  v_their_zones uuid[];
  v_shared  boolean;
  v_low     uuid := least(v_me.profile_id, p_target_profile_id);
  v_high    uuid := greatest(v_me.profile_id, p_target_profile_id);
  v_id      uuid;
  v_created boolean;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'get_or_create_direct_channel',
               jsonb_build_object('target', p_target_profile_id));
  if v_prior is not null then return v_prior; end if;

  if p_target_profile_id = v_me.profile_id then
    raise exception 'you cannot message yourself' using errcode = 'P0001';
  end if;
  if not public.chat_is_available(v_me.tenant_id, p_target_profile_id) then
    raise exception 'that person is not available' using errcode = 'P0001';
  end if;

  -- an existing pair is reopened without the scope rule (§4.1)
  select c.id into v_id from public.chat_channels c
   where c.tenant_id = v_me.tenant_id and c.channel_type = 'DIRECT'
     and c.direct_low_id = v_low and c.direct_high_id = v_high;
  if found then
    return public.idempotency_complete(p_idempotency_key,
      jsonb_build_object('channel_id', v_id, 'created', false));
  end if;

  select * into v_target from public.tenant_users tu
   where tu.tenant_id = v_me.tenant_id and tu.profile_id = p_target_profile_id and tu.status = 'ACTIVE';
  v_my_zones    := array(select public.chat_staff_zone_ids(v_me.tenant_id, v_me.profile_id));
  v_their_zones := array(select public.chat_staff_zone_ids(v_me.tenant_id, p_target_profile_id));
  v_shared      := v_my_zones && v_their_zones;

  if not (
       (v_me.territory_id is not null and v_me.territory_id = v_target.territory_id)
    or (v_me.role = 'ZSM' and v_shared)
    or (v_target.role = 'ZSM' and v_shared)
    or (v_me.role in ('TM', 'ZSM') and v_target.role in ('TM', 'ZSM') and v_shared)
  ) then
    raise exception 'you may not message that person' using errcode = '42501';
  end if;

  insert into public.chat_channels (tenant_id, channel_type, direct_low_id, direct_high_id)
  values (v_me.tenant_id, 'DIRECT', v_low, v_high)
  on conflict (tenant_id, direct_low_id, direct_high_id) where channel_type = 'DIRECT' do nothing
  returning id into v_id;
  v_created := v_id is not null;

  -- lost a race with a concurrent create of the same pair
  if not v_created then
    select c.id into v_id from public.chat_channels c
     where c.tenant_id = v_me.tenant_id and c.channel_type = 'DIRECT'
       and c.direct_low_id = v_low and c.direct_high_id = v_high;
  end if;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('channel_id', v_id, 'created', v_created));
end;
$function$;

-- hide_chat_message: the room's zone must be one of the ZSM's zones
CREATE OR REPLACE FUNCTION public.hide_chat_message(p_idempotency_key uuid, p_message_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_msg    public.chat_messages;
  v_ch     public.chat_channels;
  v_zone   uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'hide_chat_message',
               jsonb_build_object('message', p_message_id, 'reason', v_reason));
  if v_prior is not null then return v_prior; end if;

  if length(v_reason) not between 1 and 200 then
    raise exception 'a reason of 1 to 200 characters is required' using errcode = 'P0001';
  end if;

  select m.* into v_msg from public.chat_messages m
   where m.id = p_message_id and m.tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'message not found' using errcode = 'P0001';
  end if;

  select c.* into v_ch from public.chat_channels c
   where c.id = v_msg.channel_id and c.tenant_id = v_me.tenant_id;

  if v_ch.channel_type = 'DIRECT' then
    raise exception 'direct chats cannot be moderated' using errcode = '42501';
  elsif v_ch.channel_type = 'TERRITORY' then
    select t.zone_id into v_zone from public.territories t
     where t.tenant_id = v_ch.tenant_id and t.id = v_ch.territory_id;
  elsif v_ch.channel_type = 'ZONE' then
    v_zone := v_ch.zone_id;
  end if;
  if v_ch.channel_type in ('TERRITORY', 'ZONE') and not exists (
    select 1 from public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id) where z.zone_id = v_zone
  ) then
    raise exception 'this room is outside your zone' using errcode = '42501';
  end if;

  if v_msg.hidden_at is null then
    update public.chat_messages
       set body = '[removed]', hidden_at = now(), hidden_by = v_me.profile_id
     where id = v_msg.id
     returning * into v_msg;

    perform public.write_audit(v_me.tenant_id, 'CHAT_MESSAGE_HIDDEN', 'chat_messages', v_msg.id::text,
      null, jsonb_build_object('message_id', v_msg.id, 'channel_id', v_msg.channel_id,
                               'reason', v_reason), p_idempotency_key);
  end if;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('message_id', v_msg.id, 'hidden_at', v_msg.hidden_at));
end;
$function$;

-- upsert_zone: a new zone is a state, found by its name; an edit keeps the
-- state (zone_name is a display name)
CREATE OR REPLACE FUNCTION public.upsert_zone(p_idempotency_key uuid, p_zone_id uuid, p_zone_name text, p_boundary jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_geom   extensions.geometry;
  v_state  text;
  v_before public.zones;
  v_after  public.zones;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_zone',
    jsonb_build_object('zone_id', p_zone_id, 'zone_name', p_zone_name, 'boundary', p_boundary));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_zone_name is null or btrim(p_zone_name) = '' then
    raise exception 'zone_name is required' using errcode = 'P0001';
  end if;
  v_geom := public.geojson_to_multipolygon(p_boundary);

  if p_zone_id is null then
    select s.code into v_state from public.ng_states s
     where lower(s.name) = lower(btrim(p_zone_name));
    if v_state is null then
      raise exception 'a zone is a Nigerian state: name it by its state' using errcode = 'P0001';
    end if;
    insert into public.zones (tenant_id, zone_name, state_code, boundary)
    values (v_me.tenant_id, btrim(p_zone_name), v_state, v_geom)
    returning * into v_after;
  else
    select * into v_before from public.zones
     where id = p_zone_id and tenant_id = v_me.tenant_id
     for update;
    if not found then
      raise exception 'zone not found' using errcode = 'P0001';
    end if;
    update public.zones
       set zone_name = btrim(p_zone_name),
           boundary  = coalesce(v_geom, boundary)
     where id = p_zone_id
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_zone', 'zones', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('zone_id', v_after.id));
end;
$function$;

-- upsert_territory: the zone must be one of the ZSM's zones
CREATE OR REPLACE FUNCTION public.upsert_territory(p_idempotency_key uuid, p_territory_id uuid, p_zone_id uuid, p_territory_name text, p_boundary jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_geom   extensions.geometry;
  v_before public.territories;
  v_after  public.territories;
begin
  if p_zone_id is null or not exists (
    select 1 from public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id) where z.zone_id = p_zone_id
  ) then
    raise exception 'a ZSM manages territories in their own zone only' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_territory',
    jsonb_build_object('territory_id', p_territory_id, 'zone_id', p_zone_id,
                       'territory_name', p_territory_name, 'boundary', p_boundary));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_territory_name is null or btrim(p_territory_name) = '' then
    raise exception 'territory_name is required' using errcode = 'P0001';
  end if;
  v_geom := public.geojson_to_multipolygon(p_boundary);

  if p_territory_id is null then
    insert into public.territories (tenant_id, zone_id, territory_name, boundary)
    values (v_me.tenant_id, p_zone_id, btrim(p_territory_name), v_geom)
    returning * into v_after;
  else
    select * into v_before from public.territories
     where id = p_territory_id and tenant_id = v_me.tenant_id and zone_id = p_zone_id
     for update;
    if not found then
      raise exception 'territory not found in your zone' using errcode = 'P0001';
    end if;
    update public.territories
       set territory_name = btrim(p_territory_name),
           boundary       = coalesce(v_geom, boundary)
     where id = p_territory_id
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_territory', 'territories', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('territory_id', v_after.id));
end;
$function$;

-- upsert_area: a ZSM works in any territory of their zones
CREATE OR REPLACE FUNCTION public.upsert_area(p_idempotency_key uuid, p_area_id uuid, p_territory_id uuid, p_area_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_terr   public.territories;
  v_before public.areas;
  v_after  public.areas;
begin
  select * into v_terr from public.territories
   where id = p_territory_id and tenant_id = v_me.tenant_id;
  if not found
     or (v_me.role = 'ZSM' and not exists (
           select 1 from public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id)
            where z.zone_id = v_terr.zone_id))
     or (v_me.role = 'TM'  and v_terr.id is distinct from v_me.territory_id) then
    raise exception 'areas are managed by the ZSM of the zone or the TM of the territory'
      using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_area',
    jsonb_build_object('area_id', p_area_id, 'territory_id', p_territory_id, 'area_name', p_area_name));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_area_name is null or btrim(p_area_name) = '' then
    raise exception 'area_name is required' using errcode = 'P0001';
  end if;

  if p_area_id is null then
    insert into public.areas (tenant_id, territory_id, area_name)
    values (v_me.tenant_id, p_territory_id, btrim(p_area_name))
    returning * into v_after;
  else
    select * into v_before from public.areas
     where id = p_area_id and tenant_id = v_me.tenant_id and territory_id = p_territory_id
     for update;
    if not found then
      raise exception 'area not found in this territory' using errcode = 'P0001';
    end if;
    update public.areas set area_name = btrim(p_area_name)
     where id = p_area_id
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_area', 'areas', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('area_id', v_after.id));
end;
$function$;

-- invite_tenant_user: "the territory is in one of my zones"; a ZSA takes the
-- zone of the territory named in the invite, or the ZSM's only zone when the
-- invite names none (a ZSM covering several zones must name a territory)
CREATE OR REPLACE FUNCTION public.invite_tenant_user(p_idempotency_key uuid, p_phone_number text, p_role tenant_role_enum, p_territory_id uuid, p_reports_to_id uuid, p_area_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_phone   text := '+' || ltrim(btrim(coalesce(p_phone_number, '')), '+');
  v_profile uuid;
  v_member  public.tenant_users;
  v_zone    uuid;
  v_area    uuid;
  v_reports uuid := p_reports_to_id;
begin
  if v_me.role = 'CLIENT_SERVICE_MANAGER' then
    if p_role not in ('LOGISTICS_MANAGER', 'TENANT_ADMIN') then
      raise exception 'a client service manager invites tenant admins and logistics managers only'
        using errcode = '42501';
    end if;
    if p_territory_id is not null or p_area_id is not null then
      raise exception 'tenant-wide roles have no territory or area' using errcode = 'P0001';
    end if;
    if p_role = 'LOGISTICS_MANAGER' then
      if p_reports_to_id is not null and p_reports_to_id <> v_me.id then
        raise exception 'a logistics manager reports to the inviting client service manager'
          using errcode = 'P0001';
      end if;
      v_reports := v_me.id;
    else
      v_reports := null;
    end if;
  else
    if p_role = 'CLIENT_SERVICE_MANAGER' then
      raise exception 'only a platform administrator appoints a client service manager' using errcode = '42501';
    end if;
    if p_role in ('TENANT_ADMIN', 'LOGISTICS_MANAGER') then
      raise exception 'the client service manager invites tenant admins and logistics managers' using errcode = '42501';
    end if;
    if p_role = 'ZSM' then
      raise exception 'only a platform administrator appoints a ZSM' using errcode = '42501';
    end if;
    if p_territory_id is not null and not exists (
      select 1 from public.territories t
      where t.id = p_territory_id and t.tenant_id = v_me.tenant_id
        and t.zone_id in (select public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id))
    ) then
      raise exception 'a ZSM invites into territories of their own zone only' using errcode = '42501';
    end if;
    if p_role = 'ASA' and p_territory_id is null then
      raise exception 'ASA requires a territory' using errcode = 'P0001';
    end if;
    if p_role = 'ASA' and p_area_id is not null and not exists (
      select 1 from public.areas a
      where a.id = p_area_id and a.tenant_id = v_me.tenant_id and a.territory_id = p_territory_id
    ) then
      raise exception 'the area is not inside the territory' using errcode = '42501';
    end if;
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'invite_tenant_user',
    jsonb_build_object('phone_number', v_phone, 'role', p_role,
                       'territory_id', p_territory_id, 'reports_to_id', v_reports,
                       'area_id', p_area_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select p.id into v_profile
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.phone_number = v_phone
    and u.phone_confirmed_at is not null;
  if v_profile is null then
    raise exception 'no Teafair account with a verified phone exists for %', v_phone using errcode = 'P0001';
  end if;
  if p_role in ('TM', 'ASM', 'DSM', 'DSA', 'POS_AGENT', 'ASA') and p_territory_id is null then
    raise exception '% requires a territory', p_role using errcode = 'P0001';
  end if;
  if p_role in ('ASM', 'DSM', 'DSA', 'ZSA', 'ASA') and v_reports is null then
    raise exception '% must report to someone', p_role using errcode = 'P0001';
  end if;
  if v_reports is not null and not exists (
    select 1 from public.tenant_users tu
    where tu.id = v_reports and tu.tenant_id = v_me.tenant_id and tu.status = 'ACTIVE'
  ) then
    raise exception 'reports_to must be an active member of this tenant' using errcode = 'P0001';
  end if;

  if p_role = 'ZSA' then
    if p_territory_id is not null then
      select t.zone_id into v_zone from public.territories t
       where t.id = p_territory_id and t.tenant_id = v_me.tenant_id;
    else
      select case when count(*) = 1 then (array_agg(z.zone_id))[1] end into v_zone
        from public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id);
      if v_zone is null then
        raise exception 'a ZSM covering several zones names a territory of the ZSA''s zone' using errcode = 'P0001';
      end if;
    end if;
    if not exists (
      select 1 from public.tenant_users tu
      where tu.id = v_reports and tu.tenant_id = v_me.tenant_id
        and tu.role = 'ZSM'
        and v_zone in (select public.zsm_zone_ids(tu.tenant_id, tu.profile_id))
    ) then
      raise exception 'a ZSA reports to a ZSM of the zone' using errcode = 'P0001';
    end if;
  elsif p_role = 'ASA' then
    if p_area_id is null then
      raise exception 'ASA requires an area' using errcode = 'P0001';
    end if;
    v_area := p_area_id;
    if not exists (
      select 1 from public.tenant_users tu
      where tu.id = v_reports and tu.tenant_id = v_me.tenant_id
        and tu.role in ('ASM', 'TM') and tu.territory_id = p_territory_id
    ) then
      raise exception 'an ASA reports to an ASM or TM of the territory' using errcode = 'P0001';
    end if;
  end if;

  insert into public.tenant_users (tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status)
  values (v_me.tenant_id, v_profile, p_role, v_zone, p_territory_id, v_area, v_reports, 'INVITED')
  returning * into v_member;

  insert into public.notifications (tenant_id, user_id, kind, title, payload)
  values (v_me.tenant_id, v_profile, 'TENANT_INVITE', 'You have been invited to join a team',
          jsonb_build_object('tenant_user_id', v_member.id, 'role', p_role));

  perform public.write_audit(v_me.tenant_id, 'invite_tenant_user', 'tenant_users', v_member.id::text,
                             null, to_jsonb(v_member) - 'pin_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_user_id', v_member.id, 'status', v_member.status));
end;
$function$;
