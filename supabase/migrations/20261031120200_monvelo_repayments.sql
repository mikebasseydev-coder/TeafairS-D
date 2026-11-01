-- Addendum A6 §4.4, §5 steps 9–10, §7.2 (Monvelo Step 3, Task 4) — repayments,
-- limit growth and outstanding-based exposure.
--
--   monvelo_repayments          each part payment: recorded by the funder's member, confirmed by the owner's code
--   record_monvelo_repayment    the funder's member records an amount; the database draws the owner's code
--   confirm_monvelo_repayment   the recorder types the code the owner reads out: outstanding falls
--   reject_monvelo_repayment    the shop owner refuses a recorded repayment: a flag and a HIGH ticket
--   monvelo_apply_late_charge   the one late charge (internal; specified in Task 5, used here)
--   monvelo_brand_exposure      recreated: a delivered financing counts its outstanding share
--
-- Codes follow start_monvelo_delivery exactly: 6 digits drawn by the database,
-- bcrypt-hashed, a 10-minute TTL, 5 wrong attempts lock, 3 per hour keyed on
-- the financing and the purpose (R26), sent to the owner's verified profile
-- phone. The code is returned on the first call only and never stored in clear.
--
-- Rulings. R30: a code that comes back EXPIRED or LOCKED moves its repayment
-- PENDING -> EXPIRED in the same (committed, data-returning) call, and record's
-- "outstanding - pending" counts only PENDING repayments whose code is still
-- live; the Task 5 sweep expires the rest after 24 h. R31: repayments and the
-- late charge book nothing in the tenant ledger. R32: only the member who
-- recorded a repayment confirms it, while still an ACTIVE member of the funder.
-- R29: the tenant ledger holds at most one FUNDED_GROSS and one FEE per
-- financing.
--
-- The late charge (Review Focus 4): a confirmation at or after due_at on a
-- financing still DELIVERED applies the charge first, in the same transaction,
-- so a shop that pays the principal late still owes the charge.
--
-- Tenants never see lenders (§16.2.2, R15): a repayment names the lender by its
-- recorder, so the table is read only by the funder's members, the shop owner
-- and Monvelo staff, and every audit row written here that names a repayment,
-- a recorder or the agent is written with tenant_id null. The late charge's own
-- audit row names no one (source SYSTEM, no actor) and stays with the tenant.

-- ── notification_logs: a new purpose ────────────────────────────────────
alter table public.notification_logs drop constraint notification_logs_purpose_check;
alter table public.notification_logs add constraint notification_logs_purpose_check
  check (purpose in ('OTP', 'DELIVERY_CODE', 'DELIVERY_CODE_RESEND', 'PHONE_VERIFY', 'AUTH_OTP', 'MONVELO_CONSENT',
                     'MONVELO_DELIVERY', 'MONVELO_REPAYMENT'));

-- ── R29: one FUNDED_GROSS and one FEE per financing ─────────────────────
create unique index monvelo_tenant_ledger_entries_one_gross_fee
  on public.monvelo_tenant_ledger_entries (financing_id, entry_type)
  where entry_type in ('FUNDED_GROSS', 'FEE');

-- ── monvelo_repayments ──────────────────────────────────────────────────
-- challenge_id points at the repayment's own REPAYMENT code, which in turn
-- names the repayment; the foreign key is deferred so both are inserted in
-- one transaction and the repayment row is never updated to link them.
create table public.monvelo_repayments (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  financing_id uuid not null,
  amount       numeric(15,2) not null check (amount > 0),
  recorded_by  uuid not null references public.profiles (id) on delete restrict,
  recorded_at  timestamptz not null default now(),
  status       text not null default 'PENDING' check (status in ('PENDING', 'CONFIRMED', 'REJECTED', 'EXPIRED')),
  challenge_id uuid not null unique,
  confirmed_at timestamptz,
  ended_at     timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  constraint monvelo_repayments_challenge_fk
    foreign key (tenant_id, challenge_id) references public.monvelo_owner_challenges (tenant_id, id)
    on delete restrict deferrable initially deferred,
  check ((status = 'CONFIRMED') = (confirmed_at is not null)),
  check ((status = 'PENDING') = (ended_at is null))
);
create index idx_monvelo_repayments_financing   on public.monvelo_repayments (tenant_id, financing_id, status);
create index idx_monvelo_repayments_financing_id on public.monvelo_repayments (financing_id);
create index idx_monvelo_repayments_recorded_by on public.monvelo_repayments (recorded_by);
create index idx_monvelo_repayments_pending     on public.monvelo_repayments (recorded_at) where status = 'PENDING';

