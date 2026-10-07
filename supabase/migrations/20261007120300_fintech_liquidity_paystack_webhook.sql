-- Spec A §3.6 — the database half of the Paystack webhook. process-payment
-- (service_role) has already checked the signature and the ±300 s window and
-- re-fetched the transaction from the Verify API; these functions apply the
-- verified result at most once and audit everything they decline to apply.
--
-- Rows are WEBHOOK-sourced with no actor; teafair_agent_id is the payment's
-- accountable agent (§6.10). Order status and commission rows are Spec C/D.

-- payments are unique per (tenant, reference) but the webhook knows no tenant
create index idx_payments_paystack_reference on public.payments (paystack_reference);

create or replace function public.settle_paystack_payment(
  p_event        text,
  p_reference    text,
  p_status       text,
  p_amount_minor bigint,
  p_currency     text,
  p_verified     jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- (event, reference) is the at-most-once key (§3.6 check 4)
  v_key      uuid := md5('paystack:' || p_event || ':' || p_reference)::uuid;
  v_matches  integer;
  v_payment  public.payments;
  v_currency text;
  v_target   public.payment_status_enum;
  v_prior    jsonb;
begin
  select count(*) into v_matches from public.payments where paystack_reference = p_reference;
  if v_matches <> 1 then
    -- not marked processed: a payment row that lands later can still settle
    perform public.write_audit(null,
      case when v_matches = 0 then 'PAYSTACK_UNKNOWN_REFERENCE' else 'PAYSTACK_AMBIGUOUS_REFERENCE' end,
      'payments', p_reference, null,
      jsonb_build_object('event', p_event, 'reference', p_reference, 'matches', v_matches),
      null, 'WEBHOOK');
    return jsonb_build_object('outcome',
      case when v_matches = 0 then 'unknown_reference' else 'ambiguous_reference' end);
  end if;

  v_target := case p_status
                when 'success'   then 'SUCCESS'
                when 'failed'    then 'FAILED'
                when 'abandoned' then 'FAILED'
                when 'reversed'  then 'REFUNDED'
              end;
  if v_target is null then
    -- ongoing / pending / processing: the reconcile-funds sweep settles it later
    return jsonb_build_object('outcome', 'not_final', 'status', p_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'settle_paystack_payment',
    jsonb_build_object('event', p_event, 'reference', p_reference));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_payment from public.payments where paystack_reference = p_reference for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');

  if v_target = 'SUCCESS'
     and (p_amount_minor is distinct from (v_payment.amount * 100)::bigint
          or p_currency is distinct from v_currency) then
    perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_MISMATCH', 'payments', v_payment.id::text,
      jsonb_build_object('amount_minor', (v_payment.amount * 100)::bigint, 'currency', v_currency),
      jsonb_build_object('amount_minor', p_amount_minor, 'currency', p_currency, 'event', p_event),
      v_key, 'WEBHOOK', v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key,
      jsonb_build_object('outcome', 'mismatch', 'payment_id', v_payment.id));
  end if;

  if v_payment.payment_status = v_target then
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'unchanged', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  if v_payment.payment_status = 'REFUNDED'
     or (v_payment.payment_status = 'SUCCESS' and v_target = 'FAILED')
     or (v_target = 'REFUNDED' and v_payment.payment_status <> 'SUCCESS') then
    perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_STATUS_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('verified_status', p_status, 'event', p_event),
      v_key, 'WEBHOOK', v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  update public.payments
     set payment_status = v_target, gateway_response_payload = p_verified
   where id = v_payment.id;

  perform public.write_audit(v_payment.tenant_id, 'settle_paystack_payment', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', v_target, 'event', p_event),
    v_key, 'WEBHOOK', v_payment.teafair_agent_id);

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'updated', 'payment_id', v_payment.id, 'payment_status', v_target));
end;
$$;

-- §3.6 check 2: an event outside ±300 s is not processed, only recorded.
-- The payment is left for the reconcile-funds Verify-API sweep.
create or replace function public.record_stale_paystack_webhook(
  p_event      text,
  p_reference  text,
  p_event_time timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
begin
  if (select count(*) from public.payments where paystack_reference = p_reference) = 1 then
    select * into v_payment from public.payments where paystack_reference = p_reference;
  end if;

  perform public.write_audit(v_payment.tenant_id, 'WEBHOOK_STALE', 'payments',
    coalesce(v_payment.id::text, p_reference), null,
    jsonb_build_object('event', p_event, 'reference', p_reference, 'event_time', p_event_time),
    null, 'WEBHOOK', v_payment.teafair_agent_id);
  return jsonb_build_object('outcome', 'stale');
end;
$$;

revoke execute on function public.settle_paystack_payment(text, text, text, bigint, text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.record_stale_paystack_webhook(text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.settle_paystack_payment(text, text, text, bigint, text, jsonb) to service_role;
grant execute on function public.record_stale_paystack_webhook(text, text, timestamptz) to service_role;
