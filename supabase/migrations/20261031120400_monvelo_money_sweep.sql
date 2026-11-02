-- Addendum A6 §4.4, §5 step 10 (Monvelo Step 3, Task 5) — the money sweep and
-- Monvelo refunds.
--
--   monvelo_delivery_cutoff     funded_at + 23 hours: the one instant delivery stops and a refund is due (R46)
--   monvelo_sweep_money         cron monvelo-money-sweep, every 5 minutes: refund due, the late charge,
--                               unconfirmed repayments
--   apply_monvelo_refund        the Paystack refund or reversal of an MV- payment (service_role)
--   apply_paystack_refund       recreated: an MV- payment is left to apply_monvelo_refund (R47)
--
-- The sweep, in order, each loop `for update skip locked` as monvelo_sweep_offers:
--   1. FUNDED at or past the cutoff -> REFUND_DUE (user, 2026-11-01). The order is
--      CANCELLED; what is still RESERVED is released; stock already dispatched
--      (CONSUMED) comes back when the LM or CSM records its return
--      (record_order_return), so the ticket asks for that too. The rebate payable
--      goes DUE -> CANCELLED. One HIGH system ticket asks staff to refund the
--      funding in Paystack. If that funding payment was already refunded (staff
--      acted early), the financing is closed at once and no ticket is raised.
--      No tenant ledger entry: nothing is booked before delivery (Task 3).
--   2. DELIVERED, due_at passed, outstanding > 0 -> monvelo_apply_late_charge
--      (built in Task 4's migration, unchanged here): applied once ever.
--   3. Repayments PENDING for 24 hours -> EXPIRED, a REPAYMENT_UNCONFIRMED flag
--      and a HIGH system ticket for the TM (A6 §4.4).
--
-- apply_monvelo_refund follows apply_paystack_refund's rules (the same refund id
-- is applied at most once; a reversal of an unconfirmed payment makes it
-- REFUNDED; a REFUND of an unconfirmed payment takes no key so the daily pass
-- re-applies it; partial refunds change no status) with Monvelo's effects: a
-- full refund makes the payment REFUNDED; when it is the funding payment of a
-- REFUND_DUE financing, the financing is closed (closed_at). Any other payment
-- (a payer mismatch, a late or second payment) leaves its financing as it is.
-- A funding payment refunded while its financing is still live (FUNDED or
-- later) is flagged FUNDING_REFUNDED for the operator: the agent has its money
-- back while the financing runs on.
--
-- Tenants never see lenders (§16.2.2, R15): every audit row about a Monvelo
-- payment, a payable or a repayment (they name the agent or its member) is
-- written with tenant_id null; the rows about the financing and its order are
-- the tenant's and carry no lender id. Ticket bodies name the MV- reference,
-- never the agent.

-- ── R46: one cutoff for delivery and for the refund ─────────────────────
create or replace function public.monvelo_delivery_cutoff(p_funded_at timestamptz)
returns timestamptz
language sql
immutable
set search_path = public, pg_temp
as $$
  select p_funded_at + interval '23 hours';
$$;
revoke all on function public.monvelo_delivery_cutoff(timestamptz) from public, anon, authenticated, service_role;

-- recreated from 20261031120300 with the cutoff taken from the helper; message,
-- signature and grants unchanged
create or replace function public.monvelo_assert_delivery_day(p_fin public.monvelo_financings)
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if now() >= public.monvelo_delivery_cutoff(p_fin.funded_at) then
    raise exception 'the 23-hour delivery window has passed; this financing is due a refund' using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.monvelo_assert_delivery_day(public.monvelo_financings) from public, anon, authenticated, service_role;

-- ── flags: a funding refunded while its financing is live ───────────────
alter table public.monvelo_flags drop constraint monvelo_flags_kind_check;
alter table public.monvelo_flags add constraint monvelo_flags_kind_check
  check (kind in ('PAYER_MISMATCH', 'LATE_PAYMENT', 'AMOUNT_MISMATCH', 'REPAYMENT_REJECTED', 'REPAYMENT_UNCONFIRMED',
                  'FUNDING_REFUNDED'));

