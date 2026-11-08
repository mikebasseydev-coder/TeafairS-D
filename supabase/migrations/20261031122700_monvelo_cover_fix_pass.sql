-- Addendum A8 pre-merge fix pass (user, 2026-11-08): the fresh review's
-- Important 1-5 and the pre-underwriter operating policy.
--
-- Policy. No storage or GIT premium is charged and no declaration is sent
-- until a live underwriter's product is approved. A MOCK insurer is not an
-- underwriter: its products count only where monvelo_platform_settings
-- .allow_mock_insurers is true (local and staging; false by default, so
-- production must leave it). MANUAL insurers are real underwriters handled by
-- hand. Until one is live every financing is NONE (the full rebate) and no
-- GIT cover is bought.
--
-- Fixes:
--   1. monvelo_settle_claim recognises at most the principal still unpaid at
--      settlement; anything the insurer paid above it is flagged
--      CLAIM_OVER_RECOVERY. A repayment while a STORAGE claim is open lowers
--      claimed_amount to the unpaid principal (claimed_amount is now mutable).
--   2. close_monvelo_insurance_claim (operator) ends a stalled open claim
--      WITHDRAWN; a rejected cover declaration rejects the REPORTED claims
--      waiting on it (REPORTED -> REJECTED is now allowed).
--   3. confirm_monvelo_repayment: a repayment that clears the principal after
--      due_at takes the late charge even with a claim open (the claim ends),
--      and a financing reaching 0 after due_at is REPAID_LATE, never
--      REPAID_WITHIN_WINDOW (DELIVERED -> REPAID_LATE is now allowed).
--   4. monvelo_lock_cover locks the shop row, re-quotes under the lock and
--      refuses a quote that moved, so two claims cannot both spend one
--      policy's room.
--   5. a rejected GIT declaration writes a GIT_PREMIUM_REVERSAL (+G) to the
--      tenant ledger, once.

-- ── the policy ──────────────────────────────────────────────────────────
alter table public.monvelo_platform_settings
  add column allow_mock_insurers boolean not null default false;

create or replace function public.monvelo_insurer_underwrites(p_insurer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.monvelo_insurers i
                  where i.id = p_insurer_id and i.status = 'ACTIVE'
                    and (i.api_provider <> 'MOCK'
                         or coalesce((select s.allow_mock_insurers from public.monvelo_platform_settings s limit 1), false)));
$$;
revoke all on function public.monvelo_insurer_underwrites(uuid) from public, anon, authenticated, service_role;

-- ── state machines ──────────────────────────────────────────────────────
drop trigger monvelo_insurance_claims_guard on public.monvelo_insurance_claims;
create trigger monvelo_insurance_claims_guard before insert or update on public.monvelo_insurance_claims
  for each row execute function public.monvelo_cover_guard('REPORTED',
    'REPORTED>FILED,REPORTED>WITHDRAWN,REPORTED>REJECTED,FILED>UNDER_REVIEW,FILED>SETTLED,FILED>REJECTED,FILED>WITHDRAWN,'
    'UNDER_REVIEW>SETTLED,UNDER_REVIEW>REJECTED,UNDER_REVIEW>WITHDRAWN',
    'claimed_amount,insurer_claim_reference,settled_amount,shortfall,late_charge_waived,payout_reference,filed_by,'
    'filed_at,settled_at,closed_reason');

-- a claim rejected with its cover was never filed
alter table public.monvelo_insurance_claims drop constraint monvelo_insurance_claims_check3;
alter table public.monvelo_insurance_claims add constraint monvelo_insurance_claims_filed_check
  check (status in ('REPORTED', 'WITHDRAWN', 'REJECTED') or filed_at is not null);

-- ── the tenant ledger: a reversal for rejected GIT cover ────────────────
alter table public.monvelo_tenant_ledger_entries drop constraint monvelo_tenant_ledger_entries_entry_type_check;
alter table public.monvelo_tenant_ledger_entries add constraint monvelo_tenant_ledger_entries_entry_type_check
  check (entry_type in ('FUNDED_GROSS', 'REBATE', 'FEE', 'REFUND', 'REMITTANCE', 'GIT_PREMIUM', 'GIT_PREMIUM_REVERSAL'));
alter table public.monvelo_tenant_ledger_entries drop constraint monvelo_tenant_ledger_entries_sign;
alter table public.monvelo_tenant_ledger_entries add constraint monvelo_tenant_ledger_entries_sign
  check ((entry_type in ('FUNDED_GROSS', 'GIT_PREMIUM_REVERSAL') and amount > 0)
         or (entry_type not in ('FUNDED_GROSS', 'GIT_PREMIUM_REVERSAL') and amount < 0));
create unique index monvelo_tenant_ledger_entries_one_git_reversal
  on public.monvelo_tenant_ledger_entries (financing_id) where entry_type = 'GIT_PREMIUM_REVERSAL';

alter table public.monvelo_flags drop constraint monvelo_flags_kind_check;
alter table public.monvelo_flags add constraint monvelo_flags_kind_check
  check (kind in ('PAYER_MISMATCH', 'LATE_PAYMENT', 'AMOUNT_MISMATCH', 'REPAYMENT_REJECTED', 'REPAYMENT_UNCONFIRMED',
                  'FUNDING_REFUNDED',
                  'DECLARATION_FAILED', 'DECLARATION_STALE', 'DECLARATION_REJECTED', 'CLAIM_SHORTFALL',
                  'CLAIM_SETTLED_AFTER_CLOSE', 'POLICY_WITHDRAWN_OPEN_FINANCING', 'PREMIUM_RECOVERY',
                  'CLAIM_OVER_RECOVERY'));

