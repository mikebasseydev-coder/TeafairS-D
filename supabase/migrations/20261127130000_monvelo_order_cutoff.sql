-- Addendum A6 §23.5 (rulings 2026-11-27) — the 3:00 PM Africa/Lagos daily
-- consolidation cutoff for next-day supply.
--
--   monvelo_platform_settings.order_cutoff_local   15:00 (Lagos wall clock)
--   monvelo_platform_settings.supply_lead_days     1 (next-day supply)
--
-- A request raised on Lagos day D is for supply_date D + supply_lead_days, and
-- only before D's cutoff; that supply date must be a supply day for the area.
-- The TM approves only before the same cutoff. Offers, claims and funding then
-- run against the supply date's pledges, through the end of that supply day,
-- exactly as before (monvelo_supply_day_ended is unchanged). The financed trade
-- order's stock reservations are extended to the end of the supply date, so
-- the stock sweep does not cancel it at midnight after the order day.
--
-- Both settings are set by migration only (no RPC), like the radius and the
-- window. pgTAP files written before §23 pin supply_lead_days = 0 and a
-- 23:59:59.999999 cutoff inside their own transaction, as 065/066 pin ceilings.
--
-- request_monvelo_financing and approve_monvelo_financing are recreated from
-- their live definitions; only the marked lines change.

alter table public.monvelo_platform_settings
  add column order_cutoff_local time not null default time '15:00',
  add column supply_lead_days   integer not null default 1 check (supply_lead_days between 0 and 7);

-- ── helpers ─────────────────────────────────────────────────────────────
-- The supply date a request raised now is for.
create or replace function public.monvelo_request_supply_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.monvelo_today() + (select ps.supply_lead_days from public.monvelo_platform_settings ps);
$$;
revoke all on function public.monvelo_request_supply_date() from public, anon, authenticated, service_role;
grant execute on function public.monvelo_request_supply_date() to authenticated;
comment on function public.monvelo_request_supply_date() is
  'A6 §23.5: the supply date of a request raised now (Lagos today + supply_lead_days).';

-- The instant requests and approvals for a supply date close: the cutoff on
-- the Lagos day supply_lead_days before it.
create or replace function public.monvelo_order_cutoff_at(p_supply_date date)
returns timestamptz
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select ((p_supply_date - ps.supply_lead_days)::timestamp + ps.order_cutoff_local) at time zone 'Africa/Lagos'
    from public.monvelo_platform_settings ps;
$$;
revoke all on function public.monvelo_order_cutoff_at(date) from public, anon, authenticated, service_role;
grant execute on function public.monvelo_order_cutoff_at(date) to authenticated;
comment on function public.monvelo_order_cutoff_at(date) is
  'A6 §23.5: when requests and TM approvals for a supply date close (Lagos cutoff, supply_lead_days before it).';

-- ── stock reservations: a later expiry is the one other change ─────────
-- A RESERVED row may now stay RESERVED with a later expires_at (a financed
-- trade order held through its supply date); every other rule is unchanged.
create or replace function public.stock_reservations_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op <> 'UPDATE' then
    raise exception 'stock reservations are never deleted' using errcode = 'P0001';
  end if;
  if old.status = 'RESERVED' and new.status = 'RESERVED' then
    if new.expires_at < old.expires_at
       or (new.id, new.tenant_id, new.order_id, new.order_item_id, new.warehouse_id, new.batch_id, new.sku_code,
           new.quantity, new.created_at, new.closed_at, new.close_reason)
          is distinct from
          (old.id, old.tenant_id, old.order_id, old.order_item_id, old.warehouse_id, old.batch_id, old.sku_code,
           old.quantity, old.created_at, old.closed_at, old.close_reason) then
      raise exception 'a held reservation only gets a later expiry' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if old.status <> 'RESERVED' or new.status not in ('CONSUMED', 'RELEASED') then
    raise exception 'a reservation closes once, from RESERVED to CONSUMED or RELEASED' using errcode = 'P0001';
  end if;
  if (new.id, new.tenant_id, new.order_id, new.order_item_id, new.warehouse_id, new.batch_id, new.sku_code,
      new.quantity, new.expires_at, new.created_at)
     is distinct from
     (old.id, old.tenant_id, old.order_id, old.order_item_id, old.warehouse_id, old.batch_id, old.sku_code,
      old.quantity, old.expires_at, old.created_at) then
    raise exception 'only the status of a reservation changes' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- Internal operational writer (A6 §18.1 list, pgTAP 049): hold an order's open
-- reservations until p_until (never earlier than they already run).
create or replace function public.stock_hold_order(p_tenant_id uuid, p_order_id uuid, p_until timestamptz)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  update public.stock_reservations r
     set expires_at = greatest(r.expires_at, p_until)
   where r.tenant_id = p_tenant_id and r.order_id = p_order_id and r.status = 'RESERVED';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.stock_hold_order(uuid, uuid, timestamptz) from public, anon, authenticated, service_role;

-- ── request and approval, recreated from their live definitions ─────────
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
  v_supply    date := public.monvelo_request_supply_date();
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

  -- 9. A6 §23.5: the request is for the next supply date (supply_lead_days
  -- after today, Lagos), it is raised before that date's consolidation cutoff,
  -- and that date is a supply day for the area
  if now() >= public.monvelo_order_cutoff_at(v_supply) then
    raise exception 'today''s Monvelo order cutoff (% Lagos) has passed; raise the request tomorrow before the cutoff',
      left((select ps.order_cutoff_local from public.monvelo_platform_settings ps)::text, 5)
      using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_supply_days d
                  where d.tenant_id = v_me.tenant_id and d.area_id = v_area.id
                    and d.day_of_week = extract(isodow from v_supply)::int and d.active) then
    raise exception '% is not a supply day for this area',
      case v_supply - v_today when 0 then 'today' when 1 then 'tomorrow' else to_char(v_supply, 'YYYY-MM-DD') end
      using errcode = 'P0001';
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
          v_order.total_amount, v_supply, 'REQUESTED', v_approval)
  returning * into v_fin;

  for i in 1 .. array_length(v_keys, 1) loop
    insert into public.monvelo_financing_lines (tenant_id, financing_id, brand, brand_key, amount)
    values (v_me.tenant_id, v_fin.id, v_brands[i], v_keys[i], v_amounts[i]);
  end loop;

  -- A8 §6.4: a brand whose rebate is below the storage premium is refused up
  -- front, by name (the quote raises), unless the shop's own cover exempts it
  -- A6 §23.5: the trade order's stock was reserved to the end of the day it
  -- was placed; a financed order is held through its supply date instead, so
  -- the stock sweep does not cancel it overnight
  perform public.stock_hold_order(v_me.tenant_id, v_order.id, ((v_supply + 1)::timestamp at time zone 'Africa/Lagos'));
  perform public.monvelo_quote_agent_yield(v_fin.id);
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
  -- deferred minor (2026-11-04): live, not only at the minute sweep
  if public.monvelo_supply_day_ended(v_fin.supply_date) then
    raise exception 'this request''s supply day has ended' using errcode = 'P0001';
  end if;
  -- A6 §23.5: approval is part of the consolidation, so it closes at the cutoff
  if now() >= public.monvelo_order_cutoff_at(v_fin.supply_date) then
    raise exception 'the Monvelo order cutoff for this supply date has passed' using errcode = 'P0001';
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
