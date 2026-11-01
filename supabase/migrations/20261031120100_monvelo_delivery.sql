-- Addendum A6 §4.4, §5 step 7 (Monvelo Step 3, Task 3) — dispatch and the
-- shop owner's delivery code.
--
--   monvelo_owner_challenges    the owner's one-time codes (DELIVERY now, REPAYMENT in Task 4)
--   dispatch_monvelo_financing  FUNDED, order PAID -> order IN_TRANSIT, stock consumed
--   start_monvelo_delivery      the database draws the owner's code (gateway proof)
--   confirm_monvelo_delivery    the right code: DELIVERED, the clock starts, the tenant ledger
--   monvelo_fee_bps_at          Teafair's fee terms valid on a day (internal)
--
-- Who acts. Dispatch: whoever passes fulfilment_can_dispatch (the LM, a ZSM of
-- the order's zone, the fulfilment warehouse's manager). The code: whoever has
-- a fulfilment_delivery_path for the order (ruling R20: start and confirm use
-- the same gate, so a code alone never confirms; the deliverer types the code
-- the owner reads out). mark_order_dispatched stays web-only (R22); dispatch
-- here consumes the order's FEFO reservations through stock_consume_order.
--
-- Codes follow start_monvelo_consent exactly: 6 digits drawn by the database,
-- bcrypt-hashed, a 10-minute TTL, 5 wrong attempts lock, 3 per hour, here
-- keyed on the financing and the purpose. They go to the shop owner's verified
-- profile phone, never the shop's contact number. The code is returned on the
-- first call only and never stored in clear; a replay carries none.
--
-- The delivery day. A6 §5 step 7: stock not delivered by 23:59 of the funding
-- day is REFUND_DUE (the sweep in Task 5), so dispatch, a new code and a
-- confirmation are all refused once the Lagos funding day has passed.
--
-- The tenant ledger (§4.4, §16.5): FUNDED_GROSS and the FEE are booked at
-- delivery, on the delivery's Lagos date, because gross is "principal funded
-- and delivered" (plan call 8). A refund before delivery needs no REFUND entry.
--
-- Tenants never see lenders (§16.2.2): the challenges have no reader at all,
-- and no audit row written here names the agent, the pledge or the payer (the
-- financing is never audited whole: it carries the lender columns).

-- ── notification_logs: a new purpose ────────────────────────────────────
alter table public.notification_logs drop constraint notification_logs_purpose_check;
alter table public.notification_logs add constraint notification_logs_purpose_check
  check (purpose in ('OTP', 'DELIVERY_CODE', 'DELIVERY_CODE_RESEND', 'PHONE_VERIFY', 'AUTH_OTP', 'MONVELO_CONSENT',
                     'MONVELO_DELIVERY'));

-- ── monvelo_owner_challenges ────────────────────────────────────────────
-- Column names follow monvelo_consent_challenges (ruling R21). repayment_id
-- gets its foreign key with monvelo_repayments (Task 4).
create table public.monvelo_owner_challenges (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  financing_id    uuid not null,
  repayment_id    uuid,
  purpose         text not null check (purpose in ('DELIVERY', 'REPAYMENT')),
  code_hash       text not null,
  expires_at      timestamptz not null,
  failed_attempts integer not null default 0 check (failed_attempts >= 0),
  consumed_at     timestamptz,
  issued_by       uuid not null references public.profiles (id) on delete restrict,
  created_at      timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  check ((purpose = 'REPAYMENT') = (repayment_id is not null))
);
create index idx_monvelo_owner_challenges_financing on public.monvelo_owner_challenges (financing_id, purpose, created_at);
create index idx_monvelo_owner_challenges_fin_fk    on public.monvelo_owner_challenges (tenant_id, financing_id);
create index idx_monvelo_owner_challenges_repayment on public.monvelo_owner_challenges (repayment_id);
create index idx_monvelo_owner_challenges_issued_by on public.monvelo_owner_challenges (issued_by);
create trigger monvelo_owner_challenges_no_delete before delete on public.monvelo_owner_challenges
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_owner_challenges_no_truncate before truncate on public.monvelo_owner_challenges
  for each statement execute function public.monvelo_no_delete();

-- no reader: RLS on and no policy, like monvelo_consent_challenges
alter table public.monvelo_owner_challenges enable row level security;
revoke all on public.monvelo_owner_challenges from anon, authenticated, service_role;

-- ── monvelo_fee_bps_at (internal) ───────────────────────────────────────
-- Fee terms are half-open [valid_from, valid_to) and never overlap
-- (monvelo_fee_terms_guard); no terms that day is 0.
create or replace function public.monvelo_fee_bps_at(p_tenant_id uuid, p_date date)
returns integer
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce((select t.fee_bps from public.monvelo_tenant_fee_terms t
                    where t.tenant_id = p_tenant_id
                      and t.valid_from <= p_date
                      and (t.valid_to is null or p_date < t.valid_to)
                    order by t.valid_from desc
                    limit 1), 0);
$$;
revoke all on function public.monvelo_fee_bps_at(uuid, date) from public, anon, authenticated, service_role;

-- ── internal: the financing in the caller's tenant, locked ──────────────
create or replace function public.monvelo_lock_financing(p_me public.tenant_users, p_financing_id uuid)
returns public.monvelo_financings
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_fin public.monvelo_financings;
begin
  select f.* into v_fin from public.monvelo_financings f
   where f.id = p_financing_id and f.tenant_id = p_me.tenant_id
     for update;
  if v_fin.id is null then
    raise exception 'not permitted to act on this financing' using errcode = '42501';
  end if;
  return v_fin;
