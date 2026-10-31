-- Addendum A6 §4.4, §6.2, §7.4, §11 F1 (Monvelo Step 3, Task 1) — funding.
--
-- An agent's member starts a Paystack payment for the financing its agent has
-- claimed (start_monvelo_funding). The webhook or the reconcile sweep then calls
-- settle_monvelo_funding with Paystack's Verify data. A verified transfer from
-- the agent's own settlement account (F1: transfer channel, the last four digits
-- of the masked sender account, and the holder's name) moves the financing to
-- FUNDED, locks each line's terms, debits the pledge once, moves the trade order
-- PENDING -> PAID (so the stock sweep, which cancels PENDING orders only, leaves
-- it alone) and creates the rebate Teafair owes the agent, due in 24 hours.
-- Anything else is flagged for the operator and the money is refunded in
-- Paystack by staff, as D1 does.
--
-- F1 gap (recorded): two accounts with the same holder name and the same last
-- four digits cannot be told apart; Paystack masks the rest of the number.
--
-- Tenants never see or steer lenders (A6 §16.2.2): the payments columns naming
-- the financing and the agent are not granted to the API; payables are read by
-- the agent's members and Monvelo staff, flags by Monvelo staff only; and no
-- audit row written here names the agent, the pledge or the payer.
--
-- Rulings: R1 adds OFFERED -> FUNDED (the late-payment route) to the financing
-- guard; R2 picks the pledge on that route; R3 makes settle_paystack_payment
-- leave MV- payments to Monvelo; R9 moves monvelo_financings to a column grant
-- that leaves out every lender column; R10 makes the late route re-run the claim
-- checks through one helper shared with claim_monvelo_financing; R12 records the
-- starting member on the payment; R13 serialises each agent's claims and
-- fundings on an advisory lock.

-- ── payments: the Monvelo link (§15.3: monvelo_-named, never granted) ───
-- monvelo_agent_id and monvelo_started_by record which agent, and which of its
-- members, started the payment: on the late route the financing no longer names
-- a claimant, so the payment must (R7, R12).
alter table public.payments
  add column monvelo_financing_id uuid,
  add column monvelo_agent_id     uuid references public.monvelo_agents (id) on delete restrict,
  add column monvelo_started_by   uuid references public.profiles (id) on delete restrict,
  add constraint payments_monvelo_financing_fk
    foreign key (tenant_id, monvelo_financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  add constraint payments_monvelo_pair
    check (num_nulls(monvelo_financing_id, monvelo_agent_id, monvelo_started_by) in (0, 3));
create index idx_payments_monvelo_financing on public.payments (tenant_id, monvelo_financing_id);
create index idx_payments_monvelo_agent on public.payments (monvelo_agent_id);
create index idx_payments_monvelo_started_by on public.payments (monvelo_started_by);
-- the column grant (20261020120100) is deliberately not re-issued

-- ── monvelo_financings: no lender column for the API (R9, §16.2.2) ──────
-- The financing's tenant-side readers (TENANT_ADMIN, CSM, ZSM, the TM, the
-- raiser, the owner, the LM) read the row, so the columns naming the agent, its
-- member, its pledge or its Paystack payment are left out of the grant. Agents
-- and staff reach them through the RPCs (and agents through their own claims).
revoke select on public.monvelo_financings from authenticated;
grant select (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by, principal, supply_date,
              status, approval_required, approved_by, approved_at, offered_at, preferred_window_ends_at,
              claim_expires_at, funded_at, delivered_at, due_at, late_charge_amount, outstanding, closed_at,
              cancelled_by, cancelled_at, cancel_reason, created_at, updated_at)
  on public.monvelo_financings to authenticated;

-- ── the financing guard: plus OFFERED -> FUNDED (R1) ────────────────────
-- Recreated from its live definition (20261029130200) with one move added.
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
    or (old.status = 'OFFERED' and new.status in ('CLAIMED', 'CANCELLED', 'EXPIRED', 'FUNDED'))
    or (old.status = 'CLAIMED' and new.status in ('OFFERED', 'FUNDED'))
    or (old.status = 'FUNDED' and new.status in ('DELIVERED', 'REFUND_DUE'))
    or (old.status = 'DELIVERED' and new.status in ('REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE'))
    or (old.status = 'DEFAULTED_WITH_LATE_CHARGE' and new.status = 'REPAID_LATE')) then
    raise exception 'a financing cannot move from % to %', old.status, new.status using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- ── monvelo_flags: pattern flags for the operator (§7.4) ────────────────
