-- Spec D1 §4, §5.1 — web order routing and the coverage management RPCs.
-- Routing is internal: quote_web_order and place_web_order (a later task)
-- call it, no client role can.

create type public.web_route as (
  territory_id   uuid,
  warehouse_id   uuid,
  accountable_id uuid
);

-- Decision 1: codeless traffic belongs to the ACTIVE TEAFAIR tenant.
create function public.web_codeless_tenant()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.tenants where code = 'TEAFAIR' and status = 'ACTIVE';
  if v_id is null then
    raise exception 'This shop is not open yet' using errcode = 'P0001';
  end if;
  return v_id;
end;
$$;

-- §4 steps 1-3. Never raises: a field is null where its step found nothing.
-- p_code is null for a codeless order.
create function public.web_route_try(p_tenant_id uuid, p_code public.agent_codes, p_lga_id uuid)
returns public.web_route
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_coded      boolean := p_code.id is not null;
  v_state      text;
  v_holder     public.tenant_users;
  v_terminal_t uuid;
  v_territory  uuid;
  v_zone       uuid;
  v_warehouse  uuid;
  v_acct       uuid;
  v_r          public.web_route;
begin
  select state_code into v_state from public.ng_lgas where id = p_lga_id;

  -- 1. territory
  if v_coded then
    select * into v_holder from public.tenant_users
     where tenant_id = p_tenant_id and profile_id = p_code.agent_id and status = 'ACTIVE';
    if p_code.terminal_id is not null then
      select territory_id into v_terminal_t from public.fintech_terminals
       where tenant_id = p_tenant_id and id = p_code.terminal_id;
    end if;
    v_territory := coalesce(v_terminal_t, v_holder.territory_id);
  end if;
  if v_territory is null and v_state is not null then
    select territory_id into v_territory from public.territory_coverage
     where tenant_id = p_tenant_id and state_code = v_state and lga_id = p_lga_id;
    if v_territory is null then
      select territory_id into v_territory from public.territory_coverage
       where tenant_id = p_tenant_id and state_code = v_state and lga_id is null;
    end if;
  end if;

  -- 2. warehouse
  select coalesce(
           (select t.web_fulfilment_warehouse_id from public.territories t
             where t.tenant_id = p_tenant_id and t.id = v_territory),
           (select s.web_default_warehouse_id from public.tenant_settings s
             where s.tenant_id = p_tenant_id))
    into v_warehouse;

  -- 3. accountable person; every candidate must be an ACTIVE member
  if v_coded then
    if v_holder.role in ('DSA', 'DSM', 'ASM', 'TM', 'ZSM') then
      v_acct := v_holder.profile_id;
    else
      select tu.profile_id into v_acct
        from public.territories t
        join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id
                                   and tu.status = 'ACTIVE'
       where t.tenant_id = p_tenant_id and t.id = v_territory;
    end if;
  else
    select tu.profile_id into v_acct
      from public.territories t
      join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id
                                 and tu.status = 'ACTIVE'
     where t.tenant_id = p_tenant_id and t.id = v_territory;
    if v_acct is null then
      select zone_id into v_zone from public.territories
       where tenant_id = p_tenant_id and id = v_territory;
      select tu.profile_id into v_acct
        from public.zones z
        join public.tenant_users tu on tu.tenant_id = z.tenant_id and tu.profile_id = z.zsm_id
                                   and tu.status = 'ACTIVE'
       where z.tenant_id = p_tenant_id and z.id = v_zone;
    end if;
    if v_acct is null then
      select tu.profile_id into v_acct
        from public.tenant_settings s
        join public.tenant_users tu on tu.tenant_id = s.tenant_id and tu.profile_id = s.web_default_agent_id
                                   and tu.status = 'ACTIVE'
       where s.tenant_id = p_tenant_id;
    end if;
  end if;

  v_r.territory_id := v_territory;
  v_r.warehouse_id := v_warehouse;
  v_r.accountable_id := v_acct;
  return v_r;
end;
$$;

-- The refusing wrapper: quote and place both call this.
create function public.web_route_order(p_tenant_id uuid, p_code public.agent_codes, p_lga_id uuid)
returns public.web_route
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.web_route;
begin
  if p_lga_id is null or not exists (select 1 from public.ng_lgas where id = p_lga_id) then
    raise exception 'choose a delivery area from the list' using errcode = 'P0001';
  end if;
  v_r := public.web_route_try(p_tenant_id, p_code, p_lga_id);
  if p_code.id is not null and v_r.accountable_id is null then
    raise exception 'This link is not active yet' using errcode = 'P0001';
  end if;
  if v_r.territory_id is null or v_r.warehouse_id is null or v_r.accountable_id is null then
    raise exception 'We don''t deliver to this area yet.' using errcode = 'P0001';
  end if;
  return v_r;
