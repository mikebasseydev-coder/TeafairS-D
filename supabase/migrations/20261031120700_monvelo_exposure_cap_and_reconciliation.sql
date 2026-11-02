-- Addendum A6 §19 (2026-11-02): the agent's open exposure cap, the pledge
-- restored when a REFUND_DUE financing's refund is confirmed, and the lender
-- reconciliation summary. Approved by the user 2026-11-02.
--
--   monvelo_open_exposure_ceiling()        one platform constant, 100000.00
--   monvelo_agent_open_exposure(agent)     what the agent has open
--   monvelo_claim_refusal                  + the exposure check; the daily cap
--                                          leaves out REFUND_DUE (R63)
--   apply_monvelo_refund                   restores the pledge when it closes a
--                                          REFUND_DUE financing
--   monvelo_sweep_money                    restores it when the funding was
--                                          already refunded (R62)
--   get_lender_reconciliation_summary      per agent and Lagos funding week
--
-- monvelo_claim_refusal, apply_monvelo_refund and monvelo_sweep_money are
-- recreated from their latest definitions (20261031120000, 20261031120500 and
-- 20261031120500) with only the changes marked "A6 §19". Signatures, grants and the callers' lock order are unchanged.
-- No RLS policy changes.

-- ── the ceiling: a migration changes it ─────────────────────────────────
create or replace function public.monvelo_open_exposure_ceiling()
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select 100000.00::numeric(15,2);
$$;
revoke all on function public.monvelo_open_exposure_ceiling() from public, anon, authenticated, service_role;
comment on function public.monvelo_open_exposure_ceiling() is
  'A6 §19: the most one agent may have open across Monvelo, in naira. A migration changes it.';