create table public.monvelo_flags (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('PAYER_MISMATCH', 'LATE_PAYMENT', 'AMOUNT_MISMATCH',
                                             'REPAYMENT_REJECTED', 'REPAYMENT_UNCONFIRMED')),
  financing_id uuid references public.monvelo_financings (id) on delete restrict,
  agent_id     uuid references public.monvelo_agents (id) on delete restrict,
  details      jsonb not null default '{}'::jsonb,
  status       text not null default 'OPEN' check (status in ('OPEN', 'REVIEWED')),
  reviewed_by  uuid references public.profiles (id) on delete restrict,
  reviewed_at  timestamptz,
  review_note  text check (char_length(review_note) <= 1000),
  created_at   timestamptz not null default now(),
  check ((status = 'REVIEWED') = (reviewed_by is not null and reviewed_at is not null))
);
create index idx_monvelo_flags_financing   on public.monvelo_flags (financing_id);
create index idx_monvelo_flags_agent       on public.monvelo_flags (agent_id);
create index idx_monvelo_flags_reviewed_by on public.monvelo_flags (reviewed_by);
create index idx_monvelo_flags_open        on public.monvelo_flags (created_at) where status = 'OPEN';

-- inserted OPEN; reviewed once (status, reviewed_by, reviewed_at, review_note); nothing else changes
create or replace function public.monvelo_flags_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'OPEN' then
      raise exception 'a flag is raised OPEN' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if old.status = 'OPEN' and new.status = 'REVIEWED'
     and (new.id, new.kind, new.financing_id, new.agent_id, new.details, new.created_at)
         is not distinct from (old.id, old.kind, old.financing_id, old.agent_id, old.details, old.created_at) then
    return new;
  end if;
  raise exception 'a flag is only reviewed, once' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_flags_guard() from public, anon, authenticated, service_role;
create trigger monvelo_flags_guard before insert or update on public.monvelo_flags
  for each row execute function public.monvelo_flags_guard();
create trigger monvelo_flags_no_delete before delete on public.monvelo_flags
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_flags_no_truncate before truncate on public.monvelo_flags
  for each statement execute function public.monvelo_no_delete();

-- ── monvelo_rebate_payables and their per-brand lines (§4.4) ────────────
-- Step 5 adds AWAITING_SECOND_APPROVAL, PAID, OVERDUE and the payout columns.
create table public.monvelo_rebate_payables (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  financing_id uuid not null unique,
  agent_id     uuid not null references public.monvelo_agents (id) on delete restrict,
  amount       numeric(15,2) not null check (amount >= 0),
  due_at       timestamptz not null,
  status       text not null default 'DUE' check (status in ('DUE', 'CANCELLED')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict
);
create index idx_monvelo_rebate_payables_financing on public.monvelo_rebate_payables (tenant_id, financing_id);
create index idx_monvelo_rebate_payables_agent     on public.monvelo_rebate_payables (agent_id);
create index idx_monvelo_rebate_payables_due       on public.monvelo_rebate_payables (status, due_at);
create trigger monvelo_rebate_payables_set_updated_at before update on public.monvelo_rebate_payables
  for each row execute function public.set_updated_at();

-- inserted DUE; only the status moves (DUE -> CANCELLED here; Step 5 widens it)
create or replace function public.monvelo_rebate_payables_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'DUE' then
      raise exception 'a payable is created DUE' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if (new.id, new.tenant_id, new.financing_id, new.agent_id, new.amount, new.due_at, new.created_at)
     is distinct from (old.id, old.tenant_id, old.financing_id, old.agent_id, old.amount, old.due_at, old.created_at) then
    raise exception 'a payable''s amount, agent and due date never change' using errcode = 'P0001';
  end if;
  if new.status <> old.status and not (old.status = 'DUE' and new.status = 'CANCELLED') then
    raise exception 'a payable cannot move from % to %', old.status, new.status using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.monvelo_rebate_payables_guard() from public, anon, authenticated, service_role;
create trigger monvelo_rebate_payables_guard before insert or update on public.monvelo_rebate_payables
  for each row execute function public.monvelo_rebate_payables_guard();
create trigger monvelo_rebate_payables_no_delete before delete on public.monvelo_rebate_payables
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_rebate_payables_no_truncate before truncate on public.monvelo_rebate_payables
  for each statement execute function public.monvelo_no_delete();

create table public.monvelo_rebate_payable_lines (
  payable_id uuid not null references public.monvelo_rebate_payables (id) on delete restrict,
  brand_key  text not null check (brand_key = lower(btrim(brand_key)) and brand_key <> ''),
  amount     numeric(15,2) not null check (amount >= 0),
  primary key (payable_id, brand_key)
);

create or replace function public.monvelo_rebate_payable_lines_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'payable lines never change' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_rebate_payable_lines_insert_only() from public, anon, authenticated, service_role;
create trigger monvelo_rebate_payable_lines_insert_only before update on public.monvelo_rebate_payable_lines
  for each row execute function public.monvelo_rebate_payable_lines_insert_only();
create trigger monvelo_rebate_payable_lines_no_delete before delete on public.monvelo_rebate_payable_lines
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_rebate_payable_lines_no_truncate before truncate on public.monvelo_rebate_payable_lines
  for each statement execute function public.monvelo_no_delete();

-- ── grants and policies ─────────────────────────────────────────────────
-- service_role holds no write either: only the RPCs below write these
alter table public.monvelo_flags enable row level security;
alter table public.monvelo_rebate_payables enable row level security;
alter table public.monvelo_rebate_payable_lines enable row level security;
revoke all on public.monvelo_flags, public.monvelo_rebate_payables, public.monvelo_rebate_payable_lines
  from anon, authenticated, service_role;
grant select on public.monvelo_flags, public.monvelo_rebate_payables, public.monvelo_rebate_payable_lines to authenticated;

create policy monvelo_flags_select on public.monvelo_flags for select to authenticated
  using ((select public.is_monvelo_staff()));
create policy monvelo_rebate_payables_select on public.monvelo_rebate_payables for select to authenticated
  using (
    agent_id in (select public.my_monvelo_agent_ids())
    or (select public.is_monvelo_staff()));
create policy monvelo_rebate_payable_lines_select on public.monvelo_rebate_payable_lines for select to authenticated
  using (payable_id in (select p.id from public.monvelo_rebate_payables p));

-- ── internal helpers (no API grant) ─────────────────────────────────────

-- the distinct upper-case alphabetic words of a name, in order; apostrophes and
-- full stops are dropped, any other non-letter separates words
create or replace function public.monvelo_name_tokens(p_name text)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(w order by first_at), '{}'::text[])
    from (select w, min(n) as first_at
            from regexp_split_to_table(
                   btrim(regexp_replace(regexp_replace(upper(coalesce(p_name, '')), '[''.]', '', 'g'), '[^A-Z]+', ' ', 'g')),
                   ' ') with ordinality as t (w, n)
           where w <> ''
           group by w) x;
