-- Addendum A1 §4.1 — issue, edit or deactivate an agent code.
-- ZSM: any agent in the tenant. TM: agents in their own territory. Agents
-- never issue their own codes, because codes carry discounts. A code's
-- tenant and agent never change; to move one, deactivate it and issue another.
create or replace function public.upsert_agent_code(
  p_idempotency_key  uuid,
  p_code             text,
  p_agent_id         uuid,
  p_terminal_id      uuid,
  p_discount_type    text,
  p_discount_value   numeric,
  p_max_redemptions  integer,
  p_expires_at       timestamptz,
  p_is_active        boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_agent  public.tenant_users;
  v_before public.agent_codes;
  v_after  public.agent_codes;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_agent_code',
    jsonb_build_object('code', v_code, 'agent_id', p_agent_id, 'terminal_id', p_terminal_id,
                       'discount_type', p_discount_type, 'discount_value', p_discount_value,
                       'max_redemptions', p_max_redemptions, 'expires_at', p_expires_at,
                       'is_active', p_is_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_code !~ '^[A-Z0-9][A-Z0-9-]{3,31}$' then
    raise exception 'a code is 4 to 32 letters, digits or dashes' using errcode = 'P0001';
  end if;

  select * into v_agent from public.tenant_users
   where tenant_id = v_me.tenant_id and profile_id = p_agent_id
   order by (status = 'ACTIVE') desc
   limit 1;
  if not found then
    raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_agent.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM issues codes for agents in their own territory only' using errcode = '42501';
  end if;
  if p_terminal_id is not null and not exists (
    select 1 from public.fintech_terminals ft
     where ft.tenant_id = v_me.tenant_id and ft.id = p_terminal_id and ft.agent_id = p_agent_id
  ) then
    raise exception 'the terminal must belong to the agent' using errcode = 'P0001';
  end if;

  if (p_discount_type is null) <> (p_discount_value is null) then
    raise exception 'a discount needs both a type and a value' using errcode = 'P0001';
  end if;
  if p_discount_type is not null and p_discount_type not in ('PERCENT', 'FIXED') then
    raise exception 'discount type must be PERCENT or FIXED' using errcode = 'P0001';
  end if;
  if p_discount_type = 'PERCENT' and not (p_discount_value > 0 and p_discount_value <= 100) then
    raise exception 'a percentage discount is more than 0 and at most 100' using errcode = 'P0001';
  end if;
  if p_discount_type = 'FIXED' and not (p_discount_value > 0) then
    raise exception 'a fixed discount is more than 0' using errcode = 'P0001';
  end if;
  if p_max_redemptions is not null and p_max_redemptions < 1 then
    raise exception 'max_redemptions is at least 1' using errcode = 'P0001';
  end if;

  select * into v_before from public.agent_codes where code = v_code for update;
  if found then
    if v_before.tenant_id <> v_me.tenant_id then
      raise exception 'that code is already taken' using errcode = 'P0001';
    end if;
    if v_before.agent_id <> p_agent_id then
      raise exception 'a code''s agent never changes; deactivate it and issue a new code' using errcode = 'P0001';
    end if;
    if coalesce(p_is_active, v_before.is_active) and v_agent.status <> 'ACTIVE' then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    update public.agent_codes
       set terminal_id     = p_terminal_id,
           discount_type   = p_discount_type,
           discount_value  = p_discount_value,
           max_redemptions = p_max_redemptions,
           expires_at      = p_expires_at,
           is_active       = coalesce(p_is_active, v_before.is_active)
     where id = v_before.id
    returning * into v_after;
  else
    if v_agent.status <> 'ACTIVE' and coalesce(p_is_active, true) then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    insert into public.agent_codes (tenant_id, code, agent_id, terminal_id, discount_type, discount_value,
                                    max_redemptions, expires_at, is_active, created_by)
    values (v_me.tenant_id, v_code, p_agent_id, p_terminal_id, p_discount_type, p_discount_value,
            p_max_redemptions, p_expires_at, coalesce(p_is_active, true), v_me.profile_id)
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_agent_code', 'agent_codes', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_code_id', v_after.id, 'code', v_after.code));
end;
$$;

grant execute on function public.upsert_agent_code(uuid, text, uuid, uuid, text, numeric, integer, timestamptz, boolean)
  to authenticated;
