-- Addendum A6 §17 (Task 1d, fix round 1): zones and ZSMs belong to the
-- platform. Only a platform administrator appoints a ZSM, creates a zone (one
-- per state) and sets a zone's ZSM, each through an audited SECURITY DEFINER
-- RPC (Spec A §9; A6 §16.4 "zero unaudited backdoors"). A ZSM edits only
-- their own zones, and a zone keeps its state's name.
--
-- appoint_zone_manager and create_zone take p_tenant_id: platform-role RPCs
-- acting on a named tenant, as appoint_client_service_manager.

-- ── appoint_zone_manager ────────────────────────────────────────────────
create function public.appoint_zone_manager(p_idempotency_key uuid, p_tenant_id uuid, p_phone_number text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor   uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior   jsonb;
  v_phone   text := '+' || ltrim(btrim(coalesce(p_phone_number, '')), '+');
  v_profile uuid;
  v_member  public.tenant_users;
  v_status  public.tenant_status_enum;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'appoint_zone_manager',
    jsonb_build_object('tenant_id', p_tenant_id, 'phone_number', v_phone));
  if v_prior is not null then
    return v_prior;
  end if;

  select t.status into v_status from public.tenants t where t.id = p_tenant_id;
  if not found then
    raise exception 'tenant not found' using errcode = 'P0001';
  end if;
  if v_status <> 'ACTIVE' then
    raise exception 'the tenant is not active' using errcode = 'P0001';
  end if;

  select p.id into v_profile
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.phone_number = v_phone
    and u.phone_confirmed_at is not null;
  if v_profile is null then
    raise exception 'no Teafair account with a verified phone exists for %', v_phone using errcode = 'P0001';
  end if;
  if exists (select 1 from public.tenant_users tu
              where tu.tenant_id = p_tenant_id and tu.profile_id = v_profile) then
    raise exception 'this person is already a member of the tenant' using errcode = '23505';
  end if;

  -- a ZSM membership carries no zone: coverage is zones.zsm_id (set_zone_zsm)
  insert into public.tenant_users (tenant_id, profile_id, role, status)
  values (p_tenant_id, v_profile, 'ZSM', 'INVITED')
  returning * into v_member;

  insert into public.notifications (tenant_id, user_id, kind, title, payload)
  values (p_tenant_id, v_profile, 'TENANT_INVITE', 'You have been invited to join a team',
          jsonb_build_object('tenant_user_id', v_member.id, 'role', 'ZSM'));

  perform public.write_audit(p_tenant_id, 'appoint_zone_manager', 'tenant_users', v_member.id::text,
                             null, to_jsonb(v_member) - 'pin_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_user_id', v_member.id, 'status', v_member.status));
end;
$$;
revoke all on function public.appoint_zone_manager(uuid, uuid, text) from public, anon;
grant execute on function public.appoint_zone_manager(uuid, uuid, text) to authenticated;

-- ── create_zone: one zone per state per tenant, named after the state ───
create function public.create_zone(p_idempotency_key uuid, p_tenant_id uuid, p_state_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_code   text := upper(btrim(coalesce(p_state_code, '')));
  v_state  public.ng_states;
  v_status public.tenant_status_enum;
  v_after  public.zones;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'create_zone',
    jsonb_build_object('tenant_id', p_tenant_id, 'state_code', v_code));
  if v_prior is not null then
    return v_prior;
  end if;

  select t.status into v_status from public.tenants t where t.id = p_tenant_id;
  if not found then
    raise exception 'tenant not found' using errcode = 'P0001';
  end if;
  if v_status <> 'ACTIVE' then
    raise exception 'the tenant is not active' using errcode = 'P0001';
  end if;
  select * into v_state from public.ng_states s where s.code = v_code;
  if not found then
    raise exception 'unknown state code' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.zones z where z.tenant_id = p_tenant_id and z.state_code = v_code) then
    raise exception 'this tenant already has a zone for that state' using errcode = '23505';
  end if;

  insert into public.zones (tenant_id, zone_name, state_code)
  values (p_tenant_id, v_state.name, v_code)
  returning * into v_after;

  perform public.write_audit(p_tenant_id, 'create_zone', 'zones', v_after.id::text,
                             null, to_jsonb(v_after) - 'boundary', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('zone_id', v_after.id, 'state_code', v_after.state_code, 'zone_name', v_after.zone_name));
end;
$$;
revoke all on function public.create_zone(uuid, uuid, text) from public, anon;
grant execute on function public.create_zone(uuid, uuid, text) to authenticated;

-- ── set_zone_zsm: the zone's coverage; the tenant comes from the zone ───
create function public.set_zone_zsm(p_idempotency_key uuid, p_zone_id uuid, p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior jsonb;
  v_zone  public.zones;
  v_old   uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_zone_zsm',
    jsonb_build_object('zone_id', p_zone_id, 'profile_id', p_profile_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_zone from public.zones z where z.id = p_zone_id for update;
  if not found then
    raise exception 'zone not found' using errcode = 'P0001';
  end if;
  if p_profile_id is not null and not exists (
    select 1 from public.tenant_users tu
     where tu.tenant_id = v_zone.tenant_id and tu.profile_id = p_profile_id
       and tu.role = 'ZSM' and tu.status = 'ACTIVE'
  ) then
    raise exception 'the zone manager must be an active ZSM of this tenant' using errcode = 'P0001';
  end if;

  v_old := v_zone.zsm_id;
  -- the zones_check_manager trigger re-checks the ZSM membership
  update public.zones set zsm_id = p_profile_id where id = v_zone.id
  returning * into v_zone;

  perform public.write_audit(v_zone.tenant_id, 'set_zone_zsm', 'zones', v_zone.id::text,
                             jsonb_build_object('zsm_id', v_old), jsonb_build_object('zsm_id', v_zone.zsm_id),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('zone_id', v_zone.id, 'zsm_id', v_zone.zsm_id));
end;
$$;
revoke all on function public.set_zone_zsm(uuid, uuid, uuid) from public, anon;
grant execute on function public.set_zone_zsm(uuid, uuid, uuid) to authenticated;

-- ── upsert_zone (live signature and grants kept) ────────────────────────
-- No creation (create_zone does that); a ZSM edits only their own zones;
-- the name stays the state's name; the boundary may change.
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
  if not exists (select 1 from public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id) as z(zone_id)
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
