-- Spec D1 §6 — collection settlement. settle_paystack_payment v2 is the only
-- writer for collections (decision 9): payment status, PENDING → PAID and the
-- commission row copied from the checkout split snapshot (decision 6). Its two
-- callers are the Paystack webhook (process-payment) and the reconcile-funds
-- sweep (§7), both passing data from Paystack's Verify API (decision 8).
-- Alerts are notifications rows in the same transaction (decision 12).

-- ── payments: sweep bookkeeping and the split/partner pairing ───────────
-- last_swept_at is internal (not in the authenticated column grant):
-- claim_unconfirmed_payments stamps every row it hands out, so the sweep
-- visits the least recently checked payment first and rows that keep failing
-- (a Verify error, an ambiguous reference) or stay not final cannot starve it.
alter table public.payments
  add column last_swept_at timestamptz,
  -- a snapshot without a partner could never become a commission row and
  -- would roll back every settlement (decision 10: real money wins)
  add constraint payments_split_has_partner
    check (split_subaccount_code is null or fintech_partner_id is not null);
drop index public.idx_payments_unconfirmed;
create index idx_payments_unconfirmed on public.payments ((coalesce(last_swept_at, created_at)))
  where payment_status in ('INITIATED', 'PROCESSING');

-- ── internal: tell every ACTIVE ZSM of a tenant ─────────────────────────
create or replace function public.notify_tenant_zsms(
  p_tenant_id uuid,
  p_kind      text,
  p_title     text,
  p_body      text,
  p_payload   jsonb
)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
  select distinct p_tenant_id, tu.profile_id, p_kind, p_title, p_body, coalesce(p_payload, '{}'::jsonb)
    from public.tenant_users tu
   where tu.tenant_id = p_tenant_id and tu.role = 'ZSM' and tu.status = 'ACTIVE';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── settle_paystack_payment v2 ──────────────────────────────────────────
drop function public.settle_paystack_payment(text, text, text, bigint, text, jsonb);

