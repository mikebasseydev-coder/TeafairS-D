-- Spec D1 §9 — refunds and reversals. apply_paystack_refund is the only
-- writer for refunds (decision 9). Its callers are process-payment
-- (refund.processed, re-fetched with Fetch Refund; a Verify result of
-- `reversed`) and the reconcile-funds daily refund pass, all service_role.
-- At most once per refund id; a reversal uses 'reversal:' || reference.
--
-- Plan Decision 2: a refund that arrives while its charge is not yet SUCCESS
-- is audited and returned BEFORE the key is taken, so the daily refund pass
-- can apply it once settle_paystack_payment has recorded the charge.
--
-- A reversal of a charge not yet confirmed (INITIATED, PROCESSING, FAILED)
-- moves the payment straight to REFUNDED in this one transaction: the order
-- is never marked PAID and nobody is told it is ready to ship.

create or replace function public.apply_paystack_refund(
  p_source                 text,
  p_refund_id              text,
  p_transaction_reference  text,
  p_amount_minor           bigint,
  p_currency               text,
  p_reason                 text,
  p_verified               jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key       uuid;
  v_source    public.audit_source_enum;
  v_request   jsonb;
  v_matches   integer;
  v_payment   public.payments;
  v_order     public.orders;
  v_currency  text;
  v_paid      bigint;
  v_conflict  text;
  v_prior     jsonb;
  v_order_out text;
  v_comm      record;
begin
  -- p_verified is accepted for the gateway contract but never stored: it can
  -- carry the customer's contact details (CLAUDE.md, addendum A2)
  if p_source is null or p_source not in ('webhook', 'sweep') then
    raise exception 'p_source must be webhook or sweep' using errcode = 'P0001';
  end if;
  if p_reason is null or p_reason not in ('REFUND', 'REVERSAL') then
    raise exception 'p_reason must be REFUND or REVERSAL' using errcode = 'P0001';
  end if;
  if p_refund_id is null or btrim(p_refund_id) = '' then
    raise exception 'p_refund_id is required' using errcode = 'P0001';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'p_amount_minor must be positive' using errcode = 'P0001';
  end if;

  v_key    := md5('paystack-refund:' || p_refund_id)::uuid;
  v_source := case when p_source = 'sweep' then 'CRON' else 'WEBHOOK' end;
  -- the refund itself, not who delivered it: the webhook and the refund pass
  -- may both deliver one refund, and the second must replay the first reply
  v_request := jsonb_build_object('refund_id', p_refund_id, 'reference', p_transaction_reference,
                                  'amount_minor', p_amount_minor, 'currency', p_currency, 'reason', p_reason);

  select count(*) into v_matches from public.payments where paystack_reference = p_transaction_reference;
  if v_matches <> 1 then
    -- zero or several payments: no single payment to refund. The key is taken
    -- (payment rows exist before their charge, so a retry cannot help).
    v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    perform public.write_audit(null, 'REFUND_CONFLICT', 'payments', p_transaction_reference, null,
      jsonb_build_object('reason', 'unknown_reference', 'refund_id', p_refund_id,
                         'reference', p_transaction_reference, 'matches', v_matches,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source);
    return public.idempotency_complete(v_key,
      jsonb_build_object('outcome', 'conflict', 'reason', 'unknown_reference'));
  end if;

  -- payment row first (§6.2 lock order), held across the status check so a
  -- concurrent settle cannot slip between the check and the key
  select * into v_payment from public.payments where paystack_reference = p_transaction_reference for update;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') and p_reason = 'REVERSAL' then
    -- the charge was reversed before Teafair recorded it: the money is gone,
    -- so the payment is REFUNDED and the order is left as it is (never PAID)
    v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
    v_paid     := (v_payment.amount * 100)::bigint;
    v_conflict := case
                    when p_currency is distinct from v_currency then 'currency_mismatch'
                    when p_amount_minor <> v_paid then 'amount_mismatch'
                  end;
    if v_conflict is not null then
      perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
        jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id,
                           'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
        v_key, v_source, v_payment.teafair_agent_id);
      return public.idempotency_complete(v_key, jsonb_build_object(
        'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
        'payment_status', v_payment.payment_status));
    end if;

    update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
      'order_status', (select o.status from public.orders o
                        where o.tenant_id = v_payment.tenant_id and o.id = v_payment.order_id),
      'reason', p_reason));
  end if;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') then
    -- Decision 2 (REFUND only): no key, so the daily refund pass re-applies it after settle
    perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('reason', 'payment_not_success', 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      null, v_source, v_payment.teafair_agent_id);
    return jsonb_build_object('outcome', 'conflict', 'reason', 'payment_not_success',
                              'payment_id', v_payment.id, 'payment_status', v_payment.payment_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_order from public.orders
   where tenant_id = v_payment.tenant_id and id = v_payment.order_id for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
  v_paid     := (v_payment.amount * 100)::bigint;

  v_conflict := case
                  -- REFUNDED is final: no later charge can make it SUCCESS
                  -- again, so this conflict takes its key
                  when v_payment.payment_status <> 'SUCCESS' then 'payment_not_success'
                  when p_currency is distinct from v_currency then 'currency_mismatch'
                  when p_amount_minor > v_paid then 'over_refund'
                end;
  if v_conflict is not null then
    perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
      jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
      'payment_status', v_payment.payment_status));
  end if;

  -- ── partial refund: no status change, the ZSMs are told ───────────────
  if p_amount_minor < v_paid then
    perform public.write_audit(v_payment.tenant_id, 'PARTIAL_REFUND', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid),
      jsonb_build_object('refund_id', p_refund_id, 'reason', p_reason,
                         'amount_minor', p_amount_minor, 'currency', p_currency),
      v_key, v_source, v_payment.teafair_agent_id);
    perform public.notify_tenant_zsms(v_payment.tenant_id, 'PAYMENT_PARTIALLY_REFUNDED', 'Partial refund',
      'Order ' || coalesce(v_order.public_reference, v_order.id::text) || ' was partly refunded ('
        || to_char(p_amount_minor / 100.0, 'FM999999999999990.00') || ' ' || p_currency || ').',
      jsonb_build_object('order_id', v_order.id, 'payment_id', v_payment.id,
                         'public_reference', v_order.public_reference,
                         'amount_minor', p_amount_minor, 'currency', p_currency));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'partial', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status,
      'amount_minor', p_amount_minor));
  end if;

  -- ── full refund or reversal ───────────────────────────────────────────
  -- gateway_response_payload keeps the verified charge; the refund payload is
  -- not stored
  update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
  perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                       'amount_minor', p_amount_minor, 'currency', p_currency),
    v_key, v_source, v_payment.teafair_agent_id);

  -- the order, ONLINE only (field-order transitions are Spec C / D2), and
  -- only once it was paid; any other status is left as it is
  v_order_out := v_order.status;
  if v_order.channel = 'ONLINE' and v_order.status in ('PAID', 'IN_TRANSIT', 'DELIVERED') then
    update public.orders set status = 'REFUNDED' where id = v_order.id;
    v_order_out := 'REFUNDED';
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'orders', v_order.id::text,
      jsonb_build_object('status', v_order.status),
      jsonb_build_object('status', 'REFUNDED', 'payment_id', v_payment.id, 'reason', p_reason,
                         'refund_id', p_refund_id),
      v_key, v_source, v_payment.teafair_agent_id);
  end if;

  -- Paystack does not claw the share back from the subaccount: the commission
  -- becomes DISPUTED and recovery is recorded work for D3
  for v_comm in
    update public.commission_records c
       set status = 'DISPUTED', dispute_reason = 'ORDER_REFUNDED'
      from public.commission_records old
     where c.id = old.id
       and c.tenant_id = v_payment.tenant_id and c.payment_id = v_payment.id
       and c.status in ('SPLIT', 'SETTLED')
    returning c.id, c.order_id, old.status as old_status
  loop
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'commission_records', v_comm.id::text,
      jsonb_build_object('status', v_comm.old_status),
      jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'ORDER_REFUNDED', 'payment_id', v_payment.id,
                         'refund_id', p_refund_id),
      v_key, v_source, v_payment.teafair_agent_id);
    perform public.notify_tenant_zsms(v_payment.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
      'A partner commission needs review (ORDER_REFUNDED).',
      jsonb_build_object('commission_id', v_comm.id, 'order_id', v_comm.order_id, 'reason', 'ORDER_REFUNDED'));
  end loop;

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
    'order_status', v_order_out, 'reason', p_reason));
end;
$$;

revoke execute on function public.apply_paystack_refund(text, text, text, bigint, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.apply_paystack_refund(text, text, text, bigint, text, text, jsonb)
  to service_role;
