-- Addendum A6 §16.3 (Monvelo Step 1c) — CSM appointment, the CSM invite rules,
-- tenant-wide role anchors, and LOGISTICS_MANAGER in dispatch and delivery.

-- ── anchors ─────────────────────────────────────────────────────────────
alter table public.tenant_users
  add constraint tenant_users_tenant_wide_roles check (
    role not in ('CLIENT_SERVICE_MANAGER', 'TENANT_ADMIN', 'LOGISTICS_MANAGER')
    or (zone_id is null and territory_id is null and area_id is null)),
  add constraint tenant_users_lm_reports check (
    role <> 'LOGISTICS_MANAGER' or reports_to_id is not null);

-- ── is_platform_staff ───────────────────────────────────────────────────
create or replace function public.is_platform_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.platform_role is not null
  );
$$;
revoke all on function public.is_platform_staff() from public, anon;
grant execute on function public.is_platform_staff() to authenticated, service_role;

-- ── appoint_client_service_manager ──────────────────────────────────────
create or replace function public.appoint_client_service_manager(
  p_idempotency_key uuid, p_tenant_id uuid, p_phone_number text)
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
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'appoint_client_service_manager',
    jsonb_build_object('tenant_id', p_tenant_id, 'phone_number', v_phone));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_tenant_id is null or not exists (select 1 from public.tenants t where t.id = p_tenant_id) then
    raise exception 'tenant not found' using errcode = 'P0001';
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

  insert into public.tenant_users (tenant_id, profile_id, role, status)
  values (p_tenant_id, v_profile, 'CLIENT_SERVICE_MANAGER', 'INVITED')
  returning * into v_member;

  insert into public.notifications (tenant_id, user_id, kind, title, payload)
  values (p_tenant_id, v_profile, 'TENANT_INVITE', 'You have been invited to join a team',
          jsonb_build_object('tenant_user_id', v_member.id, 'role', 'CLIENT_SERVICE_MANAGER'));

  perform public.write_audit(p_tenant_id, 'appoint_client_service_manager', 'tenant_users', v_member.id::text,
                             null, to_jsonb(v_member) - 'pin_hash', p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_user_id', v_member.id, 'status', v_member.status));
end;
$$;
revoke all on function public.appoint_client_service_manager(uuid, uuid, text) from public, anon;
grant execute on function public.appoint_client_service_manager(uuid, uuid, text) to authenticated;

-- ── invite_tenant_user (recreated from the live body) ───────────────────
create or replace function public.invite_tenant_user(p_idempotency_key uuid, p_phone_number text, p_role public.tenant_role_enum, p_territory_id uuid, p_reports_to_id uuid, p_area_id uuid DEFAULT NULL::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
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
      where t.id = p_territory_id and t.tenant_id = v_me.tenant_id and t.zone_id = v_me.zone_id
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
    v_zone := v_me.zone_id;
    if not exists (
      select 1 from public.tenant_users tu
      where tu.id = v_reports and tu.tenant_id = v_me.tenant_id
        and tu.role = 'ZSM' and tu.zone_id = v_zone
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
revoke all on function public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid, uuid) from public, anon;
grant execute on function public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid, uuid) to authenticated, service_role;

-- ── fulfilment ──────────────────────────────────────────────────────────
create or replace function public.fulfilment_can_dispatch(p_me public.tenant_users, p_order public.orders)
 returns boolean
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(p_me.status = 'ACTIVE' and p_me.tenant_id = p_order.tenant_id
                  and (p_me.role in ('ZSM', 'LOGISTICS_MANAGER')
                       or exists (select 1 from public.warehouses w
                                   where w.tenant_id = p_order.tenant_id
                                     and w.id = p_order.fulfilment_warehouse_id
                                     and w.manager_id = p_me.profile_id)), false);
$function$;
revoke all on function public.fulfilment_can_dispatch(public.tenant_users, public.orders) from public, anon, authenticated, service_role;

create or replace function public.fulfilment_delivery_path(p_me public.tenant_users, p_order public.orders)
 returns text
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select case
           when not coalesce(p_me.status = 'ACTIVE' and p_me.tenant_id = p_order.tenant_id, false) then null
           when p_me.role = 'ZSM' then 'FIELD_STAFF'
           when p_me.role = 'LOGISTICS_MANAGER' then 'COURIER'
           when p_me.role in ('TM', 'DSM', 'DSA') and p_me.territory_id = p_order.territory_id then 'FIELD_STAFF'
           when exists (select 1 from public.warehouses w
                         where w.tenant_id = p_order.tenant_id
                           and w.id = p_order.fulfilment_warehouse_id
                           and w.manager_id = p_me.profile_id) then 'COURIER'
         end;
$function$;
revoke all on function public.fulfilment_delivery_path(public.tenant_users, public.orders) from public, anon, authenticated, service_role;

-- ── monvelo staff read helper ───────────────────────────────────────────
create or replace function public.my_monvelo_staff_tenant_ids()
 returns setof uuid
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select tu.tenant_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA', 'ZSA', 'ASA', 'CLIENT_SERVICE_MANAGER', 'TENANT_ADMIN');
$function$;
revoke all on function public.my_monvelo_staff_tenant_ids() from public, anon;
grant execute on function public.my_monvelo_staff_tenant_ids() to authenticated, service_role;