-- the owner's REPAYMENT code names its repayment
alter table public.monvelo_owner_challenges
  add constraint monvelo_owner_challenges_repayment_fk
    foreign key (tenant_id, repayment_id) references public.monvelo_repayments (tenant_id, id) on delete restrict;
create index idx_monvelo_owner_challenges_repayment_fk on public.monvelo_owner_challenges (tenant_id, repayment_id);

-- inserted PENDING; then one move to a final status, and nothing else changes
create or replace function public.monvelo_repayments_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'PENDING' then
      raise exception 'a repayment is recorded PENDING' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if old.status = 'PENDING' and new.status in ('CONFIRMED', 'REJECTED', 'EXPIRED')
     and (new.id, new.tenant_id, new.financing_id, new.amount, new.recorded_by, new.recorded_at, new.challenge_id)
         is not distinct from
         (old.id, old.tenant_id, old.financing_id, old.amount, old.recorded_by, old.recorded_at, old.challenge_id) then
    return new;
  end if;
  raise exception 'a repayment moves once, from PENDING to its final status' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_repayments_guard() from public, anon, authenticated, service_role;
create trigger monvelo_repayments_guard before insert or update on public.monvelo_repayments
  for each row execute function public.monvelo_repayments_guard();
create trigger monvelo_repayments_no_delete before delete on public.monvelo_repayments
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_repayments_no_truncate before truncate on public.monvelo_repayments
  for each statement execute function public.monvelo_no_delete();

-- ── grants and policy ───────────────────────────────────────────────────
alter table public.monvelo_repayments enable row level security;
revoke all on public.monvelo_repayments from anon, authenticated, service_role;
grant select on public.monvelo_repayments to authenticated;

-- the financings whose repayments the caller reads: those an agent of theirs
-- funded, and those of the shops they own (no tenant staff)
create or replace function public.my_monvelo_repayment_financing_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.id from public.monvelo_financings f
   where f.funder_agent_id in (select public.my_monvelo_agent_ids())
  union
  select f.id from public.monvelo_financings f
   where f.shop_id in (select public.my_owned_shop_ids());
$$;
revoke all on function public.my_monvelo_repayment_financing_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_monvelo_repayment_financing_ids() to authenticated;

create policy monvelo_repayments_select on public.monvelo_repayments for select to authenticated
  using (
    financing_id in (select public.my_monvelo_repayment_financing_ids())
    or (select public.is_monvelo_staff()));

-- ── monvelo_apply_late_charge (internal; Task 5 specifies it) ───────────
-- Σ per line of round(outstanding × line share × late_charge_bps), added to
-- outstanding once; DELIVERED -> DEFAULTED_WITH_LATE_CHARGE. A financing that
-- is no longer DELIVERED has had its charge (or is closed) and is returned as
-- it is, so the charge is applied once ever.
create or replace function public.monvelo_apply_late_charge(p_fin public.monvelo_financings)
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
revoke all on function public.monvelo_apply_late_charge(public.monvelo_financings)
  from public, anon, authenticated, service_role;

-- ── monvelo_brand_exposure: outstanding-based (settles Step 2 call 9) ───
-- Before delivery a financing counts its line amounts; once delivered, the
-- line's share of what is still outstanding.
create or replace function public.monvelo_brand_exposure(p_tenant_id uuid, p_shop_id uuid, p_brand_key text, p_exclude uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(case
           when f.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')
             then round(coalesce(f.outstanding, f.principal) * l.amount / f.principal, 2)
           else l.amount
         end), 0)
    from public.monvelo_financing_lines l
    join public.monvelo_financings f on f.tenant_id = l.tenant_id and f.id = l.financing_id
   where f.tenant_id = p_tenant_id and f.shop_id = p_shop_id and l.brand_key = p_brand_key
     and f.status in ('AWAITING_APPROVAL', 'OFFERED', 'CLAIMED', 'FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')
     and f.id is distinct from p_exclude;
$$;
revoke all on function public.monvelo_brand_exposure(uuid, uuid, text, uuid) from public, anon, authenticated, service_role;