-- ── what one agent has open ─────────────────────────────────────────────
-- CLAIMED (by claimed_by_agent_id) and FUNDED (by funder_agent_id) count their
-- principal; DELIVERED and DEFAULTED_WITH_LATE_CHARGE count what is
-- outstanding, never more than the principal, so part repayments free room and
-- the late charge consumes none. R63 (the user, 2026-11-02: "the central truth
-- is funded order fulfilment"): REFUND_DUE counts nothing, closed or not; its
-- fulfilment has failed. OFFERED belongs to no agent; IN_TRANSIT is an order
-- status, not a financing's.
create or replace function public.monvelo_agent_open_exposure(p_agent_id uuid)
returns numeric(15,2)
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(sum(case
           when f.status in ('CLAIMED', 'FUNDED') then f.principal
           else least(f.outstanding, f.principal)
         end), 0)::numeric(15,2)
    from public.monvelo_financings f
   where (f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent_id)
      or (f.funder_agent_id = p_agent_id
          and f.status in ('FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE'));
$$;
revoke all on function public.monvelo_agent_open_exposure(uuid) from public, anon, authenticated, service_role;
comment on function public.monvelo_agent_open_exposure(uuid) is
  'A6 §19: the agent''s open exposure: CLAIMED and FUNDED at principal; DELIVERED and DEFAULTED_WITH_LATE_CHARGE at least(outstanding, principal). REFUND_DUE counts nothing (R63).';

-- ── monvelo_claim_refusal: + the exposure cap ───────────────────────────
-- Recreated from 20261031120000. A6 §19: check 8's daily sum leaves out a
-- REFUND_DUE financing (R63: its fulfilment has failed, closed or not); a new check after
-- the daily cap refuses what would take the agent's open exposure above the
-- ceiling. Both callers (claim_monvelo_financing and the late route of
-- settle_monvelo_funding) hold the agent's advisory lock (R13), so the sum is
-- read once at a time per agent.
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
  v_ceiling   numeric(15,2) := public.monvelo_open_exposure_ceiling();
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

  -- 8. caps: per financing, and per Lagos day (claimed now plus funded today);
  --    A6 §19, R63: a REFUND_DUE financing (fulfilment failed) no longer fills the day
  if p_fin.principal > p_agent.per_financing_cap then
    return 'this request is above your per-financing cap';
  end if;
  select coalesce(sum(f.principal) filter (where f.status = 'CLAIMED' and f.claimed_by_agent_id = p_agent.id), 0)
       + coalesce(sum(f.principal) filter (where f.funder_agent_id = p_agent.id
                                             and (f.funded_at at time zone 'Africa/Lagos')::date = v_today
                                             and f.status <> 'REFUND_DUE'), 0)
    into v_daily
    from public.monvelo_financings f
   where f.claimed_by_agent_id = p_agent.id or f.funder_agent_id = p_agent.id;
  if v_daily + p_fin.principal > p_agent.daily_cap then
    return 'this request would pass your daily cap';
  end if;

  -- A6 §19: the open exposure cap, across every tenant
  if public.monvelo_agent_open_exposure(p_agent.id) + p_fin.principal > v_ceiling then
    return 'this request would take your open exposure above ₦' || to_char(v_ceiling, 'FM999,999,999,990');
  end if;

  return null;
end;
$$;
revoke all on function public.monvelo_claim_refusal(public.monvelo_financings, public.monvelo_agents, uuid,
                                                    public.monvelo_pledges, boolean)
  from public, anon, authenticated, service_role;

-- ── apply_monvelo_refund: A6 §19, the pledge restored ───────────────────
-- Recreated from 20261031120500 (R56). A6 §19: the branch that closes a
-- REFUND_DUE financing on the full refund of its funding payment also locks the
-- financing's own pledge (payment, financing, then pledge: settle's order) and
-- gives the principal back to its remaining, even after its supply day, with a
-- tenant-null audit row (R15). Once per refund id (the key) and once per
-- financing (only while closed_at was null). Nothing at the sweep, and nothing
-- for a live financing's refunded funding (FUNDING_REFUNDED is for staff).
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
  v_open     boolean;
  v_pledge   public.monvelo_pledges;
  v_restored public.monvelo_pledges;
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
    v_open := v_fin.closed_at is null;
    update public.monvelo_financings set closed_at = now() where id = v_fin.id returning * into v_fin;
    v_closed := true;
    perform public.write_audit(v_fin.tenant_id, 'apply_monvelo_refund', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', v_fin.status, 'closed_at', null),
      jsonb_build_object('status', v_fin.status, 'closed_at', v_fin.closed_at, 'payment_id', v_payment.id,
                         'refund_id', p_refund_id, 'reason', p_reason),
      v_key, v_source, v_fin.raised_by);
    -- A6 §19: the agent has its money back, so its pledge has the principal back
    -- (its exposure frees through closed_at). Only the financing's own pledge,
    -- only once.
    if v_open and v_fin.pledge_id is not null then
      select * into v_pledge from public.monvelo_pledges
       where tenant_id = v_fin.tenant_id and id = v_fin.pledge_id
         for update;
      if v_pledge.id is not null then
        update public.monvelo_pledges set remaining = remaining + v_fin.principal
         where id = v_pledge.id
        returning * into v_restored;
        -- R15: it names the agent and its pledge, so no tenant reads it
        perform public.write_audit(null, 'apply_monvelo_refund', 'monvelo_pledges', v_pledge.id::text,
          jsonb_build_object('remaining', v_pledge.remaining),
          jsonb_build_object('remaining', v_restored.remaining, 'amount', v_fin.principal,
                             'agent_id', v_pledge.agent_id, 'pledge_id', v_pledge.id, 'financing_id', v_fin.id,
                             'payment_id', v_payment.id, 'refund_id', p_refund_id, 'reason', 'REFUND_CONFIRMED'),
          v_key, v_source);
      end if;
    end if;
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

