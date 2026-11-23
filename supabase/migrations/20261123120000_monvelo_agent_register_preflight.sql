-- monvelo-agent-register: authorise and replay BEFORE the Paystack call
-- (Playwright API findings, 2026-11-23).
--
-- The gateway resolved the settlement account at Paystack (/bank/resolve)
-- before the database saw the caller, so:
--   1. a caller the database would refuse (TM, ZSM, an operator, a shop owner,
--      a POS agent's staff, a street agent of a tenant not opted in) still cost
--      a Paystack call, and 422 versus 403 told them whether an account exists;
--   2. an identical retry called Paystack again, and because the request hash
--      included the bank's holder name, a name that changed in between turned
--      a clean replay into TF002.
--
-- The fix, in two parts:
--   * the request hashed for idempotency is the client's request only, never
--     the bank-resolved `settlement_account_name` (it is derived from the
--     account number and bank code, which stay in the hash). Built in one place,
--     `monvelo_recruitment_request`, used by both RPCs and the preflight, so the
--     three always hash the same thing;
--   * `monvelo_agent_register_preflight` (read-only, `authenticated`) runs the
--     same role gate as the two RPCs (an ACTIVE ZSA or ASA of a tenant opted in
--     to Monvelo), for a settlement change also the recruiter check, and looks
--     the key up: a COMPLETED key for the same actor,
--     operation and request returns the stored response, a key used for
--     anything else raises TF002, an unknown key returns `{replay: false}`.
--
-- The preflight needs no gateway proof: it writes nothing and hands back only
-- the caller's own stored response, which they already read in
-- `idempotency_logs` under RLS (`idempotency_logs_select_actor`). The RPCs
-- still decide everything (role, gateway proof, idempotency, the recruiter
-- check); the preflight only stops the gateway from calling Paystack for a
-- caller or a key that cannot succeed.
--
-- The two RPC bodies are recreated from their latest definitions
-- (20261031120060); the only change in each is the request passed to
-- idempotency_begin. Signatures and grants are unchanged. No client exists and
-- nothing is deployed, so keys logged under the old hash need no migration
-- (a replay of one would raise TF002).

-- ── the request hashed for idempotency ──────────────────────────────────
create or replace function public.monvelo_recruitment_request(p_operation text, p_args jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_operation = 'register_monvelo_agent' then
    return coalesce(p_args, '{}'::jsonb) - 'settlement_account_name';
  elsif p_operation = 'request_monvelo_settlement_change' then
    return jsonb_build_object(
      'agent_id', p_args -> 'agent_id',
      'account', coalesce(p_args -> 'account', '{}'::jsonb) - 'settlement_account_name');
  end if;
  raise exception 'unknown Monvelo recruitment operation' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_recruitment_request(text, jsonb) from public, anon, authenticated;

-- ── the preflight ───────────────────────────────────────────────────────
create or replace function public.monvelo_agent_register_preflight(
  p_idempotency_key uuid,
  p_operation       text,
  p_request         jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_request jsonb;
  v_hash      text;
  v_row       public.idempotency_logs;
  v_recruiter uuid;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'p_idempotency_key is required' using errcode = 'P0001';
  end if;
  v_request := public.monvelo_recruitment_request(p_operation, p_request);

  -- a settlement change is the recruiter's alone; mirror that check too, so a
  -- street agent who did not recruit the agent costs no Paystack call either
  if p_operation = 'request_monvelo_settlement_change' then
    select a.recruited_by into v_recruiter from public.monvelo_agents a
     where a.id = (nullif(v_request ->> 'agent_id', ''))::uuid;
    if not found then
      raise exception 'unknown Monvelo agent' using errcode = 'P0001';
    end if;
    if v_recruiter is distinct from (select auth.uid()) then
      raise exception 'only the street agent who recruited this agent can request an account change'
        using errcode = '42501';
    end if;
  end if;

  select * into v_row from public.idempotency_logs where key = p_idempotency_key;
  if not found then
    return jsonb_build_object('replay', false);
  end if;

  -- the same digest idempotency_begin computes
  v_hash := encode(extensions.digest(v_request::text, 'sha256'), 'hex');
  if v_row.operation <> p_operation
     or v_row.request_hash <> v_hash
     or v_row.actor_id is distinct from (select auth.uid()) then
    raise exception 'idempotency key % was already used for a different request', p_idempotency_key
      using errcode = 'TF002';
  end if;
  if v_row.status = 'COMPLETED' then
    return jsonb_build_object('replay', true, 'response', v_row.response);
  end if;
  raise exception 'request % is still in progress', p_idempotency_key using errcode = '40001';
end;
$$;
revoke all on function public.monvelo_agent_register_preflight(uuid, text, jsonb) from public, anon;
grant execute on function public.monvelo_agent_register_preflight(uuid, text, jsonb) to authenticated;

-- ── register_monvelo_agent (from 20261031120060; the hashed request changes) ──
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
  -- the client's request only: the bank-resolved holder name is not part of it
  v_prior := public.idempotency_begin(p_idempotency_key, 'register_monvelo_agent',
    public.monvelo_recruitment_request('register_monvelo_agent', p_agent));
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

-- ── request_monvelo_settlement_change (from 20261031120060; the hashed request changes) ──
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
  -- the client's request only: the bank-resolved holder name is not part of it
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_monvelo_settlement_change',
    public.monvelo_recruitment_request('request_monvelo_settlement_change',
      jsonb_build_object('agent_id', p_agent_id, 'account', coalesce(p_account, '{}'::jsonb))));
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