end;
$$;

-- ── §5.1 management RPCs (ZSM) ──────────────────────────────────────────
create function public.set_territory_coverage(
  p_idempotency_key uuid,
  p_state_code      text,
  p_lga_id          uuid,
  p_territory_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.territory_coverage;
  v_after  public.territory_coverage;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_territory_coverage',
    jsonb_build_object('state_code', p_state_code, 'lga_id', p_lga_id, 'territory_id', p_territory_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_state_code is null or not exists (select 1 from public.ng_states where code = p_state_code) then
    raise exception 'choose a state from the list' using errcode = 'P0001';
  end if;
  if p_lga_id is not null and not exists (
       select 1 from public.ng_lgas where id = p_lga_id and state_code = p_state_code) then
    raise exception 'the LGA is not in that state' using errcode = 'P0001';
  end if;

  select * into v_before from public.territory_coverage
   where tenant_id = v_me.tenant_id and state_code = p_state_code and lga_id is not distinct from p_lga_id
     for update;

  if p_territory_id is null then
    delete from public.territory_coverage where id = v_before.id;
    perform public.write_audit(v_me.tenant_id, 'set_territory_coverage', 'territory_coverage',
      coalesce(v_before.id::text, p_state_code), to_jsonb(v_before), null, p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('coverage_id', null));
  end if;

  if not exists (select 1 from public.territories where tenant_id = v_me.tenant_id and id = p_territory_id) then
    raise exception 'the territory does not belong to this tenant' using errcode = 'P0001';
  end if;

  insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values (v_me.tenant_id, p_state_code, p_lga_id, p_territory_id)
  on conflict (tenant_id, state_code, lga_id)
  do update set territory_id = excluded.territory_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_territory_coverage', 'territory_coverage',
    v_after.id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('coverage_id', v_after.id));
end;
$$;

create function public.set_territory_web_warehouse(
  p_idempotency_key uuid,
  p_territory_id    uuid,
  p_warehouse_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_territory_web_warehouse',
    jsonb_build_object('territory_id', p_territory_id, 'warehouse_id', p_warehouse_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select web_fulfilment_warehouse_id into v_before from public.territories
   where tenant_id = v_me.tenant_id and id = p_territory_id for update;
  if not found then
    raise exception 'the territory does not belong to this tenant' using errcode = 'P0001';
  end if;
  if p_warehouse_id is not null and not exists (
       select 1 from public.warehouses where tenant_id = v_me.tenant_id and id = p_warehouse_id) then
    raise exception 'the warehouse does not belong to this tenant' using errcode = 'P0001';
  end if;

  update public.territories set web_fulfilment_warehouse_id = p_warehouse_id
   where tenant_id = v_me.tenant_id and id = p_territory_id;

  perform public.write_audit(v_me.tenant_id, 'set_territory_web_warehouse', 'territories', p_territory_id::text,
    jsonb_build_object('warehouse_id', v_before), jsonb_build_object('warehouse_id', p_warehouse_id),
    p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('territory_id', p_territory_id, 'warehouse_id', p_warehouse_id));
end;
$$;

create function public.set_web_defaults(
  p_idempotency_key uuid,
  p_warehouse_id    uuid,
  p_agent_id        uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
        where tenant_id = v_me.tenant_id and profile_id = p_agent_id and status = 'ACTIVE') then
    raise exception 'the default agent must be an active member of this tenant' using errcode = 'P0001';
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
$$;

-- ── grants ──────────────────────────────────────────────────────────────
revoke execute on function public.web_codeless_tenant() from public, anon, authenticated, service_role;
revoke execute on function public.web_route_try(uuid, public.agent_codes, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.web_route_order(uuid, public.agent_codes, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.set_territory_coverage(uuid, text, uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.set_territory_web_warehouse(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.set_web_defaults(uuid, uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.set_territory_coverage(uuid, text, uuid, uuid) to authenticated;
grant execute on function public.set_territory_web_warehouse(uuid, uuid, uuid) to authenticated;
grant execute on function public.set_web_defaults(uuid, uuid, uuid) to authenticated;
