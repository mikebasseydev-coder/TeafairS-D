-- Spec A §5.5 / §7.4 — PIN verification for PIN-gated gateways (§3.1 step 4).
--
-- The bcrypt comparison runs here, through pgcrypto: pin_hash is not readable
-- by `authenticated` (grants migration) and user-facing gateways never hold
-- the service-role key (§3.2), so the gateway cannot fetch the hash itself.
-- Doing it here also makes the attempt counter atomic.
--
-- The verdict is RETURNED, never raised: a raise would roll back the failure
-- counter and make the lockout useless. It is also deliberately not
-- idempotent — a replayed key must never re-grant a pass — so it returns a
-- composite, not the jsonb of a queued write RPC.
--
-- A pass is recorded in pin_pass_at and spent by consume_pin_pass(): a
-- PIN-gated RPC called straight through PostgREST, skipping the gateway,
-- still finds no pass and refuses.
alter table public.tenant_users add column pin_pass_at timestamptz;

create type public.pin_check as (ok boolean, attempts_left integer, locked_until timestamptz);

create or replace function public.verify_pin(p_pin text)
returns public.pin_check
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer  := 5;
  c_lockout      constant interval := interval '15 minutes';
  v_me  public.tenant_users := public.assert_tenant_role(null);
  v_row public.tenant_users;
begin
  select * into v_row from public.tenant_users where id = v_me.id for update;

  if v_row.pin_hash is null then
    raise exception 'no PIN has been set for this membership' using errcode = 'P0001';
  end if;
  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    return (false, 0, v_row.pin_locked_until)::public.pin_check;
  end if;

  if p_pin ~ '^[0-9]{4}$' and extensions.crypt(p_pin, v_row.pin_hash) = v_row.pin_hash then
    update public.tenant_users
       set pin_failed_attempts = 0, pin_locked_until = null, pin_pass_at = now()
     where id = v_row.id;
    return (true, c_max_attempts, null)::public.pin_check;
  end if;

  v_row.pin_failed_attempts := v_row.pin_failed_attempts + 1;
  if v_row.pin_failed_attempts >= c_max_attempts then
    update public.tenant_users
       set pin_failed_attempts = 0, pin_locked_until = now() + c_lockout
     where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'PIN_LOCKED', 'tenant_users', v_row.id::text,
                               null, jsonb_build_object('locked_until', now() + c_lockout), null);
    return (false, 0, now() + c_lockout)::public.pin_check;
  end if;

  update public.tenant_users set pin_failed_attempts = v_row.pin_failed_attempts where id = v_row.id;
  return (false, c_max_attempts - v_row.pin_failed_attempts, null)::public.pin_check;
end;
$$;

grant execute on function public.verify_pin(text) to authenticated;

-- Spends the caller's PIN pass: under 60 s old, once. PIN-gated RPCs (Spec C/D)
-- call it right after idempotency_begin, so a replayed key returns its stored
-- result without needing a fresh PIN. Internal: no EXECUTE for the API.
create or replace function public.consume_pin_pass()
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  c_pass_ttl constant interval := interval '60 seconds';
  v_me public.tenant_users := public.assert_tenant_role(null);
begin
  update public.tenant_users
     set pin_pass_at = null
   where id = v_me.id
     and pin_pass_at > now() - c_pass_ttl;
  if not found then
    raise exception 'a fresh PIN check is required' using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public.consume_pin_pass() from public, anon, authenticated;
