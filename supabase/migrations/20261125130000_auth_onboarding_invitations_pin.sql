-- Onboarding (pre-Spec B, 2026-11-25): accepting or declining an invitation,
-- and setting or changing the membership PIN.
--
-- Every appointment and invite creates an INVITED tenant_users row, and the
-- claims hook (access_token_claims) counts ACTIVE memberships only, so until
-- now an invitee could sign in (auth_email_context allows INVITED) but never
-- receive a tenant. Nothing wrote tenant_users.pin_hash either, so verify_pin
-- could never pass for a real user.
--
--   1. list_my_invitations(): the caller's INVITED memberships in ACTIVE
--      tenants, with the tenant's name and code (an invitee cannot read
--      tenants under RLS) and the place names of the post. No person is named.
--   2. accept_tenant_invitation(key, tenant_user_id): INVITED -> ACTIVE. If
--      the caller has no ACTIVE primary membership, this one becomes primary,
--      so the next token carries it as active_tenant_id. Replies
--      refresh_session, as set_active_tenant does.
--   3. decline_tenant_invitation(key, tenant_user_id): INVITED -> DISABLED.
--      The status enum has no DECLINED value; (tenant_id, profile_id) is
--      unique, so a re-invite of a decliner needs a later re-enable path.
--   4. get_my_pin_status(): whether the active membership has a PIN, and its
--      lock. pin_hash itself stays ungranted.
--   5. set_tenant_pin(key, new_pin): the first PIN of the active membership.
--   6. change_tenant_pin(key, current_pin, new_pin): rotates it. A wrong or
--      locked current PIN is returned as data (A5 R5), so the failure counter
--      commits; it shares verify_pin's 5 attempts and 15-minute lock.
--
-- The membership is named by tenant_users.id, never by a client tenant id
-- (Spec A §2 item 4; set_active_tenant is the only exception). PINs are four
-- digits and bcrypt-hashed, exactly what verify_pin reads. A PIN never enters
-- idempotency_logs (the request omits it, as A5's delivery PIN: a reused key
-- replays the first answer), an error, a notice or an audit row.