-- ── the principal still unpaid (repayments go to principal first, A6) ───
create or replace function public.monvelo_unpaid_principal(p_fin public.monvelo_financings)
returns numeric(15,2)
language sql
stable
set search_path = public, pg_temp
as $$
  select greatest(p_fin.principal - coalesce((select sum(r.amount) from public.monvelo_repayments r
                                               where r.tenant_id = p_fin.tenant_id and r.financing_id = p_fin.id
                                                 and r.status = 'CONFIRMED'), 0), 0)::numeric(15,2);
$$;
revoke all on function public.monvelo_unpaid_principal(public.monvelo_financings) from public, anon, authenticated, service_role;

-- ── 4. the shop is locked while its policy room is spent ────────────────
-- Recreated from 20261031121900. Every caller (the claim, a hold's allow, the
-- late funding route) has already taken the agent's lock and the financing;
-- the shop row comes last, so the order is the same everywhere. The quote is
-- taken again under the lock: a policy's room that a concurrent claim has
-- just used shows here, and the claim is refused (the late route turns the
-- refusal into COVER_REFUSED, as before).
create or replace function public.monvelo_lock_cover(p_quote jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin   public.monvelo_financings;
  v_again jsonb;
begin
  select * into v_fin from public.monvelo_financings where id = (p_quote ->> 'financing_id')::uuid;
  perform 1 from public.retail_shops s where s.id = v_fin.shop_id for update;
  v_again := public.monvelo_quote_agent_yield(v_fin.id);
  if (v_again ->> 'cover_kind', v_again ->> 'shop_policy_id', v_again ->> 'product_id',
      (v_again ->> 'storage_premium')::numeric, (v_again ->> 'net_rebate')::numeric)
     is distinct from
     (p_quote ->> 'cover_kind', p_quote ->> 'shop_policy_id', p_quote ->> 'product_id',
      (p_quote ->> 'storage_premium')::numeric, (p_quote ->> 'net_rebate')::numeric) then
    raise exception 'cover changed; review the new yield' using errcode = 'P0001',
      detail = 'net_yield_bps=' || (v_again ->> 'net_yield_bps');
  end if;

  insert into public.monvelo_financing_cover (financing_id, tenant_id, cover_kind, shop_policy_id, product_id,
    storage_rate_bps, blocks, storage_premium, gross_rebate, net_rebate, locked_at)
  values (v_fin.id, v_fin.tenant_id, p_quote ->> 'cover_kind', (p_quote ->> 'shop_policy_id')::uuid,
          (p_quote ->> 'product_id')::uuid, (p_quote ->> 'storage_rate_bps')::integer, (p_quote ->> 'blocks')::integer,
          (p_quote ->> 'storage_premium')::numeric, (p_quote ->> 'gross_rebate')::numeric,
          (p_quote ->> 'net_rebate')::numeric, clock_timestamp())
  on conflict (financing_id) do update
    set cover_kind = excluded.cover_kind, shop_policy_id = excluded.shop_policy_id, product_id = excluded.product_id,
        storage_rate_bps = excluded.storage_rate_bps, blocks = excluded.blocks,
        storage_premium = excluded.storage_premium, gross_rebate = excluded.gross_rebate,
        net_rebate = excluded.net_rebate, locked_at = excluded.locked_at;

  insert into public.monvelo_financing_line_cover (financing_id, brand_key, tenant_id, terms_id, rebate_bps,
    interest_free_days, late_charge_bps, gross_rebate, storage_premium, net_rebate)
  select v_fin.id, l.brand_key, v_fin.tenant_id, l.terms_id, l.rebate_bps, l.interest_free_days, l.late_charge_bps,
         l.gross_rebate, l.storage_premium, l.net_rebate
    from jsonb_to_recordset(p_quote -> 'lines') as l (brand_key text, terms_id uuid, rebate_bps integer,
         interest_free_days integer, late_charge_bps integer, gross_rebate numeric, storage_premium numeric,
         net_rebate numeric)
  on conflict (financing_id, brand_key) do update
    set terms_id = excluded.terms_id, rebate_bps = excluded.rebate_bps,
        interest_free_days = excluded.interest_free_days, late_charge_bps = excluded.late_charge_bps,
        gross_rebate = excluded.gross_rebate, storage_premium = excluded.storage_premium,
        net_rebate = excluded.net_rebate;
end;
$$;
revoke all on function public.monvelo_lock_cover(jsonb) from public, anon, authenticated, service_role;

-- ── 2. an operator closes a stalled claim ───────────────────────────────
create or replace function public.close_monvelo_insurance_claim(p_idempotency_key uuid, p_claim_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_before public.monvelo_insurance_claims;
  v_claim  public.monvelo_insurance_claims;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'close_monvelo_insurance_claim',
    jsonb_build_object('claim_id', p_claim_id, 'reason', v_reason));
  if v_prior is not null then
    return v_prior;
  end if;
  if v_reason is null or length(v_reason) not between 10 and 1000 then
    raise exception 'give a reason of 10 to 1000 characters' using errcode = 'P0001';
  end if;
  select * into v_before from public.monvelo_insurance_claims where id = p_claim_id;
  if not found then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  -- the financing first, as every other claim path
  perform 1 from public.monvelo_financings f where f.id = v_before.financing_id for update;
  select * into v_before from public.monvelo_insurance_claims where id = p_claim_id for update;
  if v_before.status not in ('REPORTED', 'FILED', 'UNDER_REVIEW') then
    raise exception 'only an open claim can be closed' using errcode = 'P0001';
  end if;
  update public.monvelo_insurance_claims set status = 'WITHDRAWN', closed_reason = v_reason
   where id = p_claim_id returning * into v_claim;
  perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'close_monvelo_insurance_claim',
                             'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', v_before.status),
                             jsonb_build_object('status', 'WITHDRAWN', 'reason', v_reason), p_idempotency_key);
  perform public.monvelo_notify_claim(v_claim);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('claim_id', v_claim.id, 'status', 'WITHDRAWN'));
