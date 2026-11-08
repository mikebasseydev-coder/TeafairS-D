-- Addendum A8 §6.2, §7.2 (plan Task 4): the cover starts with the goods.
--
--   monvelo_enqueue_declaration   internal: one row in the declarations outbox
--   dispatch_monvelo_financing    + GIT cover, the GIT premium payable, the
--                                   GIT_PREMIUM ledger line, a GIT_DECLARE
--   confirm_monvelo_delivery      + for AUTO_POLICY: the STORAGE premium payable,
--                                   declared_status PENDING, a STORAGE_DECLARE
--   record_monvelo_premium_paid   MONVELO_FINANCE: a premium payable DUE -> PAID
--   record_monvelo_topup_paid     MONVELO_FINANCE: a rebate top-up DUE -> PAID
--
-- dispatch_monvelo_financing and confirm_monvelo_delivery are recreated from
-- 20261031120100 (their latest bodies; 20261031120300 changed only the
-- delivery-cutoff helper they call). Signatures and grants are unchanged.
--
-- GIT is the tenant's own cover (git_cover_enabled), bought at dispatch and
-- kept on a refund. STORAGE is the agent's capital: its payable is created at
-- delivery, so a REFUND_DUE financing (never delivered) never has one.
-- Declaration payloads carry references, amounts and dates only: never a
-- shop name, a phone, an address, an account or an agent. Rows that name a
-- lender's money (the storage payable, top-ups) are audited tenant-null.

-- ── the declarations outbox writer ──────────────────────────────────────
create or replace function public.monvelo_enqueue_declaration(p_tenant_id uuid, p_kind text, p_insurer_id uuid,
  p_subject_table text, p_subject_id uuid, p_payload jsonb)
returns uuid
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'a declaration payload is an object' using errcode = 'P0001';
  end if;
  -- the insurer gets references, amounts and dates; never a person or an account
  if p_payload ?| array['phone', 'phone_number', 'contact_phone', 'shop_name', 'owner_name', 'name', 'address',
                        'address_text', 'email', 'account_number', 'settlement_account_number', 'agent_id',
                        'funder_agent_id', 'pledge_id'] then
    raise exception 'a declaration payload names no person, contact, account or lender' using errcode = 'P0001';
  end if;
  insert into public.monvelo_insurance_declarations (tenant_id, kind, insurer_id, subject_table, subject_id, payload)
  values (p_tenant_id, p_kind, p_insurer_id, p_subject_table, p_subject_id, p_payload)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.monvelo_enqueue_declaration(uuid, text, uuid, text, uuid, jsonb)
  from public, anon, authenticated, service_role;

