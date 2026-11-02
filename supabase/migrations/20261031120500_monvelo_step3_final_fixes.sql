-- Monvelo Step 3, final review fixes (A6 §19; rulings R53-R58).
--
--   R53  payments.monvelo_authorization_url / monvelo_access_code (§15.3: monvelo_-named, granted to no API
--        role); record_monvelo_checkout (service_role) stores them after Paystack's Initialize; a replay of
--        start_monvelo_funding hands them back, so monvelo-fund never initialises a reference twice
--   R54  record_monvelo_repayment ends the recorder's own PENDING repayments whose code is dead; the money
--        sweep expires orphans (financing closed, or a later CONFIRMED repayment by the same recorder) with no
--        flag and no ticket
--   R56  apply_monvelo_refund resolves the monvelo-refund:<financing> ticket when the refund closes it
--   R57  start_monvelo_funding refuses an agent that is not ACTIVE
--   R58  settle_monvelo_funding's CLAIM route: no supply-day bound, by design (comment on the function)
--
-- Each function is recreated from its live definition (start_monvelo_funding 20261031120000,
-- record_monvelo_repayment 20261031120200, apply_monvelo_refund and monvelo_sweep_money 20261031120400) with
-- only the changes named; signatures and grants unchanged. monvelo_sweep_money's result gains
-- repayments_superseded (the orphans; repayments_expired keeps counting the flagged ones).

-- ── R53: the stored checkout ────────────────────────────────────────────
alter table public.payments
  add column monvelo_authorization_url text,
  add column monvelo_access_code       text,
  add constraint payments_monvelo_checkout_pair
    check (num_nulls(monvelo_authorization_url, monvelo_access_code) in (0, 2)
           and (monvelo_authorization_url is null or monvelo_financing_id is not null));
-- the column grant (20261020120100) is deliberately not re-issued: no API role reads either column