-- ── the PIN policy ──────────────────────────────────────────────────────
-- Four digits, not one digit repeated, not a run up or down (0123, 9876).
create function public.pin_policy_refusal(p_pin text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  d int[];
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    return 'a PIN is exactly four digits';
  end if;
  d := array[substr(p_pin, 1, 1)::int, substr(p_pin, 2, 1)::int,
             substr(p_pin, 3, 1)::int, substr(p_pin, 4, 1)::int];
  if d[1] = d[2] and d[2] = d[3] and d[3] = d[4] then
    return 'choose a PIN that is not one digit repeated';
  end if;
  if (d[2] = d[1] + 1 and d[3] = d[2] + 1 and d[4] = d[3] + 1)
     or (d[2] = d[1] - 1 and d[3] = d[2] - 1 and d[4] = d[3] - 1) then
    return 'choose a PIN that is not a run of digits';
  end if;
  return null;
end;
$$;
revoke all on function public.pin_policy_refusal(text) from public, anon, authenticated, service_role;

-- ── 1. list_my_invitations ──────────────────────────────────────────────
create function public.list_my_invitations()
returns table (
  tenant_user_id uuid,
  tenant_id      uuid,
  tenant_name    text,
  tenant_code    text,
  role           public.tenant_role_enum,
  zone_name      text,
  territory_name text,
  area_name      text,
  invited_at     timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.id, t.id, t.name, t.code, tu.role,
         z.zone_name, tr.territory_name, a.area_name, tu.created_at
  from public.tenant_users tu
  join public.tenants t on t.id = tu.tenant_id and t.status = 'ACTIVE'
  left join public.zones z on z.tenant_id = tu.tenant_id and z.id = tu.zone_id
  left join public.territories tr on tr.tenant_id = tu.tenant_id and tr.id = tu.territory_id
  left join public.areas a on a.tenant_id = tu.tenant_id and a.id = tu.area_id
  where tu.profile_id = (select auth.uid())
    and tu.status = 'INVITED'
  order by tu.created_at, tu.id;
$$;
revoke all on function public.list_my_invitations() from public, anon;
grant execute on function public.list_my_invitations() to authenticated;

-- ── 2 and 3. accept and decline ─────────────────────────────────────────
-- The caller's own INVITED membership, locked. Raises P0001 "invitation not
-- found" for anything else, so another person's membership id reveals nothing.
create function public.lock_my_invitation(p_tenant_user_id uuid)
returns public.tenant_users
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_row public.tenant_users;
begin
  select * into v_row from public.tenant_users tu
   where tu.id = p_tenant_user_id and tu.profile_id = (select auth.uid())
   for update;
  if not found or v_row.status <> 'INVITED' then
    raise exception 'invitation not found' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.tenants t where t.id = v_row.tenant_id and t.status = 'ACTIVE') then
    raise exception 'this team is not active' using errcode = 'P0001';
  end if;
  return v_row;
end;
$$;
revoke all on function public.lock_my_invitation(uuid) from public, anon, authenticated, service_role;

create function public.accept_tenant_invitation(p_idempotency_key uuid, p_tenant_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public.assert_authenticated();
  v_prior   jsonb;
  v_row     public.tenant_users;
  v_primary boolean;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'accept_tenant_invitation',
                                      jsonb_build_object('tenant_user_id', p_tenant_user_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_row := public.lock_my_invitation(p_tenant_user_id);

  -- primary only when no ACTIVE membership already is; a primary flag left on
  -- a non-ACTIVE row is cleared first (one primary per person, unique index)
  v_primary := not exists (select 1 from public.tenant_users tu
                            where tu.profile_id = v_uid and tu.status = 'ACTIVE' and tu.is_primary);
  if v_primary then
    update public.tenant_users set is_primary = false
     where profile_id = v_uid and is_primary and status <> 'ACTIVE';
  end if;

  update public.tenant_users
     set status = 'ACTIVE', is_primary = v_primary
   where id = v_row.id;

  perform public.write_audit(v_row.tenant_id, 'accept_tenant_invitation', 'tenant_users', v_row.id::text,
                             jsonb_build_object('status', 'INVITED'),
                             jsonb_build_object('status', 'ACTIVE', 'role', v_row.role, 'is_primary', v_primary),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'tenant_user_id', v_row.id, 'tenant_id', v_row.tenant_id, 'role', v_row.role,
    'status', 'ACTIVE', 'is_primary', v_primary, 'refresh_session', true));
end;
$$;
revoke all on function public.accept_tenant_invitation(uuid, uuid) from public, anon;
grant execute on function public.accept_tenant_invitation(uuid, uuid) to authenticated;

create function public.decline_tenant_invitation(p_idempotency_key uuid, p_tenant_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_authenticated();
  v_prior jsonb;
  v_row   public.tenant_users;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'decline_tenant_invitation',
                                      jsonb_build_object('tenant_user_id', p_tenant_user_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_row := public.lock_my_invitation(p_tenant_user_id);

  update public.tenant_users set status = 'DISABLED', is_primary = false where id = v_row.id;

  perform public.write_audit(v_row.tenant_id, 'decline_tenant_invitation', 'tenant_users', v_row.id::text,
                             jsonb_build_object('status', 'INVITED'),
                             jsonb_build_object('status', 'DISABLED', 'role', v_row.role),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'tenant_user_id', v_row.id, 'tenant_id', v_row.tenant_id, 'status', 'DISABLED'));
end;
$$;
revoke all on function public.decline_tenant_invitation(uuid, uuid) from public, anon;
grant execute on function public.decline_tenant_invitation(uuid, uuid) to authenticated;

-- ── 4. get_my_pin_status ────────────────────────────────────────────────
create function public.get_my_pin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me public.tenant_users := public.assert_tenant_role(null);
begin
  return jsonb_build_object(
    'tenant_user_id', v_me.id,
    'pin_set',        v_me.pin_hash is not null,
    'locked_until',   case when v_me.pin_locked_until > now() then v_me.pin_locked_until end);
end;
$$;
revoke all on function public.get_my_pin_status() from public, anon;
grant execute on function public.get_my_pin_status() to authenticated;

-- ── 5. set_tenant_pin ───────────────────────────────────────────────────
create function public.set_tenant_pin(p_idempotency_key uuid, p_new_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(null);
  v_prior   jsonb;
  v_row     public.tenant_users;
  v_refusal text;
begin
  -- the PIN is not part of the request: a reused key replays the first answer
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_tenant_pin',
                                      jsonb_build_object('tenant_user_id', v_me.id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_row from public.tenant_users where id = v_me.id for update;
  if v_row.pin_hash is not null then
    raise exception 'a PIN is already set; change it with your current PIN' using errcode = 'P0001';
  end if;
  v_refusal := public.pin_policy_refusal(p_new_pin);
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;

  update public.tenant_users
     set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
         pin_failed_attempts = 0, pin_locked_until = null, pin_pass_at = null
   where id = v_row.id;

  perform public.write_audit(v_row.tenant_id, 'set_tenant_pin', 'tenant_users', v_row.id::text,
                             jsonb_build_object('pin_set', false), jsonb_build_object('pin_set', true),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_user_id', v_row.id, 'pin_set', true));
end;
$$;
revoke all on function public.set_tenant_pin(uuid, text) from public, anon;
grant execute on function public.set_tenant_pin(uuid, text) to authenticated;

-- ── 6. change_tenant_pin ────────────────────────────────────────────────
-- Shares verify_pin's counter and lock: 5 wrong current PINs lock the
-- membership for 15 minutes (PIN_LOCKED audit, as verify_pin writes). A wrong
-- or locked current PIN is a reply, not a raise, so the counter commits;
-- use a fresh key for every attempt.
create function public.change_tenant_pin(p_idempotency_key uuid, p_current_pin text, p_new_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer  := 5;
  c_lockout      constant interval := interval '15 minutes';
  v_me      public.tenant_users := public.assert_tenant_role(null);
  v_prior   jsonb;
  v_row     public.tenant_users;
  v_refusal text;
  v_failed  integer;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'change_tenant_pin',
                                      jsonb_build_object('tenant_user_id', v_me.id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_row from public.tenant_users where id = v_me.id for update;
  if v_row.pin_hash is null then
    raise exception 'no PIN has been set for this membership' using errcode = 'P0001';
  end if;
  -- the new PIN's shape is checked before the current PIN, so a bad new PIN
  -- costs no attempt
  v_refusal := public.pin_policy_refusal(p_new_pin);
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;

  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'changed', false, 'attempts_remaining', 0, 'locked_until', v_row.pin_locked_until));
  end if;

  if p_current_pin is null or p_current_pin !~ '^[0-9]{4}$'
     or extensions.crypt(p_current_pin, v_row.pin_hash) <> v_row.pin_hash then
    v_failed := v_row.pin_failed_attempts + 1;
    if v_failed >= c_max_attempts then
      update public.tenant_users
         set pin_failed_attempts = 0, pin_locked_until = now() + c_lockout
       where id = v_row.id;
      perform public.write_audit(v_row.tenant_id, 'PIN_LOCKED', 'tenant_users', v_row.id::text,
                                 null, jsonb_build_object('locked_until', now() + c_lockout), p_idempotency_key);
      return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
        'changed', false, 'attempts_remaining', 0, 'locked_until', now() + c_lockout));
    end if;
    update public.tenant_users set pin_failed_attempts = v_failed where id = v_row.id;
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'changed', false, 'attempts_remaining', c_max_attempts - v_failed, 'locked_until', null));
  end if;

  if p_new_pin = p_current_pin then
    raise exception 'choose a PIN different from your current one' using errcode = 'P0001';
  end if;

  update public.tenant_users
     set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf', 10)),
         pin_failed_attempts = 0, pin_locked_until = null, pin_pass_at = null
   where id = v_row.id;

  perform public.write_audit(v_row.tenant_id, 'change_tenant_pin', 'tenant_users', v_row.id::text,
                             null, jsonb_build_object('pin_changed', true), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'changed', true, 'attempts_remaining', c_max_attempts, 'locked_until', null));
end;
$$;
revoke all on function public.change_tenant_pin(uuid, text, text) from public, anon;
grant execute on function public.change_tenant_pin(uuid, text, text) to authenticated;