-- ── apply_paystack_refund: leave Monvelo payments alone (R47) ───────────
-- Recreated from its live definition (pg_get_functiondef; last written in
-- 20261029130150) with one change: right after it finds the single payment, a
-- payment linked to a Monvelo financing is audited and returned as
-- {outcome: 'monvelo_reference'} through payment_monvelo_route, with no lock,
-- no idempotency key and no other write. Defence in depth: the gateway already
-- sends MV- refunds to apply_monvelo_refund. Signature and grants unchanged, and
-- the body still names no Monvelo table (045).
CREATE OR REPLACE FUNCTION public.apply_paystack_refund(p_source text, p_refund_id text, p_transaction_reference text, p_amount_minor bigint, p_currency text, p_reason text, p_verified jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_released  integer;
  v_routed    jsonb;
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

  -- R47: a Monvelo payment is refunded by apply_monvelo_refund only; audit it
  -- and write nothing else (no lock, no key), as settle_paystack_payment's R3
  select * into v_payment from public.payments where paystack_reference = p_transaction_reference;
  v_routed := public.payment_monvelo_route(v_payment, lower(p_reason), v_source);
  if v_routed is not null then
    return v_routed;
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
    -- A6 §18.1 (Task 6b): refunded before dispatch, the reservation is released;
    -- after dispatch nothing is RESERVED, so nothing changes
    v_released := public.stock_release_order(v_order.tenant_id, v_order.id, 'REFUNDED');
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'orders', v_order.id::text,
      jsonb_build_object('status', v_order.status),
      jsonb_build_object('status', 'REFUNDED', 'payment_id', v_payment.id, 'reason', p_reason,
                         'refund_id', p_refund_id, 'reservations_released', v_released),
      v_key, v_source, v_payment.teafair_agent_id);
  end if;

  -- Paystack does not claw the share back from the subaccount: the commission
  -- becomes DISPUTED and recovery is recorded work for D3
  for v_comm in
    update public.web_commissions c
       set status = 'DISPUTED', dispute_reason = 'ORDER_REFUNDED'
      from public.web_commissions old
     where c.id = old.id
       and c.tenant_id = v_payment.tenant_id and c.payment_id = v_payment.id
       and c.status in ('SPLIT', 'SETTLED')
    returning c.id, c.order_id, old.status as old_status
  loop
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'web_commissions', v_comm.id::text,
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
$function$;

