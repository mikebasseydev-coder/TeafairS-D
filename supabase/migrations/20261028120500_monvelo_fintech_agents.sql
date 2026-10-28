-- Addendum A6 §4.1 — the platform-level fintech (POS) agent registry and the
-- staff logins that belong to it.
--
--   monvelo_fintech_agents   one row per POS agent per network; recruited by a
--                            ZSA or ASA, approved by a MONVELO_OPERATOR
--   monvelo_fintech_members  the profiles that sign in for an agent; kept out
--                            of tenant_users
--
-- Named 120500 (not 120200) because it reads monvelo_tenant_settings and
-- is_monvelo_staff(), which the terms migration (120400) creates.
--
-- The settlement account never leaves the database: the account number, the
-- bank code, the pending change and the Paystack payer reference have no
-- column grant. Audit rows and responses carry the last four digits only, and
-- never the contact phone.

-- ── tables ──────────────────────────────────────────────────────────────
create table public.monvelo_fintech_agents (
  id                         uuid primary key default gen_random_uuid(),
  business_name              text not null check (length(btrim(business_name)) > 0),
  pos_network                public.pos_network_enum not null,
  network_agent_id           text not null check (network_agent_id = upper(btrim(network_agent_id)) and length(network_agent_id) > 0),
  contact_phone              text not null check (length(btrim(contact_phone)) > 0),
  location                   extensions.geography(Point, 4326) not null,
  address_text               text not null check (length(btrim(address_text)) > 0),
  settlement_account_number  text not null check (settlement_account_number ~ '^[0-9]{10}$'),
  settlement_account_last4   text not null check (settlement_account_last4 ~ '^[0-9]{4}$'),
  settlement_bank_code       text not null check (length(btrim(settlement_bank_code)) > 0),
  settlement_account_name    text not null check (length(btrim(settlement_account_name)) > 0),
  pending_settlement         jsonb,
  paystack_payer_ref         text,
  network_kyc_reference      text not null check (length(btrim(network_kyc_reference)) > 0),
  recruited_by               uuid not null references public.profiles (id) on delete restrict,
  status                     text not null default 'PENDING' check (status in ('PENDING', 'ACTIVE', 'SUSPENDED')),
  approved_by                uuid references public.profiles (id) on delete restrict,
  approved_at                timestamptz,
  daily_cap                  numeric(15,2) not null default 0 check (daily_cap >= 0),
  per_financing_cap          numeric(15,2) not null default 0 check (per_financing_cap >= 0),
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  unique (pos_network, network_agent_id),
  check (per_financing_cap <= daily_cap)
);
alter table public.monvelo_fintech_agents enable row level security;
create index idx_monvelo_fintech_agents_recruited_by on public.monvelo_fintech_agents (recruited_by);
create index idx_monvelo_fintech_agents_approved_by on public.monvelo_fintech_agents (approved_by);
create index idx_monvelo_fintech_agents_status on public.monvelo_fintech_agents (status);
create trigger monvelo_fintech_agents_set_updated_at before update on public.monvelo_fintech_agents
  for each row execute function public.set_updated_at();

create table public.monvelo_fintech_members (
  agent_id    uuid not null references public.monvelo_fintech_agents (id) on delete restrict,
  profile_id  uuid not null references public.profiles (id) on delete restrict,
  status      text not null default 'ACTIVE' check (status in ('ACTIVE', 'REVOKED')),
  created_at  timestamptz not null default now(),
  primary key (agent_id, profile_id)
);
alter table public.monvelo_fintech_members enable row level security;
create index idx_monvelo_fintech_members_profile on public.monvelo_fintech_members (profile_id);

-- ── grants: the settlement account is never readable by the API ─────────
revoke all on public.monvelo_fintech_agents from anon, authenticated;
revoke all on public.monvelo_fintech_members from anon, authenticated;
grant select (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
              settlement_account_last4, settlement_account_name, network_kyc_reference, recruited_by,
              status, approved_by, approved_at, daily_cap, per_financing_cap, created_at, updated_at)
  on public.monvelo_fintech_agents to authenticated;
grant select on public.monvelo_fintech_members to authenticated;

-- ── policy helpers ──────────────────────────────────────────────────────
-- The agents the caller is an ACTIVE member of. The agent's own status is not
-- checked, so the staff of a suspended agent still see its record.
create or replace function public.my_monvelo_agent_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.agent_id from public.monvelo_fintech_members m
  where m.profile_id = (select auth.uid()) and m.status = 'ACTIVE';
