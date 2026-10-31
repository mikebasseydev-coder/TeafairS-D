-- A6 §16.2.2 (user ruling R19, 2026-10-31): tenants never see lenders. The
-- tenant's ZSM reads every tenant-scoped audit row (and the TM the rows of its
-- territory), so a Monvelo audit row that names an agent is written with
-- tenant_id null, as Step 3 R15 did for claims, lapses and pledges.
--
-- The four recruitment RPCs below are recreated from their live definitions
-- (pg_get_functiondef; last defined in 20261028130400 for register_monvelo_agent,
-- 20261029130500 for request_monvelo_settlement_change and close_monvelo_nomination,
-- 20261028120600 for nominate_monvelo_agent). The only change in each is the
-- write_audit tenant argument;
-- bodies, signatures and grants are otherwise unchanged.
--
--   register_monvelo_agent              the agent's record (business name, network, holder name)
--   request_monvelo_settlement_change   the agent's record before and after
--   nominate_monvelo_agent              the nominated agent's name and phone last four
--   close_monvelo_nomination            the nomination, with recruited_agent_id
--
-- A grep of every other Monvelo function's write_audit call found no other
-- tenant-scoped row carrying an agent_id, a pledge_id or an agent name.

-- ── register_monvelo_agent ──────────────────────────────────────────────
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

  -- R19: the row names an agent, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'register_monvelo_agent', 'monvelo_agents', v_row.id::text,
                             null, public.monvelo_agent_audit(v_row), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', v_row.id, 'status', v_row.status,
    'name_matches', lower(btrim(v_acct ->> 'settlement_account_name')) = lower(btrim(v_name))));
end;
$function$;

-- ── request_monvelo_settlement_change ───────────────────────────────────
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

    raise exception 'unknown Monvelo agent' using errcode = 'P0001';

  end if;

  if v_before.recruited_by is distinct from (select auth.uid()) then

    raise exception 'only the street agent who recruited this agent can request an account change'

      using errcode = '42501';

  end if;



  v_acct := public.monvelo_clean_account(p_account)

            || jsonb_build_object('requested_by', (select auth.uid()), 'requested_at', now());

  update public.monvelo_agents set pending_settlement = v_acct where id = p_agent_id

  returning * into v_after;



  -- R19: the row names an agent, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'request_monvelo_settlement_change', 'monvelo_agents', p_agent_id::text,

                             public.monvelo_agent_audit(v_before), public.monvelo_agent_audit(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(

    'agent_id', p_agent_id, 'status', 'PENDING_APPROVAL', 'last4', v_acct ->> 'last4'));

end;

$function$;

-- ── nominate_monvelo_agent ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.nominate_monvelo_agent(p_idempotency_key uuid, p_shop_id uuid, p_name text, p_phone text, p_pos_network pos_network_enum)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid     uuid := (select auth.uid());
  v_owner   uuid;
  v_tenant  uuid;
  v_prior   jsonb;
  v_name    text := btrim(coalesce(p_name, ''));
  v_digits  text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_row     public.monvelo_agent_nominations;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select owner_id into v_owner from public.retail_shops where id = p_shop_id;
  if v_owner is not null and v_owner = v_uid then
    -- re-verified live: the owner must be an ACTIVE RETAIL_SHOP_OWNER member of
    -- the tenant in their session (assert_tenant_role reads tenant_users)
    v_tenant := (public.assert_tenant_role(array['RETAIL_SHOP_OWNER']::public.tenant_role_enum[])).tenant_id;
  else
    v_tenant := (public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[])).tenant_id;
  end if;
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_tenant and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'nominate_monvelo_agent',
    jsonb_build_object('shop_id', p_shop_id, 'name', v_name, 'phone_last4', right(v_digits, 4),
                       'pos_network', p_pos_network));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_name = '' then
    raise exception 'the agent''s name is required' using errcode = 'P0001';
  end if;
  if length(v_digits) < 7 or length(v_digits) > 15 then
    raise exception 'enter a valid phone number' using errcode = 'P0001';
  end if;
  if p_pos_network is null then
    raise exception 'the POS network is required' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = v_tenant and e.shop_id = p_shop_id and e.status = 'ACTIVE') then
    raise exception 'this shop is not enrolled' using errcode = 'P0001';
  end if;

  insert into public.monvelo_agent_nominations (tenant_id, shop_id, nominated_name, nominated_phone_last4,
                                                pos_network, raised_by)
  values (v_tenant, p_shop_id, v_name, right(v_digits, 4), p_pos_network, v_uid)
  returning * into v_row;

  -- R19: the row names an agent, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'nominate_monvelo_agent', 'monvelo_agent_nominations', v_row.id::text,
                             null, to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('nomination_id', v_row.id, 'status', v_row.status));
end;
$function$;

-- ── close_monvelo_nomination ────────────────────────────────────────────
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

      raise exception 'unknown Monvelo agent' using errcode = 'P0001';

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



  -- R19: the row names an agent, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'close_monvelo_nomination', 'monvelo_agent_nominations', p_nomination_id::text,

                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(

    'nomination_id', p_nomination_id, 'status', v_after.status, 'recruited_agent_id', v_after.recruited_agent_id));

end;

$function$;