-- ── apply_monvelo_refund (service_role) ─────────────────────────────────
-- p_verified is accepted for the gateway contract but never stored, as in
-- apply_paystack_refund. The key is derived from the refund id, so the webhook
-- and the daily refund pass apply one refund once.
create or replace function public.apply_monvelo_refund(
  p_source                text,
  p_refund_id             text,
  p_transaction_reference text,
  p_amount_minor          bigint,
  p_currency              text,
  p_reason                text,
  p_verified              jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key      uuid;
  v_source   public.audit_source_enum;
  v_request  jsonb;
  v_matches  integer;
  v_payment  public.payments;
  v_fin      public.monvelo_financings;
  v_currency text;
  v_paid     bigint;
  v_conflict text;
  v_prior    jsonb;
  v_funding  boolean;
  v_closed   boolean := false;
begin
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

  v_key    := md5('monvelo-refund:' || p_refund_id)::uuid;
  v_source := case when p_source = 'sweep' then 'CRON' else 'WEBHOOK' end;
  v_request := jsonb_build_object('refund_id', p_refund_id, 'reference', p_transaction_reference,
                                  'amount_minor', p_amount_minor, 'currency', p_currency, 'reason', p_reason);

  select count(*) into v_matches from public.payments
   where paystack_reference = p_transaction_reference and monvelo_financing_id is not null;
  if v_matches <> 1 then
    v_prior := public.idempotency_begin(v_key, 'apply_monvelo_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    perform public.write_audit(null, 'MONVELO_REFUND_CONFLICT', 'payments', p_transaction_reference, null,
      jsonb_build_object('reason', 'unknown_reference', 'refund_id', p_refund_id, 'reference', p_transaction_reference,
                         'matches', v_matches, 'amount_minor', p_amount_minor, 'currency', p_currency,
                         'refund_reason', p_reason),
      v_key, v_source);
    return public.idempotency_complete(v_key, jsonb_build_object('outcome', 'conflict', 'reason', 'unknown_reference'));
  end if;

  -- payment, then financing (settle_monvelo_funding's order)
  select * into v_payment from public.payments
   where paystack_reference = p_transaction_reference and monvelo_financing_id is not null
     for update;
  select * into v_fin from public.monvelo_financings
   where tenant_id = v_payment.tenant_id and id = v_payment.monvelo_financing_id
     for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
  v_paid     := (v_payment.amount * 100)::bigint;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') and p_reason = 'REVERSAL' then
    -- reversed before it was recorded: the money is gone, so the payment is
    -- REFUNDED; it never funded anything, so the financing is left as it is
    v_prior := public.idempotency_begin(v_key, 'apply_monvelo_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    v_conflict := case
                    when p_currency is distinct from v_currency then 'currency_mismatch'
                    when p_amount_minor <> v_paid then 'amount_mismatch'
                  end;
    if v_conflict is not null then
      perform public.write_audit(null, 'MONVELO_REFUND_CONFLICT', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
        jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id, 'amount_minor', p_amount_minor,
                           'currency', p_currency, 'refund_reason', p_reason),
        v_key, v_source);
      return public.idempotency_complete(v_key, jsonb_build_object(
        'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
        'payment_status', v_payment.payment_status));
    end if;
    update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
    perform public.write_audit(null, 'apply_monvelo_refund', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'financing_id', v_fin.id),
      v_key, v_source);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
      'financing_status', v_fin.status, 'financing_closed', false, 'reason', p_reason));
  end if;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') then
    -- a REFUND before the charge is recorded: no key, so the daily refund pass
    -- re-applies it once the payment settles (as apply_paystack_refund)
    perform public.write_audit(null, 'MONVELO_REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('reason', 'payment_not_success', 'refund_id', p_refund_id, 'amount_minor', p_amount_minor,
                         'currency', p_currency, 'refund_reason', p_reason),
      null, v_source);
    return jsonb_build_object('outcome', 'conflict', 'reason', 'payment_not_success',
                              'payment_id', v_payment.id, 'payment_status', v_payment.payment_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'apply_monvelo_refund', v_request);
  if v_prior is not null then
    return v_prior;
  end if;

  v_conflict := case
                  -- REFUNDED is final, so this conflict takes its key
                  when v_payment.payment_status <> 'SUCCESS' then 'payment_not_success'
                  when p_currency is distinct from v_currency then 'currency_mismatch'
                  when p_amount_minor > v_paid then 'over_refund'
                end;
  if v_conflict is not null then
    perform public.write_audit(null, 'MONVELO_REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
      jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id, 'amount_minor', p_amount_minor,
                         'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
      'payment_status', v_payment.payment_status));
  end if;

  -- a partial refund changes no status; Monvelo staff read it in the audit
  if p_amount_minor < v_paid then
    perform public.write_audit(null, 'MONVELO_PARTIAL_REFUND', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid),
      jsonb_build_object('refund_id', p_refund_id, 'reason', p_reason, 'amount_minor', p_amount_minor,
                         'currency', p_currency, 'financing_id', v_fin.id),
      v_key, v_source);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'partial', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status,
      'amount_minor', p_amount_minor));
  end if;

  -- ── full refund or reversal ───────────────────────────────────────────
  update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
  perform public.write_audit(null, 'apply_monvelo_refund', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                       'amount_minor', p_amount_minor, 'currency', p_currency, 'financing_id', v_fin.id),
    v_key, v_source);

  -- the payment that funded the financing (settle_monvelo_funding stamps its reference)
  v_funding := v_fin.paystack_reference is not distinct from v_payment.paystack_reference;
  if v_funding and v_fin.status = 'REFUND_DUE' then
    update public.monvelo_financings set closed_at = now() where id = v_fin.id returning * into v_fin;
    v_closed := true;
    perform public.write_audit(v_fin.tenant_id, 'apply_monvelo_refund', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', v_fin.status, 'closed_at', null),
      jsonb_build_object('status', v_fin.status, 'closed_at', v_fin.closed_at, 'payment_id', v_payment.id,
                         'refund_id', p_refund_id, 'reason', p_reason),
      v_key, v_source, v_fin.raised_by);
  elsif v_funding then
    -- the agent has its money back while the financing runs on: staff decide
    perform public.monvelo_raise_flag('FUNDING_REFUNDED', v_fin.id, v_payment.monvelo_agent_id,
      jsonb_build_object('payment_id', v_payment.id, 'reference', v_payment.paystack_reference,
                         'refund_id', p_refund_id, 'amount_minor', p_amount_minor, 'reason', p_reason,
                         'financing_status', v_fin.status));
  end if;

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
    'financing_status', v_fin.status, 'financing_closed', v_closed, 'reason', p_reason));
