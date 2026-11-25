-- Email-first authentication (user decision 2026-11-25).
--
-- Meta's WhatsApp templates and the Nigerian sender-ID approvals are not in
-- place, so every persona signs in by email (a 6-digit code or a password)
-- through the send-auth-email hook. The phone becomes optional; the
-- send-auth-sms hook stays as it is, parked until those approvals arrive.
--
-- Identity stays auth.users -> profiles -> tenant_users -> access_token_claims:
-- the claims never read the phone, so they need no change.
--
--   1. profiles.phone_number is nullable; a profile holds an email, a phone
--      or both (profiles_contact_present).
--   2. handle_new_user takes the email and the phone from GoTrue's own
--      columns (never user metadata, audit H1) and requires one of them.
--   3. A change of email or phone in auth.users now follows into profiles
--      (handle_user_contact_change), so the profile is never stale after a
--      confirmed email_change.
--   4. Invitations and appointments resolve the person by a confirmed email
--      or a confirmed phone (resolve_verified_account). The four RPCs are
--      recreated with the parameter p_contact (was p_phone_number); argument
--      types, order and grants are unchanged, and every caller is positional.
--      Their errors no longer echo the contact (Ruling 46).
--   5. auth_email_context(user): whether the person may receive a sign-in
--      code, and which copy (TEAM, TRADE, MONVELO) the email uses. No PII.
--
-- Left as they are, on purpose: the shop owner's delivery, repayment, consent
-- and OTP codes go to a verified phone (a business rule, not sign-in); they
-- already fail closed when the owner has none.

-- ── 1. profiles ─────────────────────────────────────────────────────────
alter table public.profiles alter column phone_number drop not null;
alter table public.profiles add constraint profiles_contact_present
  check (email is not null or phone_number is not null);

-- ── 2. handle_new_user ──────────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- GoTrue's own columns only; user metadata is client-controlled (H1)
  v_email text := lower(nullif(btrim(coalesce(new.email, '')), ''));
  v_phone text := nullif(btrim(coalesce(new.phone, '')), '');
begin
  if v_email is null and v_phone is null then
    raise exception 'an email address is required to create a Teafair account'
      using errcode = 'P0001';
  end if;

  insert into public.profiles (id, full_name, phone_number, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    case when v_phone is not null then '+' || ltrim(v_phone, '+') end,
    v_email
  );
  return new;
end;
$$;

-- ── 3. contact changes follow into profiles ─────────────────────────────
-- GoTrue writes auth.users.email only once an email change is confirmed (the
-- pending address sits in email_change), and phone likewise; the Admin API
-- writes them directly. Removing the last contact fails the update
-- (profiles_contact_present), so GoTrue refuses it.
create function public.handle_user_contact_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := nullif(btrim(coalesce(new.phone, '')), '');
begin
  update public.profiles p
     set email        = lower(nullif(btrim(coalesce(new.email, '')), '')),
         phone_number = case when v_phone is not null then '+' || ltrim(v_phone, '+') end
   where p.id = new.id;
  return new;
end;
$$;
revoke all on function public.handle_user_contact_change() from public, anon, authenticated, service_role;

create trigger on_auth_user_contact_changed
  after update of email, phone on auth.users
  for each row
  when (old.email is distinct from new.email or old.phone is distinct from new.phone)
  execute function public.handle_user_contact_change();

-- ── 4. resolving an invitee by email or phone ───────────────────────────
-- The normalised contact as it goes into an idempotency request. A phone keeps
-- the key 'phone_number' so keys stored before this migration still replay.
create function public.auth_contact_request(p_contact text)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v text := btrim(coalesce(p_contact, ''));
begin
  if position('@' in v) > 0 then
    v := lower(v);
    if v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      raise exception 'enter a valid email address or phone number' using errcode = 'P0001';
    end if;
    return jsonb_build_object('email', v);
  end if;
  return jsonb_build_object('phone_number', '+' || ltrim(v, '+'));
end;
$$;
revoke all on function public.auth_contact_request(text) from public, anon, authenticated, service_role;

-- The profile whose email (or phone) Supabase Auth has confirmed. Matched on
-- auth.users, GoTrue's own record, never on anything a client wrote. Raises
-- P0001 without echoing the contact.
create function public.resolve_verified_account(p_contact text)
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_req jsonb := public.auth_contact_request(p_contact);
  v_id  uuid;
begin
  if v_req ? 'email' then
    select p.id into v_id
    from public.profiles p
    join auth.users u on u.id = p.id
    where u.email = v_req ->> 'email'
      and u.is_sso_user = false
      and u.email_confirmed_at is not null;
  else
    select p.id into v_id
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.phone_number = v_req ->> 'phone_number'
      and u.phone_confirmed_at is not null;
  end if;
  if v_id is null then
    raise exception 'no Teafair account with a verified email or phone matches that contact'
      using errcode = 'P0001';
  end if;
  return v_id;
end;
$$;
revoke all on function public.resolve_verified_account(text) from public, anon, authenticated, service_role;

-- The four RPCs, recreated from their latest bodies with p_contact. Dropped
-- first because CREATE OR REPLACE cannot rename a parameter.
drop function public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid, uuid);
drop function public.add_monvelo_member(uuid, uuid, text);
drop function public.appoint_zone_manager(uuid, uuid, text);
drop function public.appoint_client_service_manager(uuid, uuid, text);

