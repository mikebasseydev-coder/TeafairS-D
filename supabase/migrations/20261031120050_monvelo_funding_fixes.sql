-- Addendum A6 Monvelo Step 3, Task 1, review round 1 (rulings R15-R18).
-- Each function below is recreated from its live definition (pg_get_functiondef)
-- with only the change named above it; signatures and grants are unchanged.
--
-- R15 (C1): tenants never see lenders (A6 §16.2.2), and the tenant's ZSM reads
-- every tenant-scoped audit row. A Monvelo audit row that names an agent, a
-- pledge or a payer is therefore written with tenant_id null: the claim, the
-- sweep's lapse of a claim, and the pledge. The request and the TM's approval
-- stay tenant-scoped (they are the tenant's own records) but no longer carry
-- the shop's preferred agent. settle_monvelo_funding's rows name no agent,
-- pledge or payer and are unchanged.
--
-- R16 (I1): settle_monvelo_funding records a mismatched, payer-mismatched or
-- late payment as SUCCESS (the money arrived; staff refund it). The stock sweep
-- skipped every order with a SUCCESS payment, so such a payment held the trade
-- order's stock past its expiry, on demand. The sweep now ignores payments that
-- belong to a Monvelo financing: a funded financing's order is PAID, never
-- PENDING, so only unfunded ones are affected.
--
-- R17: settle's CLAIMED route also refuses (late_payment and a flag) when the
-- agent is no longer ACTIVE or the member who started the payment is no longer
-- an ACTIVE member of it, matching the late route.
--
-- R18: in the payer check a token shorter than 2 letters (an initial) no
-- longer counts toward the 2-token minimum, so "B O" does not match
-- "ADE B. O.".
--
-- F1 gaps (recorded):
--   * two accounts with the same holder name and the same last four digits
--     cannot be told apart; Paystack masks the rest of the number;
--   * reverse containment is allowed on purpose: the holder's name may sit
--     inside a longer sender name, so a transfer from "BISI ADE STORES LTD"
--     matches an agent registered as "BISI ADE" (and the reverse), as long as
--     the smaller side has at least 2 tokens of 2 or more letters.

-- ── payment_for_monvelo: is this payment a Monvelo funding? (R16) ───────
create or replace function public.payment_for_monvelo(p_payment public.payments)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select p_payment.monvelo_financing_id is not null;
$$;
revoke all on function public.payment_for_monvelo(public.payments) from public, anon, authenticated, service_role;

-- ── stock_reservation_sweep: ignores Monvelo payments (R16) ────────────
CREATE OR REPLACE FUNCTION public.stock_reservation_sweep()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_order public.orders;
  v_rel   integer;
  v_count integer := 0;
begin
  for v_order in
    select o.* from public.orders o
     where o.status = 'PENDING'
       and exists (select 1 from public.stock_reservations r
                    where r.tenant_id = o.tenant_id and r.order_id = o.id
                      and r.status = 'RESERVED' and r.expires_at <= now())
       and not exists (select 1 from public.payments p
                        where p.tenant_id = o.tenant_id and p.order_id = o.id and p.payment_status = 'SUCCESS'
                          -- R16: an unfunded Monvelo payment holds no stock
                          and not public.payment_for_monvelo(p))
     order by o.id
       for update of o skip locked
  loop
    update public.orders set status = 'CANCELLED' where id = v_order.id;
    v_rel := public.stock_release_order(v_order.tenant_id, v_order.id, 'CANCELLED');
    perform public.write_audit(v_order.tenant_id, 'stock_reservation_sweep', 'orders', v_order.id::text,
      jsonb_build_object('status', v_order.status),
      jsonb_build_object('status', 'CANCELLED', 'reason', 'RESERVATION_EXPIRED', 'channel', v_order.channel,
                         'reservations_released', v_rel),
      null, 'CRON', v_order.teafair_agent_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

-- ── claim_monvelo_financing: the audit row is lender-only (R15) ────────
CREATE OR REPLACE FUNCTION public.claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- R15: the row names the agent and its pledge, so no tenant reads it
  perform public.write_audit(null, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'OFFERED'),
    jsonb_build_object('status', v_fin.status, 'agent_id', p_agent_id, 'pledge_id', v_pledge.id,
                       'claim_expires_at', v_fin.claim_expires_at),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'claim_expires_at', v_fin.claim_expires_at, 'principal', v_fin.principal));