$$;
revoke all on function public.monvelo_name_tokens(text) from public, anon, authenticated, service_role;

-- F1: the transfer came from the agent's own settlement account, as far as
-- Paystack shows it (transfer channel, last four digits, holder name)
create or replace function public.monvelo_payer_matches(p_agent public.monvelo_agents, p_verified jsonb)
returns boolean
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_auth    jsonb := coalesce(p_verified -> 'authorization', '{}'::jsonb);
  v_channel text := coalesce(v_auth ->> 'channel', p_verified ->> 'channel');
  v_digits  text := regexp_replace(coalesce(v_auth ->> 'sender_bank_account_number', ''), '[^0-9]', '', 'g');
  v_sender  text[] := public.monvelo_name_tokens(v_auth ->> 'sender_name');
  v_holder  text[] := public.monvelo_name_tokens(p_agent.settlement_account_name);
begin
  if v_channel is null or v_channel not in ('bank_transfer', 'dedicated_nuban') then
    return false;
  end if;
  if length(v_digits) < 4 or right(v_digits, 4) is distinct from p_agent.settlement_account_last4 then
    return false;
  end if;
  return (cardinality(v_sender) >= 2 and v_sender <@ v_holder)
      or (cardinality(v_holder) >= 2 and v_holder <@ v_sender);
end;
$$;
revoke all on function public.monvelo_payer_matches(public.monvelo_agents, jsonb) from public, anon, authenticated, service_role;

