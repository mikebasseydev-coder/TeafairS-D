-- Spec A §5.3 — the foundation write RPCs: tenancy, identity and geography.
-- Feature RPCs (requisitions, orders, pickups, payments) belong to Specs C/D.
--
-- Every function follows §3.3: SECURITY DEFINER, pinned search_path,
-- p_idempotency_key first, actor and tenant from the JWT (never parameters),
-- role re-asserted live, one audit row per effect, jsonb result.
--
-- PLATFORM_SUPER_ADMIN work (first ZSM of a tenant, KYC approval) runs through
-- service-role admin tooling, not these RPCs (§5.1).

-- ── set_active_tenant ───────────────────────────────────────────────────
-- The one RPC that takes a tenant id: it is the selection itself. It is a
-- proposal, accepted only for a tenant the caller is ACTIVE in. The client
-- then refreshes its session so the access-token hook re-mints the claims.
create or replace function public.set_active_tenant(p_idempotency_key uuid, p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_authenticated();
  v_prior jsonb;
begin
  if not public.is_tenant_member(p_tenant_id) then
    raise exception 'not an active member of that tenant' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'set_active_tenant',
                                      jsonb_build_object('tenant_id', p_tenant_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- two statements: one primary per person is a non-deferrable unique index
  update public.tenant_users set is_primary = false
   where profile_id = v_uid and is_primary and tenant_id <> p_tenant_id;
  update public.tenant_users set is_primary = true
   where profile_id = v_uid and tenant_id = p_tenant_id;

  perform public.write_audit(p_tenant_id, 'set_active_tenant', 'tenant_users', v_uid::text,
                             null, jsonb_build_object('active_tenant_id', p_tenant_id),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('active_tenant_id', p_tenant_id, 'refresh_session', true));
end;
$$;

-- ── register_device ─────────────────────────────────────────────────────
-- Self-scoped: needs a signed-in user, not a tenant. An invited user registers
-- their phone before accepting.
create or replace function public.register_device(
  p_idempotency_key uuid,
  p_hardware_id     text,
  p_device_model    text,
  p_push_token      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_authenticated();
  v_prior  jsonb;
  v_tenant uuid := public.jwt_tenant_id();
  v_device public.devices;
begin
  if p_hardware_id is null or btrim(p_hardware_id) = '' then
    raise exception 'hardware_id is required' using errcode = 'P0001';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'register_device',
    jsonb_build_object('hardware_id', p_hardware_id, 'device_model', p_device_model,
                       'push_token', p_push_token));
  if v_prior is not null then
    return v_prior;
  end if;

  insert into public.devices (user_id, hardware_id, device_model, push_token, last_seen_at)
  values (v_uid, btrim(p_hardware_id), p_device_model, p_push_token, now())
  on conflict (user_id, hardware_id) do update
    set device_model = excluded.device_model,
        push_token   = excluded.push_token,
        last_seen_at = now()
  returning * into v_device;

  perform public.write_audit(
    case when public.is_tenant_member(v_tenant) then v_tenant end,
    'register_device', 'devices', v_device.id::text, null,
    jsonb_build_object('hardware_id', v_device.hardware_id, 'device_model', v_device.device_model),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('device_id', v_device.id));
end;
$$;

-- ── upsert_zone ─────────────────────────────────────────────────────────
-- ZSM, tenant scope. p_zone_id null creates; otherwise updates a zone of the
-- caller's tenant. A null boundary on update leaves the boundary unchanged.
create or replace function public.upsert_zone(
  p_idempotency_key uuid,
  p_zone_id         uuid,
  p_zone_name       text,
  p_boundary        jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_geom   extensions.geometry;
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
    insert into public.zones (tenant_id, zone_name, boundary)
    values (v_me.tenant_id, btrim(p_zone_name), v_geom)
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
$$;

-- ── upsert_territory ────────────────────────────────────────────────────
-- ZSM, zone scope: only within the ZSM's own zone.
create or replace function public.upsert_territory(
  p_idempotency_key uuid,
  p_territory_id    uuid,
  p_zone_id         uuid,
  p_territory_name  text,
  p_boundary        jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_geom   extensions.geometry;
  v_before public.territories;
  v_after  public.territories;
begin
  if p_zone_id is distinct from v_me.zone_id then
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
     where id = p_territory_id and tenant_id = v_me.tenant_id and zone_id = v_me.zone_id
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
$$;

-- ── invite_tenant_user ──────────────────────────────────────────────────
-- ZSM, zone scope. The invitee must already have an account (the gateway
-- creates it through the Auth admin API before calling this). A ZSM cannot
-- appoint another ZSM; that is PLATFORM_SUPER_ADMIN tooling.
create or replace function public.invite_tenant_user(
  p_idempotency_key uuid,
  p_phone_number    text,
  p_role            public.tenant_role_enum,
  p_territory_id    uuid,
  p_reports_to_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_phone   text := '+' || ltrim(btrim(coalesce(p_phone_number, '')), '+');
  v_profile uuid;
  v_member  public.tenant_users;
begin
  if p_role = 'ZSM' then
    raise exception 'only a platform administrator appoints a ZSM' using errcode = '42501';
  end if;
  if p_territory_id is not null and not exists (
    select 1 from public.territories t
    where t.id = p_territory_id and t.tenant_id = v_me.tenant_id and t.zone_id = v_me.zone_id
  ) then
    raise exception 'a ZSM invites into territories of their own zone only' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'invite_tenant_user',
    jsonb_build_object('phone_number', v_phone, 'role', p_role,
                       'territory_id', p_territory_id, 'reports_to_id', p_reports_to_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select id into v_profile from public.profiles where phone_number = v_phone;
  if v_profile is null then
    raise exception 'no Teafair account exists for %', v_phone using errcode = 'P0001';
  end if;
  if p_role in ('TM', 'ASM', 'DSM', 'DSA', 'FINTECH_AGENT') and p_territory_id is null then
    raise exception '% requires a territory', p_role using errcode = 'P0001';
  end if;
  if p_role in ('ASM', 'DSM', 'DSA') and p_reports_to_id is null then
    raise exception '% must report to someone', p_role using errcode = 'P0001';
  end if;
  if p_reports_to_id is not null and not exists (
    select 1 from public.tenant_users tu
    where tu.id = p_reports_to_id and tu.tenant_id = v_me.tenant_id and tu.status = 'ACTIVE'
  ) then
    raise exception 'reports_to must be an active member of this tenant' using errcode = 'P0001';
  end if;

  insert into public.tenant_users (tenant_id, profile_id, role, territory_id, reports_to_id, status)
  values (v_me.tenant_id, v_profile, p_role, p_territory_id, p_reports_to_id, 'INVITED')
  returning * into v_member;

  insert into public.notifications (tenant_id, user_id, kind, title, payload)
  values (v_me.tenant_id, v_profile, 'TENANT_INVITE', 'You have been invited to join a team',
          jsonb_build_object('tenant_user_id', v_member.id, 'role', p_role));

  perform public.write_audit(v_me.tenant_id, 'invite_tenant_user', 'tenant_users', v_member.id::text,
                             null, to_jsonb(v_member) - 'pin_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_user_id', v_member.id, 'status', v_member.status));
end;
$$;

-- ── set_brand_approval_policy ───────────────────────────────────────────
-- ZSM, tenant scope, PIN-gated at the gateway (§5.3). Brands match
-- case-insensitively; the stored spelling follows the latest call. Applies to
-- requisitions submitted afterwards, never to those in flight (§5.4).
create or replace function public.set_brand_approval_policy(
  p_idempotency_key          uuid,
  p_brand                    text,
  p_required_approval_level  public.tenant_role_enum
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_brand  text := btrim(coalesce(p_brand, ''));
  v_before public.brand_approval_policies;
  v_after  public.brand_approval_policies;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_brand_approval_policy',
    jsonb_build_object('brand', v_brand, 'level', p_required_approval_level));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_brand = '' then
    raise exception 'brand is required' using errcode = 'P0001';
  end if;
  if public.approval_rank(p_required_approval_level) is null then
    raise exception 'approval level must be DSM, ASM, TM or ZSM' using errcode = 'P0001';
  end if;

  select * into v_before from public.brand_approval_policies
   where tenant_id = v_me.tenant_id and lower(brand) = lower(v_brand)
   for update;

  if found then
    update public.brand_approval_policies
       set brand = v_brand,
           required_approval_level = p_required_approval_level,
           updated_by = v_me.profile_id
     where tenant_id = v_me.tenant_id and brand = v_before.brand
    returning * into v_after;
  else
    insert into public.brand_approval_policies (tenant_id, brand, required_approval_level, updated_by)
    values (v_me.tenant_id, v_brand, p_required_approval_level, v_me.profile_id)
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'set_brand_approval_policy', 'brand_approval_policies',
                             v_after.brand, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('brand', v_after.brand,
                       'required_approval_level', v_after.required_approval_level));
end;
$$;

grant execute on function
  public.set_active_tenant(uuid, uuid),
  public.register_device(uuid, text, text, text),
  public.upsert_zone(uuid, uuid, text, jsonb),
  public.upsert_territory(uuid, uuid, uuid, text, jsonb),
  public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid),
  public.set_brand_approval_policy(uuid, text, public.tenant_role_enum)
to authenticated;