end;
$$;
revoke all on function public.close_monvelo_insurance_claim(uuid, uuid, text) from public, anon, service_role;
grant execute on function public.close_monvelo_insurance_claim(uuid, uuid, text) to authenticated;

-- ── 3. DELIVERED may end REPAID_LATE (recreated from 20261031121700) ────
create or replace function public.monvelo_financings_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'REQUESTED' then
      raise exception 'a financing is created as REQUESTED' using errcode = 'P0001';
    end if;
    return new;
  end if;

  if (new.id, new.tenant_id, new.reference, new.shop_id, new.order_id, new.area_id, new.territory_id, new.raised_by,
      new.principal, new.supply_date, new.created_at)
     is distinct from
     (old.id, old.tenant_id, old.reference, old.shop_id, old.order_id, old.area_id, old.territory_id, old.raised_by,
      old.principal, old.supply_date, old.created_at) then
    raise exception 'a financing''s identity never changes' using errcode = 'P0001';
  end if;

  if new.status <> old.status and not (
       (old.status = 'REQUESTED' and new.status in ('OFFERED', 'AWAITING_APPROVAL', 'CANCELLED'))
    or (old.status = 'AWAITING_APPROVAL' and new.status in ('OFFERED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'OFFERED' and new.status in ('HELD', 'CLAIMED', 'CANCELLED', 'EXPIRED', 'FUNDED'))
    or (old.status = 'HELD' and new.status in ('CLAIMED', 'OFFERED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'CLAIMED' and new.status in ('OFFERED', 'FUNDED'))
    or (old.status = 'FUNDED' and new.status in ('DELIVERED', 'REFUND_DUE'))
    or (old.status = 'DELIVERED' and new.status in ('REPAID_WITHIN_WINDOW', 'REPAID_LATE', 'DEFAULTED_WITH_LATE_CHARGE',
                                                   'CLOSED_BY_CLAIM'))
    or (old.status = 'DEFAULTED_WITH_LATE_CHARGE' and new.status in ('REPAID_LATE', 'CLOSED_BY_CLAIM'))) then
    raise exception 'a financing cannot move from % to %', old.status, new.status using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- ── the policy: only a live underwriter's product is quoted ───────────
-- Recreated from 20261031121900; the insurer join changes only.
create or replace function public.monvelo_quote_agent_yield(p_financing_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin      public.monvelo_financings;
  v_today    date := public.monvelo_today();
  v_terms    public.monvelo_brand_terms;
  v_line     record;
  v_terms_by jsonb := '{}'::jsonb;
  v_min_days integer;
  v_blocks   integer;
  v_through  timestamptz;
  v_status   text;
  v_policy   uuid;
  v_product  public.monvelo_insurance_products;
  v_kind     text;
  v_rate     integer := 0;
  v_gross    numeric(15,2);
  v_prem     numeric(15,2);
  v_lines    jsonb := '[]'::jsonb;
  v_tg       numeric(15,2) := 0;
  v_tp       numeric(15,2) := 0;
  v_bps      integer;
begin
  select * into v_fin from public.monvelo_financings where id = p_financing_id;
  if not found then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;

  -- each brand's approved terms today (as request_monvelo_financing and A6 funding)
  for v_line in
    select l.brand, l.brand_key from public.monvelo_financing_lines l
     where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id order by l.brand_key
  loop
    v_terms := public.monvelo_terms_at(v_fin.tenant_id, v_line.brand, v_today);
    if v_terms.id is null then
      raise exception '% has no approved Monvelo terms', v_line.brand using errcode = 'P0001';
    end if;
    v_terms_by := v_terms_by || jsonb_build_object(v_line.brand_key, to_jsonb(v_terms));
  end loop;
  if v_terms_by = '{}'::jsonb then
    raise exception 'the financing has no lines' using errcode = 'P0001';
  end if;
  select min((t.value ->> 'interest_free_days')::integer) into v_min_days from jsonb_each(v_terms_by) t;
  v_blocks := ceil(v_min_days / 30.0)::integer;

  -- the latest the financing can fall due: funded on its supply day, delivered
  -- within 23 h (A6 §19), then the shortest interest-free period
  v_through := ((v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos')
               + interval '23 hours' + make_interval(days => v_min_days);
  select s.status, s.policy_id into v_status, v_policy
    from public.monvelo_shop_cover_status(v_fin.shop_id, v_through,
           case when v_fin.status in ('CLAIMED', 'FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then 0
                else v_fin.principal end) s;

  if v_status = 'VERIFIED' then
    v_kind := 'SHOP_POLICY';
  else
    select p.* into v_product
      from public.monvelo_insurance_products p
      join public.monvelo_insurers i on i.id = p.insurer_id and public.monvelo_insurer_underwrites(i.id)
     where p.kind = 'STORAGE' and p.status = 'APPROVED'
       and p.valid_from <= v_today and (p.valid_to is null or p.valid_to > v_today)
     order by p.valid_from desc, p.id
     limit 1;
    if v_product.id is not null then
      v_kind := 'AUTO_POLICY';
      v_rate := v_product.rate_bps;
      v_policy := null;
    else
      v_kind := 'NONE';
      v_policy := null;
    end if;
  end if;

  for v_line in
    select l.brand, l.brand_key, l.amount from public.monvelo_financing_lines l
     where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id order by l.brand_key
  loop
    v_gross := round(v_line.amount * ((v_terms_by -> v_line.brand_key ->> 'rebate_bps')::integer) / 10000.0, 2);
    v_prem  := round(v_line.amount * v_rate * v_blocks / 10000.0, 2);
    if v_prem > v_gross then
      raise exception 'rebate below storage premium for brand %; verify the shop''s cover', v_line.brand
        using errcode = 'P0001';
    end if;
    v_tg := v_tg + v_gross;
    v_tp := v_tp + v_prem;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'brand_key', v_line.brand_key,
      'terms_id', v_terms_by -> v_line.brand_key ->> 'id',
      'rebate_bps', (v_terms_by -> v_line.brand_key ->> 'rebate_bps')::integer,
      'interest_free_days', (v_terms_by -> v_line.brand_key ->> 'interest_free_days')::integer,
      'late_charge_bps', (v_terms_by -> v_line.brand_key ->> 'late_charge_bps')::integer,
      'gross_rebate', v_gross, 'storage_premium', v_prem, 'net_rebate', v_gross - v_prem));
  end loop;

  v_bps := floor((v_tg - v_tp) * 10000 / v_fin.principal)::integer;
  return jsonb_build_object(
    'financing_id', v_fin.id, 'cover_kind', v_kind, 'shop_policy_id', v_policy,
    'product_id', v_product.id, 'insurer_id', v_product.insurer_id, 'storage_rate_bps', v_rate,
    'blocks', v_blocks, 'gross_rebate', v_tg, 'storage_premium', v_tp, 'net_rebate', v_tg - v_tp,
    'net_yield_bps', v_bps, 'net_yield_percent', round(v_bps / 100.0, 2), 'lines', v_lines);
end;
$$;

-- Recreated from 20261031122000; the insurer join changes only.
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
      join public.monvelo_insurers i on i.id = p.insurer_id and public.monvelo_insurer_underwrites(i.id)
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

-- ── 3. the late charge: paused by an open claim, or applied now ───────
-- Recreated from 20261031122100 as two: _now applies it; the original keeps the pause.
create or replace function public.monvelo_apply_late_charge_now(p_fin public.monvelo_financings)
returns public.monvelo_financings
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_fin    public.monvelo_financings;
  v_charge numeric(15,2);
begin
  select * into v_fin from public.monvelo_financings where id = p_fin.id for update;
  if v_fin.id is null or v_fin.status <> 'DELIVERED' then
    return v_fin;
  end if;

  select coalesce(sum(round(v_fin.outstanding * l.amount / v_fin.principal * l.late_charge_bps / 10000.0, 2)), 0)
    into v_charge
    from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  update public.monvelo_financings
     set late_charge_amount = v_charge, outstanding = outstanding + v_charge,
         status = 'DEFAULTED_WITH_LATE_CHARGE'
   where id = v_fin.id
  returning * into v_fin;

  -- the rule, not a person: no actor, so the row names no lender
  perform public.write_audit(v_fin.tenant_id, 'monvelo_apply_late_charge', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'DELIVERED', 'outstanding', v_fin.outstanding - v_charge, 'late_charge_amount', 0),
    jsonb_build_object('status', v_fin.status, 'outstanding', v_fin.outstanding, 'late_charge_amount', v_charge,
                       'due_at', v_fin.due_at),
    null, 'SYSTEM', v_fin.raised_by);
  return v_fin;
end;
$$;
revoke all on function public.monvelo_apply_late_charge_now(public.monvelo_financings)
  from public, anon, authenticated, service_role;

create or replace function public.monvelo_apply_late_charge(p_fin public.monvelo_financings)
returns public.monvelo_financings
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_fin public.monvelo_financings;
begin
  -- A8 §6.4: an open STORAGE claim pauses the charge
  if public.monvelo_has_open_storage_claim(p_fin.id) then
    select * into v_fin from public.monvelo_financings where id = p_fin.id for update;
    return v_fin;
  end if;
  return public.monvelo_apply_late_charge_now(p_fin);
end;
$$;
revoke all on function public.monvelo_apply_late_charge(public.monvelo_financings)
  from public, anon, authenticated, service_role;

-- ── 1 and 3. repayments (recreated from 20261031122100) ───────────────
create or replace function public.confirm_monvelo_repayment(p_idempotency_key uuid, p_challenge_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_max_attempts constant integer := 5;
  v_uid      uuid := (select auth.uid());
  v_prior    jsonb;
  v_ch       public.monvelo_owner_challenges;
  v_rep      public.monvelo_repayments;
  v_fin      public.monvelo_financings;
  v_from     text;
  v_charged  boolean := false;
  v_settings public.monvelo_tenant_settings;
  v_line     record;
  v_limit    public.monvelo_shop_limits;
  v_new      numeric(15,2);
  v_grown    jsonb := '[]'::jsonb;
  v_reason   text;
  v_claim    uuid;
  v_withdrawn uuid[] := array[]::uuid[];
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'confirm_monvelo_repayment',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- the challenge, then its repayment, then the financing
  select * into v_ch from public.monvelo_owner_challenges where id = p_challenge_id for update;
  if not found or v_ch.purpose <> 'REPAYMENT' then
    raise exception 'unknown repayment code request' using errcode = '42501';
  end if;
  select * into v_rep from public.monvelo_repayments where id = v_ch.repayment_id for update;
  select * into v_fin from public.monvelo_financings where id = v_rep.financing_id for update;
  -- R32: the member who recorded it, still an ACTIVE member of the funder
  if v_rep.recorded_by is distinct from v_uid
     or not exists (select 1 from public.monvelo_agent_members m
                     where m.agent_id = v_fin.funder_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'only the member who recorded this repayment confirms it' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the repayment code must be 6 digits' using errcode = 'P0001';
  end if;

  -- a repayment already ended answers as it ended
  if v_rep.status = 'CONFIRMED' then
    return public.idempotency_complete(p_idempotency_key,
      jsonb_build_object('confirmed', true, 'outstanding', v_fin.outstanding, 'status', v_fin.status));
  elsif v_rep.status = 'EXPIRED' then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false, 'reason', 'EXPIRED'));
  elsif v_rep.status = 'REJECTED' then
    raise exception 'the shop owner rejected this repayment' using errcode = 'P0001';
  end if;

  if v_ch.failed_attempts >= c_max_attempts then
    v_reason := 'LOCKED';
  elsif v_ch.expires_at <= now() then
    v_reason := 'EXPIRED';
  elsif v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_owner_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(null, 'MONVELO_REPAYMENT_CODE_FAILED', 'monvelo_owner_challenges', v_ch.id::text,
      null, jsonb_build_object('failed_attempts', v_ch.failed_attempts, 'repayment_id', v_rep.id,
                               'financing_id', v_fin.id),
      p_idempotency_key);
    v_reason := case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end;
  end if;

  if v_reason is not null then
    -- R30: a code that can no longer confirm ends its repayment
    if v_reason in ('LOCKED', 'EXPIRED') then
      update public.monvelo_repayments set status = 'EXPIRED', ended_at = now() where id = v_rep.id;
      perform public.write_audit(null, 'confirm_monvelo_repayment', 'monvelo_repayments', v_rep.id::text,
        jsonb_build_object('status', 'PENDING'), jsonb_build_object('status', 'EXPIRED', 'reason', v_reason),
        p_idempotency_key);
    end if;
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', false, 'reason', v_reason));
  end if;

  -- the right code
  if v_fin.status not in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
    raise exception 'this financing takes no more repayments' using errcode = 'P0001';
  end if;
  update public.monvelo_owner_challenges set consumed_at = now() where id = v_ch.id;
  v_from := v_fin.status;

  -- Review Focus 4: past due_at and still uncharged, the charge comes first
  if v_fin.status = 'DELIVERED' and now() >= v_fin.due_at then
    -- A8 §6.4: an open STORAGE claim holds the charge back while principal is
    -- unpaid; a repayment that clears the principal ends the claim, so the
    -- charge applies (fix pass: a claim never buys a late repayment)
    if v_rep.amount >= public.monvelo_unpaid_principal(v_fin) then
      v_fin := public.monvelo_apply_late_charge_now(v_fin);
    else
      v_fin := public.monvelo_apply_late_charge(v_fin);
    end if;
    v_charged := v_fin.status = 'DEFAULTED_WITH_LATE_CHARGE';
  end if;
  if v_rep.amount > v_fin.outstanding then
    raise exception 'the amount is more than is left to repay' using errcode = 'P0001';
  end if;

  update public.monvelo_repayments set status = 'CONFIRMED', confirmed_at = now(), ended_at = now() where id = v_rep.id;
  update public.monvelo_financings
     set outstanding = outstanding - v_rep.amount,
         status = case when outstanding - v_rep.amount > 0 then status
                       when status = 'DELIVERED' and now() < due_at then 'REPAID_WITHIN_WINDOW'
                       else 'REPAID_LATE' end,
         closed_at = case when outstanding - v_rep.amount = 0 then now() else closed_at end
   where id = v_fin.id
  returning * into v_fin;

  -- A8 §6.4: the principal repaid, an open STORAGE claim has nothing left to
  -- cover; otherwise it claims only what is still unpaid (fix pass)
  if public.monvelo_unpaid_principal(v_fin) = 0 then
    for v_claim in
      update public.monvelo_insurance_claims set status = 'WITHDRAWN', closed_reason = 'repaid in full'
       where financing_id = v_fin.id and kind = 'STORAGE' and status in ('REPORTED', 'FILED', 'UNDER_REVIEW')
      returning id
    loop
      v_withdrawn := v_withdrawn || v_claim;
      -- R15: a STORAGE claim names the lender: tenant-null
      perform public.write_audit(null, 'confirm_monvelo_repayment', 'monvelo_insurance_claims', v_claim::text,
        null, jsonb_build_object('status', 'WITHDRAWN', 'reason', 'REPAID_IN_FULL', 'financing_id', v_fin.id),
        p_idempotency_key);
      perform public.monvelo_notify_claim((select c from public.monvelo_insurance_claims c where c.id = v_claim));
    end loop;
  else
    update public.monvelo_insurance_claims c set claimed_amount = public.monvelo_unpaid_principal(v_fin)
     where c.financing_id = v_fin.id and c.kind = 'STORAGE' and c.status in ('REPORTED', 'FILED', 'UNDER_REVIEW')
       and c.claimed_amount > public.monvelo_unpaid_principal(v_fin);
  end if;

  -- §7.2: repaid within the window, each brand's limit grows, capped by max_limit
  if v_fin.status = 'REPAID_WITHIN_WINDOW' then
    select * into v_settings from public.monvelo_tenant_settings where tenant_id = v_fin.tenant_id;
    if coalesce(v_settings.limit_growth_bps, 0) > 0 then
      for v_line in
        select l.brand_key from public.monvelo_financing_lines l
         where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id
         order by l.brand_key
      loop
        v_limit := public.monvelo_shop_limit_for(v_fin.tenant_id, v_fin.shop_id, v_line.brand_key);
        v_new := round(v_limit.limit_amount * (10000 + v_settings.limit_growth_bps) / 10000.0, 2);
        if v_settings.max_limit is not null then
          v_new := least(v_new, v_settings.max_limit);
        end if;
        if v_new > v_limit.limit_amount then
          update public.monvelo_shop_limits set limit_amount = v_new
           where tenant_id = v_fin.tenant_id and shop_id = v_fin.shop_id and brand_key = v_line.brand_key;
          insert into public.monvelo_shop_limit_events (tenant_id, shop_id, brand_key, kind, old_limit, new_limit, financing_id)
          values (v_fin.tenant_id, v_fin.shop_id, v_line.brand_key, 'GROWN', v_limit.limit_amount, v_new, v_fin.id);
          v_grown := v_grown || jsonb_build_object('brand_key', v_line.brand_key, 'old_limit', v_limit.limit_amount,
                                                   'new_limit', v_new);
        end if;
      end loop;
    end if;
  end if;

  -- R15: the row names the recorder, so no tenant reads it
  perform public.write_audit(null, 'confirm_monvelo_repayment', 'monvelo_repayments', v_rep.id::text,
    jsonb_build_object('status', 'PENDING', 'financing_status', v_from),
    jsonb_build_object('status', 'CONFIRMED', 'financing_id', v_fin.id, 'amount', v_rep.amount,
                       'outstanding', v_fin.outstanding, 'financing_status', v_fin.status,
                       'late_charge_applied', v_charged, 'grown', v_grown,
                       'claims_withdrawn', to_jsonb(v_withdrawn)),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('confirmed', true, 'outstanding', v_fin.outstanding, 'status', v_fin.status));
end;
$$;
revoke all on function public.confirm_monvelo_repayment(uuid, uuid, text) from public, anon;
grant execute on function public.confirm_monvelo_repayment(uuid, uuid, text) to authenticated;

-- ── 1. the settlement cap (recreated from 20261031122100) ─────────────
create or replace function public.monvelo_settle_claim(p_claim_id uuid, p_settled_amount numeric,
                                                       p_payout_reference text, p_actor uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ref    text := nullif(btrim(coalesce(p_payout_reference, '')), '');
  v_src    public.audit_source_enum := case when p_actor is null then 'WEBHOOK' else 'USER' end;
  v_claim  public.monvelo_insurance_claims;
  v_fin    public.monvelo_financings;
  v_closed boolean := false;
  v_waived numeric(15,2);
  v_flag   uuid;
  v_cap    numeric(15,2);
  v_paid   numeric(15,2);
  v_over   uuid;
begin
  select * into v_claim from public.monvelo_insurance_claims where id = p_claim_id;
  if not found then
    raise exception 'claim not found' using errcode = 'P0001';
  end if;
  if p_settled_amount is null or p_settled_amount < 0 or p_settled_amount <> round(p_settled_amount, 2) then
    raise exception 'the settled amount must be zero or more, with at most 2 decimals' using errcode = 'P0001';
  end if;
  if v_ref is null or length(v_ref) > 128 then
    raise exception 'the payout reference is 1 to 128 characters' using errcode = 'P0001';
  end if;
  select * into v_fin from public.monvelo_financings where id = v_claim.financing_id for update;
  select * into v_claim from public.monvelo_insurance_claims where id = p_claim_id for update;

  if v_claim.status not in ('FILED', 'UNDER_REVIEW') then
    v_flag := public.monvelo_raise_flag('CLAIM_SETTLED_AFTER_CLOSE', v_fin.id, v_claim.payee_agent_id,
      jsonb_build_object('claim_id', v_claim.id, 'claim_status', v_claim.status,
                         'settled_amount', p_settled_amount, 'payout_reference', v_ref));
    perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'monvelo_settle_claim',
                               'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', v_claim.status),
                               jsonb_build_object('status', v_claim.status, 'ignored', true, 'flag_id', v_flag,
                                                  'settled_amount', p_settled_amount),
                               null, v_src);
    return jsonb_build_object('claim_id', v_claim.id, 'ignored', true, 'status', v_claim.status);
  end if;
  -- fix pass: a STORAGE settlement is recognised up to the principal still
  -- unpaid now (a repayment may have landed since the report); the insurer's
  -- excess is flagged for recovery, never credited to the agent's loan
  v_paid := p_settled_amount;
  v_cap := case when v_claim.kind = 'STORAGE' then least(v_claim.claimed_amount, public.monvelo_unpaid_principal(v_fin))
                else v_claim.claimed_amount end;
  if v_paid > v_cap then
    v_over := public.monvelo_raise_flag('CLAIM_OVER_RECOVERY', v_fin.id, v_claim.payee_agent_id,
      jsonb_build_object('claim_id', v_claim.id, 'insurer_paid', v_paid, 'recognised', v_cap,
                         'excess', v_paid - v_cap, 'payout_reference', v_ref));
  end if;

  if v_claim.kind = 'STORAGE' and v_fin.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE') then
    v_waived := v_fin.late_charge_amount;
    update public.monvelo_financings
       set status = 'CLOSED_BY_CLAIM', outstanding = 0, closed_at = now()
     where id = v_fin.id;
    v_closed := true;
  end if;
  update public.monvelo_insurance_claims
     set status = 'SETTLED', settled_amount = least(v_paid, v_cap), settled_at = now(), payout_reference = v_ref,
         late_charge_waived = v_waived
   where id = v_claim.id returning * into v_claim;

  if v_claim.kind = 'STORAGE' and v_claim.shortfall > 0 then
    v_flag := public.monvelo_raise_flag('CLAIM_SHORTFALL', v_fin.id, v_claim.payee_agent_id,
      jsonb_build_object('claim_id', v_claim.id, 'claimed_amount', v_claim.claimed_amount,
                         'settled_amount', v_claim.settled_amount, 'shortfall', v_claim.shortfall));
  end if;

  -- a STORAGE settlement names the lender's money: tenant-null, the financing's row too
  perform public.write_audit(case v_claim.kind when 'GIT' then v_claim.tenant_id end, 'monvelo_settle_claim',
                             'monvelo_insurance_claims', v_claim.id::text, jsonb_build_object('status', 'FILED'),
                             jsonb_build_object('status', 'SETTLED', 'settled_amount', v_claim.settled_amount,
                                                'shortfall', v_claim.shortfall, 'payout_reference', v_ref,
                                                'late_charge_waived', v_waived, 'flag_id', v_flag,
                                                'insurer_paid', v_paid, 'over_recovery_flag_id', v_over),
                             null, v_src);
  if v_closed then
    perform public.write_audit(null, 'monvelo_settle_claim', 'monvelo_financings', v_fin.id::text,
                               jsonb_build_object('status', v_fin.status, 'outstanding', v_fin.outstanding),
                               jsonb_build_object('status', 'CLOSED_BY_CLAIM', 'outstanding', 0, 'claim_id', v_claim.id,
                                                  'late_charge_waived', v_waived),
                               null, v_src);
  end if;
  perform public.monvelo_notify_claim(v_claim);
  return jsonb_build_object('claim_id', v_claim.id, 'status', 'SETTLED', 'settled_amount', v_claim.settled_amount,
                            'shortfall', v_claim.shortfall,
                            'financing_status', case when v_closed then 'CLOSED_BY_CLAIM' else v_fin.status end);
end;
$$;
revoke all on function public.monvelo_settle_claim(uuid, numeric, text, uuid) from public, anon, authenticated, service_role;

-- ── 2 and 5. declaration outcomes (recreated from 20261031122600) ─────
create or replace function public.monvelo_apply_declaration_outcome(p_id uuid, p_outcome text, p_insurer_reference text,
                                                                    p_error text, p_actor uuid)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ref     text := nullif(btrim(coalesce(p_insurer_reference, '')), '');
  v_err     text := left(nullif(btrim(coalesce(p_error, '')), ''), 2000);
  v_src     public.audit_source_enum := case when p_actor is null then 'SYSTEM' else 'USER' end;
  v_decl    public.monvelo_insurance_declarations;
  v_fin     public.monvelo_financings;
  v_fin_id  uuid;
  v_cover   public.monvelo_financing_cover;
  v_pay     public.monvelo_premium_payables;
  v_claim   public.monvelo_insurance_claims;
  v_flag    uuid;
  v_topup   uuid;
  v_next    timestamptz;
begin
  if p_outcome is null or p_outcome not in ('ACCEPTED', 'REJECTED', 'RETRY') then
    raise exception 'an outcome is ACCEPTED, REJECTED or RETRY' using errcode = 'P0001';
  end if;
  if length(v_ref) > 128 then
    raise exception 'the insurer''s reference must be at most 128 characters' using errcode = 'P0001';
  end if;
  select * into v_decl from public.monvelo_insurance_declarations where id = p_id;
  if not found then
    raise exception 'declaration not found' using errcode = 'P0001';
  end if;
  v_fin_id := public.monvelo_declaration_financing(v_decl);
  -- lock order: the financing (as the claim and repayment paths), then the declaration
  if v_fin_id is not null then
    select * into v_fin from public.monvelo_financings where id = v_fin_id for update;
  end if;
  select * into v_decl from public.monvelo_insurance_declarations where id = p_id for update;
  -- final review: a FAILED row (24 hours of retries) is answered only by an
  -- operator recording what the insurer said; the declare function never reopens it
  if not (v_decl.status in ('PENDING', 'SENDING')
          or (v_decl.status = 'FAILED' and p_actor is not null and p_outcome in ('ACCEPTED', 'REJECTED'))) then
    return jsonb_build_object('declaration_id', v_decl.id, 'ignored', true, 'status', v_decl.status);
  end if;

  if p_outcome = 'RETRY' then
    if now() >= v_decl.created_at + interval '24 hours' then
      update public.monvelo_insurance_declarations
         set status = 'FAILED', last_error = coalesce(v_err, last_error), completed_at = now()
       where id = v_decl.id;
      v_flag := public.monvelo_raise_flag('DECLARATION_FAILED', v_fin_id, v_fin.funder_agent_id,
        jsonb_build_object('declaration_id', v_decl.id, 'kind', v_decl.kind, 'attempts', v_decl.attempts,
                           'last_error', coalesce(v_err, v_decl.last_error)));
      return jsonb_build_object('declaration_id', v_decl.id, 'status', 'FAILED', 'flag_id', v_flag);
    end if;
    v_next := now() + least(make_interval(mins => power(2, least(v_decl.attempts, 16))::integer), interval '6 hours');
    update public.monvelo_insurance_declarations
       set status = 'PENDING', next_attempt_at = v_next, last_error = coalesce(v_err, last_error)
     where id = v_decl.id;
    return jsonb_build_object('declaration_id', v_decl.id, 'status', 'PENDING', 'next_attempt_at', v_next);
  end if;

  update public.monvelo_insurance_declarations
     set status = p_outcome, insurer_reference = coalesce(v_ref, insurer_reference),
         last_error = case when p_outcome = 'REJECTED' then coalesce(v_err, last_error) else last_error end,
         completed_at = now()
   where id = v_decl.id;

  if v_decl.kind = 'STORAGE_DECLARE' then
    select * into v_cover from public.monvelo_financing_cover where financing_id = v_decl.subject_id for update;
    if v_cover.declared_status = 'PENDING' then
      update public.monvelo_financing_cover set declared_status = p_outcome where financing_id = v_cover.financing_id;
    end if;
    if p_outcome = 'REJECTED' and v_cover.declared_status = 'PENDING' then
      -- §6.4: the agent paid for cover that does not exist
      select * into v_pay from public.monvelo_premium_payables
       where financing_id = v_cover.financing_id and kind = 'STORAGE' for update;
      if v_pay.status = 'DUE' then
        update public.monvelo_premium_payables set status = 'CANCELLED' where id = v_pay.id;
      elsif v_pay.status = 'PAID' then
        perform public.monvelo_raise_flag('PREMIUM_RECOVERY', v_fin.id, v_fin.funder_agent_id,
          jsonb_build_object('declaration_id', v_decl.id, 'payable_id', v_pay.id, 'amount', v_pay.amount,
                             'paid_reference', v_pay.paid_reference));
      end if;
      insert into public.monvelo_rebate_topups (tenant_id, financing_id, agent_id, amount, reason, due_at)
      values (v_fin.tenant_id, v_fin.id, v_fin.funder_agent_id, v_cover.storage_premium, 'DECLARATION_REJECTED',
              now() + interval '24 hours')
      on conflict (financing_id, reason) do nothing
      returning id into v_topup;
      v_flag := public.monvelo_raise_flag('DECLARATION_REJECTED', v_fin.id, v_fin.funder_agent_id,
        jsonb_build_object('declaration_id', v_decl.id, 'kind', v_decl.kind, 'reason', v_err, 'topup_id', v_topup));
      -- the agent's members (tenant-null, §16.2.2) and every operator
      insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
      select null, r.profile_id, 'MONVELO_COVER_REJECTED', 'Stock cover declined',
             'The insurer declined the stock cover on ' || v_fin.reference
               || '. The financing continues uncovered; the premium is returned to the agent.',
             jsonb_build_object('financing_id', v_fin.id, 'reference', v_fin.reference, 'topup_id', v_topup)
        from (select m.profile_id from public.monvelo_agent_members m
               where m.agent_id = v_fin.funder_agent_id and m.status = 'ACTIVE'
              union
              select p.id from public.profiles p where p.platform_role = 'MONVELO_OPERATOR') r;
      -- fix pass: a loss reported against this cover can never be filed: it ends with it
      for v_claim in
        update public.monvelo_insurance_claims
           set status = 'REJECTED', closed_reason = 'the insurer rejected the stock cover'
         where financing_id = v_fin.id and kind = 'STORAGE' and status = 'REPORTED'
        returning *
      loop
        perform public.monvelo_notify_claim(v_claim);
      end loop;
    end if;
  elsif v_decl.kind = 'GIT_DECLARE' then
    update public.monvelo_order_git_cover set declared_status = p_outcome
     where order_id = v_decl.subject_id and declared_status = 'PENDING';
    if p_outcome = 'REJECTED' then
      select * into v_pay from public.monvelo_premium_payables
       where financing_id = v_fin_id and kind = 'GIT' for update;
      if v_pay.status = 'DUE' then
        update public.monvelo_premium_payables set status = 'CANCELLED' where id = v_pay.id;
      elsif v_pay.status = 'PAID' then
        perform public.monvelo_raise_flag('PREMIUM_RECOVERY', v_fin_id, null,
          jsonb_build_object('declaration_id', v_decl.id, 'payable_id', v_pay.id, 'amount', v_pay.amount));
      end if;
      v_flag := public.monvelo_raise_flag('DECLARATION_REJECTED', v_fin_id, null,
        jsonb_build_object('declaration_id', v_decl.id, 'kind', v_decl.kind, 'reason', v_err));
      -- fix pass: no cover, no charge: the tenant's GIT_PREMIUM is reversed, once
      insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
      select l.tenant_id, public.monvelo_today(), 'GIT_PREMIUM_REVERSAL', l.financing_id, -l.amount
        from public.monvelo_tenant_ledger_entries l
       where l.financing_id = v_fin_id and l.entry_type = 'GIT_PREMIUM'
      on conflict do nothing;
      for v_claim in
        update public.monvelo_insurance_claims
           set status = 'REJECTED', closed_reason = 'the insurer rejected the transit cover'
         where financing_id = v_fin_id and kind = 'GIT' and status = 'REPORTED'
        returning *
      loop
        perform public.monvelo_notify_claim(v_claim);
      end loop;
    end if;
  elsif v_decl.kind = 'CLAIM_FILE' then
    select * into v_claim from public.monvelo_insurance_claims where id = v_decl.subject_id for update;
    if v_claim.status in ('FILED', 'UNDER_REVIEW') then
      update public.monvelo_insurance_claims
         set insurer_claim_reference = coalesce(v_ref, insurer_claim_reference),
             status = case when p_outcome = 'REJECTED' then 'REJECTED' else status end,
             closed_reason = case when p_outcome = 'REJECTED' then coalesce(v_err, 'rejected by the insurer')
                                  else closed_reason end
       where id = v_claim.id returning * into v_claim;
      perform public.monvelo_notify_claim(v_claim);
    end if;
  end if;

  -- declarations carry no tenant reader; the row is tenant-null (STORAGE and claims name the lender)
  perform public.write_audit(null, 'monvelo_declaration_outcome', 'monvelo_insurance_declarations', v_decl.id::text,
                             jsonb_build_object('status', v_decl.status),
                             jsonb_build_object('status', p_outcome, 'kind', v_decl.kind, 'insurer_reference', v_ref,
                                                'flag_id', v_flag, 'topup_id', v_topup),
                             null, v_src);
  return jsonb_build_object('declaration_id', v_decl.id, 'status', p_outcome);
end;
$$;
revoke all on function public.monvelo_apply_declaration_outcome(uuid, text, text, text, uuid)
  from public, anon, authenticated, service_role;
