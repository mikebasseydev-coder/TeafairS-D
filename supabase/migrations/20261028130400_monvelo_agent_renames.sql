-- Domain separation, Task 5 (A6 section 15.4): the Monvelo agent tables lose
-- "fintech" from their names, and the two settlement-account RPCs carry the
-- monvelo_ prefix. ALTER ... RENAME keeps rows, grants, column privileges, RLS
-- and dependent constraint definitions. Function bodies are not
-- dependency-tracked, so every body naming an old table is recreated.

alter table public.monvelo_fintech_agents rename to monvelo_agents;
alter table public.monvelo_fintech_members rename to monvelo_agent_members;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_address_text_check to monvelo_agents_address_text_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_approved_by_fkey to monvelo_agents_approved_by_fkey;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_business_name_check to monvelo_agents_business_name_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_check to monvelo_agents_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_contact_phone_check to monvelo_agents_contact_phone_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_daily_cap_check to monvelo_agents_daily_cap_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_network_agent_id_check to monvelo_agents_network_agent_id_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_network_kyc_reference_check to monvelo_agents_network_kyc_reference_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_per_financing_cap_check to monvelo_agents_per_financing_cap_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_recruited_by_fkey to monvelo_agents_recruited_by_fkey;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_settlement_account_last4_check to monvelo_agents_settlement_account_last4_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_settlement_account_name_check to monvelo_agents_settlement_account_name_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_settlement_account_number_check to monvelo_agents_settlement_account_number_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_settlement_bank_code_check to monvelo_agents_settlement_bank_code_check;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_status_check to monvelo_agents_status_check;
alter table public.monvelo_agent_members rename constraint monvelo_fintech_members_agent_id_fkey to monvelo_agent_members_agent_id_fkey;
alter table public.monvelo_agent_members rename constraint monvelo_fintech_members_profile_id_fkey to monvelo_agent_members_profile_id_fkey;
alter table public.monvelo_agent_members rename constraint monvelo_fintech_members_status_check to monvelo_agent_members_status_check;

-- primary-key and unique constraints rename their indexes too
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_pkey to monvelo_agents_pkey;
alter table public.monvelo_agents rename constraint monvelo_fintech_agents_pos_network_network_agent_id_key to monvelo_agents_pos_network_network_agent_id_key;
alter table public.monvelo_agent_members rename constraint monvelo_fintech_members_pkey to monvelo_agent_members_pkey;

alter index public.idx_monvelo_fintech_agents_approved_by rename to idx_monvelo_agents_approved_by;
alter index public.idx_monvelo_fintech_agents_recruited_by rename to idx_monvelo_agents_recruited_by;
alter index public.idx_monvelo_fintech_agents_status rename to idx_monvelo_agents_status;
alter index public.idx_monvelo_fintech_members_profile rename to idx_monvelo_agent_members_profile;

alter policy monvelo_fintech_agents_select on public.monvelo_agents rename to monvelo_agents_select;
alter policy monvelo_fintech_members_select on public.monvelo_agent_members rename to monvelo_agent_members_select;

alter trigger monvelo_fintech_agents_set_updated_at on public.monvelo_agents rename to monvelo_agents_set_updated_at;

drop function public.request_settlement_change(uuid, text, uuid, jsonb);
drop function public.approve_settlement_change(uuid, uuid);

CREATE OR REPLACE FUNCTION public.my_monvelo_agent_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select m.agent_id from public.monvelo_agent_members m
  where m.profile_id = (select auth.uid()) and m.status = 'ACTIVE';