-- service_role, from monvelo-fund only, after Initialize succeeded. The key is
-- derived from the payment, so a checkout is stored once: the same values again
-- replay, other values are TF002. The audit row names the payment only (never
-- the URL or the code) and is written with tenant null, like start_monvelo_funding's.
create or replace function public.record_monvelo_checkout(p_payment_id uuid, p_authorization_url text, p_access_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key     uuid := md5('monvelo-checkout:' || coalesce(p_payment_id::text, ''))::uuid;
  v_prior   jsonb;
  v_payment public.payments;
begin
  if p_payment_id is null then
    raise exception 'not a Monvelo payment' using errcode = 'P0001';
  end if;
  if p_authorization_url is null or p_authorization_url !~ '^https://' or char_length(p_authorization_url) > 2048
     or p_access_code is null or btrim(p_access_code) = '' or char_length(p_access_code) > 256 then
    raise exception 'the checkout must be a Paystack https URL and an access code' using errcode = 'P0001';
  end if;
  v_prior := public.idempotency_begin(v_key, 'record_monvelo_checkout',
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
  if v_payment.monvelo_authorization_url is not null then
    raise exception 'this payment already has its checkout' using errcode = 'P0001';
  end if;

  update public.payments
     set monvelo_authorization_url = p_authorization_url, monvelo_access_code = p_access_code
   where id = v_payment.id;
  perform public.write_audit(null, 'record_monvelo_checkout', 'payments', v_payment.id::text,
    null, jsonb_build_object('checkout_recorded', true, 'reference', v_payment.paystack_reference),
    v_key, 'SYSTEM');

  return public.idempotency_complete(v_key, jsonb_build_object('recorded', true, 'payment_id', v_payment.id));
end;
$$;
revoke all on function public.record_monvelo_checkout(uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_monvelo_checkout(uuid, text, text) to service_role;

-- ── start_monvelo_funding: R57 and the R53 replay ───────────────────────
create or replace function public.start_monvelo_funding(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_prior    jsonb;
  v_fin      public.monvelo_financings;
  v_n        integer;
  v_ref      text;
  v_currency text;
  v_payment  public.payments;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.monvelo_agent_members m
                  where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;
  -- R57: a suspended agent starts no funding (the claim checks refuse it the same way)
  if not exists (select 1 from public.monvelo_agents a where a.id = p_agent_id and a.status = 'ACTIVE') then
    raise exception 'the agent is not active' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'start_monvelo_funding',
    jsonb_build_object('financing_id', p_financing_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    -- R53: a replay hands back the checkout the gateway stored, if it stored one
    return v_prior || jsonb_build_object('replayed', true)
        || coalesce((select jsonb_strip_nulls(jsonb_build_object('authorization_url', p.monvelo_authorization_url,
                                                                 'access_code', p.monvelo_access_code))
                       from public.payments p
                      where p.id = (v_prior ->> 'payment_id')::uuid and p.monvelo_started_by = v_uid),
                    '{}'::jsonb);
  end if;

  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id for update;
  if v_fin.id is null or v_fin.status <> 'CLAIMED' or v_fin.claimed_by_agent_id is distinct from p_agent_id then
    raise exception 'fund only a request your agent holds the claim on' using errcode = 'P0001';
  end if;
  if v_fin.claim_expires_at <= now() + interval '60 seconds' then
    raise exception 'your claim ends in under a minute; it cannot be funded now' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.orders o
                  where o.tenant_id = v_fin.tenant_id and o.id = v_fin.order_id and o.status = 'PENDING') then
    raise exception 'this request is no longer open' using errcode = 'P0001';
  end if;

  -- the financing row is locked, so n is drawn once
  select count(*) + 1 into v_n from public.payments p
   where p.tenant_id = v_fin.tenant_id and p.monvelo_financing_id = v_fin.id;
  v_ref := v_fin.reference || '-' || v_n;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_fin.tenant_id), 'NGN');

  insert into public.payments (tenant_id, order_id, customer_id, teafair_agent_id, amount, payment_status,
                               paystack_reference, monvelo_financing_id, monvelo_agent_id, monvelo_started_by)
  values (v_fin.tenant_id, v_fin.order_id, null, v_fin.raised_by, v_fin.principal, 'INITIATED',
          v_ref, v_fin.id, p_agent_id, v_uid)
  returning * into v_payment;

  -- tenant null: the actor is the agent's member, and tenants never see lenders (§16.2.2)
  perform public.write_audit(null, 'start_monvelo_funding', 'payments', v_payment.id::text, null,
    jsonb_build_object('financing_id', v_fin.id, 'reference', v_ref, 'amount', v_payment.amount),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'payment_id', v_payment.id, 'reference', v_ref, 'amount_minor', (v_fin.principal * 100)::bigint,
    'currency', v_currency, 'claim_expires_at', v_fin.claim_expires_at)) || jsonb_build_object('replayed', false);
end;
$$;
revoke all on function public.start_monvelo_funding(uuid, uuid, uuid) from public, anon;
grant execute on function public.start_monvelo_funding(uuid, uuid, uuid) to authenticated;

-- ── record_monvelo_repayment: R54 ───────────────────────────────────────
create or replace function public.record_monvelo_repayment(p_idempotency_key uuid, p_gateway_proof text,
                                                           p_financing_id uuid, p_agent_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_ttl           constant interval := interval '10 minutes';
  c_window        constant interval := interval '1 hour';
  c_max_in_window constant integer  := 3;
  c_max_attempts  constant integer  := 5;
  v_uid     uuid := (select auth.uid());
  v_prior   jsonb;
  v_fin     public.monvelo_financings;
  v_pending numeric(15,2);
  v_owner   uuid;
  v_phone   text;
  v_draw    bigint;
  v_code    text;
  v_ch_id   uuid := gen_random_uuid();
  v_rep     public.monvelo_repayments;
  v_ch      public.monvelo_owner_challenges;
  v_reply   jsonb;
  v_dead    uuid[] := '{}';
  v_old     uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  if p_agent_id is null or not exists (select 1 from public.monvelo_agent_members m
                                        where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  -- neither the proof nor the code is part of the stored request
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_repayment',
    jsonb_build_object('financing_id', p_financing_id, 'agent_id', p_agent_id, 'amount', p_amount));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  -- the financing row lock serialises records, confirmations and the code limit
  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id for update;
  if v_fin.id is null or v_fin.funder_agent_id is distinct from p_agent_id then
    raise exception 'only the funding agent records repayments on this financing' using errcode = '42501';
  end if;
  if v_fin.status not in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
    raise exception 'only a delivered financing takes repayments' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'the amount must be positive, with at most 2 decimals' using errcode = 'P0001';
  end if;

  -- R54: this recorder's own PENDING repayments on this financing whose code is
  -- dead (expired or locked) can never be confirmed: they end now, quietly (no
  -- flag, no ticket), so the money sweep does not take them for a dispute
  for v_old in
    select r.id from public.monvelo_repayments r
      join public.monvelo_owner_challenges c on c.id = r.challenge_id
     where r.tenant_id = v_fin.tenant_id and r.financing_id = v_fin.id and r.status = 'PENDING'
       and r.recorded_by = v_uid and c.consumed_at is null
       and (c.expires_at <= now() or c.failed_attempts >= c_max_attempts)
     order by r.id
       for update of r
  loop
    update public.monvelo_repayments set status = 'EXPIRED', ended_at = now() where id = v_old;
    v_dead := v_dead || v_old;
  end loop;

  -- R30: only PENDING repayments whose code is still live hold back the outstanding
  select coalesce(sum(r.amount), 0) into v_pending
    from public.monvelo_repayments r
    join public.monvelo_owner_challenges c on c.id = r.challenge_id
   where r.tenant_id = v_fin.tenant_id and r.financing_id = v_fin.id and r.status = 'PENDING'
     and c.consumed_at is null and c.expires_at > now() and c.failed_attempts < c_max_attempts;
  if p_amount > v_fin.outstanding - v_pending then
    raise exception 'the amount is more than is left to repay' using errcode = 'P0001';
  end if;

  -- the owner's own verified phone (as start_monvelo_delivery), never the shop's number
  select s.owner_id into v_owner from public.retail_shops s where s.id = v_fin.shop_id;
  select p.phone_number into v_phone
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.id = v_owner and u.phone_confirmed_at is not null;
  if v_phone is null then
    raise exception 'the shop owner has no verified phone' using errcode = 'P0001';
  end if;

  if (select count(*) from public.monvelo_owner_challenges c
       where c.financing_id = v_fin.id and c.purpose = 'REPAYMENT'
         and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this financing; try again later' using errcode = 'P0001';
  end if;

  -- uniform 6 digits (as start_monvelo_delivery)
  loop
    v_draw := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v_draw < 4294000000;
  end loop;
  v_code := lpad((v_draw % 1000000)::text, 6, '0');

  insert into public.monvelo_repayments (tenant_id, financing_id, amount, recorded_by, challenge_id)
  values (v_fin.tenant_id, v_fin.id, p_amount, v_uid, v_ch_id)
  returning * into v_rep;
  insert into public.monvelo_owner_challenges (id, tenant_id, financing_id, repayment_id, purpose, code_hash, expires_at,
                                               issued_by)
  values (v_ch_id, v_fin.tenant_id, v_fin.id, v_rep.id, 'REPAYMENT', extensions.crypt(v_code, extensions.gen_salt('bf', 8)),
          now() + c_ttl, v_uid)
  returning * into v_ch;

  -- R15: the row names the recorder, so no tenant reads it
  perform public.write_audit(null, 'record_monvelo_repayment', 'monvelo_repayments', v_rep.id::text,
    null, jsonb_build_object('financing_id', v_fin.id, 'amount', v_rep.amount, 'challenge_id', v_ch.id,
                             'expires_at', v_ch.expires_at),
    p_idempotency_key);
  -- R54, R15: one row per repayment ended here; it names the recorder's repayments, so no tenant
  foreach v_old in array v_dead loop
    perform public.write_audit(null, 'record_monvelo_repayment', 'monvelo_repayments', v_old::text,
      jsonb_build_object('status', 'PENDING'),
      jsonb_build_object('status', 'EXPIRED', 'reason', 'SUPERSEDED', 'superseded_by', v_rep.id, 'financing_id', v_fin.id),
      p_idempotency_key);
  end loop;

  v_reply := public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'repayment_id', v_rep.id, 'challenge_id', v_ch.id, 'expires_at', v_ch.expires_at, 'destination_phone', v_phone));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$$;
revoke all on function public.record_monvelo_repayment(uuid, text, uuid, uuid, numeric) from public, anon;
grant execute on function public.record_monvelo_repayment(uuid, text, uuid, uuid, numeric) to authenticated;

-- ── apply_monvelo_refund: R56 ───────────────────────────────────────────
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
  v_ticket   public.support_tickets;
  v_was      text;
  v_now      timestamptz := clock_timestamp();
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
    -- R56: the sweep's refund ticket is done; resolve it with a SYSTEM message
    -- (as raise_system_ticket writes them), so nobody refunds twice by hand
    select * into v_ticket from public.support_tickets
     where system_key = 'monvelo-refund:' || v_fin.id and status in ('OPEN', 'IN_PROGRESS')
       for update;
    if v_ticket.id is not null then
      v_was := v_ticket.status;
      update public.support_tickets
         set status = 'RESOLVED', resolved_at = v_now, last_message_at = v_now
       where id = v_ticket.id;
      insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body, created_at)
      values (v_ticket.tenant_id, v_ticket.id, 'SYSTEM', v_ticket.territory_id,
              'Refund received in Paystack; financing closed.', v_now);
      -- the ticket names the MV- reference, never the lender: the tenant's row
      perform public.write_audit(v_fin.tenant_id, 'apply_monvelo_refund', 'support_tickets', v_ticket.id::text,
        jsonb_build_object('status', v_was),
        jsonb_build_object('status', 'RESOLVED', 'financing_id', v_fin.id, 'reason', 'REFUND_RECEIVED'),
        v_key, v_source, v_fin.raised_by);
    end if;
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

