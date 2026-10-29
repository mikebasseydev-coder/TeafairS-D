-- Fix round 1 for 20261029120100: the new tenant-wide roles must not leak
-- into older checks, and an LM must see the fulfilment it performs.

-- ── the web default agent is not a tenant-wide role member ────────────────────────
-- (a TENANT_ADMIN, CSM or LM would otherwise become the accountable person
-- on tickets and the selling agent on web orders)
create or replace function public.set_web_defaults(p_idempotency_key uuid, p_warehouse_id uuid, p_agent_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.tenant_settings;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_web_defaults',
    jsonb_build_object('warehouse_id', p_warehouse_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_warehouse_id is not null and not exists (
       select 1 from public.warehouses where tenant_id = v_me.tenant_id and id = p_warehouse_id) then
    raise exception 'the warehouse does not belong to this tenant' using errcode = 'P0001';
  end if;
  if p_agent_id is not null and not exists (
       select 1 from public.tenant_users
        where tenant_id = v_me.tenant_id and profile_id = p_agent_id and status = 'ACTIVE'
          and role not in ('CLIENT_SERVICE_MANAGER', 'TENANT_ADMIN', 'LOGISTICS_MANAGER')) then
    raise exception 'the default agent must be an active member of this tenant without a tenant-wide role' using errcode = 'P0001';
  end if;

  select * into v_before from public.tenant_settings where tenant_id = v_me.tenant_id for update;

  insert into public.tenant_settings (tenant_id, web_default_warehouse_id, web_default_agent_id)
  values (v_me.tenant_id, p_warehouse_id, p_agent_id)
  on conflict (tenant_id)
  do update set web_default_warehouse_id = excluded.web_default_warehouse_id,
                web_default_agent_id     = excluded.web_default_agent_id;

  perform public.write_audit(v_me.tenant_id, 'set_web_defaults', 'tenant_settings', v_me.tenant_id::text,
    jsonb_build_object('warehouse_id', v_before.web_default_warehouse_id, 'agent_id', v_before.web_default_agent_id),
    jsonb_build_object('warehouse_id', p_warehouse_id, 'agent_id', p_agent_id),
    p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('warehouse_id', p_warehouse_id, 'agent_id', p_agent_id));
end;
$function$;
revoke all on function public.set_web_defaults(uuid, uuid, uuid) from public, anon;
grant execute on function public.set_web_defaults(uuid, uuid, uuid) to authenticated;

create or replace function public.tenant_settings_web_defaults_check()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.web_default_warehouse_id is not null and exists (
    select 1 from public.warehouses w
     where w.tenant_id = new.tenant_id and w.id = new.web_default_warehouse_id)
     and not exists (
    select 1 from public.warehouses w
     where w.tenant_id = new.tenant_id and w.id = new.web_default_warehouse_id
       and w.kind = 'CENTRAL') then
    raise exception 'the default web warehouse must be a CENTRAL warehouse';
  end if;
  if new.web_default_agent_id is not null and not exists (
    select 1 from public.tenant_users tu
     where tu.tenant_id = new.tenant_id and tu.profile_id = new.web_default_agent_id
       and tu.status = 'ACTIVE'
       and tu.role not in ('CLIENT_SERVICE_MANAGER', 'TENANT_ADMIN', 'LOGISTICS_MANAGER')) then
    raise exception 'the default web agent must be an active member of this tenant without a tenant-wide role';
  end if;
  return new;
end $function$;

-- ── an LM sees the fulfilment of its tenant's orders ────────────────────
create or replace function public.my_fulfilment_order_ids()
 returns setof uuid
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select f.order_id
    from public.order_fulfilments f
   where f.tenant_id in (select public.my_tenant_ids_with_role(array['ZSM', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]))
  union
  select f.order_id
    from public.order_fulfilments f
    join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
   where o.territory_id in (select public.my_tm_territory_ids())
  union
  select f.order_id
    from public.order_fulfilments f
    join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
    join public.warehouses w on w.tenant_id = o.tenant_id and w.id = o.fulfilment_warehouse_id
   where w.manager_id = (select auth.uid())
     and w.tenant_id in (select public.my_tenant_ids());
$function$;
revoke all on function public.my_fulfilment_order_ids() from public, anon;
grant execute on function public.my_fulfilment_order_ids() to authenticated;

-- ── appoint_client_service_manager: only into an ACTIVE tenant ──────────
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
  v_status  public.tenant_status_enum;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'appoint_client_service_manager',
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