-- ── record_monvelo_repayment: the funder's member ───────────────────────
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

  v_reply := public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'repayment_id', v_rep.id, 'challenge_id', v_ch.id, 'expires_at', v_ch.expires_at, 'destination_phone', v_phone));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$$;
revoke all on function public.record_monvelo_repayment(uuid, text, uuid, uuid, numeric) from public, anon;
grant execute on function public.record_monvelo_repayment(uuid, text, uuid, uuid, numeric) to authenticated;

-- ── confirm_monvelo_repayment: the recorder, with the owner's code ──────
-- A wrong, expired or locked code is returned as data and completes the
-- idempotency key, so the attempt counter and the EXPIRED move (R30) commit.
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
    v_fin := public.monvelo_apply_late_charge(v_fin);
    v_charged := true;
  end if;
  if v_rep.amount > v_fin.outstanding then
    raise exception 'the amount is more than is left to repay' using errcode = 'P0001';
  end if;

  update public.monvelo_repayments set status = 'CONFIRMED', confirmed_at = now(), ended_at = now() where id = v_rep.id;
  update public.monvelo_financings
     set outstanding = outstanding - v_rep.amount,
         status = case when outstanding - v_rep.amount > 0 then status
                       when status = 'DELIVERED' then 'REPAID_WITHIN_WINDOW'
                       else 'REPAID_LATE' end,
         closed_at = case when outstanding - v_rep.amount = 0 then now() else closed_at end
   where id = v_fin.id
  returning * into v_fin;

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
                       'late_charge_applied', v_charged, 'grown', v_grown),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('confirmed', true, 'outstanding', v_fin.outstanding, 'status', v_fin.status));
end;
$$;
revoke all on function public.confirm_monvelo_repayment(uuid, uuid, text) from public, anon;
grant execute on function public.confirm_monvelo_repayment(uuid, uuid, text) to authenticated;

-- ── reject_monvelo_repayment: the shop owner ────────────────────────────
create or replace function public.reject_monvelo_repayment(p_idempotency_key uuid, p_repayment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_prior jsonb;
  v_rep   public.monvelo_repayments;
  v_fin   public.monvelo_financings;
  v_flag  uuid;
  v_tkt   uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'reject_monvelo_repayment',
    jsonb_build_object('repayment_id', p_repayment_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_rep from public.monvelo_repayments where id = p_repayment_id for update;
  select * into v_fin from public.monvelo_financings where id = v_rep.financing_id for update;
  if v_rep.id is null
     or not exists (select 1 from public.retail_shops s where s.id = v_fin.shop_id and s.owner_id = v_uid) then
    raise exception 'only the shop owner rejects this repayment' using errcode = '42501';
  end if;
  if v_rep.status <> 'PENDING' then
    raise exception 'only a pending repayment can be rejected' using errcode = 'P0001';
  end if;

  update public.monvelo_repayments set status = 'REJECTED', ended_at = now() where id = v_rep.id;
  v_flag := public.monvelo_raise_flag('REPAYMENT_REJECTED', v_fin.id, v_fin.funder_agent_id,
    jsonb_build_object('repayment_id', v_rep.id, 'amount', v_rep.amount));
  -- the dispute ticket for the TM (§4.4): it names the financing, never the lender
  v_tkt := public.raise_system_ticket('monvelo-repayment:' || v_rep.id, v_fin.order_id,
    format('The shop owner rejected a repayment of NGN %s recorded on Monvelo financing %s. Check it with the shop.',
           to_char(v_rep.amount, 'FM999,999,999,990.00'), v_fin.reference),
    'HIGH');

  -- R15: the row names the repayment and its flag (the agent), so no tenant reads it
  perform public.write_audit(null, 'reject_monvelo_repayment', 'monvelo_repayments', v_rep.id::text,
    jsonb_build_object('status', 'PENDING'),
    jsonb_build_object('status', 'REJECTED', 'financing_id', v_fin.id, 'flag_id', v_flag, 'ticket_id', v_tkt),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('repayment_id', v_rep.id, 'status', 'REJECTED'));
end;
$$;
revoke all on function public.reject_monvelo_repayment(uuid, uuid) from public, anon;
grant execute on function public.reject_monvelo_repayment(uuid, uuid) to authenticated;