end;
$function$;

-- ── monvelo_sweep_offers: the lapse row is lender-only (R15) ───────────
CREATE OR REPLACE FUNCTION public.monvelo_sweep_offers()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_fin     public.monvelo_financings;
  v_ended   boolean;
  v_rel     integer;
  v_lapsed  integer := 0;
  v_expired integer := 0;
begin
  -- 1. lapsed claims: back to OFFERED, with no new preferred window
  for v_fin in
    select * from public.monvelo_financings f
     where f.status = 'CLAIMED' and f.claim_expires_at <= now()
     order by f.id
       for update skip locked
  loop
    update public.monvelo_financing_claims set outcome = 'LAPSED', ended_at = now()
     where financing_id = v_fin.id and outcome is null;
    update public.monvelo_financings
       set status = 'OFFERED', claimed_by_agent_id = null, claimed_by = null, claim_expires_at = null,
           pledge_id = null, preferred_window_ends_at = null
     where id = v_fin.id;
    -- R15: the lapse names the agent, so no tenant reads it
    perform public.write_audit(null, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'CLAIMED', 'agent_id', v_fin.claimed_by_agent_id),
      jsonb_build_object('status', 'OFFERED', 'reason', 'CLAIM_LAPSED'),
      null, 'CRON', v_fin.raised_by);
    v_lapsed := v_lapsed + 1;
  end loop;

  -- 2. the supply day (Lagos) has ended, or the trade order is no longer PENDING
  for v_fin in
    select f.* from public.monvelo_financings f
      join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
     where f.status in ('OFFERED', 'AWAITING_APPROVAL')
       and (now() >= ((f.supply_date + 1)::timestamp at time zone 'Africa/Lagos') or o.status <> 'PENDING')
     order by f.id
       for update of f skip locked
  loop
    v_ended := now() >= ((v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos');
    update public.monvelo_financings set status = 'EXPIRED' where id = v_fin.id;
    v_rel := public.monvelo_cancel_trade_order(v_fin.tenant_id, v_fin.order_id);
    perform public.write_audit(v_fin.tenant_id, 'monvelo_sweep_offers', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', v_fin.status),
      jsonb_build_object('status', 'EXPIRED',
                         'reason', case when v_ended then 'SUPPLY_DAY_ENDED' else 'ORDER_NOT_PENDING' end,
                         'order_cancelled', v_rel is not null, 'reservations_released', v_rel),
      null, 'CRON', v_fin.raised_by);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('lapsed', v_lapsed, 'expired', v_expired);
end;
$function$;

-- ── pledge_monvelo_funds: the audit row is lender-only (R15) ───────────
CREATE OR REPLACE FUNCTION public.pledge_monvelo_funds(p_idempotency_key uuid, p_agent_id uuid, p_area_id uuid, p_supply_date date, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

declare

  v_uid     uuid := (select auth.uid());

  v_prior   jsonb;

  v_status  text;

  v_area    public.areas;

  v_before  public.monvelo_pledges;

  v_after   public.monvelo_pledges;

  v_amount  numeric(15,2);

  v_found   boolean;

  v_reduction boolean;

begin

  if v_uid is null then

    raise exception 'not authenticated' using errcode = '42501';

  end if;

  if p_agent_id is null or not exists (select 1 from public.my_monvelo_agent_ids() m(id) where m.id = p_agent_id) then

    raise exception 'not an active member of this agent' using errcode = '42501';

  end if;



  v_prior := public.idempotency_begin(p_idempotency_key, 'pledge_monvelo_funds',

    jsonb_build_object('agent_id', p_agent_id, 'area_id', p_area_id,

                       'supply_date', p_supply_date, 'amount', p_amount));

  if v_prior is not null then

    return v_prior;

  end if;



  select a.status into v_status from public.monvelo_agents a where a.id = p_agent_id;

  if v_status is distinct from 'ACTIVE' then

    raise exception 'the agent is not active' using errcode = 'P0001';

  end if;



  if p_amount is null or p_amount <= 0 or p_supply_date is null or p_area_id is null then

    raise exception 'an area, a supply date and a positive amount are required' using errcode = 'P0001';

  end if;

  v_amount := round(p_amount, 2);

  if v_amount <= 0 then

    raise exception 'an area, a supply date and a positive amount are required' using errcode = 'P0001';

  end if;



  select * into v_area from public.areas where id = p_area_id;

  if not found then

    raise exception 'area not found' using errcode = 'P0001';

  end if;

  if not coalesce((select ts.enabled from public.monvelo_tenant_settings ts

                    where ts.tenant_id = v_area.tenant_id), false) then

    raise exception 'Monvelo is not enabled for this area''s tenant' using errcode = 'P0001';

  end if;



  select * into v_before from public.monvelo_pledges

   where agent_id = p_agent_id and tenant_id = v_area.tenant_id

     and area_id = p_area_id and supply_date = p_supply_date

   for update;

  v_found := found;



  -- A6 §18.4: a new pledge or an increase is new work and needs an operating

  -- state; a reduction (winding down) is always allowed, even after the TM

  -- has switched the supply day off

  v_reduction := v_found and v_amount <= v_before.amount;

  if not v_reduction then

    perform public.assert_state_app_operational(v_area.tenant_id, v_area.territory_id);

  end if;



  if p_supply_date < public.monvelo_today()

     or (not v_reduction

         and not exists (select 1 from public.monvelo_supply_days d

                          where d.tenant_id = v_area.tenant_id and d.area_id = p_area_id

                            and d.day_of_week = extract(isodow from p_supply_date)::int and d.active)) then

    raise exception 'that date is not a supply day for this area' using errcode = 'P0001';

  end if;



  if not v_found then

    insert into public.monvelo_pledges (tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)

    values (v_area.tenant_id, p_agent_id, p_area_id, p_supply_date, v_amount, v_amount, v_uid)

    returning * into v_after;

  else

    if v_before.remaining + (v_amount - v_before.amount) < 0 then

      raise exception 'a pledge cannot drop below what is already funded' using errcode = 'P0001';

    end if;

    update public.monvelo_pledges

       set amount = v_amount,

           remaining = v_before.remaining + (v_amount - v_before.amount),

           pledged_by = v_uid

     where id = v_before.id

    returning * into v_after;

  end if;



  -- R15: a pledge is the agent's, so no tenant reads its audit row
  perform public.write_audit(null, 'pledge_monvelo_funds', 'monvelo_pledges', v_after.id::text,

                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);



  return public.idempotency_complete(p_idempotency_key,

    jsonb_build_object('pledge_id', v_after.id, 'amount', v_after.amount, 'remaining', v_after.remaining));

end;

$function$;

-- ── request_monvelo_financing: no preferred agent in the audit (R15) ───
CREATE OR REPLACE FUNCTION public.request_monvelo_financing(p_idempotency_key uuid, p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

declare

  v_me        public.tenant_users :=

    public.assert_tenant_role(array['ZSA', 'ASA', 'TM']::public.tenant_role_enum[]);

  v_prior     jsonb;

  v_settings  public.monvelo_tenant_settings;

  v_overdue   numeric(15,2);

  v_book      numeric(15,2);

  v_order     public.orders;

  v_enrol     public.monvelo_shop_enrolments;

  v_area      public.areas;

  v_on_beat   boolean;

  v_today     date := public.monvelo_today();

  v_cleared   timestamptz;

  v_resume    date;

  v_brand     record;

  v_terms     public.monvelo_brand_terms;

  v_limit     public.monvelo_shop_limits;

  v_reset     numeric(15,2);

  v_approval  boolean := false;

  v_brands    text[] := '{}';

  v_keys      text[] := '{}';

  v_amounts   numeric[] := '{}';

  v_ref       text;

  v_fin       public.monvelo_financings;

  i           integer;

begin

  v_prior := public.idempotency_begin(p_idempotency_key, 'request_monvelo_financing',

    jsonb_build_object('order_id', p_order_id));

  if v_prior is not null then

    return v_prior;

  end if;



  -- 1. the tenant lends through Monvelo

  select * into v_settings from public.monvelo_tenant_settings where tenant_id = v_me.tenant_id;

  if not found or not v_settings.enabled then

    raise exception 'Monvelo is not switched on for this tenant' using errcode = 'P0001';

  end if;



  -- 2. a PENDING trade order of the tenant; 3. raised by the caller

  select * into v_order from public.orders o

   where o.tenant_id = v_me.tenant_id and o.id = p_order_id

     for update;

  if not found or v_order.channel <> 'FIELD_SALES' or v_order.status <> 'PENDING' then

    raise exception 'only a pending trade order can be financed' using errcode = 'P0001';

  end if;

  if v_order.teafair_agent_id is distinct from v_me.profile_id then

    raise exception 'only the order''s raiser requests its financing' using errcode = '42501';

  end if;



  -- §7.3: a raiser whose PAR30 (outstanding over 30 days past due, over the

  -- outstanding of everything they raised that has been delivered) passes 10%

  -- raises nothing new, with any tenant, until it drops

  select coalesce(sum(coalesce(f.outstanding, f.principal))

                    filter (where f.status = 'DEFAULTED_WITH_LATE_CHARGE' and f.due_at <= now() - interval '30 days'), 0),

         coalesce(sum(coalesce(f.outstanding, f.principal)), 0)

    into v_overdue, v_book

    from public.monvelo_financings f

   where f.raised_by = v_me.profile_id and f.status in ('DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE');

  if v_book > 0 and v_overdue * 10 > v_book then

    raise exception 'more than 10%% of the Monvelo credit you raised is over 30 days overdue; you can raise new requests once it drops'

      using errcode = 'P0001';

  end if;



  -- new app work (A6 §18.4): the order's state must be on for the app, platform and brand

  perform public.assert_state_app_operational(v_me.tenant_id, v_order.territory_id);



  -- 4. one live financing per order

  if exists (select 1 from public.monvelo_financings f

              where f.tenant_id = v_me.tenant_id and f.order_id = v_order.id

                and f.status not in ('CANCELLED', 'EXPIRED')) then

    raise exception 'this order already has a Monvelo financing' using errcode = 'P0001';

  end if;



  -- 5. the shop is enrolled with the owner's consent

  select * into v_enrol from public.monvelo_shop_enrolments e

   where e.tenant_id = v_me.tenant_id and e.shop_id = v_order.retail_shop_id;

  if not found or v_enrol.status <> 'ACTIVE' then

    raise exception 'the shop is not enrolled in Monvelo' using errcode = 'P0001';

  end if;



  -- 6. on the caller's beat: the ASA's own area, the ZSA's zone, the TM's territory

  select * into v_area from public.areas a where a.tenant_id = v_me.tenant_id and a.id = v_enrol.area_id;

  v_on_beat := case v_me.role

    when 'ASA' then v_me.area_id is not distinct from v_area.id

    when 'ZSA' then exists (select 1 from public.territories t

                             where t.tenant_id = v_me.tenant_id and t.id = v_area.territory_id

                               and t.zone_id = v_me.zone_id)

    else v_me.territory_id is not distinct from v_area.territory_id

  end;

  if not v_on_beat then

    raise exception 'the shop is not on your beat' using errcode = '42501';

  end if;



  -- 7. the order belongs to the area's territory

  if v_order.territory_id is distinct from v_area.territory_id then

    raise exception 'the order was placed in another territory' using errcode = 'P0001';

  end if;



  -- 8. the owner's own phone is verified

  if not exists (select 1 from public.retail_shops s

                   join public.profiles p on p.id = s.owner_id

                   join auth.users u on u.id = p.id

                  where s.id = v_order.retail_shop_id

                    and p.phone_number is not null and u.phone_confirmed_at is not null) then

    raise exception 'the shop owner has no verified phone' using errcode = 'P0001';

  end if;



  -- 9. today (Lagos) is a supply day for the area

  if not exists (select 1 from public.monvelo_supply_days d

                  where d.tenant_id = v_me.tenant_id and d.area_id = v_area.id

                    and d.day_of_week = extract(isodow from v_today)::int and d.active) then

    raise exception 'today is not a supply day for this area' using errcode = 'P0001';

  end if;



  -- the shop's last cleared default, with any tenant (A6 §18.2): each tenant

  -- applies its own cure days and restart limit to it

  select max(coalesce(f.closed_at, f.updated_at)) into v_cleared

    from public.monvelo_financings f

   where f.shop_id = v_order.retail_shop_id and f.status = 'REPAID_LATE';



  -- 10. every brand of the order, or none of it

  for v_brand in

    select min(p.brand) as brand, lower(btrim(p.brand)) as brand_key, sum(i2.line_total) as amount

      from public.order_items i2

      join public.central_products p on p.tenant_id = i2.tenant_id and p.sku_code = i2.sku_code

     where i2.tenant_id = v_me.tenant_id and i2.order_id = v_order.id

     group by lower(btrim(p.brand))

     order by lower(btrim(p.brand))

  loop

    v_terms := public.monvelo_terms_at(v_me.tenant_id, v_brand.brand, v_today);

    if v_terms.id is null then

      raise exception '% has no approved Monvelo terms', v_brand.brand using errcode = 'P0001';

    end if;



    -- the platform hard freeze: read across tenants, named to none

    if exists (select 1 from public.monvelo_financings f

                where f.shop_id = v_order.retail_shop_id and f.status = 'DEFAULTED_WITH_LATE_CHARGE') then

      raise exception 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared'

        using errcode = 'P0001';

    end if;



    -- the brand's cure rule

    if v_cleared is not null then

      v_resume := (v_cleared at time zone 'Africa/Lagos')::date + v_settings.default_cure_days;

      if v_today < v_resume then

        raise exception '% credit resumes on %', v_brand.brand, to_char(v_resume, 'YYYY-MM-DD') using errcode = 'P0001';

      end if;

    end if;



    v_limit := public.monvelo_shop_limit_for(v_me.tenant_id, v_order.retail_shop_id, v_brand.brand_key);

    -- after a cure the limit restarts at post_default_limit_bps of the opening

    -- limit, once per cleared default

    if v_cleared is not null and not exists (

         select 1 from public.monvelo_shop_limit_events e

          where e.tenant_id = v_me.tenant_id and e.shop_id = v_order.retail_shop_id

            and e.brand_key = v_brand.brand_key and e.kind = 'RESET' and e.created_at >= v_cleared) then

      v_reset := round(v_settings.opening_limit * v_settings.post_default_limit_bps / 10000.0, 2);

      insert into public.monvelo_shop_limit_events (tenant_id, shop_id, brand_key, kind, old_limit, new_limit)

      values (v_me.tenant_id, v_order.retail_shop_id, v_brand.brand_key, 'RESET', v_limit.limit_amount, v_reset);

      update public.monvelo_shop_limits

         set limit_amount = v_reset, status = 'ACTIVE'

       where tenant_id = v_me.tenant_id and shop_id = v_order.retail_shop_id and brand_key = v_brand.brand_key

      returning * into v_limit;

    end if;



    -- above the limit: the TM approves (§7.2)

    if public.monvelo_brand_exposure(v_me.tenant_id, v_order.retail_shop_id, v_brand.brand_key, null)

       + v_brand.amount > v_limit.limit_amount then

      v_approval := true;

    end if;



    v_brands := v_brands || v_brand.brand;

    v_keys := v_keys || v_brand.brand_key;

    v_amounts := v_amounts || v_brand.amount;

  end loop;



  if coalesce(array_length(v_keys, 1), 0) = 0 then

    raise exception 'only a pending trade order can be financed' using errcode = 'P0001';

  end if;



  -- a fresh reference: a collision is about one in 10^12, so three draws suffice

  for i in 1 .. 3 loop

    v_ref := public.monvelo_draw_reference();

    exit when not exists (select 1 from public.monvelo_financings f where f.reference = v_ref);

  end loop;



  insert into public.monvelo_financings (tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,

                                         principal, supply_date, status, approval_required)

  values (v_me.tenant_id, v_ref, v_order.retail_shop_id, v_order.id, v_area.id, v_area.territory_id, v_me.profile_id,

          v_order.total_amount, v_today, 'REQUESTED', v_approval)

  returning * into v_fin;



  for i in 1 .. array_length(v_keys, 1) loop

    insert into public.monvelo_financing_lines (tenant_id, financing_id, brand, brand_key, amount)

    values (v_me.tenant_id, v_fin.id, v_brands[i], v_keys[i], v_amounts[i]);

  end loop;



  if v_approval then

    update public.monvelo_financings set status = 'AWAITING_APPROVAL' where id = v_fin.id returning * into v_fin;

  else

    v_fin := public.monvelo_offer(v_fin.id);

  end if;



  perform public.write_audit(v_me.tenant_id, 'request_monvelo_financing', 'monvelo_financings', v_fin.id::text,

    null,

    jsonb_build_object('reference', v_fin.reference, 'order_id', v_fin.order_id, 'shop_id', v_fin.shop_id,

                       'principal', v_fin.principal, 'status', v_fin.status, 'approval_required', v_approval,


                       'lines', (select jsonb_agg(jsonb_build_object('brand', b, 'amount', a))

                                   from unnest(v_brands, v_amounts) as x (b, a))),

    p_idempotency_key);



  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(

    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,

    'principal', v_fin.principal, 'approval_required', v_approval));

end;

$function$;

-- ── approve_monvelo_financing: no preferred agent in the audit (R15) ───
CREATE OR REPLACE FUNCTION public.approve_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['TM']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_fin   public.monvelo_financings;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_fin from public.monvelo_financings f
   where f.tenant_id = v_me.tenant_id and f.id = p_financing_id
     for update;
  if not found then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;
  if v_fin.territory_id is distinct from v_me.territory_id then
    raise exception 'only the territory''s TM approves this financing' using errcode = '42501';
  end if;
  if v_fin.status <> 'AWAITING_APPROVAL' then
    raise exception 'only a financing awaiting approval can be approved' using errcode = 'P0001';
  end if;

  update public.monvelo_financings
     set approved_by = v_me.profile_id, approved_at = now()
   where id = v_fin.id;
  v_fin := public.monvelo_offer(v_fin.id);

  perform public.write_audit(v_me.tenant_id, 'approve_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'AWAITING_APPROVAL'),
    jsonb_build_object('status', v_fin.status, 'approved_by', v_fin.approved_by),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('financing_id', v_fin.id, 'status', v_fin.status));
end;
$function$;

-- ── monvelo_payer_matches: initials do not count (R18) ─────────────────
CREATE OR REPLACE FUNCTION public.monvelo_payer_matches(p_agent monvelo_agents, p_verified jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  -- R18: only tokens of 2 or more letters count toward the 2-token minimum
  return ((select count(*) from unnest(v_sender) t where length(t) >= 2) >= 2 and v_sender <@ v_holder)
      or ((select count(*) from unnest(v_holder) t where length(t) >= 2) >= 2 and v_holder <@ v_sender);
end;
$function$;

-- ── settle_monvelo_funding: the CLAIMED route re-checks agent and member (R17) ──
CREATE OR REPLACE FUNCTION public.settle_monvelo_funding(p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb, p_transaction_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    -- R17: the agent and the member who started the payment are still ACTIVE
    if v_agent.status <> 'ACTIVE' then
      v_reason := 'the agent is not active';
    elsif not exists (select 1 from public.monvelo_agent_members m
                       where m.agent_id = v_agent.id and m.profile_id = v_payment.monvelo_started_by
                         and m.status = 'ACTIVE') then
      v_reason := 'not an active member of this agent';
    elsif v_pledge.id is null or v_pledge.remaining < v_fin.principal then
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
$function$;