$$;
grant execute on function public.my_monvelo_agent_ids() to authenticated;

-- True for an ACTIVE ZSA or ASA of a tenant that opted in to Monvelo.
create or replace function public.is_monvelo_field_agent()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.tenant_users tu
    join public.monvelo_tenant_settings s on s.tenant_id = tu.tenant_id and s.enabled
    where tu.profile_id = (select auth.uid())
      and tu.status = 'ACTIVE'
      and tu.role in ('ZSA', 'ASA')
  );
$$;
grant execute on function public.is_monvelo_field_agent() to authenticated;

create policy monvelo_fintech_agents_select on public.monvelo_fintech_agents
  for select to authenticated
  using (
    (select public.is_monvelo_staff())
    or id in (select public.my_monvelo_agent_ids())
    or (status = 'ACTIVE' and (select public.is_monvelo_field_agent()))
  );

create policy monvelo_fintech_members_select on public.monvelo_fintech_members
  for select to authenticated
  using (profile_id = (select auth.uid()) or (select public.is_monvelo_staff()));

-- ── internal helpers (no grants) ────────────────────────────────────────
-- The agent row as audit data. Removed: the account number, the bank code, the
-- pending change, the payer reference, the contact phone and the location
-- point. Kept: address_text (and the last four digits of the account).
create or replace function public.monvelo_agent_audit(p_agent public.monvelo_fintech_agents)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select (to_jsonb(p_agent)
           - 'settlement_account_number' - 'settlement_bank_code' - 'pending_settlement'
           - 'paystack_payer_ref' - 'contact_phone' - 'location')
         || jsonb_build_object('has_pending_settlement', p_agent.pending_settlement is not null,
                               'pending_settlement_last4', p_agent.pending_settlement ->> 'last4');
$$;
revoke all on function public.monvelo_agent_audit(public.monvelo_fintech_agents) from public, anon, authenticated;

-- Validates a settlement account object (10-digit number, bank code, name) and
-- returns it trimmed, with the derived last4. Raises P0001 when invalid.
create or replace function public.monvelo_clean_account(p_account jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_number text := btrim(coalesce(p_account ->> 'settlement_account_number', ''));
  v_bank   text := btrim(coalesce(p_account ->> 'settlement_bank_code', ''));
  v_name   text := btrim(coalesce(p_account ->> 'settlement_account_name', ''));
begin
  if v_number !~ '^[0-9]{10}$' then
    raise exception 'the settlement account number must be ten digits' using errcode = 'P0001';
  end if;
  if v_bank = '' or v_name = '' then
    raise exception 'the settlement bank code and account name are required' using errcode = 'P0001';
  end if;
  return jsonb_build_object('settlement_account_number', v_number, 'settlement_bank_code', v_bank,
                            'settlement_account_name', v_name, 'last4', right(v_number, 4));
end;
$$;
revoke all on function public.monvelo_clean_account(jsonb) from public, anon, authenticated;

-- ── register_monvelo_agent ──────────────────────────────────────────────
create or replace function public.register_monvelo_agent(
  p_idempotency_key uuid,
  p_gateway_proof   text,
  p_agent           jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_acct    jsonb;
  v_name    text := btrim(coalesce(p_agent ->> 'business_name', ''));
  v_net     public.pos_network_enum;
  v_netid   text := upper(btrim(coalesce(p_agent ->> 'network_agent_id', '')));
  v_phone   text := btrim(coalesce(p_agent ->> 'contact_phone', ''));
  v_addr    text := btrim(coalesce(p_agent ->> 'address_text', ''));
  v_kyc     text := btrim(coalesce(p_agent ->> 'network_kyc_reference', ''));
  v_lat     numeric;
  v_lng     numeric;
  v_row     public.monvelo_fintech_agents;
  v_cname   text;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'register_monvelo_agent',
    coalesce(p_agent, '{}'::jsonb));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_agent is null or jsonb_typeof(p_agent) <> 'object' then
    raise exception 'the agent details are required' using errcode = 'P0001';
  end if;
  if v_name = '' or v_netid = '' or v_phone = '' or v_addr = '' or v_kyc = '' then
    raise exception 'business name, network agent id, phone, address and network KYC reference are required'
      using errcode = 'P0001';
  end if;
  begin
    v_net := (p_agent ->> 'pos_network')::public.pos_network_enum;
  exception when invalid_text_representation then
    raise exception 'unknown POS network' using errcode = 'P0001';
  end;
  if v_net is null then
    raise exception 'unknown POS network' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_agent -> 'latitude') is distinct from 'number'
     or jsonb_typeof(p_agent -> 'longitude') is distinct from 'number' then
    raise exception 'latitude and longitude are required' using errcode = 'P0001';
  end if;
  v_lat := (p_agent ->> 'latitude')::numeric;
  v_lng := (p_agent ->> 'longitude')::numeric;
  if v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'the location is out of range' using errcode = 'P0001';
  end if;
  v_acct := public.monvelo_clean_account(p_agent);

  -- Race-safe: the unique constraint decides, not a pre-check.
  begin
    insert into public.monvelo_fintech_agents (
      business_name, pos_network, network_agent_id, contact_phone, location, address_text,
      settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name,
      network_kyc_reference, recruited_by)
    values (
      v_name, v_net, v_netid, v_phone,
      extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography,
      v_addr,
      v_acct ->> 'settlement_account_number', v_acct ->> 'last4', v_acct ->> 'settlement_bank_code',
      v_acct ->> 'settlement_account_name', v_kyc, (select auth.uid()))
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_cname = constraint_name;
    if v_cname = 'monvelo_fintech_agents_pos_network_network_agent_id_key' then
      raise exception 'this agent is already registered with Monvelo' using errcode = '23505';
    end if;
    raise;
  end;

  perform public.write_audit(v_me.tenant_id, 'register_monvelo_agent', 'monvelo_fintech_agents', v_row.id::text,
                             null, public.monvelo_agent_audit(v_row), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', v_row.id, 'status', v_row.status,
    'name_matches', lower(btrim(v_acct ->> 'settlement_account_name')) = lower(btrim(v_name))));