create or replace function public.monvelo_raise_flag(p_kind text, p_financing_id uuid, p_agent_id uuid, p_details jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into public.monvelo_flags (kind, financing_id, agent_id, details)
  values (p_kind, p_financing_id, p_agent_id, coalesce(p_details, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.monvelo_raise_flag(text, uuid, uuid, jsonb) from public, anon, authenticated, service_role;

-- R3: settle_paystack_payment's guard. A payment that belongs to a Monvelo
-- financing is settled by settle_monvelo_funding only: audit it, return the
-- outcome, write nothing else. Null for every other payment.
create or replace function public.payment_monvelo_route(p_payment public.payments, p_event text,
                                                        p_source public.audit_source_enum)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_payment.monvelo_financing_id is null then
    return null;
  end if;
  perform public.write_audit(p_payment.tenant_id, 'PAYSTACK_MONVELO_REFERENCE', 'payments', p_payment.id::text,
    null, jsonb_build_object('event', p_event, 'reference', p_payment.paystack_reference),
    null, p_source, p_payment.teafair_agent_id);
  return jsonb_build_object('outcome', 'monvelo_reference', 'payment_id', p_payment.id);
end;
$$;
revoke all on function public.payment_monvelo_route(public.payments, text, public.audit_source_enum)
  from public, anon, authenticated, service_role;

-- ── R10: the claim checks, shared by the claim and the late route ──────
-- What claim_monvelo_financing checks, in its order and with its messages, for
-- one agent's member, one agent and one financing. Null when it may proceed.
-- The callers lock the financing and the pledge first (p_pledge is the agent's
-- pledge for the financing's area and supply day, or a null row). p_late (the
-- late-payment route) skips only what belongs to the claim itself: the rule
-- that a lapsed claimant cannot claim again, and the preferred window.
create or replace function public.monvelo_claim_refusal(
  p_fin    public.monvelo_financings,
  p_agent  public.monvelo_agents,
  p_member uuid,
  p_pledge public.monvelo_pledges,
  p_late   boolean
)
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_shop      public.retail_shops;
  v_ps        public.monvelo_platform_settings;
  v_committed numeric(15,2) := 0;
  v_today     date := public.monvelo_today();
  v_daily     numeric(15,2);
begin
  -- the caller is an ACTIVE member of the agent
  if p_member is null or p_agent.id is null
     or not exists (select 1 from public.monvelo_agent_members m
                     where m.agent_id = p_agent.id and m.profile_id = p_member and m.status = 'ACTIVE') then
    return 'not an active member of this agent';
  end if;

  -- 1. still open, and its trade order still PENDING
  if p_fin.id is null or p_fin.status <> 'OFFERED'
     or not exists (select 1 from public.orders o
                     where o.tenant_id = p_fin.tenant_id and o.id = p_fin.order_id and o.status = 'PENDING') then
    return 'this request is no longer open';
  end if;

  -- 2. the agent; 3. the enrolment
  if p_agent.status <> 'ACTIVE' then
    return 'the agent is not active';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = p_fin.tenant_id and e.shop_id = p_fin.shop_id and e.status = 'ACTIVE') then
    return 'the shop is no longer enrolled';
  end if;

  -- the platform hard freeze (A6 §18.2): funding is new credit too
  if exists (select 1 from public.monvelo_financings f
              where f.shop_id = p_fin.shop_id and f.status = 'DEFAULTED_WITH_LATE_CHARGE') then
    return 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared';
  end if;

  -- 4. one claim per agent per request (the claim itself; not on the late route)
  if not p_late and exists (select 1 from public.monvelo_financing_claims c
                             where c.financing_id = p_fin.id and c.agent_id = p_agent.id and c.outcome = 'LAPSED') then
    return 'your claim on this request lapsed; another agent may claim it';
  end if;

  -- 5. the preferred window (the claim itself; not on the late route)
  if not p_late and p_fin.preferred_window_ends_at > now() and p_fin.preferred_agent_id is distinct from p_agent.id then
    return 'the shop''s preferred agent has first claim until '
           || to_char(p_fin.preferred_window_ends_at at time zone 'Africa/Lagos', 'HH24:MI');
  end if;

  -- 6. distance: the shop's preferred agent is exempt
  select * into v_ps from public.monvelo_platform_settings;
  select * into v_shop from public.retail_shops s where s.id = p_fin.shop_id;
  if v_shop.preferred_agent_id is distinct from p_agent.id
     and not extensions.st_dwithin(p_agent.location, v_shop.location::extensions.geography, v_ps.offer_radius_m) then
    return 'this shop is outside your area';
  end if;

  -- 7. the agent's pledge for the area and day, less what its other claims hold
  if p_pledge.id is not null then
    select coalesce(sum(f.principal), 0) into v_committed from public.monvelo_financings f
     where f.tenant_id = p_pledge.tenant_id and f.pledge_id = p_pledge.id and f.status = 'CLAIMED' and f.id <> p_fin.id;
  end if;
  if p_pledge.id is null or p_pledge.remaining - v_committed < p_fin.principal then
    return 'pledge enough funds for this area and day first';
  end if;

  -- 8. caps: per financing, and per Lagos day (claimed now plus funded today)
  if p_fin.principal > p_agent.per_financing_cap then
    return 'this request is above your per-financing cap';
  end if;
  select coalesce(sum(f.principal) filter (where f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent.id), 0)
       + coalesce(sum(f.principal) filter (where f.funder_agent_id = p_agent.id
                                             and (f.funded_at at time zone 'Africa/Lagos')::date = v_today), 0)
    into v_daily
    from public.monvelo_financings f
   where f.claimed_by_agent_id = p_agent.id or f.funder_agent_id = p_agent.id;
  if v_daily + p_fin.principal > p_agent.daily_cap then
    return 'this request would pass your daily cap';
  end if;

  return null;
end;
$$;
revoke all on function public.monvelo_claim_refusal(public.monvelo_financings, public.monvelo_agents, uuid,
                                                    public.monvelo_pledges, boolean)
  from public, anon, authenticated, service_role;

-- ── claim_monvelo_financing: through the shared checks (R10) ────────────
-- Recreated from its live definition (20261029130300). Checks 1-8 move into
-- monvelo_claim_refusal with the same order, messages and error code (P0001);
-- the pledge is now locked before the checks instead of at check 7. Signature,
-- result and grants unchanged.
create or replace function public.claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_prior   jsonb;
  v_fin     public.monvelo_financings;
  v_agent   public.monvelo_agents;
  v_ps      public.monvelo_platform_settings;
  v_pledge  public.monvelo_pledges;
  v_refusal text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.monvelo_agent_members m
                  where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'claim_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- R13: one agent's claims and late fundings queue on one advisory lock, taken
  -- before any row lock; then the agent row, so its caps are read once at a time
  perform pg_advisory_xact_lock(hashtextextended('monvelo_agent:' || p_agent_id::text, 0));
  select * into v_agent from public.monvelo_agents a where a.id = p_agent_id for update;
  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id for update;
  if v_fin.id is not null then
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = p_agent_id
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
       for update;
  end if;

  v_refusal := public.monvelo_claim_refusal(v_fin, v_agent, v_uid, v_pledge, false);
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;

  select * into v_ps from public.monvelo_platform_settings;
  update public.monvelo_financings
     set status = 'CLAIMED', claimed_by_agent_id = p_agent_id, claimed_by = v_uid,
         claim_expires_at = now() + make_interval(mins => v_ps.claim_minutes),
         pledge_id = v_pledge.id, preferred_window_ends_at = null
   where id = v_fin.id
  returning * into v_fin;
  insert into public.monvelo_financing_claims (tenant_id, financing_id, agent_id, claimed_by, pledge_id, expires_at)
  values (v_fin.tenant_id, v_fin.id, p_agent_id, v_uid, v_pledge.id, v_fin.claim_expires_at);

  perform public.write_audit(v_fin.tenant_id, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'OFFERED'),
    jsonb_build_object('status', v_fin.status, 'agent_id', p_agent_id, 'pledge_id', v_pledge.id,
                       'claim_expires_at', v_fin.claim_expires_at),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'claim_expires_at', v_fin.claim_expires_at, 'principal', v_fin.principal));