-- ── the lender reconciliation summary ───────────────────────────────────
-- One row per agent and Lagos week of funded_at, from this week back
-- p_weeks - 1 weeks; every figure belongs to the funding week. The readers,
-- checked live:
--   an ACTIVE member of an agent: that agent's rows across every tenant (this
--     wins over any tenant role the caller also holds);
--   a ZSA: fundings in the active tenant whose area lies in their zone;
--   an ASA: fundings in the active tenant in their area;
--   anyone else: 42501.
-- The ZSA/ASA reading is the user's decision (2026-11-02, A6 §19). The output
-- names the lender (its registered business name), never a shop, an owner, a
-- phone, a brand, a tenant or a place.
create or replace function public.get_lender_reconciliation_summary(p_weeks integer default 12)
returns table (
  agent_id       uuid,
  agent_name     text,
  week_start     date,
  capital_funded numeric(15,2),
  outstanding    numeric(15,2),
  repaid         numeric(15,2),
  refunded       numeric(15,2),
  rebates_owed   numeric(15,2),
  rebates_paid   numeric(15,2),
  mv_references  text[]
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_agents uuid[];
  v_me     public.tenant_users;
  v_from   date;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_agents := array(select m.id from public.my_monvelo_agent_ids() m(id));
  if cardinality(v_agents) = 0 then
    v_me := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  end if;
  if p_weeks is null or p_weeks < 1 or p_weeks > 52 then
    raise exception 'p_weeks must be between 1 and 52' using errcode = '22023';
  end if;

  v_from := (date_trunc('week', now() at time zone 'Africa/Lagos'))::date - 7 * (p_weeks - 1);

  return query
  with fin as (
    select f.id, f.tenant_id, f.funder_agent_id, f.principal, f.status, f.outstanding, f.closed_at,
           f.paystack_reference,
           (date_trunc('week', f.funded_at at time zone 'Africa/Lagos'))::date as wk
      from public.monvelo_financings f
     where f.funded_at is not null
       and f.funder_agent_id is not null
       and f.funded_at >= (v_from::timestamp at time zone 'Africa/Lagos')
       and case
             when cardinality(v_agents) > 0 then f.funder_agent_id = any (v_agents)
             when v_me.role = 'ZSA' then
               f.tenant_id = v_me.tenant_id
               and exists (select 1
                             from public.areas ar
                             join public.territories t on t.tenant_id = ar.tenant_id and t.id = ar.territory_id
                            where ar.tenant_id = f.tenant_id and ar.id = f.area_id and t.zone_id = v_me.zone_id)
             else f.tenant_id = v_me.tenant_id and f.area_id = v_me.area_id
           end
  ),
  rep as (
    select r.financing_id, sum(r.amount) as amount
      from public.monvelo_repayments r
      join fin on fin.tenant_id = r.tenant_id and fin.id = r.financing_id
     where r.status = 'CONFIRMED'
     group by r.financing_id
  )
  select fin.funder_agent_id,
         a.business_name,
         fin.wk,
         coalesce(sum(fin.principal), 0)::numeric(15,2),
         coalesce(sum(fin.outstanding) filter (where fin.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')), 0)::numeric(15,2),
         coalesce(sum(rep.amount), 0)::numeric(15,2),
         coalesce(sum(fin.principal) filter (where fin.status = 'REFUND_DUE' and fin.closed_at is not null), 0)::numeric(15,2),
         coalesce(sum(pay.amount) filter (where pay.status = 'DUE'), 0)::numeric(15,2),
         coalesce(sum(pay.amount) filter (where pay.status = 'PAID'), 0)::numeric(15,2),
         coalesce(array_agg(fin.paystack_reference order by fin.paystack_reference)
                    filter (where fin.paystack_reference is not null), array[]::text[])
    from fin
    join public.monvelo_agents a on a.id = fin.funder_agent_id
    left join rep on rep.financing_id = fin.id
    left join public.monvelo_rebate_payables pay on pay.tenant_id = fin.tenant_id and pay.financing_id = fin.id
   group by fin.funder_agent_id, a.business_name, fin.wk
   order by fin.wk desc, a.business_name, fin.funder_agent_id;
end;
$$;
revoke all on function public.get_lender_reconciliation_summary(integer) from public, anon, service_role;
grant execute on function public.get_lender_reconciliation_summary(integer) to authenticated;
comment on function public.get_lender_reconciliation_summary(integer) is
  'A6 §19: per agent and Lagos funding week: capital funded, outstanding, repaid, refunded, rebates owed and paid, MV- references. Readers: the agent''s members (all tenants), a ZSA (zone), an ASA (area).';

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
  v_pledge   public.monvelo_pledges;
  v_restored public.monvelo_pledges;
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

    -- A6 §19.4 (R62): Paystack already confirmed the refund of this funding,
    -- so the agent's pledge has the principal back, as apply_monvelo_refund
    -- gives it when the refund lands after REFUND_DUE. Locks: financing, order,
    -- then pledge. Once: only while closed_at was null.
    if v_refunded and v_fin.closed_at is null and v_fin.pledge_id is not null then
      select * into v_pledge from public.monvelo_pledges
       where tenant_id = v_fin.tenant_id and id = v_fin.pledge_id
         for update;
      if v_pledge.id is not null then
        update public.monvelo_pledges set remaining = remaining + v_fin.principal
         where id = v_pledge.id
        returning * into v_restored;
        -- R15: it names the agent and its pledge, so no tenant reads it
        perform public.write_audit(null, 'monvelo_sweep_money', 'monvelo_pledges', v_pledge.id::text,
          jsonb_build_object('remaining', v_pledge.remaining),
          jsonb_build_object('remaining', v_restored.remaining, 'amount', v_fin.principal,
                             'agent_id', v_pledge.agent_id, 'pledge_id', v_pledge.id, 'financing_id', v_fin.id,
                             'reason', 'REFUND_CONFIRMED'),
          null, 'CRON');
      end if;
    end if;

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
