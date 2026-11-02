-- Monvelo Step 3, R59 (amends R53): monvelo-fund records its checkout through
-- the caller's JWT and the gateway proof, not the service role.
--
-- Spec A §9 forbids a user-facing gateway calling an RPC with the service-role
-- key, and R22's exception covers only Storage and log_message_delivery. So
-- record_monvelo_checkout follows the gateway-proof pattern of
-- start_monvelo_delivery and start_monvelo_consent (R16): the Vault
-- gateway_secret proves the call came through monvelo-fund, and the caller must
-- be the member who started the payment, still an ACTIVE member of an ACTIVE
-- agent. The two payments columns stay granted to no API role.

drop function if exists public.record_monvelo_checkout(uuid, text, text);

create or replace function public.record_monvelo_checkout(
  p_idempotency_key   uuid,
  p_gateway_proof     text,
  p_payment_id        uuid,
  p_authorization_url text,
  p_access_code       text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_prior   jsonb;
  v_payment public.payments;
begin
  perform public.assert_gateway_proof(p_gateway_proof);
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_authorization_url is null or p_authorization_url !~ '^https://' or char_length(p_authorization_url) > 2048
     or p_access_code is null or btrim(p_access_code) = '' or char_length(p_access_code) > 256 then
    raise exception 'the checkout must be a Paystack https URL and an access code' using errcode = 'P0001';
  end if;

  -- neither the proof nor the checkout itself is kept in clear: the request is stored as a hash
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_checkout',
    jsonb_build_object('payment_id', p_payment_id, 'authorization_url', p_authorization_url, 'access_code', p_access_code));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_payment from public.payments
   where id = p_payment_id and monvelo_financing_id is not null
     for update;
  if v_payment.id is null then
    raise exception 'not a Monvelo payment' using errcode = 'P0001';
  end if;
  -- live: the starter, still an ACTIVE member of the paying agent, which is ACTIVE
  if v_payment.monvelo_started_by is distinct from v_uid
     or not exists (select 1 from public.monvelo_agent_members m
                      join public.monvelo_agents a on a.id = m.agent_id
                     where m.agent_id = v_payment.monvelo_agent_id and m.profile_id = v_uid
                       and m.status = 'ACTIVE' and a.status = 'ACTIVE') then
    raise exception 'only the member who started this payment records its checkout' using errcode = '42501';
  end if;
  if v_payment.payment_status <> 'INITIATED' then
    raise exception 'only a payment still being started takes its checkout' using errcode = 'P0001';
  end if;
  if v_payment.monvelo_authorization_url is not null then
    raise exception 'this payment already has its checkout' using errcode = 'P0001';
  end if;

  update public.payments
     set monvelo_authorization_url = p_authorization_url, monvelo_access_code = p_access_code
   where id = v_payment.id;
  -- R15: the actor is the agent's member, so no tenant reads the row; it holds neither the URL nor the code
  perform public.write_audit(null, 'record_monvelo_checkout', 'payments', v_payment.id::text,
    null, jsonb_build_object('checkout_recorded', true, 'reference', v_payment.paystack_reference),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('recorded', true, 'payment_id', v_payment.id));
end;
$$;
revoke all on function public.record_monvelo_checkout(uuid, text, uuid, text, text) from public, anon, service_role;
grant execute on function public.record_monvelo_checkout(uuid, text, uuid, text, text) to authenticated;