end;
$$;

-- ── approve / suspend ───────────────────────────────────────────────────
create or replace function public.approve_monvelo_agent(p_idempotency_key uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_fintech_agents;
  v_after  public.monvelo_fintech_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_agent',
    jsonb_build_object('agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_fintech_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.status = 'ACTIVE' then
    raise exception 'this agent is already active' using errcode = 'P0001';
  end if;

  update public.monvelo_fintech_agents
     set status = 'ACTIVE', approved_by = v_uid, approved_at = now()
   where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'approve_monvelo_agent', 'monvelo_fintech_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before), public.monvelo_agent_audit(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'status', v_after.status));
end;
$$;

create or replace function public.suspend_monvelo_agent(p_idempotency_key uuid, p_agent_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_before public.monvelo_fintech_agents;
  v_after  public.monvelo_fintech_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'suspend_monvelo_agent',
    jsonb_build_object('agent_id', p_agent_id, 'reason', v_reason));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_reason = '' then
    raise exception 'a reason is required' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_fintech_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.status = 'SUSPENDED' then
    raise exception 'this agent is already suspended' using errcode = 'P0001';
  end if;

  update public.monvelo_fintech_agents set status = 'SUSPENDED' where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'suspend_monvelo_agent', 'monvelo_fintech_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before),
                             public.monvelo_agent_audit(v_after) || jsonb_build_object('reason', v_reason, 'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'status', v_after.status));
end;
$$;

-- ── set_monvelo_agent_caps (ruling 9; enforced at claim time in Step 2) ─
create or replace function public.set_monvelo_agent_caps(
  p_idempotency_key   uuid,
  p_agent_id          uuid,
  p_daily_cap         numeric,
  p_per_financing_cap numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_fintech_agents;
  v_after  public.monvelo_fintech_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_agent_caps',
    jsonb_build_object('agent_id', p_agent_id, 'daily_cap', p_daily_cap, 'per_financing_cap', p_per_financing_cap));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_daily_cap is null or p_per_financing_cap is null or p_daily_cap < 0 or p_per_financing_cap < 0 then
    raise exception 'both caps must be zero or more' using errcode = 'P0001';
  end if;
  if p_per_financing_cap > p_daily_cap then
    raise exception 'the per-financing cap cannot exceed the daily cap' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_fintech_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  update public.monvelo_fintech_agents
     set daily_cap = round(p_daily_cap, 2), per_financing_cap = round(p_per_financing_cap, 2)
   where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'set_monvelo_agent_caps', 'monvelo_fintech_agents', p_agent_id::text,
                             jsonb_build_object('daily_cap', v_before.daily_cap, 'per_financing_cap', v_before.per_financing_cap),
                             jsonb_build_object('daily_cap', v_after.daily_cap, 'per_financing_cap', v_after.per_financing_cap,
                                                'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', p_agent_id, 'daily_cap', v_after.daily_cap, 'per_financing_cap', v_after.per_financing_cap));
end;
$$;

-- ── add_monvelo_member ──────────────────────────────────────────────────
create or replace function public.add_monvelo_member(p_idempotency_key uuid, p_agent_id uuid, p_phone_number text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior   jsonb;
  v_phone   text := '+' || ltrim(btrim(coalesce(p_phone_number, '')), '+');
  v_profile uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'add_monvelo_member',
    jsonb_build_object('agent_id', p_agent_id, 'phone_number', v_phone));
  if v_prior is not null then
    return v_prior;
  end if;
  if not exists (select 1 from public.monvelo_fintech_agents where id = p_agent_id) then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;

  select p.id into v_profile
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.phone_number = v_phone
    and u.phone_confirmed_at is not null;
  if v_profile is null then
    raise exception 'no Teafair account with a verified phone exists for that number' using errcode = 'P0001';
  end if;

  insert into public.monvelo_fintech_members (agent_id, profile_id, status)
  values (p_agent_id, v_profile, 'ACTIVE')
  on conflict (agent_id, profile_id) do update set status = 'ACTIVE';

  -- the audit carries ids only, not the phone number
  perform public.write_audit(null, 'add_monvelo_member', 'monvelo_fintech_members', p_agent_id::text,
                             null, jsonb_build_object('agent_id', p_agent_id, 'profile_id', v_profile, 'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'profile_id', v_profile, 'status', 'ACTIVE'));
end;
$$;

-- ── request_settlement_change / approve_settlement_change ───────────────
create or replace function public.request_settlement_change(
  p_idempotency_key uuid,
  p_gateway_proof   text,
  p_agent_id        uuid,
  p_account         jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_acct   jsonb;
  v_before public.monvelo_fintech_agents;
  v_after  public.monvelo_fintech_agents;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_settlement_change',
    jsonb_build_object('agent_id', p_agent_id, 'account', coalesce(p_account, '{}'::jsonb)));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_fintech_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.recruited_by is distinct from (select auth.uid()) then
    raise exception 'only the street agent who recruited this agent can request an account change'
      using errcode = '42501';
  end if;

  v_acct := public.monvelo_clean_account(p_account)
            || jsonb_build_object('requested_by', (select auth.uid()), 'requested_at', now());
  update public.monvelo_fintech_agents set pending_settlement = v_acct where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'request_settlement_change', 'monvelo_fintech_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before), public.monvelo_agent_audit(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', p_agent_id, 'status', 'PENDING_APPROVAL', 'last4', v_acct ->> 'last4'));
end;
$$;

create or replace function public.approve_settlement_change(p_idempotency_key uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_fintech_agents;
  v_after  public.monvelo_fintech_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_settlement_change',
    jsonb_build_object('agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_fintech_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.pending_settlement is null then
    raise exception 'there is no settlement change waiting for approval' using errcode = 'P0001';
  end if;

  update public.monvelo_fintech_agents
     set settlement_account_number = v_before.pending_settlement ->> 'settlement_account_number',
         settlement_account_last4  = v_before.pending_settlement ->> 'last4',
         settlement_bank_code      = v_before.pending_settlement ->> 'settlement_bank_code',
         settlement_account_name   = v_before.pending_settlement ->> 'settlement_account_name',
         pending_settlement        = null
   where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'approve_settlement_change', 'monvelo_fintech_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before),
                             public.monvelo_agent_audit(v_after) || jsonb_build_object('by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'last4', v_after.settlement_account_last4));
end;
$$;

grant execute on function
  public.register_monvelo_agent(uuid, text, jsonb),
  public.approve_monvelo_agent(uuid, uuid),
  public.suspend_monvelo_agent(uuid, uuid, text),
  public.set_monvelo_agent_caps(uuid, uuid, numeric, numeric),
  public.add_monvelo_member(uuid, uuid, text),
  public.request_settlement_change(uuid, text, uuid, jsonb),
  public.approve_settlement_change(uuid, uuid)
to authenticated;