-- ── dispatch_monvelo_financing ──────────────────────────────────────────
create or replace function public.dispatch_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid,
                                                             p_tracking_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(null);
  v_prior   jsonb;
  v_fin     public.monvelo_financings;
  v_order   public.orders;
  v_track   text := nullif(btrim(coalesce(p_tracking_reference, '')), '');
  v_stock   jsonb;
  v_reply   jsonb;
  v_at      timestamptz := now();
  v_today   date := (now() at time zone 'Africa/Lagos')::date;
  v_product public.monvelo_insurance_products;
  v_premium numeric(15,2);
  v_git     jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'dispatch_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id, 'tracking_reference', v_track));
  if v_prior is not null then
    return v_prior;
  end if;

  -- the financing, then its order (settle_monvelo_funding's order)
  v_fin := public.monvelo_lock_financing(v_me, p_financing_id);
  v_order := public.fulfilment_lock_order(v_me, v_fin.order_id);
  if not public.fulfilment_can_dispatch(v_me, v_order) then
    raise exception 'not permitted to dispatch this order' using errcode = '42501';
  end if;
  if v_fin.status <> 'FUNDED' then
    raise exception 'only a funded financing can be dispatched' using errcode = 'P0001';
  end if;
  if v_order.status <> 'PAID' then
    raise exception 'this order is not waiting for dispatch' using errcode = 'P0001';
  end if;
  perform public.monvelo_assert_delivery_day(v_fin);
  if length(v_track) > 100 then
    raise exception 'the tracking reference must be at most 100 characters' using errcode = 'P0001';
  end if;

  -- A6 §18.1: the order's reservations are consumed and the stock deducted now
  v_stock := public.stock_consume_order(v_order, v_me.profile_id);
  update public.orders set status = 'IN_TRANSIT' where id = v_order.id;

  -- A8 §6.2: goods in transit, when the tenant opted in and a GIT product is approved today
  if exists (select 1 from public.monvelo_tenant_settings s
              where s.tenant_id = v_fin.tenant_id and s.git_cover_enabled) then
    select p.* into v_product
      from public.monvelo_insurance_products p
      join public.monvelo_insurers i on i.id = p.insurer_id and i.status = 'ACTIVE'
     where p.kind = 'GIT' and p.status = 'APPROVED'
       and p.valid_from <= v_today and (p.valid_to is null or p.valid_to > v_today)
     order by p.valid_from desc, p.id
     limit 1;
    if v_product.id is not null then
      v_premium := round(v_fin.principal * v_product.rate_bps / 10000.0, 2);
    end if;
    if v_premium > 0 then
      insert into public.monvelo_order_git_cover (order_id, tenant_id, financing_id, product_id, rate_bps,
                                                  insured_value, premium)
      values (v_order.id, v_fin.tenant_id, v_fin.id, v_product.id, v_product.rate_bps, v_fin.principal, v_premium);
      insert into public.monvelo_premium_payables (tenant_id, kind, financing_id, insurer_id, amount, due_at)
      values (v_fin.tenant_id, 'GIT', v_fin.id, v_product.insurer_id, v_premium, v_at + interval '24 hours');
      insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
      values (v_fin.tenant_id, v_today, 'GIT_PREMIUM', v_fin.id, -v_premium);
      perform public.monvelo_enqueue_declaration(v_fin.tenant_id, 'GIT_DECLARE', v_product.insurer_id,
        'monvelo_order_git_cover', v_order.id,
        jsonb_build_object('financing_reference', v_fin.reference, 'order_id', v_order.id,
                           'insured_value', v_fin.principal, 'premium', v_premium,
                           'dispatched_at', v_at, 'tracking_reference', v_track));
      v_git := jsonb_build_object('product_id', v_product.id, 'rate_bps', v_product.rate_bps,
                                  'insured_value', v_fin.principal, 'premium', v_premium);
    end if;
  end if;

  perform public.write_audit(v_fin.tenant_id, 'dispatch_monvelo_financing', 'monvelo_financings', v_fin.id::text,
                             jsonb_build_object('order_status', v_order.status),
                             jsonb_build_object('financing_id', v_fin.id, 'order_id', v_order.id,
                                                'order_status', 'IN_TRANSIT', 'tracking_reference', v_track,
                                                'stock', v_stock, 'git_cover', v_git),
                             p_idempotency_key);

  v_reply := jsonb_build_object('financing_id', v_fin.id, 'order_id', v_order.id, 'order_status', 'IN_TRANSIT');
  return public.idempotency_complete(p_idempotency_key, v_reply);
end;
$$;
revoke all on function public.dispatch_monvelo_financing(uuid, uuid, text) from public, anon;
grant execute on function public.dispatch_monvelo_financing(uuid, uuid, text) to authenticated;

-- ── confirm_monvelo_delivery ────────────────────────────────────────────
-- A wrong, expired or locked code is returned as data and completes the
-- idempotency key, so the attempt counter commits; raising would roll it back.
create or replace function public.confirm_monvelo_delivery(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_me      public.tenant_users := public.assert_tenant_role(null);
  v_prior   jsonb;
  v_ch      public.monvelo_owner_challenges;
  v_fin     public.monvelo_financings;
  v_order   public.orders;
  v_days    integer;
  v_at      timestamptz;
  v_date    date;
  v_due     timestamptz;
  v_fee_bps integer;
  v_fee     numeric(15,2);
  v_cover   public.monvelo_financing_cover;
  v_insurer uuid;
  v_payable uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'confirm_monvelo_delivery',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- the challenge, then the financing, then its order
  select * into v_ch from public.monvelo_owner_challenges where id = p_challenge_id for update;
  if not found or v_ch.tenant_id <> v_me.tenant_id or v_ch.purpose <> 'DELIVERY' then
    raise exception 'unknown delivery code request' using errcode = '42501';
  end if;
  v_fin := public.monvelo_lock_financing(v_me, v_ch.financing_id);
  v_order := public.fulfilment_lock_order(v_me, v_fin.order_id);
  -- R20: only a deliverer confirms; a code alone never does
  if public.fulfilment_delivery_path(v_me, v_order) is null then
    raise exception 'not permitted to deliver this order' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the delivery code must be 6 digits' using errcode = 'P0001';
  end if;

  -- this very challenge already delivered the financing: say so again
  if v_ch.consumed_at is not null then
    return public.idempotency_complete(p_idempotency_key,
      jsonb_build_object('confirmed', true, 'due_at', v_fin.due_at));
  end if;
  if v_fin.status <> 'FUNDED' or v_order.status <> 'IN_TRANSIT' then
    raise exception 'only a dispatched, funded financing takes a delivery code' using errcode = 'P0001';
  end if;
  perform public.monvelo_assert_delivery_day(v_fin);
  if v_ch.failed_attempts >= c_max_attempts then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false, 'reason', 'LOCKED'));
  end if;
  if v_ch.expires_at <= now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false, 'reason', 'EXPIRED'));
  end if;

  if v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_owner_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(v_ch.tenant_id, 'MONVELO_DELIVERY_CODE_FAILED', 'monvelo_owner_challenges', v_ch.id::text,
                               null, jsonb_build_object('failed_attempts', v_ch.failed_attempts,
                                                        'financing_id', v_ch.financing_id),
                               p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false,
      'reason', case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end));
  end if;

  -- the right code: the clock starts
  update public.monvelo_owner_challenges set consumed_at = now() where id = v_ch.id;

  -- one due date: the shortest interest-free period across the brands (plan
  -- call 7), to the end of that Lagos day; the terms were locked at funding
  select min(l.interest_free_days) into v_days from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;
  if v_days is null then
    raise exception 'this financing has no locked terms' using errcode = 'P0001';
  end if;
  v_at := now();
  v_date := (v_at at time zone 'Africa/Lagos')::date;
  v_due := ((v_date + v_days + 1)::timestamp at time zone 'Africa/Lagos');

  update public.monvelo_financings
     set status = 'DELIVERED', delivered_at = v_at, due_at = v_due, outstanding = principal
   where id = v_fin.id;
  update public.orders set status = 'DELIVERED' where id = v_order.id;

  -- the tenant ledger, on the delivery's Lagos date (§4.4, §16.5)
  v_fee_bps := public.monvelo_fee_bps_at(v_fin.tenant_id, v_date);
  v_fee := round(v_fin.principal * v_fee_bps / 10000.0, 2);
  insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
  values (v_fin.tenant_id, v_date, 'FUNDED_GROSS', v_fin.id, v_fin.principal);
  if v_fee > 0 then
    insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
    values (v_fin.tenant_id, v_date, 'FEE', v_fin.id, -v_fee);
  end if;

  perform public.write_audit(v_fin.tenant_id, 'confirm_monvelo_delivery', 'monvelo_financings', v_fin.id::text,
                             jsonb_build_object('status', v_fin.status, 'order_status', v_order.status),
                             jsonb_build_object('status', 'DELIVERED', 'order_id', v_order.id,
                                                'order_status', 'DELIVERED', 'challenge_id', v_ch.id,
                                                'delivered_at', v_at, 'due_at', v_due, 'outstanding', v_fin.principal,
                                                'fee_bps', v_fee_bps, 'fee', v_fee),
                             p_idempotency_key);

  -- A8 §6.2: an auto-policy's storage cover starts now, paid from the agent's rebate
  select c.* into v_cover from public.monvelo_financing_cover c where c.financing_id = v_fin.id for update;
  if v_cover.cover_kind = 'AUTO_POLICY' and v_cover.storage_premium > 0 then
    select p.insurer_id into v_insurer from public.monvelo_insurance_products p where p.id = v_cover.product_id;
    insert into public.monvelo_premium_payables (tenant_id, kind, financing_id, insurer_id, amount, due_at)
    values (v_fin.tenant_id, 'STORAGE', v_fin.id, v_insurer, v_cover.storage_premium, v_at + interval '24 hours')
    returning id into v_payable;
    update public.monvelo_financing_cover set declared_status = 'PENDING' where financing_id = v_fin.id;
    perform public.monvelo_enqueue_declaration(v_fin.tenant_id, 'STORAGE_DECLARE', v_insurer,
      'monvelo_financing_cover', v_fin.id,
      jsonb_build_object('financing_reference', v_fin.reference, 'sum_insured', v_fin.principal,
                         'premium', v_cover.storage_premium, 'cover_from', v_at, 'cover_to', v_due,
                         'area_id', v_fin.area_id));
    -- the storage premium is part of the lender's rebate (§16.2.2): tenant-null
    perform public.write_audit(null, 'MONVELO_STORAGE_COVER_DUE', 'monvelo_financing_cover', v_fin.id::text,
                               jsonb_build_object('declared_status', v_cover.declared_status),
                               jsonb_build_object('declared_status', 'PENDING', 'payable_id', v_payable,
                                                  'premium', v_cover.storage_premium, 'cover_to', v_due),
                               p_idempotency_key);
  end if;

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', true, 'due_at', v_due));
end;
$$;
revoke all on function public.confirm_monvelo_delivery(uuid, uuid, text) from public, anon;
grant execute on function public.confirm_monvelo_delivery(uuid, uuid, text) to authenticated;