$function$
;
CREATE OR REPLACE FUNCTION public.register_monvelo_agent(p_idempotency_key uuid, p_gateway_proof text, p_agent jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_row     public.monvelo_agents;
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
    insert into public.monvelo_agents (
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
    if v_cname = 'monvelo_agents_pos_network_network_agent_id_key' then
      raise exception 'this agent is already registered with Monvelo' using errcode = '23505';
    end if;
    raise;
  end;

  perform public.write_audit(v_me.tenant_id, 'register_monvelo_agent', 'monvelo_agents', v_row.id::text,
                             null, public.monvelo_agent_audit(v_row), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', v_row.id, 'status', v_row.status,
    'name_matches', lower(btrim(v_acct ->> 'settlement_account_name')) = lower(btrim(v_name))));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.approve_monvelo_agent(p_idempotency_key uuid, p_agent_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agents;
  v_after  public.monvelo_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_agent',
    jsonb_build_object('agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.status = 'ACTIVE' then
    raise exception 'this agent is already active' using errcode = 'P0001';
  end if;

  update public.monvelo_agents
     set status = 'ACTIVE', approved_by = v_uid, approved_at = now()
   where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'approve_monvelo_agent', 'monvelo_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before), public.monvelo_agent_audit(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'status', v_after.status));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.suspend_monvelo_agent(p_idempotency_key uuid, p_agent_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_before public.monvelo_agents;
  v_after  public.monvelo_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'suspend_monvelo_agent',
    jsonb_build_object('agent_id', p_agent_id, 'reason', v_reason));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_reason = '' then
    raise exception 'a reason is required' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.status = 'SUSPENDED' then
    raise exception 'this agent is already suspended' using errcode = 'P0001';
  end if;

  update public.monvelo_agents set status = 'SUSPENDED' where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'suspend_monvelo_agent', 'monvelo_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before),
                             public.monvelo_agent_audit(v_after) || jsonb_build_object('reason', v_reason, 'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'status', v_after.status));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.set_monvelo_agent_caps(p_idempotency_key uuid, p_agent_id uuid, p_daily_cap numeric, p_per_financing_cap numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agents;
  v_after  public.monvelo_agents;
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

  select * into v_before from public.monvelo_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  update public.monvelo_agents
     set daily_cap = round(p_daily_cap, 2), per_financing_cap = round(p_per_financing_cap, 2)
   where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'set_monvelo_agent_caps', 'monvelo_agents', p_agent_id::text,
                             jsonb_build_object('daily_cap', v_before.daily_cap, 'per_financing_cap', v_before.per_financing_cap),
                             jsonb_build_object('daily_cap', v_after.daily_cap, 'per_financing_cap', v_after.per_financing_cap,
                                                'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', p_agent_id, 'daily_cap', v_after.daily_cap, 'per_financing_cap', v_after.per_financing_cap));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.add_monvelo_member(p_idempotency_key uuid, p_agent_id uuid, p_phone_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  if not exists (select 1 from public.monvelo_agents where id = p_agent_id) then
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

  insert into public.monvelo_agent_members (agent_id, profile_id, status)
  values (p_agent_id, v_profile, 'ACTIVE')
  on conflict (agent_id, profile_id) do update set status = 'ACTIVE';

  -- the audit carries ids only, not the phone number
  perform public.write_audit(null, 'add_monvelo_member', 'monvelo_agent_members', p_agent_id::text,
                             null, jsonb_build_object('agent_id', p_agent_id, 'profile_id', v_profile, 'by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'profile_id', v_profile, 'status', 'ACTIVE'));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.request_monvelo_settlement_change(p_idempotency_key uuid, p_gateway_proof text, p_agent_id uuid, p_account jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_acct   jsonb;
  v_before public.monvelo_agents;
  v_after  public.monvelo_agents;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_monvelo_settlement_change',
    jsonb_build_object('agent_id', p_agent_id, 'account', coalesce(p_account, '{}'::jsonb)));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.recruited_by is distinct from (select auth.uid()) then
    raise exception 'only the street agent who recruited this agent can request an account change'
      using errcode = '42501';
  end if;

  v_acct := public.monvelo_clean_account(p_account)
            || jsonb_build_object('requested_by', (select auth.uid()), 'requested_at', now());
  update public.monvelo_agents set pending_settlement = v_acct where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'request_monvelo_settlement_change', 'monvelo_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before), public.monvelo_agent_audit(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', p_agent_id, 'status', 'PENDING_APPROVAL', 'last4', v_acct ->> 'last4'));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.approve_monvelo_settlement_change(p_idempotency_key uuid, p_agent_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agents;
  v_after  public.monvelo_agents;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_settlement_change',
    jsonb_build_object('agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_agents where id = p_agent_id for update;
  if not found then
    raise exception 'unknown fintech agent' using errcode = 'P0001';
  end if;
  if v_before.pending_settlement is null then
    raise exception 'there is no settlement change waiting for approval' using errcode = 'P0001';
  end if;

  update public.monvelo_agents
     set settlement_account_number = v_before.pending_settlement ->> 'settlement_account_number',
         settlement_account_last4  = v_before.pending_settlement ->> 'last4',
         settlement_bank_code      = v_before.pending_settlement ->> 'settlement_bank_code',
         settlement_account_name   = v_before.pending_settlement ->> 'settlement_account_name',
         pending_settlement        = null
   where id = p_agent_id
  returning * into v_after;

  perform public.write_audit(null, 'approve_monvelo_settlement_change', 'monvelo_agents', p_agent_id::text,
                             public.monvelo_agent_audit(v_before),
                             public.monvelo_agent_audit(v_after) || jsonb_build_object('by', v_uid),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('agent_id', p_agent_id, 'last4', v_after.settlement_account_last4));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.close_monvelo_nomination(p_idempotency_key uuid, p_nomination_id uuid, p_agent_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agent_nominations;
  v_after  public.monvelo_agent_nominations;
  v_agent  public.monvelo_agents;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'close_monvelo_nomination',
    jsonb_build_object('nomination_id', p_nomination_id, 'agent_id', p_agent_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_status is null or p_status not in ('RECRUITED', 'DECLINED') then
    raise exception 'a nomination closes as RECRUITED or DECLINED' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_agent_nominations
   where id = p_nomination_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'unknown nomination' using errcode = 'P0001';
  end if;
  if v_before.status <> 'OPEN' then
    raise exception 'this nomination is already closed' using errcode = 'P0001';
  end if;

  if p_status = 'RECRUITED' then
    if p_agent_id is null then
      raise exception 'the recruited agent is required' using errcode = 'P0001';
    end if;
    select * into v_agent from public.monvelo_agents where id = p_agent_id;
    if not found then
      raise exception 'unknown fintech agent' using errcode = 'P0001';
    end if;
    if v_agent.status <> 'ACTIVE' then
      raise exception 'the agent is not active yet' using errcode = 'P0001';
    end if;
    if v_agent.pos_network is distinct from v_before.pos_network then
      raise exception 'the agent is on a different network' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.monvelo_shop_enrolments e
                    where e.tenant_id = v_me.tenant_id and e.shop_id = v_before.shop_id and e.status = 'ACTIVE') then
      raise exception 'this shop is not enrolled' using errcode = 'P0001';
    end if;
    update public.retail_shops set preferred_agent_id = p_agent_id where id = v_before.shop_id;
  elsif p_agent_id is not null then
    raise exception 'a declined nomination has no agent' using errcode = 'P0001';
  end if;

  update public.monvelo_agent_nominations
     set status = p_status, recruited_agent_id = case when p_status = 'RECRUITED' then p_agent_id end
   where id = p_nomination_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'close_monvelo_nomination', 'monvelo_agent_nominations', p_nomination_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'nomination_id', p_nomination_id, 'status', v_after.status, 'recruited_agent_id', v_after.recruited_agent_id));
end;
$function$
;

-- grants: the same as before (authenticated, service_role); new functions get none by default
revoke all on function public.request_monvelo_settlement_change(uuid, text, uuid, jsonb) from public, anon;
grant execute on function public.request_monvelo_settlement_change(uuid, text, uuid, jsonb) to authenticated, service_role;
revoke all on function public.approve_monvelo_settlement_change(uuid, uuid) from public, anon;
grant execute on function public.approve_monvelo_settlement_change(uuid, uuid) to authenticated, service_role;
