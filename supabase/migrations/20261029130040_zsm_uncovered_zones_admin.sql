-- Addendum A6 §18.3, plan Task 1e, fix round 2 (user ruling 2026-10-30:
-- "Unassigned zones remain accessible to any active ZSM of the brand until a
-- dedicated ZSM is assigned"). The no-orphan rule of 20261029130030 now also
-- covers the Task 1d administrative objects and chat rooms: every "may this
-- ZSM act in this zone" check uses the one helper zsm_reach_zone_ids (zones
-- the ZSM covers, plus zones no ACTIVE ZSM of the tenant covers).
--
-- zsm_zone_ids (strict coverage) stays where coverage itself is meant: the
-- default zone of a ZSA invited without a territory ("the ZSM's only covered
-- zone"), chat_staff_zone (a ZSM's single covered zone), web_route_try and
-- assign_ticket accountability (zones.zsm_id), set_zone_zsm validation, and
-- the referral-code "ZSM sharing a covered zone" branch.
--
-- Recreated from their live definitions, same signatures; CREATE OR REPLACE
-- keeps their grants. Only the zsm_zone_ids calls named below change.

-- chat: ZONE and TERRITORY room membership (my_chat_channel_ids) and the
-- zone-set rules of get_or_create_direct_channel follow through this helper
CREATE OR REPLACE FUNCTION public.chat_staff_zone_ids(p_tenant uuid, p_profile uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select z.zone_id
    from public.tenant_users tu
    cross join lateral public.zsm_reach_zone_ids(tu.tenant_id, tu.profile_id) as z(zone_id)
   where tu.tenant_id = p_tenant and tu.profile_id = p_profile
     and tu.status = 'ACTIVE' and tu.role = 'ZSM'
  union
  select t.zone_id
    from public.tenant_users tu
    join public.territories t on t.tenant_id = tu.tenant_id and t.id = tu.territory_id
   where tu.tenant_id = p_tenant and tu.profile_id = p_profile
     and tu.status = 'ACTIVE' and tu.role in ('TM', 'ASM', 'DSM', 'DSA');
$function$;

-- moderation of ZONE and TERRITORY rooms
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
    select 1 from public.zsm_reach_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id) where z.zone_id = v_zone
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

-- invites: the territory check and the ZSA manager check use reach; the
-- default zone of a ZSA invited without a territory stays the inviting
-- ZSM's only covered zone
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
        and t.zone_id in (select public.zsm_reach_zone_ids(v_me.tenant_id, v_me.profile_id))
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
        and v_zone in (select public.zsm_reach_zone_ids(tu.tenant_id, tu.profile_id))
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

-- the policy helper: the caller's zones in the active tenant
CREATE OR REPLACE FUNCTION public.my_zsm_zone_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select public.zsm_reach_zone_ids(public.jwt_tenant_id(), (select auth.uid()));
$function$;

-- areas
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
           select 1 from public.zsm_reach_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id)
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

-- territories
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
    select 1 from public.zsm_reach_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id) where z.zone_id = p_zone_id
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

-- zone boundaries
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
  if p_zone_id is null then
    raise exception 'zones are created by a platform administrator' using errcode = '42501';
  end if;
  if not exists (select 1 from public.zsm_reach_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id)
                  where z.zone_id = p_zone_id) then
    raise exception 'this zone is not yours' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_zone',
    jsonb_build_object('zone_id', p_zone_id, 'zone_name', p_zone_name, 'boundary', p_boundary));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.zones
   where id = p_zone_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'zone not found' using errcode = 'P0001';
  end if;
  select s.name into v_state from public.ng_states s where s.code = v_before.state_code;
  if p_zone_name is not null and lower(btrim(p_zone_name)) <> lower(v_state) then
    raise exception 'a zone is named after its state' using errcode = 'P0001';
  end if;
  v_geom := public.geojson_to_multipolygon(p_boundary);

  update public.zones
     set boundary = coalesce(v_geom, boundary)
   where id = p_zone_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'upsert_zone', 'zones', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('zone_id', v_after.id));
end;
$function$;

