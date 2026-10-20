-- Spec D1 §8.1 — commission release. Paystack settles a split commission to
-- the partner's subaccount; the settlements pass (reconcile-funds, cron)
-- lists the subaccounts with SPLIT rows older than 24 h, fetches their
-- settlements, and calls release_commission once per payment in a settlement.
-- Only SPLIT rows move (decision 9): anything else, a commission on a
-- refunded payment included, is no_match. All three are service_role only.
-- The partial index on SPLIT rows (idx_commission_records_split) already
-- exists from 20261020120100.

-- ── list: subaccounts with SPLIT rows older than 24 h ───────────────────
create or replace function public.list_unsettled_subaccounts()
returns table (subaccount_code text, oldest_at timestamptz, payment_references text[])
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.paystack_subaccount_code,
         min(c.created_at),
         array_agg(p.paystack_reference order by c.created_at, p.paystack_reference)
    from public.commission_records c
    join public.payments p on p.id = c.payment_id and p.tenant_id = c.tenant_id
   where c.status = 'SPLIT'
     and c.created_at < now() - interval '24 hours'
     and p.paystack_reference is not null
   group by c.paystack_subaccount_code
   order by min(c.created_at), c.paystack_subaccount_code;
$$;

-- ── release one commission on a settlement ──────────────────────────────
create or replace function public.release_commission(
  p_settlement_id          text,
  p_settled_at             timestamptz,
  p_reference              text,
  p_subaccount_share_minor bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key      uuid;
  v_request  jsonb;
  v_comm     public.commission_records;
  v_prior    jsonb;
  v_expected bigint;
begin
  if p_settlement_id is null or btrim(p_settlement_id) = '' then
    raise exception 'p_settlement_id is required' using errcode = 'P0001';
  end if;
  if p_reference is null or btrim(p_reference) = '' then
    raise exception 'p_reference is required' using errcode = 'P0001';
  end if;
  if p_settled_at is null then
    raise exception 'p_settled_at is required' using errcode = 'P0001';
  end if;

  v_key     := md5('paystack-settlement:' || p_settlement_id || ':' || p_reference)::uuid;
  v_request := jsonb_build_object('settlement_id', p_settlement_id, 'reference', p_reference,
                                  'share_minor', p_subaccount_share_minor);

  select c.* into v_comm
    from public.commission_records c
    join public.payments p on p.id = c.payment_id and p.tenant_id = c.tenant_id
   where p.paystack_reference = p_reference
   for update of c;

  if not found then
    return jsonb_build_object('outcome', 'no_match');
  end if;

  if v_comm.status <> 'SPLIT' then
    -- a replay of a settlement that already moved this row returns its first
    -- reply; anything else is no_match and takes no key
    if exists (select 1 from public.idempotency_logs where key = v_key) then
      return public.idempotency_begin(v_key, 'release_commission', v_request);
    end if;
    return jsonb_build_object('outcome', 'no_match');
  end if;

  v_prior := public.idempotency_begin(v_key, 'release_commission', v_request);
  if v_prior is not null then
    return v_prior;
  end if;

  v_expected := (v_comm.amount * 100)::bigint;

  -- a missing share settles on inclusion (Paystack fact F3), unverified
  if p_subaccount_share_minor is null or p_subaccount_share_minor = v_expected then
    update public.commission_records
       set status = 'SETTLED', settled_at = p_settled_at, paystack_settlement_id = p_settlement_id
     where id = v_comm.id;
    perform public.write_audit(v_comm.tenant_id, 'release_commission', 'commission_records', v_comm.id::text,
      jsonb_build_object('status', 'SPLIT'),
      jsonb_build_object('status', 'SETTLED', 'settlement_id', p_settlement_id, 'settled_at', p_settled_at,
                         'share_verified', p_subaccount_share_minor is not null),
      v_key, 'CRON', v_comm.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'settled', 'commission_id', v_comm.id, 'settlement_id', p_settlement_id));
  end if;

  update public.commission_records
     set status = 'DISPUTED', dispute_reason = 'SETTLEMENT_MISMATCH'
   where id = v_comm.id;
  perform public.write_audit(v_comm.tenant_id, 'release_commission', 'commission_records', v_comm.id::text,
    jsonb_build_object('status', 'SPLIT', 'share_minor', v_expected),
    jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'SETTLEMENT_MISMATCH',
                       'share_minor', p_subaccount_share_minor, 'settlement_id', p_settlement_id),
    v_key, 'CRON', v_comm.teafair_agent_id);
  perform public.notify_tenant_zsms(v_comm.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
    'A partner commission needs review (SETTLEMENT_MISMATCH).',
    jsonb_build_object('commission_id', v_comm.id, 'order_id', v_comm.order_id, 'reason', 'SETTLEMENT_MISMATCH'));
  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'mismatch', 'commission_id', v_comm.id, 'settlement_id', p_settlement_id));
end;
$$;

-- ── expire SPLIT rows never settled within 7 days ───────────────────────
create or replace function public.expire_unsettled_commissions()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    select c.id, c.tenant_id, c.order_id, c.teafair_agent_id
      from public.commission_records c
     where c.status = 'SPLIT' and c.created_at < now() - interval '7 days'
     order by c.id
       for update
  loop
    update public.commission_records
       set status = 'DISPUTED', dispute_reason = 'NOT_SETTLED'
     where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'expire_unsettled_commissions', 'commission_records',
      v_row.id::text, jsonb_build_object('status', 'SPLIT'),
      jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'NOT_SETTLED'),
      null, 'CRON', v_row.teafair_agent_id);
    perform public.notify_tenant_zsms(v_row.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
      'A partner commission needs review (NOT_SETTLED).',
      jsonb_build_object('commission_id', v_row.id, 'order_id', v_row.order_id, 'reason', 'NOT_SETTLED'));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.list_unsettled_subaccounts() from public, anon, authenticated;
revoke execute on function public.release_commission(text, timestamptz, text, bigint) from public, anon, authenticated;
revoke execute on function public.expire_unsettled_commissions() from public, anon, authenticated;
grant execute on function public.list_unsettled_subaccounts() to service_role;
grant execute on function public.release_commission(text, timestamptz, text, bigint) to service_role;
grant execute on function public.expire_unsettled_commissions() to service_role;