create or replace function public.settle_paystack_payment(
  p_event              text,
  p_reference          text,
  p_status             text,
  p_amount_minor       bigint,
  p_currency           text,
  p_verified           jsonb,
  p_transaction_id     text,
  p_split_subaccount   text,
  p_split_share_minor  bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- (event, reference) is the at-most-once key (Spec A §3.6 check 4)
  v_key        uuid := md5('paystack:' || p_event || ':' || p_reference)::uuid;
  v_source     public.audit_source_enum := case when p_event = 'sweep' then 'CRON' else 'WEBHOOK' end;
  v_matches    integer;
  v_payment    public.payments;
  v_order      public.orders;
  v_age        interval;
  v_expired    boolean := false;
  v_currency   text;
  v_target     public.payment_status_enum;
  v_prior      jsonb;
  v_order_out  text;
  v_comm_id    uuid;
  v_comm_out   public.commission_status_enum;
  v_expected   bigint;
begin
  if p_status = 'reversed' then
    -- §9: the gateway applies a reversal as a full refund instead
    raise exception 'reversed is applied by apply_paystack_refund' using errcode = 'P0001';
  end if;

  select count(*) into v_matches from public.payments where paystack_reference = p_reference;
  if v_matches <> 1 then
    -- not marked processed: a payment row that lands later can still settle
    perform public.write_audit(null,
      case when v_matches = 0 then 'PAYSTACK_UNKNOWN_REFERENCE' else 'PAYSTACK_AMBIGUOUS_REFERENCE' end,
      'payments', p_reference, null,
      jsonb_build_object('event', p_event, 'reference', p_reference, 'matches', v_matches),
      null, v_source);
    return jsonb_build_object('outcome',
      case when v_matches = 0 then 'unknown_reference' else 'ambiguous_reference' end);
  end if;

  -- §6.1: age decides abandoned and the non-final statuses. No lock yet:
  -- created_at never changes, and a not-final result takes no key.
  select * into v_payment from public.payments where paystack_reference = p_reference;
  v_age := now() - v_payment.created_at;

  v_target := case
                when p_status = 'success' then 'SUCCESS'
                -- failed is held like abandoned: Paystack Checkout lets the
                -- buyer retry a declined card on the same reference
                when p_status in ('failed', 'abandoned') and v_age >= interval '2 hours' then 'FAILED'
                when p_status in ('ongoing', 'pending', 'processing', 'queued')
                     and v_age > interval '72 hours' then 'FAILED'
              end;
  if v_target is null then
    -- the reconcile-funds sweep asks again later, after the others it owes
    if p_event = 'sweep' then
      update public.payments set last_swept_at = now() where id = v_payment.id;
    end if;
    return jsonb_build_object('outcome', 'not_final', 'status', p_status);
  end if;
  v_expired := p_status in ('ongoing', 'pending', 'processing', 'queued');

  v_prior := public.idempotency_begin(v_key, 'settle_paystack_payment',
    jsonb_build_object('event', p_event, 'reference', p_reference));
  if v_prior is not null then
    return v_prior;
  end if;

  -- §6.2: payment row, then order row
  select * into v_payment from public.payments where id = v_payment.id for update;
  select * into v_order from public.orders
   where tenant_id = v_payment.tenant_id and id = v_payment.order_id for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');

  if v_target = 'SUCCESS'
     and (p_amount_minor is distinct from (v_payment.amount * 100)::bigint
          or p_currency is distinct from v_currency) then
    perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_MISMATCH', 'payments', v_payment.id::text,
      jsonb_build_object('amount_minor', (v_payment.amount * 100)::bigint, 'currency', v_currency),
      jsonb_build_object('amount_minor', p_amount_minor, 'currency', p_currency, 'event', p_event),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key,
      jsonb_build_object('outcome', 'mismatch', 'payment_id', v_payment.id));
  end if;

  if v_payment.payment_status = v_target then
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'unchanged', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  if v_payment.payment_status = 'REFUNDED'
     or (v_payment.payment_status = 'SUCCESS' and v_target = 'FAILED') then
    perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_STATUS_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('verified_status', p_status, 'event', p_event),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  update public.payments
     set payment_status = v_target, gateway_response_payload = p_verified
   where id = v_payment.id;

  perform public.write_audit(v_payment.tenant_id, 'settle_paystack_payment', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', v_target, 'event', p_event),
    v_key, v_source, v_payment.teafair_agent_id);

  if v_target = 'FAILED' and v_expired then
    perform public.write_audit(v_payment.tenant_id, 'SWEEP_EXPIRED', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'created_at', v_payment.created_at),
      jsonb_build_object('payment_status', 'FAILED', 'verified_status', p_status, 'event', p_event),
      v_key, v_source, v_payment.teafair_agent_id);
  end if;

  v_order_out := v_order.status;

  if v_target = 'SUCCESS' then
    if v_payment.payment_status = 'FAILED' then
      perform public.write_audit(v_payment.tenant_id, 'LATE_SUCCESS', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', 'FAILED'),
        jsonb_build_object('payment_status', 'SUCCESS', 'event', p_event),
        v_key, v_source, v_payment.teafair_agent_id);
    end if;

    -- step 3: the order, ONLINE only (D1 is the web loop; field-order
    -- transitions are Spec C / D2, so a field order is left untouched).
    -- Real money wins (decision 10): a web order that cannot become PAID is
    -- left as it is and escalated, never dropped.
    if v_order.channel <> 'ONLINE' then
      null;
    elsif v_order.status = 'PENDING' then
      update public.orders set status = 'PAID' where id = v_order.id;
      v_order_out := 'PAID';
      perform public.write_audit(v_payment.tenant_id, 'settle_paystack_payment', 'orders', v_order.id::text,
        jsonb_build_object('status', 'PENDING'),
        jsonb_build_object('status', 'PAID', 'payment_id', v_payment.id, 'event', p_event),
        v_key, v_source, v_payment.teafair_agent_id);

      -- step 5: the warehouse's to-ship signal (decision 11: stock is not touched)
      insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
      select v_order.tenant_id, r.user_id, 'WEB_ORDER_PAID', 'Web order paid',
             'Order ' || v_order.public_reference || ' is paid and ready to ship.',
             jsonb_build_object('order_id', v_order.id, 'public_reference', v_order.public_reference)
        from (select w.manager_id as user_id from public.warehouses w
               where w.tenant_id = v_order.tenant_id and w.id = v_order.fulfilment_warehouse_id
              union
              select t.tm_id from public.territories t
               where t.tenant_id = v_order.tenant_id and t.id = v_order.territory_id) r
       where r.user_id is not null;
    else
      perform public.write_audit(v_payment.tenant_id, 'PAID_AFTER_CANCEL', 'orders', v_order.id::text,
        jsonb_build_object('status', v_order.status),
        jsonb_build_object('status', v_order.status, 'payment_id', v_payment.id, 'event', p_event),
        v_key, v_source, v_payment.teafair_agent_id);
      perform public.notify_tenant_zsms(v_order.tenant_id, 'WEB_ORDER_PAID_AFTER_CANCEL',
        'Paid order was cancelled',
        'Order ' || coalesce(v_order.public_reference, v_order.id::text)
          || ' was paid after it was cancelled. Refund or reinstate it.',
        jsonb_build_object('order_id', v_order.id, 'public_reference', v_order.public_reference));
    end if;

    -- step 4: the commission row copies the snapshot and is checked against
    -- the split Paystack verified. UNIQUE (tenant_id, payment_id) keeps it to one.
    if v_payment.split_subaccount_code is not null then
      v_expected := (v_payment.split_amount * 100)::bigint;
      v_comm_out := case
                      when p_split_subaccount is not distinct from v_payment.split_subaccount_code
                       and p_split_share_minor is not distinct from v_expected then 'SPLIT'
                      else 'DISPUTED'
                    end;

      insert into public.commission_records (tenant_id, order_id, payment_id, fintech_partner_id, teafair_agent_id,
                                             amount, bps_applied, paystack_subaccount_code,
                                             paystack_split_reference, status, dispute_reason)
      values (v_payment.tenant_id, v_payment.order_id, v_payment.id, v_payment.fintech_partner_id,
              v_payment.teafair_agent_id, v_payment.split_amount, v_payment.split_bps,
              v_payment.split_subaccount_code, p_transaction_id, v_comm_out,
              case when v_comm_out = 'DISPUTED' then 'SPLIT_MISMATCH' end)
      returning id into v_comm_id;

      perform public.write_audit(v_payment.tenant_id, 'settle_paystack_payment', 'commission_records', v_comm_id::text,
        null,
        jsonb_build_object('status', v_comm_out, 'payment_id', v_payment.id, 'amount', v_payment.split_amount,
                           'bps_applied', v_payment.split_bps, 'paystack_split_reference', p_transaction_id),
        v_key, v_source, v_payment.teafair_agent_id);

      if v_comm_out = 'DISPUTED' then
        perform public.write_audit(v_payment.tenant_id, 'SPLIT_MISMATCH', 'commission_records', v_comm_id::text,
          jsonb_build_object('split_subaccount', v_payment.split_subaccount_code, 'split_share_minor', v_expected),
          jsonb_build_object('split_subaccount', p_split_subaccount, 'split_share_minor', p_split_share_minor,
                             'event', p_event),
          v_key, v_source, v_payment.teafair_agent_id);
        perform public.notify_tenant_zsms(v_payment.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
          'A partner commission needs review (SPLIT_MISMATCH).',
          jsonb_build_object('commission_id', v_comm_id, 'order_id', v_payment.order_id,
                             'reason', 'SPLIT_MISMATCH'));
      end if;
    end if;
  end if;

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'updated', 'payment_id', v_payment.id, 'payment_status', v_target,
    'order_status', v_order_out, 'commission_status', v_comm_out));