-- ── monvelo_sweep_money: R54 ────────────────────────────────────────────
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
  v_quiet    integer := 0;
  v_why      text;
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
  --    funder and order never change once funded. R54: an orphan (its financing
  --    closed, or the same recorder's later repayment on it CONFIRMED) is only
  --    EXPIRED, with no flag and no ticket.
  for v_rep in
    select * from public.monvelo_repayments r
     where r.status = 'PENDING' and r.recorded_at <= now() - interval '24 hours'
     order by r.id
       for update skip locked
  loop
    select * into v_fin from public.monvelo_financings where id = v_rep.financing_id;
    update public.monvelo_repayments set status = 'EXPIRED', ended_at = now() where id = v_rep.id;
    v_why := case
               when v_fin.closed_at is not null
                    or v_fin.status in ('REPAID_WITHIN_WINDOW', 'REPAID_LATE', 'REFUND_DUE') then 'FINANCING_CLOSED'
               when exists (select 1 from public.monvelo_repayments r2
                             where r2.tenant_id = v_rep.tenant_id and r2.financing_id = v_rep.financing_id
                               and r2.recorded_by = v_rep.recorded_by and r2.status = 'CONFIRMED'
                               and r2.recorded_at > v_rep.recorded_at) then 'SUPERSEDED'
             end;
    if v_why is not null then
      -- R15: the row names the recorder's repayment, so no tenant reads it
      perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_repayments', v_rep.id::text,
        jsonb_build_object('status', 'PENDING'),
        jsonb_build_object('status', 'EXPIRED', 'reason', v_why, 'financing_id', v_fin.id),
        null, 'CRON');
      v_quiet := v_quiet + 1;
      continue;
    end if;
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

  return jsonb_build_object('refund_due', v_due, 'late_charged', v_charged, 'repayments_expired', v_expired,
                            'repayments_superseded', v_quiet);
end;
$$;
revoke all on function public.monvelo_sweep_money() from public, anon, authenticated, service_role;

-- ── R58: settle_monvelo_funding's CLAIM route ───────────────────────────
comment on function public.settle_monvelo_funding(text, text, text, bigint, text, jsonb, text) is
  'The webhook and the reconcile sweep (service_role). The CLAIM route (the paying agent still holds its claim) has '
  'no supply-day bound by design: the agent held the claim when it paid, and an unpaid trade order is cancelled by '
  'the stock sweep at its next run. The LATE route (an unclaimed request) is bounded by the supply day.';