end;
$$;
revoke all on function public.claim_monvelo_financing(uuid, uuid, uuid) from public, anon;
grant execute on function public.claim_monvelo_financing(uuid, uuid, uuid) to authenticated;

-- ── start_monvelo_funding: the claiming agent's member ──────────────────
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

  v_prior := public.idempotency_begin(p_idempotency_key, 'start_monvelo_funding',
    jsonb_build_object('financing_id', p_financing_id, 'agent_id', p_agent_id));
  if v_prior is not null then
    return v_prior;
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
    'currency', v_currency, 'claim_expires_at', v_fin.claim_expires_at));
end;
$$;
revoke all on function public.start_monvelo_funding(uuid, uuid, uuid) from public, anon;
grant execute on function public.start_monvelo_funding(uuid, uuid, uuid) to authenticated;

-- ── settle_monvelo_funding: the webhook and the sweep (service_role) ────
create or replace function public.settle_monvelo_funding(
  p_event          text,
  p_reference      text,
  p_status         text,
  p_amount_minor   bigint,
  p_currency       text,
  p_verified       jsonb,
  p_transaction_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- (event, reference) is the at-most-once key
  v_key      uuid := md5('monvelo:' || p_event || ':' || p_reference)::uuid;
  v_source   public.audit_source_enum := case when p_event = 'sweep' then 'CRON' else 'WEBHOOK' end;
  v_matches  integer;
  v_payment  public.payments;
  v_fin      public.monvelo_financings;
  v_order    public.orders;
  v_agent    public.monvelo_agents;
  v_pledge   public.monvelo_pledges;
  v_age      interval;
  v_target   public.payment_status_enum;
  v_prior    jsonb;
  v_currency text;
  v_auth     jsonb := coalesce(p_verified -> 'authorization', '{}'::jsonb);
  v_payer    jsonb;
  v_reason   text;
  v_route    text;
  v_line     record;
  v_terms    public.monvelo_brand_terms;
  v_today    date := public.monvelo_today();
  v_payable  public.monvelo_rebate_payables;
  v_total    numeric(15,2) := 0;
  v_outcome  text;
begin
  if p_status = 'reversed' then
    raise exception 'reversed is applied as a refund' using errcode = 'P0001';
  end if;

  select count(*) into v_matches from public.payments
   where paystack_reference = p_reference and monvelo_financing_id is not null;
  if v_matches <> 1 then
    -- not marked processed: a payment row that lands later can still settle
    perform public.write_audit(null, 'MONVELO_UNKNOWN_REFERENCE', 'payments', p_reference, null,
      jsonb_build_object('event', p_event, 'reference', p_reference, 'matches', v_matches),
      null, v_source);
    return jsonb_build_object('outcome', 'unknown_reference');
  end if;

  -- age decides abandoned and the non-final statuses, as settle_paystack_payment
  select * into v_payment from public.payments
   where paystack_reference = p_reference and monvelo_financing_id is not null;
  v_age := now() - v_payment.created_at;
  v_target := case
                when p_status = 'success' then 'SUCCESS'
                when p_status in ('failed', 'abandoned') and v_age >= interval '2 hours' then 'FAILED'
                when p_status in ('ongoing', 'pending', 'processing', 'queued')
                     and v_age > interval '72 hours' then 'FAILED'
              end;
  if v_target is null then
    if p_event = 'sweep' then
      update public.payments set last_swept_at = now() where id = v_payment.id;
    end if;
    return jsonb_build_object('outcome', 'not_final', 'status', p_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'settle_monvelo_funding',
    jsonb_build_object('event', p_event, 'reference', p_reference));
  if v_prior is not null then
    return v_prior;
  end if;

  -- R13: the agent's advisory lock first, as in claim_monvelo_financing, so a
  -- late funding queues behind the agent's claims and other fundings. Taken on
  -- every route: the route is known only after the row locks, and taking it
  -- after them would reverse the claim's lock order. The agent never changes on
  -- a payment, so the unlocked read above is safe.
  perform pg_advisory_xact_lock(hashtextextended('monvelo_agent:' || v_payment.monvelo_agent_id::text, 0));

  -- payment, financing, then order
  select * into v_payment from public.payments where id = v_payment.id for update;
  select * into v_fin from public.monvelo_financings
   where tenant_id = v_payment.tenant_id and id = v_payment.monvelo_financing_id for update;
  select * into v_order from public.orders
   where tenant_id = v_fin.tenant_id and id = v_fin.order_id for update;
  select * into v_agent from public.monvelo_agents where id = v_payment.monvelo_agent_id;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');

  -- already decided, or a status that cannot follow the one recorded
  if v_payment.payment_status = v_target
     or v_payment.payment_status = 'REFUNDED'
     or (v_payment.payment_status = 'SUCCESS' and v_target = 'FAILED') then
    if v_payment.payment_status <> v_target then
      perform public.write_audit(v_payment.tenant_id, 'PAYSTACK_STATUS_CONFLICT', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', v_payment.payment_status),
        jsonb_build_object('verified_status', p_status, 'event', p_event),
        v_key, v_source, v_payment.teafair_agent_id);
    end if;
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'unchanged', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status));
  end if;

  update public.payments
     set payment_status = v_target, gateway_response_payload = p_verified
   where id = v_payment.id;
  perform public.write_audit(v_payment.tenant_id, 'settle_monvelo_funding', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', v_target, 'event', p_event),
    v_key, v_source, v_payment.teafair_agent_id);

  if v_target = 'FAILED' then
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'failed', 'payment_id', v_payment.id, 'payment_status', 'FAILED'));
  end if;

  -- what the staff reviewing a flag need about the money; flags are staff-only
  v_payer := jsonb_build_object('payment_id', v_payment.id, 'reference', p_reference, 'event', p_event,
    'transaction_id', p_transaction_id, 'amount_minor', p_amount_minor, 'currency', p_currency,
    'channel', coalesce(v_auth ->> 'channel', p_verified ->> 'channel'),
    'sender_bank', v_auth ->> 'sender_bank', 'sender_name', v_auth ->> 'sender_name',
    'sender_account', v_auth ->> 'sender_bank_account_number');

  -- 1. the amount and currency
  if p_amount_minor is distinct from (v_fin.principal * 100)::bigint or p_currency is distinct from v_currency then
    perform public.monvelo_raise_flag('AMOUNT_MISMATCH', v_fin.id, v_agent.id,
      v_payer || jsonb_build_object('expected_minor', (v_fin.principal * 100)::bigint, 'expected_currency', v_currency));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'mismatch', 'payment_id', v_payment.id, 'financing_id', v_fin.id));
  end if;

  -- 2. the payer (F1)
  if not public.monvelo_payer_matches(v_agent, p_verified) then
    perform public.monvelo_raise_flag('PAYER_MISMATCH', v_fin.id, v_agent.id, v_payer);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'payer_mismatch', 'payment_id', v_payment.id, 'financing_id', v_fin.id));
  end if;

  -- 3. still fundable by this agent: its own claim, or (R2) an unclaimed request
  --    inside its supply day that the agent's pledge still covers
  if v_order.status is distinct from 'PENDING' then
    v_reason := 'ORDER_NOT_PENDING';
  elsif v_fin.status = 'CLAIMED' and v_fin.claimed_by_agent_id = v_agent.id then
    v_route := 'CLAIM';
    select * into v_pledge from public.monvelo_pledges
     where tenant_id = v_fin.tenant_id and id = v_fin.pledge_id for update;
    if v_pledge.id is null or v_pledge.remaining < v_fin.principal then
      v_reason := 'PLEDGE_EXHAUSTED';
    end if;
  elsif v_fin.status = 'OFFERED'
        and not exists (select 1 from public.monvelo_financing_claims c
                         where c.financing_id = v_fin.id and c.outcome is null)
        and now() < ((v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos') then
    v_route := 'LATE';
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = v_agent.id
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
     order by p.created_at, p.id
     limit 1
       for update;
    -- R10: every claim check but the claim itself, for the member who started
    -- this payment (R12: payments.monvelo_started_by); the pledge check is net
    -- of the agent's other open claims
    v_reason := public.monvelo_claim_refusal(v_fin, v_agent, v_payment.monvelo_started_by, v_pledge, true);
  else
    v_reason := case
                  when v_fin.status = 'CLAIMED' then 'CLAIMED_BY_ANOTHER_AGENT'
                  when v_fin.status = 'OFFERED' then 'SUPPLY_DAY_ENDED'
                  else 'FINANCING_' || v_fin.status
                end;
  end if;

  -- every brand must still have approved terms to lock
  if v_reason is null then
    for v_line in
      select l.brand from public.monvelo_financing_lines l
       where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id
    loop
      if (public.monvelo_terms_at(v_fin.tenant_id, v_line.brand, v_today)).id is null then
        v_reason := 'NO_TERMS';
      end if;
    end loop;
  end if;

  if v_reason is not null then
    perform public.monvelo_raise_flag('LATE_PAYMENT', v_fin.id, v_agent.id,
      v_payer || jsonb_build_object('reason', v_reason, 'financing_status', v_fin.status));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'late_payment', 'payment_id', v_payment.id, 'financing_id', v_fin.id));
  end if;

  -- FUNDED, in this one transaction
  update public.monvelo_financings
     set status = 'FUNDED', funder_agent_id = v_agent.id, paystack_reference = p_reference, funded_at = now(),
         pledge_id = v_pledge.id
   where id = v_fin.id;
  update public.monvelo_financing_claims set outcome = 'FUNDED', ended_at = now()
   where financing_id = v_fin.id and outcome is null;

  update public.monvelo_financing_lines l
     set (terms_id, rebate_bps, interest_free_days, late_charge_bps, terms_locked_at) =
         (select t.id, t.rebate_bps, t.interest_free_days, t.late_charge_bps, now()
            from public.monvelo_terms_at(l.tenant_id, l.brand, v_today) t)
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  update public.monvelo_pledges set remaining = remaining - v_fin.principal where id = v_pledge.id;

  update public.orders set status = 'PAID' where id = v_order.id;

  select coalesce(sum(round(l.amount * l.rebate_bps / 10000.0, 2)), 0) into v_total
    from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;
  insert into public.monvelo_rebate_payables (tenant_id, financing_id, agent_id, amount, due_at, status)
  values (v_fin.tenant_id, v_fin.id, v_agent.id, v_total, now() + interval '24 hours', 'DUE')
  returning * into v_payable;
  insert into public.monvelo_rebate_payable_lines (payable_id, brand_key, amount)
  select v_payable.id, l.brand_key, round(l.amount * l.rebate_bps / 10000.0, 2)
    from public.monvelo_financing_lines l
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  -- audited on the raiser; no agent, pledge or payer in the row (§16.2.2)
  perform public.write_audit(v_fin.tenant_id, 'settle_monvelo_funding', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', v_fin.status),
    jsonb_build_object('status', 'FUNDED', 'payment_id', v_payment.id, 'order_id', v_order.id,
                       'principal', v_fin.principal, 'event', p_event),
    v_key, v_source, v_fin.raised_by);
  perform public.write_audit(v_fin.tenant_id, 'settle_monvelo_funding', 'orders', v_order.id::text,
    jsonb_build_object('status', 'PENDING'),
    jsonb_build_object('status', 'PAID', 'payment_id', v_payment.id, 'event', p_event),
    v_key, v_source, v_fin.raised_by);

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'funded', 'payment_id', v_payment.id, 'financing_id', v_fin.id, 'route', v_route,
    'payable_id', v_payable.id, 'rebate', v_total));
