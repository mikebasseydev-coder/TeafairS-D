-- Auth audit H1 — an account's phone number is the one Supabase Auth holds,
-- never one the client wrote into user metadata.
--
-- Before: handle_new_user fell back to raw_user_meta_data ->> 'phone', which
-- the caller of /auth/v1/signup sets freely, and invite_tenant_user matched
-- the invitee by profiles.phone_number. Anyone could sign up with a stranger's
-- number, receive the invite meant for them, and lock the real person out
-- (phone_number is unique).
--
-- After: the profile takes auth.users.phone only (set by a phone sign-up or by
-- the Admin API), and an invite only reaches an account whose phone Supabase
-- Auth has confirmed. Self-serve sign-up is also switched off (config.toml;
-- the remote dashboard must match).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- GoTrue's own column only; user metadata is client-controlled
  v_phone text := nullif(btrim(coalesce(new.phone, '')), '');
begin
  if v_phone is null then
    raise exception 'a phone number is required to create a Teafair account'
      using errcode = 'P0001';
  end if;

  insert into public.profiles (id, full_name, phone_number, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    '+' || ltrim(v_phone, '+'),
    lower(nullif(new.email, ''))
  );
  return new;
end;
$$;

-- invite_tenant_user: unchanged except the invitee lookup, which now requires
-- a phone confirmed by Supabase Auth.
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

  select p.id into v_profile
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.phone_number = v_phone
    and u.phone_confirmed_at is not null;
  if v_profile is null then
    raise exception 'no Teafair account with a verified phone exists for %', v_phone using errcode = 'P0001';
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