end;
$$;

-- ── the reconcile-funds confirmation sweep (§7) ─────────────────────────
-- Claims up to p_limit unconfirmed payments older than 5 minutes, least
-- recently checked first (coalesce(last_swept_at, created_at)), minus those
-- the sweep has already decided (a mismatch, say), which a human now owns.
-- Every claimed row is stamped before the sweep looks at it, so it moves to
-- the back whatever happens next; SKIP LOCKED keeps overlapping runs apart.
create or replace function public.claim_unconfirmed_payments(p_limit integer)
returns table (paystack_reference text, created_at timestamptz)
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  with picked as (
    select p.id, coalesce(p.last_swept_at, p.created_at) as swept_key
      from public.payments p
     where p.payment_status in ('INITIATED', 'PROCESSING')
       and p.created_at < now() - interval '5 minutes'
       and not exists (
         select 1 from public.idempotency_logs l
          where l.key = md5('paystack:sweep:' || p.paystack_reference)::uuid
            and l.status = 'COMPLETED')
     order by coalesce(p.last_swept_at, p.created_at), p.id
     limit least(greatest(coalesce(p_limit, 50), 0), 500)
       for update of p skip locked
  ), claimed as (
    update public.payments p
       set last_swept_at = now()
      from picked
     where p.id = picked.id
    returning p.id, p.paystack_reference, p.created_at
  )
  select c.paystack_reference, c.created_at
    from claimed c join picked k on k.id = c.id
   order by k.swept_key, c.id;
$$;

revoke execute on function public.notify_tenant_zsms(uuid, text, text, text, jsonb)
  from public, anon, authenticated, service_role;
revoke execute on function public.settle_paystack_payment(text, text, text, bigint, text, jsonb, text, text, bigint)
  from public, anon, authenticated;
revoke execute on function public.claim_unconfirmed_payments(integer)
  from public, anon, authenticated;
grant execute on function public.settle_paystack_payment(text, text, text, bigint, text, jsonb, text, text, bigint)
  to service_role;
grant execute on function public.claim_unconfirmed_payments(integer) to service_role;