end;
$$;
revoke all on function public.settle_monvelo_funding(text, text, text, bigint, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.settle_monvelo_funding(text, text, text, bigint, text, jsonb, text) to service_role;

-- ── review_monvelo_flag: the operator, once ─────────────────────────────
create or replace function public.review_monvelo_flag(p_idempotency_key uuid, p_flag_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
  v_flag  public.monvelo_flags;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'review_monvelo_flag',
    jsonb_build_object('flag_id', p_flag_id, 'note', p_note));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_note is null or btrim(p_note) = '' or char_length(btrim(p_note)) > 1000 then
    raise exception 'give a review note of at most 1000 characters' using errcode = 'P0001';
  end if;
  select * into v_flag from public.monvelo_flags where id = p_flag_id for update;
  if not found then
    raise exception 'flag not found' using errcode = 'P0001';
  end if;
  if v_flag.status <> 'OPEN' then
    raise exception 'this flag was already reviewed' using errcode = 'P0001';
  end if;

  update public.monvelo_flags
     set status = 'REVIEWED', reviewed_by = v_uid, reviewed_at = now(), review_note = btrim(p_note)
   where id = v_flag.id
  returning * into v_flag;

  -- tenant null: a flag names the agent, and tenants never see lenders (§16.2.2)
  perform public.write_audit(null, 'review_monvelo_flag', 'monvelo_flags', v_flag.id::text,
    jsonb_build_object('status', 'OPEN'),
    jsonb_build_object('status', 'REVIEWED', 'kind', v_flag.kind, 'financing_id', v_flag.financing_id),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('flag_id', v_flag.id, 'status', v_flag.status));
end;
$$;
revoke all on function public.review_monvelo_flag(uuid, uuid, text) from public, anon;
grant execute on function public.review_monvelo_flag(uuid, uuid, text) to authenticated;

-- ── settle_paystack_payment: leave Monvelo payments alone (R3) ──────────
-- Recreated from its live definition (20261028130200) with one change: right
-- after it finds the single payment, a payment linked to a Monvelo financing is
-- audited and returned as {outcome: 'monvelo_reference'} with no other write,
-- until the gateway routes MV- references (Task 2) and as defence in depth after.
-- Signature and grants unchanged. The check sits in payment_monvelo_route so
-- this shared body names no Monvelo table (045).
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
as $function$
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
  v_routed     jsonb;
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

  -- R3: a Monvelo payment is settled by its own RPC; audit it and write nothing else
  v_routed := public.payment_monvelo_route(v_payment, p_event, v_source);
  if v_routed is not null then
    return v_routed;
  end if;
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

      insert into public.web_commissions (tenant_id, order_id, payment_id, web_pos_partner_id, teafair_agent_id,
                                             amount, bps_applied, paystack_subaccount_code,
                                             paystack_split_reference, status, dispute_reason)
      values (v_payment.tenant_id, v_payment.order_id, v_payment.id, v_payment.web_pos_partner_id,
              v_payment.teafair_agent_id, v_payment.split_amount, v_payment.split_bps,
              v_payment.split_subaccount_code, p_transaction_id, v_comm_out,
              case when v_comm_out = 'DISPUTED' then 'SPLIT_MISMATCH' end)
      returning id into v_comm_id;

      perform public.write_audit(v_payment.tenant_id, 'settle_paystack_payment', 'web_commissions', v_comm_id::text,
        null,
        jsonb_build_object('status', v_comm_out, 'payment_id', v_payment.id, 'amount', v_payment.split_amount,
                           'bps_applied', v_payment.split_bps, 'paystack_split_reference', p_transaction_id),
        v_key, v_source, v_payment.teafair_agent_id);

      if v_comm_out = 'DISPUTED' then
        perform public.write_audit(v_payment.tenant_id, 'SPLIT_MISMATCH', 'web_commissions', v_comm_id::text,
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
$function$;