CREATE FUNCTION public.invite_tenant_user(p_idempotency_key uuid, p_contact text, p_role tenant_role_enum, p_territory_id uuid, p_reports_to_id uuid, p_area_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
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
    public.auth_contact_request(p_contact) || jsonb_build_object('role', p_role,
                       'territory_id', p_territory_id, 'reports_to_id', v_reports,
                       'area_id', p_area_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_profile := public.resolve_verified_account(p_contact);
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

CREATE FUNCTION public.add_monvelo_member(p_idempotency_key uuid, p_agent_id uuid, p_contact text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid     uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior   jsonb;
  v_profile uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'add_monvelo_member',
    jsonb_build_object('agent_id', p_agent_id) || public.auth_contact_request(p_contact));
  if v_prior is not null then
    return v_prior;
  end if;
  if not exists (select 1 from public.monvelo_agents where id = p_agent_id) then
    raise exception 'unknown Monvelo agent' using errcode = 'P0001';
  end if;

  v_profile := public.resolve_verified_account(p_contact);

  insert into public.monvelo_agent_members (agent_id, profile_id, status)
  values (p_agent_id, v_profile, 'ACTIVE')
  on conflict (agent_id, profile_id) do update set status = 'ACTIVE';

  -- the audit carries ids only, never the contact
  perform public.write_audit(null, 'add_monvelo_member', 'monvelo_agent_members', p_agent_id::text,
                             null, jsonb_build_object('agent_id', p_agent_id, 'profile_id', v_profile, 'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'profile_id', v_profile, 'status', 'ACTIVE'));
end;
$function$;

CREATE FUNCTION public.appoint_zone_manager(p_idempotency_key uuid, p_tenant_id uuid, p_contact text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor   uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior   jsonb;
  v_profile uuid;
  v_member  public.tenant_users;
  v_status  public.tenant_status_enum;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'appoint_zone_manager',
    jsonb_build_object('tenant_id', p_tenant_id) || public.auth_contact_request(p_contact));
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

  v_profile := public.resolve_verified_account(p_contact);
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
$function$;

CREATE FUNCTION public.appoint_client_service_manager(p_idempotency_key uuid, p_tenant_id uuid, p_contact text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor   uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior   jsonb;
  v_profile uuid;
  v_member  public.tenant_users;
  v_status  public.tenant_status_enum;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'appoint_client_service_manager',
    jsonb_build_object('tenant_id', p_tenant_id) || public.auth_contact_request(p_contact));
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

  v_profile := public.resolve_verified_account(p_contact);
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
$function$;

revoke all on function public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid, uuid) from public, anon;
revoke all on function public.add_monvelo_member(uuid, uuid, text) from public, anon;
revoke all on function public.appoint_zone_manager(uuid, uuid, text) from public, anon;
revoke all on function public.appoint_client_service_manager(uuid, uuid, text) from public, anon;
grant execute on function public.invite_tenant_user(uuid, text, public.tenant_role_enum, uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.add_monvelo_member(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.appoint_zone_manager(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.appoint_client_service_manager(uuid, uuid, text) to authenticated, service_role;

-- ── 5. auth_email_context ───────────────────────────────────────────────
-- For the send-auth-email hook (service role, after the hook signature).
-- allowed: a platform role, an ACTIVE or INVITED membership (an invitee signs
-- in to accept), an ACTIVE Monvelo agent membership, or a registered shop
-- owner. Only sign-in codes are gated on it; confirmations, invitations,
-- recovery and email changes are not.
-- audience picks the copy: TEAM (the platform administrator and tenant staff,
-- who win over an agent membership), MONVELO (Monvelo staff and agent
-- members), TRADE (shop owners and POS agents only).
-- Monvelo's own answer (A6 §15: only a monvelo-named function reads a
-- monvelo_* table): whether the person is an ACTIVE member of an agent.
create function public.is_monvelo_agent_member(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.monvelo_agent_members m
                 where m.profile_id = p_user_id and m.status = 'ACTIVE');
$$;
revoke all on function public.is_monvelo_agent_member(uuid) from public, anon, authenticated, service_role;

create function public.auth_email_context(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with me as (
    select p.platform_role from public.profiles p where p.id = p_user_id
  ), roles as (
    select tu.role from public.tenant_users tu
    where tu.profile_id = p_user_id and tu.status in ('ACTIVE', 'INVITED')
  ), agent as (
    select 1 where public.is_monvelo_agent_member(p_user_id)
  ), shop as (
    select 1 from public.retail_shops s where s.owner_id = p_user_id
  )
  select jsonb_build_object(
    'allowed', exists (select 1 from me where platform_role is not null)
               or exists (select 1 from roles)
               or exists (select 1 from agent)
               or exists (select 1 from shop),
    'audience', case
      when exists (select 1 from me where platform_role = 'PLATFORM_SUPER_ADMIN') then 'TEAM'
      when exists (select 1 from me where platform_role in ('MONVELO_OPERATOR', 'MONVELO_FINANCE')) then 'MONVELO'
      when exists (select 1 from roles where role not in ('RETAIL_SHOP_OWNER', 'POS_AGENT')) then 'TEAM'
      when exists (select 1 from agent) then 'MONVELO'
      when exists (select 1 from roles) or exists (select 1 from shop) then 'TRADE'
      else 'TEAM'
    end
  );
$$;
revoke all on function public.auth_email_context(uuid) from public, anon, authenticated, service_role;
grant execute on function public.auth_email_context(uuid) to service_role;