end;
$$;
revoke all on function public.apply_monvelo_refund(text, text, text, bigint, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.apply_monvelo_refund(text, text, text, bigint, text, text, jsonb) to service_role;

-- ── monvelo_sweep_money (cron; no grants) ───────────────────────────────
create index if not exists idx_monvelo_financings_funded_open
  on public.monvelo_financings (funded_at) where status = 'FUNDED';
create index if not exists idx_monvelo_financings_delivered_due
  on public.monvelo_financings (due_at) where status = 'DELIVERED';

create or replace function public.monvelo_sweep_money()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin      public.monvelo_financings;
  v_order    public.orders;
  v_rep      public.monvelo_repayments;
  v_payable  uuid;
  v_refunded boolean;
  v_rel      integer;
  v_tkt      uuid;
  v_flag     uuid;
  v_due      integer := 0;
  v_charged  integer := 0;
  v_expired  integer := 0;
begin
  -- 1. funded, not delivered within 23 hours: REFUND_DUE (R46: the same instant
  --    monvelo_assert_delivery_day starts refusing)
  for v_fin in
    select * from public.monvelo_financings f
     where f.status = 'FUNDED' and now() >= public.monvelo_delivery_cutoff(f.funded_at)
     order by f.id
       for update skip locked
  loop
    select * into v_order from public.orders
     where tenant_id = v_fin.tenant_id and id = v_fin.order_id
       for update;
    -- staff may have refunded the funding already: then it is closed now
    v_refunded := exists (select 1 from public.payments p
                           where p.tenant_id = v_fin.tenant_id and p.monvelo_financing_id = v_fin.id
                             and p.paystack_reference = v_fin.paystack_reference and p.payment_status = 'REFUNDED');
    update public.monvelo_financings
       set status = 'REFUND_DUE', closed_at = case when v_refunded then now() end
     where id = v_fin.id;

    v_rel := null;
    if v_order.status in ('PAID', 'IN_TRANSIT') then
      update public.orders set status = 'CANCELLED' where id = v_order.id;
      -- what is still RESERVED goes back; CONSUMED stock waits for record_order_return
      v_rel := public.stock_release_order(v_order.tenant_id, v_order.id, 'CANCELLED');
    end if;

    -- no rebate is owed (§4.4); the payable names the agent, so no tenant reads its row
    for v_payable in
      update public.monvelo_rebate_payables set status = 'CANCELLED'
       where tenant_id = v_fin.tenant_id and financing_id = v_fin.id and status = 'DUE'
      returning id
    loop
      perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_rebate_payables', v_payable::text,
        jsonb_build_object('status', 'DUE'),
        jsonb_build_object('status', 'CANCELLED', 'financing_id', v_fin.id, 'reason', 'REFUND_DUE'),
        null, 'CRON');
    end loop;

    v_tkt := null;
    if not v_refunded then
      v_tkt := public.raise_system_ticket('monvelo-refund:' || v_fin.id, v_fin.order_id,
        'Refund the funding of ' || v_fin.paystack_reference || ' in Paystack.'
          || case when v_order.status = 'IN_TRANSIT' then ' The stock was dispatched: record its return.' else '' end,
        'HIGH');
    end if;

    perform public.write_audit(v_fin.tenant_id, 'monvelo_sweep_money', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'FUNDED', 'order_status', v_order.status),
      jsonb_build_object('status', 'REFUND_DUE', 'reason', 'NOT_DELIVERED_IN_23_HOURS', 'funded_at', v_fin.funded_at,
                         'order_id', v_order.id,
                         'order_status', case when v_order.status in ('PAID', 'IN_TRANSIT') then 'CANCELLED'
                                              else v_order.status end,
                         'reservations_released', v_rel, 'closed', v_refunded, 'ticket_id', v_tkt),
      null, 'CRON', v_fin.raised_by);
    v_due := v_due + 1;
  end loop;

  -- 2. due and not repaid: the one late charge (monvelo_apply_late_charge audits it)
  for v_fin in
    select * from public.monvelo_financings f
     where f.status = 'DELIVERED' and now() >= f.due_at and f.outstanding > 0
     order by f.id
       for update skip locked
  loop
    perform public.monvelo_apply_late_charge(v_fin);
    v_charged := v_charged + 1;
  end loop;

  -- 3. repayments the owner has not confirmed in 24 hours: EXPIRED, a flag and
  --    a dispute ticket for the TM (§4.4). The financing is only read: its
  --    funder and order never change once funded.
  for v_rep in
    select * from public.monvelo_repayments r
     where r.status = 'PENDING' and r.recorded_at <= now() - interval '24 hours'
     order by r.id
       for update skip locked
  loop
    select * into v_fin from public.monvelo_financings where id = v_rep.financing_id;
    update public.monvelo_repayments set status = 'EXPIRED', ended_at = now() where id = v_rep.id;
    v_flag := public.monvelo_raise_flag('REPAYMENT_UNCONFIRMED', v_fin.id, v_fin.funder_agent_id,
      jsonb_build_object('repayment_id', v_rep.id, 'amount', v_rep.amount, 'recorded_at', v_rep.recorded_at));
    -- it names the financing, never the lender
    v_tkt := public.raise_system_ticket('monvelo-repayment:' || v_rep.id, v_fin.order_id,
      format('A repayment of NGN %s recorded on Monvelo financing %s was not confirmed by the shop owner within 24 hours. Check it with the shop.',
             to_char(v_rep.amount, 'FM999,999,999,990.00'), v_fin.reference),
      'HIGH');
    -- R15: the row names the repayment and its flag (the agent), so no tenant reads it
    perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_repayments', v_rep.id::text,
      jsonb_build_object('status', 'PENDING'),
      jsonb_build_object('status', 'EXPIRED', 'reason', 'UNCONFIRMED_24_HOURS', 'financing_id', v_fin.id,
                         'flag_id', v_flag, 'ticket_id', v_tkt),
      null, 'CRON');
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('refund_due', v_due, 'late_charged', v_charged, 'repayments_expired', v_expired);
end;
$$;
revoke all on function public.monvelo_sweep_money() from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('monvelo-money-sweep', '*/5 * * * *', $$select public.monvelo_sweep_money()$$);