end;
$$;
revoke all on function public.monvelo_lock_financing(public.tenant_users, uuid) from public, anon, authenticated, service_role;

-- the stock must reach the shop on the Lagos day it was funded (§5 step 7)
create or replace function public.monvelo_assert_delivery_day(p_fin public.monvelo_financings)
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if public.monvelo_today() > (p_fin.funded_at at time zone 'Africa/Lagos')::date then
    raise exception 'the funding day has passed; this financing is due a refund' using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.monvelo_assert_delivery_day(public.monvelo_financings) from public, anon, authenticated, service_role;

-- ── dispatch_monvelo_financing ──────────────────────────────────────────
create or replace function public.dispatch_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid,
                                                             p_tracking_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_fin   public.monvelo_financings;
  v_order public.orders;
  v_track text := nullif(btrim(coalesce(p_tracking_reference, '')), '');
  v_stock jsonb;
  v_reply jsonb;
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

  perform public.write_audit(v_fin.tenant_id, 'dispatch_monvelo_financing', 'monvelo_financings', v_fin.id::text,
                             jsonb_build_object('order_status', v_order.status),
                             jsonb_build_object('financing_id', v_fin.id, 'order_id', v_order.id,
                                                'order_status', 'IN_TRANSIT', 'tracking_reference', v_track,
                                                'stock', v_stock),
                             p_idempotency_key);

  v_reply := jsonb_build_object('financing_id', v_fin.id, 'order_id', v_order.id, 'order_status', 'IN_TRANSIT');
  return public.idempotency_complete(p_idempotency_key, v_reply);
end;
$$;
revoke all on function public.dispatch_monvelo_financing(uuid, uuid, text) from public, anon;
grant execute on function public.dispatch_monvelo_financing(uuid, uuid, text) to authenticated;

-- ── start_monvelo_delivery ──────────────────────────────────────────────
create or replace function public.start_monvelo_delivery(p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_ttl           constant interval := interval '10 minutes';
  c_window        constant interval := interval '1 hour';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_fin   public.monvelo_financings;
  v_order public.orders;
  v_owner uuid;
  v_phone text;
  v_draw  bigint;
  v_code  text;
  v_row   public.monvelo_owner_challenges;
  v_reply jsonb;
begin
  perform public.assert_gateway_proof(p_gateway_proof);
  -- neither the proof nor the code is part of the stored request
  v_prior := public.idempotency_begin(p_idempotency_key, 'start_monvelo_delivery',
    jsonb_build_object('financing_id', p_financing_id));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  -- the financing row lock also serialises concurrent starts under the limit
  v_fin := public.monvelo_lock_financing(v_me, p_financing_id);
  v_order := public.fulfilment_lock_order(v_me, v_fin.order_id);
  if public.fulfilment_delivery_path(v_me, v_order) is null then
    raise exception 'not permitted to deliver this order' using errcode = '42501';
  end if;
  if v_fin.status <> 'FUNDED' or v_order.status <> 'IN_TRANSIT' then
    raise exception 'only a dispatched, funded financing takes a delivery code' using errcode = 'P0001';
  end if;
  perform public.monvelo_assert_delivery_day(v_fin);

  -- the owner's own verified phone (as start_monvelo_consent), never the shop's number
  select s.owner_id into v_owner from public.retail_shops s where s.id = v_fin.shop_id;
  select p.phone_number into v_phone
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.id = v_owner and u.phone_confirmed_at is not null;
  if v_phone is null then
    raise exception 'the shop owner has no verified phone' using errcode = 'P0001';
  end if;

  if (select count(*) from public.monvelo_owner_challenges c
       where c.financing_id = v_fin.id and c.purpose = 'DELIVERY'
         and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this delivery; try again later' using errcode = 'P0001';
  end if;

  -- uniform 6 digits: a 32-bit draw, rejection-sampled below the largest
  -- multiple of 10^6 (as start_monvelo_consent and issue_otp)
  loop
    v_draw := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v_draw < 4294000000;
  end loop;
  v_code := lpad((v_draw % 1000000)::text, 6, '0');

  insert into public.monvelo_owner_challenges (tenant_id, financing_id, purpose, code_hash, expires_at, issued_by)
  values (v_fin.tenant_id, v_fin.id, 'DELIVERY', extensions.crypt(v_code, extensions.gen_salt('bf', 8)),
          now() + c_ttl, v_me.profile_id)
  returning * into v_row;

  perform public.write_audit(v_fin.tenant_id, 'start_monvelo_delivery', 'monvelo_owner_challenges', v_row.id::text,
                             null, to_jsonb(v_row) - 'code_hash', p_idempotency_key);

  v_reply := public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id', v_row.id, 'expires_at', v_row.expires_at, 'destination_phone', v_phone));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$$;
revoke all on function public.start_monvelo_delivery(uuid, text, uuid) from public, anon;
grant execute on function public.start_monvelo_delivery(uuid, text, uuid) to authenticated;

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
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('confirmed', true, 'due_at', v_due));
end;
$$;
revoke all on function public.confirm_monvelo_delivery(uuid, uuid, text) from public, anon;
grant execute on function public.confirm_monvelo_delivery(uuid, uuid, text) to authenticated;