-- ── Teafair's finance records what it paid ──────────────────────────────
create or replace function public.record_monvelo_premium_paid(p_idempotency_key uuid, p_payable_id uuid, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_FINANCE']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_ref    text := nullif(btrim(coalesce(p_reference, '')), '');
  v_before public.monvelo_premium_payables;
  v_after  public.monvelo_premium_payables;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_premium_paid',
    jsonb_build_object('payable_id', p_payable_id, 'reference', v_ref));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_ref is null or length(v_ref) > 128 then
    raise exception 'the transfer reference is 1 to 128 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_premium_payables where id = p_payable_id for update;
  if not found then
    raise exception 'premium payable not found' using errcode = 'P0001';
  end if;
  if v_before.status <> 'DUE' then
    raise exception 'only a DUE premium can be recorded paid' using errcode = 'P0001';
  end if;
  update public.monvelo_premium_payables
     set status = 'PAID', paid_reference = v_ref, paid_by = v_uid, paid_at = now()
   where id = p_payable_id returning * into v_after;
  perform public.write_audit(null, 'record_monvelo_premium_paid', 'monvelo_premium_payables', p_payable_id::text,
                             jsonb_build_object('status', v_before.status),
                             jsonb_build_object('status', 'PAID', 'paid_reference', v_ref, 'amount', v_after.amount),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('payable_id', p_payable_id, 'status', 'PAID'));
