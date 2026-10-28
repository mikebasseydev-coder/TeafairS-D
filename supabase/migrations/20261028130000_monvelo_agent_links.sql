-- Addendum A6 §15.2 (Monvelo Step 1b, Task 1) — agent-tenant links, platform
-- terminals and Paystack subaccounts. Additive only: nothing legacy is touched.
--
--   monvelo_fintech_agents.paystack_subaccount_code   set by a MONVELO_OPERATOR,
--                                                     never granted to the API
--   monvelo_agent_tenants    the tenant-scoped link of an agent; a tenant ZSM
--                            proposes it (PENDING), a MONVELO_OPERATOR approves
--   monvelo_agent_terminals  platform-level POS terminals, with the A1 venue
--
-- User decision (Step 1b, supersedes the planner's "ZSM alone" default): every
-- link needs operator approval. A link naming a tenant does not need Monvelo
-- financing to be enabled: web commission is independent of financing.

-- ── subaccount on the agent ─────────────────────────────────────────────
alter table public.monvelo_fintech_agents
  add column paystack_subaccount_code text check (paystack_subaccount_code ~ '^ACCT_[A-Za-z0-9]+$'),
  add column has_paystack_subaccount boolean generated always as (paystack_subaccount_code is not null) stored;
-- no grant on the code itself; tenants see only the flag
grant select (has_paystack_subaccount) on public.monvelo_fintech_agents to authenticated;

-- the audit image also drops the subaccount code
create or replace function public.monvelo_agent_audit(p_agent public.monvelo_fintech_agents)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select (to_jsonb(p_agent)
           - 'settlement_account_number' - 'settlement_bank_code' - 'pending_settlement'
           - 'paystack_payer_ref' - 'contact_phone' - 'location' - 'paystack_subaccount_code')
         || jsonb_build_object('has_pending_settlement', p_agent.pending_settlement is not null,
                               'pending_settlement_last4', p_agent.pending_settlement ->> 'last4');
$$;
revoke all on function public.monvelo_agent_audit(public.monvelo_fintech_agents) from public, anon, authenticated;

-- ── tables ──────────────────────────────────────────────────────────────
create table public.monvelo_agent_tenants (
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  agent_id      uuid not null references public.monvelo_fintech_agents (id) on delete restrict,
  territory_id  uuid not null,
  status        text not null default 'PENDING' check (status in ('PENDING', 'ACTIVE', 'SUSPENDED')),
  linked_by     uuid not null references public.profiles (id) on delete restrict,
  approved_by   uuid references public.profiles (id) on delete restrict,
  approved_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  primary key (tenant_id, agent_id),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict,
  constraint monvelo_agent_tenants_active_approved
    check (status <> 'ACTIVE' or (approved_by is not null and approved_at is not null))
);
alter table public.monvelo_agent_tenants enable row level security;
create index idx_monvelo_agent_tenants_agent on public.monvelo_agent_tenants (agent_id);
create index idx_monvelo_agent_tenants_territory on public.monvelo_agent_tenants (tenant_id, territory_id);
create index idx_monvelo_agent_tenants_linked_by on public.monvelo_agent_tenants (linked_by);
create index idx_monvelo_agent_tenants_approved_by on public.monvelo_agent_tenants (approved_by);
create trigger monvelo_agent_tenants_set_updated_at before update on public.monvelo_agent_tenants
  for each row execute function public.set_updated_at();

create table public.monvelo_agent_terminals (
  id                   uuid primary key default gen_random_uuid(),
  agent_id             uuid not null references public.monvelo_fintech_agents (id) on delete restrict,
  network_terminal_id  text not null check (network_terminal_id = upper(btrim(network_terminal_id)) and length(network_terminal_id) > 0),
  operator_profile_id  uuid,
  venue_channel        public.venue_channel_enum,
  venue_name           text check (venue_name is null or length(btrim(venue_name)) > 0),
  address_text         text check (address_text is null or length(btrim(address_text)) > 0),
  state                text check (state is null or length(btrim(state)) > 0),
  lga                  text,
  location             extensions.geometry(Point, 4326),
  operating_hours      jsonb check (operating_hours is null or jsonb_typeof(operating_hours) = 'object'),
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (agent_id, id),
  unique (agent_id, network_terminal_id),
  foreign key (agent_id, operator_profile_id) references public.monvelo_fintech_members (agent_id, profile_id) on delete restrict,
  constraint monvelo_agent_terminals_venue_complete
    check (num_nulls(venue_channel, venue_name, address_text, state, location) in (0, 5))
);
alter table public.monvelo_agent_terminals enable row level security;
create index idx_monvelo_agent_terminals_operator on public.monvelo_agent_terminals (operator_profile_id);
create index idx_monvelo_agent_terminals_location on public.monvelo_agent_terminals using gist (location);
create trigger monvelo_agent_terminals_set_updated_at before update on public.monvelo_agent_terminals
  for each row execute function public.set_updated_at();

revoke all on public.monvelo_agent_tenants from anon, authenticated;
revoke all on public.monvelo_agent_terminals from anon, authenticated;
grant select on public.monvelo_agent_tenants to authenticated;
grant select on public.monvelo_agent_terminals to authenticated;

-- ── helpers ─────────────────────────────────────────────────────────────
-- Agents with an ACTIVE or SUSPENDED link to a tenant the caller belongs to. A
-- PENDING proposal reveals nothing (it feeds the agent and terminal policies).
create or replace function public.my_linked_monvelo_agent_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select l.agent_id from public.monvelo_agent_tenants l
  where l.status in ('ACTIVE', 'SUSPENDED') and l.tenant_id in (select public.my_tenant_ids());
$$;
grant execute on function public.my_linked_monvelo_agent_ids() to authenticated;

-- The caller, if an ACTIVE member of an ACTIVE agent. For member-facing RPCs.
create or replace function public.assert_monvelo_member(p_agent_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null or not exists (
       select 1
       from public.monvelo_fintech_members m
       join public.monvelo_fintech_agents a on a.id = m.agent_id
       where m.agent_id = p_agent_id and m.profile_id = v_uid
         and m.status = 'ACTIVE' and a.status = 'ACTIVE') then
    raise exception 'not a member of this Monvelo agent' using errcode = '42501';
  end if;
  return v_uid;
end;
$$;
revoke all on function public.assert_monvelo_member(uuid) from public, anon, authenticated;

-- The link is ACTIVE (approved, not suspended) and so is the agent.
create or replace function public.monvelo_agent_link_active(p_tenant_id uuid, p_agent_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.monvelo_agent_tenants l
    join public.monvelo_fintech_agents a on a.id = l.agent_id
    where l.tenant_id = p_tenant_id and l.agent_id = p_agent_id
      and l.status = 'ACTIVE' and a.status = 'ACTIVE');
$$;
revoke all on function public.monvelo_agent_link_active(uuid, uuid) from public, anon, authenticated;

-- ── policies ────────────────────────────────────────────────────────────
drop policy monvelo_fintech_agents_select on public.monvelo_fintech_agents;
create policy monvelo_fintech_agents_select on public.monvelo_fintech_agents
  for select to authenticated
  using (
    (select public.is_monvelo_staff())
    or id in (select public.my_monvelo_agent_ids())
    or id in (select public.my_linked_monvelo_agent_ids())
    or (status = 'ACTIVE' and (select public.is_monvelo_field_agent()))
  );

create policy monvelo_agent_tenants_select on public.monvelo_agent_tenants
  for select to authenticated
  using (
    tenant_id in (select public.my_tenant_ids())
    or (select public.is_monvelo_staff())
    or agent_id in (select public.my_monvelo_agent_ids())
  );

create policy monvelo_agent_terminals_select on public.monvelo_agent_terminals
  for select to authenticated
  using (
    (select public.is_monvelo_staff())
    or agent_id in (select public.my_monvelo_agent_ids())
    or agent_id in (select public.my_linked_monvelo_agent_ids())
  );

-- ── set_monvelo_agent_subaccount (MONVELO_OPERATOR) ─────────────────────
create or replace function public.set_monvelo_agent_subaccount(
  p_idempotency_key uuid,
  p_agent_id        uuid,
  p_subaccount_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_code   text := btrim(p_subaccount_code);
  v_before public.monvelo_fintech_agents;
  v_after  public.monvelo_fintech_agents;
begin
  -- the request carries a hash, never the code
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_agent_subaccount',
    jsonb_build_object('agent_id', p_agent_id, 'code_md5', md5(coalesce(v_code, ''))));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_code is not null and v_code !~ '^ACCT_[A-Za-z0-9]+$' then
    raise exception 'a Paystack subaccount code looks like ACCT_…' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_fintech_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  update public.monvelo_fintech_agents set paystack_subaccount_code = v_code where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'set_monvelo_agent_subaccount', 'monvelo_fintech_agents', p_agent_id::text,
                             jsonb_build_object('has_paystack_subaccount', v_before.has_paystack_subaccount),
                             jsonb_build_object('has_paystack_subaccount', v_after.has_paystack_subaccount, 'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', p_agent_id, 'has_paystack_subaccount', v_after.has_paystack_subaccount));
end;
$$;

-- ── upsert_monvelo_terminal (MONVELO_OPERATOR) ──────────────────────────
create or replace function public.upsert_monvelo_terminal(
  p_idempotency_key     uuid,
  p_terminal_id         uuid,
  p_agent_id            uuid,
  p_network_terminal_id text,
  p_operator_profile_id uuid,
  p_is_active           boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_netid  text := upper(btrim(coalesce(p_network_terminal_id, '')));
  v_before public.monvelo_agent_terminals;
  v_after  public.monvelo_agent_terminals;
  v_cname  text;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_monvelo_terminal',
    jsonb_build_object('terminal_id', p_terminal_id, 'agent_id', p_agent_id, 'network_terminal_id', v_netid,
                       'operator_profile_id', p_operator_profile_id, 'is_active', p_is_active));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_netid = '' then
    raise exception 'the network terminal id is required' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_fintech_agents where id = p_agent_id) then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if p_operator_profile_id is not null and not exists (
       select 1 from public.monvelo_fintech_members m
       where m.agent_id = p_agent_id and m.profile_id = p_operator_profile_id and m.status = 'ACTIVE') then
    raise exception 'the operator must be an active member of the agent' using errcode = 'P0001';
  end if;

  begin
    if p_terminal_id is null then
      insert into public.monvelo_agent_terminals (agent_id, network_terminal_id, operator_profile_id, is_active)
      values (p_agent_id, v_netid, p_operator_profile_id, coalesce(p_is_active, true))
      returning * into v_after;
    else
      select * into v_before from public.monvelo_agent_terminals where id = p_terminal_id for update;
      if found then
        if v_before.agent_id is distinct from p_agent_id then
          raise exception 'a terminal''s agent never changes' using errcode = 'P0001';
        end if;
        update public.monvelo_agent_terminals
           set network_terminal_id = v_netid,
               operator_profile_id = p_operator_profile_id,
               is_active           = coalesce(p_is_active, is_active)
         where id = p_terminal_id
        returning * into v_after;
      else
        insert into public.monvelo_agent_terminals (id, agent_id, network_terminal_id, operator_profile_id, is_active)
        values (p_terminal_id, p_agent_id, v_netid, p_operator_profile_id, coalesce(p_is_active, true))
        returning * into v_after;
      end if;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_cname = constraint_name;
    if v_cname = 'monvelo_agent_terminals_agent_id_network_terminal_id_key' then
      raise exception 'this terminal is already registered for the agent' using errcode = '23505';
    end if;
    raise;
  end;

  perform public.write_audit(null, 'upsert_monvelo_terminal', 'monvelo_agent_terminals', v_after.id::text,
                             case when v_before.id is null then null else to_jsonb(v_before) - 'location' end,
                             (to_jsonb(v_after) - 'location') || jsonb_build_object('by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('terminal_id', v_after.id));
end;
$$;

-- ── link_monvelo_agent (tenant ZSM proposes; the operator approves) ─────
create or replace function public.link_monvelo_agent(
  p_idempotency_key uuid,
  p_pos_network     public.pos_network_enum,
  p_network_agent_id text,
  p_territory_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_netid    text := upper(btrim(coalesce(p_network_agent_id, '')));
  v_agent    public.monvelo_fintech_agents;
  v_boundary extensions.geometry;
  v_before   public.monvelo_agent_tenants;
  v_after    public.monvelo_agent_tenants;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'link_monvelo_agent',
    jsonb_build_object('pos_network', p_pos_network, 'network_agent_id', v_netid, 'territory_id', p_territory_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_agent from public.monvelo_fintech_agents a
   where a.pos_network = p_pos_network and a.network_agent_id = v_netid and a.status = 'ACTIVE';
  if not found then
    raise exception 'no active Monvelo agent has that network id' using errcode = 'P0001';
  end if;

  select t.boundary into v_boundary from public.territories t
   where t.id = p_territory_id and t.tenant_id = v_me.tenant_id;
  if not found then
    raise exception 'that territory does not belong to your tenant' using errcode = '42501';
  end if;
  if v_boundary is not null and exists (
       select 1 from public.monvelo_agent_terminals mt
       where mt.agent_id = v_agent.id and mt.is_active and mt.location is not null
         and not extensions.st_covers(v_boundary, mt.location)) then
    raise exception 'the agent''s venue lies outside that territory' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_agent_tenants
   where tenant_id = v_me.tenant_id and agent_id = v_agent.id for update;
  if not found then
    -- two first links can race: the loser falls through to the update path
    begin
      insert into public.monvelo_agent_tenants (tenant_id, agent_id, territory_id, status, linked_by)
      values (v_me.tenant_id, v_agent.id, p_territory_id, 'PENDING', v_me.profile_id)
      returning * into v_after;
    exception when unique_violation then
      select * into v_before from public.monvelo_agent_tenants
       where tenant_id = v_me.tenant_id and agent_id = v_agent.id for update;
    end;
  end if;
  if v_after.agent_id is null then
    if v_before.status = 'ACTIVE' and v_before.territory_id = p_territory_id then
      v_after := v_before;   -- nothing to approve again
    else
      update public.monvelo_agent_tenants
         set territory_id = p_territory_id, status = 'PENDING', linked_by = v_me.profile_id,
             approved_by = null, approved_at = null
       where tenant_id = v_me.tenant_id and agent_id = v_agent.id
      returning * into v_after;
    end if;
  end if;

  perform public.write_audit(v_me.tenant_id, 'link_monvelo_agent', 'monvelo_agent_tenants', v_agent.id::text,
                             case when v_before.agent_id is null then null else to_jsonb(v_before) end,
                             to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', v_agent.id, 'status', v_after.status));
end;
$$;

-- ── approve_monvelo_agent_link (MONVELO_OPERATOR) ───────────────────────
-- A platform role names the tenant: the same exception as record_monvelo_fee_terms.
-- The operator approves the territory they reviewed; a changed link needs a new look.
create or replace function public.approve_monvelo_agent_link(
  p_idempotency_key uuid,
  p_tenant_id       uuid,
  p_agent_id        uuid,
  p_territory_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior    jsonb;
  v_before   public.monvelo_agent_tenants;
  v_after    public.monvelo_agent_tenants;
  v_boundary extensions.geometry;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_agent_link',
    jsonb_build_object('tenant_id', p_tenant_id, 'agent_id', p_agent_id, 'territory_id', p_territory_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_agent_tenants
   where tenant_id = p_tenant_id and agent_id = p_agent_id for update;
  if not found then
    raise exception 'this agent is not linked to that tenant' using errcode = 'P0001';
  end if;
  if v_before.status <> 'PENDING' then
    raise exception 'this link is not waiting for approval' using errcode = 'P0001';
  end if;
  if v_before.territory_id is distinct from p_territory_id then
    raise exception 'the link''s territory changed; review it again' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_fintech_agents where id = p_agent_id and status = 'ACTIVE') then
    raise exception 'the agent must be active to approve its link' using errcode = 'P0001';
  end if;
  select t.boundary into v_boundary from public.territories t
   where t.id = v_before.territory_id and t.tenant_id = p_tenant_id;
  if v_boundary is not null and exists (
       select 1 from public.monvelo_agent_terminals mt
       where mt.agent_id = p_agent_id and mt.is_active and mt.location is not null
         and not extensions.st_covers(v_boundary, mt.location)) then
    raise exception 'the agent''s venue lies outside that territory' using errcode = 'P0001';
  end if;

  update public.monvelo_agent_tenants
     set status = 'ACTIVE', approved_by = v_uid, approved_at = now()
   where tenant_id = p_tenant_id and agent_id = p_agent_id
  returning * into v_after;

  perform public.write_audit(p_tenant_id, 'approve_monvelo_agent_link', 'monvelo_agent_tenants', p_agent_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_id', p_tenant_id, 'agent_id', p_agent_id, 'status', v_after.status));
end;
$$;

-- ── suspend_monvelo_agent_link (MONVELO_OPERATOR) ───────────────────────
-- Stops one tenant's link, from PENDING or ACTIVE. suspend_monvelo_agent stops
-- the agent for every tenant.
create or replace function public.suspend_monvelo_agent_link(
  p_idempotency_key uuid,
  p_tenant_id       uuid,
  p_agent_id        uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agent_tenants;
  v_after  public.monvelo_agent_tenants;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'suspend_monvelo_agent_link',
    jsonb_build_object('tenant_id', p_tenant_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_agent_tenants
   where tenant_id = p_tenant_id and agent_id = p_agent_id for update;
  if not found then
    raise exception 'this agent is not linked to that tenant' using errcode = 'P0001';
  end if;
  update public.monvelo_agent_tenants set status = 'SUSPENDED'
   where tenant_id = p_tenant_id and agent_id = p_agent_id
  returning * into v_after;

  perform public.write_audit(p_tenant_id, 'suspend_monvelo_agent_link', 'monvelo_agent_tenants', p_agent_id::text,
                             to_jsonb(v_before), to_jsonb(v_after) || jsonb_build_object('by', v_uid), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_id', p_tenant_id, 'agent_id', p_agent_id, 'status', v_after.status));
end;
$$;

-- ── set_monvelo_agent_link_status (tenant ZSM) ──────────────────────────
-- SUSPENDED stops a link at once, including withdrawing a PENDING proposal.
-- ACTIVE reactivates a SUSPENDED link as PENDING: only approve_monvelo_agent_link
-- makes a link ACTIVE. Asking for ACTIVE on an ACTIVE link changes nothing.
create or replace function public.set_monvelo_agent_link_status(
  p_idempotency_key uuid,
  p_agent_id        uuid,
  p_status          text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agent_tenants;
  v_after  public.monvelo_agent_tenants;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_agent_link_status',
    jsonb_build_object('agent_id', p_agent_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_status is null or p_status not in ('ACTIVE', 'SUSPENDED') then
    raise exception 'the status must be ACTIVE or SUSPENDED' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_agent_tenants
   where tenant_id = v_me.tenant_id and agent_id = p_agent_id for update;
  if not found then
    raise exception 'this agent is not linked to your tenant' using errcode = 'P0001';
  end if;

  if p_status = 'SUSPENDED' then
    update public.monvelo_agent_tenants set status = 'SUSPENDED'
     where tenant_id = v_me.tenant_id and agent_id = p_agent_id
    returning * into v_after;
  elsif v_before.status = 'PENDING' then
    raise exception 'this link is waiting for Monvelo approval' using errcode = 'P0001';
  elsif v_before.status = 'SUSPENDED' then
    update public.monvelo_agent_tenants
       set status = 'PENDING', approved_by = null, approved_at = null
     where tenant_id = v_me.tenant_id and agent_id = p_agent_id
    returning * into v_after;
  else
    v_after := v_before;
  end if;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_agent_link_status', 'monvelo_agent_tenants', p_agent_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'status', v_after.status));
end;
$$;

grant execute on function
  public.set_monvelo_agent_subaccount(uuid, uuid, text),
  public.upsert_monvelo_terminal(uuid, uuid, uuid, text, uuid, boolean),
  public.link_monvelo_agent(uuid, public.pos_network_enum, text, uuid),
  public.approve_monvelo_agent_link(uuid, uuid, uuid, uuid),
  public.suspend_monvelo_agent_link(uuid, uuid, uuid),
  public.set_monvelo_agent_link_status(uuid, uuid, text)
to authenticated;
