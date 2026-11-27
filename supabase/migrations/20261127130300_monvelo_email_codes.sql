-- Addendum A6 §23.6 (ruling 2026-11-27) — the shop owner's Monvelo codes go
-- by email.
--
-- The consent code (start_monvelo_consent), the policy consent code
-- (start_monvelo_policy_consent), the delivery code (start_monvelo_delivery)
-- and the repayment code (record_monvelo_repayment) go to the owner's own
-- verified email: auth.users.email with email_confirmed_at set, the address
-- they sign in with (email-first auth, 2026-11-25). Never the shop's contact
-- details, and no WhatsApp or SMS. Each reply now carries destination_email
-- in place of destination_phone; the gateways send it through Resend and
-- return only a masked address. request_monvelo_financing check 8 follows:
-- the owner needs a verified email, not a verified phone, since every later
-- code goes there.
--
-- Codes, hashes, expiries, attempt limits and the one-time reply are
-- unchanged. The five functions are recreated from their live definitions
-- (request_monvelo_financing with the §23.5 cutoff edits of 20261127130000).

-- Internal: the owner's verified sign-in email, or null.
create or replace function public.monvelo_owner_code_email(p_owner_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select lower(btrim(u.email))
    from auth.users u
   where u.id = p_owner_id and u.email_confirmed_at is not null
     and u.email is not null and btrim(u.email) <> '';
$$;
revoke all on function public.monvelo_owner_code_email(uuid) from public, anon, authenticated, service_role;
comment on function public.monvelo_owner_code_email(uuid) is
  'A6 §23.6: where a shop owner''s Monvelo codes go: their verified sign-in email.';

-- ── recreated from their live definitions ───────────────────────────────
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

  -- 8. A6 §23.6: the owner's own email is verified (the codes go there)
  if public.monvelo_owner_code_email((select s.owner_id from public.retail_shops s
                                       where s.id = v_order.retail_shop_id)) is null then
    raise exception 'the shop owner has no verified email' using errcode = 'P0001';
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

CREATE OR REPLACE FUNCTION public.start_monvelo_consent(p_idempotency_key uuid, p_gateway_proof text, p_shop_id uuid, p_area_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_ttl           constant interval := interval '10 minutes';
  c_window        constant interval := interval '1 hour';
  c_max_in_window constant integer  := 3;
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_shop   public.retail_shops;
  v_area   public.areas;
  v_zone   uuid;
  v_status text;
  v_email  text;
  v_draw   bigint;
  v_code   text;
  v_row    public.monvelo_consent_challenges;
  v_reply  jsonb;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  -- neither the proof nor the code is part of the stored request
  v_prior := public.idempotency_begin(p_idempotency_key, 'start_monvelo_consent',
    jsonb_build_object('shop_id', p_shop_id, 'area_id', p_area_id));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  -- the area guard: caller's tenant first, then the role's own scope
  select * into v_area from public.areas where id = p_area_id and tenant_id = v_me.tenant_id;
  if not found then
    raise exception 'that area does not belong to your tenant' using errcode = '42501';
  end if;
  -- A6 §18.4: a code is new app work; in an off state it could never be used
  perform public.assert_state_app_operational(v_me.tenant_id, v_area.territory_id);
  if v_me.role = 'ZSA' then
    select t.zone_id into v_zone from public.territories t
     where t.id = v_area.territory_id and t.tenant_id = v_me.tenant_id;
    if v_zone is distinct from v_me.zone_id then
      raise exception 'that area is outside your zone' using errcode = '42501';
    end if;
  elsif v_me.area_id is distinct from v_area.id then
    raise exception 'that is not your area' using errcode = '42501';
  end if;

  select * into v_shop from public.retail_shops where id = p_shop_id;
  if not found then
    raise exception 'unknown shop' using errcode = 'P0001';
  end if;
  if v_shop.owner_id is null then
    raise exception 'this shop has no owner on record to give consent' using errcode = 'P0001';
  end if;
  -- A6 §23.6: the code goes to the owner's own verified email (their
  -- sign-in address), never to the shop's contact details
  v_email := public.monvelo_owner_code_email(v_shop.owner_id);
  if v_email is null then
    raise exception 'the shop owner has no verified email' using errcode = 'P0001';
  end if;
  select e.status into v_status from public.monvelo_shop_enrolments e
   where e.tenant_id = v_me.tenant_id and e.shop_id = p_shop_id;
  if v_status in ('ACTIVE', 'SUSPENDED') then
    raise exception 'this shop is already enrolled' using errcode = 'P0001';
  end if;

  -- serialise per shop so concurrent starts cannot slip under the limit
  perform pg_advisory_xact_lock(hashtextextended('start_monvelo_consent:' || p_shop_id, 0));
  if (select count(*) from public.monvelo_consent_challenges c
       where c.shop_id = p_shop_id and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this shop; try again later' using errcode = 'P0001';
  end if;

  -- uniform 6 digits: a 32-bit draw, rejection-sampled below the largest
  -- multiple of 10^6 (as issue_otp, audit H2)
  loop
    v_draw := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v_draw < 4294000000;
  end loop;
  v_code := lpad((v_draw % 1000000)::text, 6, '0');

  insert into public.monvelo_consent_challenges (tenant_id, shop_id, area_id, code_hash, expires_at, issued_by)
  values (v_me.tenant_id, p_shop_id, p_area_id, extensions.crypt(v_code, extensions.gen_salt('bf', 8)),
          now() + c_ttl, v_me.profile_id)
  returning * into v_row;

  perform public.write_audit(v_me.tenant_id, 'start_monvelo_consent', 'monvelo_consent_challenges', v_row.id::text,
                             null, to_jsonb(v_row) - 'code_hash', p_idempotency_key);

  v_reply := public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id', v_row.id, 'expires_at', v_row.expires_at, 'destination_email', v_email));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_monvelo_policy_consent(p_idempotency_key uuid, p_gateway_proof text, p_shop_id uuid, p_area_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_ttl           constant interval := interval '10 minutes';
  c_window        constant interval := interval '1 hour';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_shop  public.retail_shops;
  v_email text;
  v_draw  bigint;
  v_code  text;
  v_row   public.monvelo_consent_challenges;
  v_reply jsonb;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'start_monvelo_policy_consent',
    jsonb_build_object('shop_id', p_shop_id, 'area_id', p_area_id));
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if not public.monvelo_covers_area(v_me, p_area_id) then
    raise exception 'that area is not yours' using errcode = '42501';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = v_me.tenant_id and e.shop_id = p_shop_id and e.area_id = p_area_id
                    and e.status = 'ACTIVE') then
    raise exception 'the shop is not enrolled in that area' using errcode = '42501';
  end if;
  select * into v_shop from public.retail_shops where id = p_shop_id;
  if v_shop.owner_id is null then
    raise exception 'this shop has no owner on record to give consent' using errcode = 'P0001';
  end if;
  -- A6 §23.6: the owner's own verified email
  v_email := public.monvelo_owner_code_email(v_shop.owner_id);
  if v_email is null then
    raise exception 'the shop owner has no verified email' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('start_monvelo_policy_consent:' || p_shop_id, 0));
  if (select count(*) from public.monvelo_consent_challenges c
       where c.shop_id = p_shop_id and c.purpose = 'SHOP_POLICY' and c.created_at > now() - c_window) >= c_max_in_window then
    raise exception 'too many codes requested for this shop; try again later' using errcode = 'P0001';
  end if;

  loop
    v_draw := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    exit when v_draw < 4294000000;
  end loop;
  v_code := lpad((v_draw % 1000000)::text, 6, '0');

  insert into public.monvelo_consent_challenges (tenant_id, shop_id, area_id, code_hash, expires_at, issued_by, purpose)
  values (v_me.tenant_id, p_shop_id, p_area_id, extensions.crypt(v_code, extensions.gen_salt('bf', 8)),
          now() + c_ttl, v_me.profile_id, 'SHOP_POLICY')
  returning * into v_row;
  perform public.write_audit(null, 'start_monvelo_policy_consent', 'monvelo_consent_challenges', v_row.id::text,
                             null, to_jsonb(v_row) - 'code_hash', p_idempotency_key);

  v_reply := public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'challenge_id', v_row.id, 'expires_at', v_row.expires_at, 'destination_email', v_email));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_monvelo_delivery(p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_ttl           constant interval := interval '10 minutes';
  c_window        constant interval := interval '1 hour';
  c_max_in_window constant integer  := 3;
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_fin   public.monvelo_financings;
  v_order public.orders;
  v_owner uuid;
  v_email text;
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

  -- A6 §23.6: the owner's own verified email (as start_monvelo_consent)
  select s.owner_id into v_owner from public.retail_shops s where s.id = v_fin.shop_id;
  v_email := public.monvelo_owner_code_email(v_owner);
  if v_email is null then
    raise exception 'the shop owner has no verified email' using errcode = 'P0001';
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
    'challenge_id', v_row.id, 'expires_at', v_row.expires_at, 'destination_email', v_email));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_monvelo_repayment(p_idempotency_key uuid, p_gateway_proof text, p_financing_id uuid, p_agent_id uuid, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_email   text;
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

  -- A6 §23.6: the owner's own verified email (as start_monvelo_delivery)
  select s.owner_id into v_owner from public.retail_shops s where s.id = v_fin.shop_id;
  v_email := public.monvelo_owner_code_email(v_owner);
  if v_email is null then
    raise exception 'the shop owner has no verified email' using errcode = 'P0001';
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
    'repayment_id', v_rep.id, 'challenge_id', v_ch.id, 'expires_at', v_ch.expires_at, 'destination_email', v_email));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$function$;