end;
$$;
revoke all on function public.record_monvelo_premium_paid(uuid, uuid, text) from public, anon, service_role;
grant execute on function public.record_monvelo_premium_paid(uuid, uuid, text) to authenticated;

create or replace function public.record_monvelo_topup_paid(p_idempotency_key uuid, p_topup_id uuid, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_FINANCE']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_ref    text := nullif(btrim(coalesce(p_reference, '')), '');
  v_before public.monvelo_rebate_topups;
  v_after  public.monvelo_rebate_topups;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_topup_paid',
    jsonb_build_object('topup_id', p_topup_id, 'reference', v_ref));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_ref is null or length(v_ref) > 128 then
    raise exception 'the transfer reference is 1 to 128 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_rebate_topups where id = p_topup_id for update;
  if not found then
    raise exception 'rebate top-up not found' using errcode = 'P0001';
  end if;
  if v_before.status <> 'DUE' then
    raise exception 'only a DUE top-up can be recorded paid' using errcode = 'P0001';
  end if;
  update public.monvelo_rebate_topups
     set status = 'PAID', paid_reference = v_ref, paid_by = v_uid, paid_at = now()
   where id = p_topup_id returning * into v_after;
  -- a top-up names the agent (§16.2.2): tenant-null
  perform public.write_audit(null, 'record_monvelo_topup_paid', 'monvelo_rebate_topups', p_topup_id::text,
                             jsonb_build_object('status', v_before.status),
                             jsonb_build_object('status', 'PAID', 'paid_reference', v_ref, 'amount', v_after.amount),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('topup_id', p_topup_id, 'status', 'PAID'));
end;
$$;
revoke all on function public.record_monvelo_topup_paid(uuid, uuid, text) from public, anon, service_role;
grant execute on function public.record_monvelo_topup_paid(uuid, uuid, text) to authenticated;
