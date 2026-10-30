-- A6 §18.4 (user ruling, 2026-10-30): switching a state off blocks NEW work only.
-- Winding down is always allowed: deactivating a supply day, reducing a pledge.
-- Issuing a shop-owner consent code is gated like enrolment, since a code
-- issued in an off state could never be used.

CREATE OR REPLACE FUNCTION public.set_monvelo_supply_day(p_idempotency_key uuid, p_area_id uuid, p_day_of_week integer, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_area   public.areas;
  v_before public.monvelo_supply_days;
  v_after  public.monvelo_supply_days;
begin
  select * into v_area from public.areas
   where id = p_area_id and tenant_id = v_me.tenant_id;
  if not found or v_me.role <> 'TM' or v_area.territory_id is distinct from v_me.territory_id then
    raise exception 'supply days are set by the TM of the area''s territory' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_supply_day',
    jsonb_build_object('area_id', p_area_id, 'day_of_week', p_day_of_week, 'active', p_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_day_of_week is null or p_day_of_week not between 1 and 7 or p_active is null then
    raise exception 'a weekday from 1 (Monday) to 7 and an active flag are required' using errcode = 'P0001';
  end if;
  -- A6 §18.4: activating is new work and needs an operating state;
  -- deactivating (winding down) is always allowed
  if p_active then
    perform public.assert_state_app_operational(v_me.tenant_id, v_area.territory_id);
  end if;

  select * into v_before from public.monvelo_supply_days
   where tenant_id = v_me.tenant_id and area_id = p_area_id and day_of_week = p_day_of_week
   for update;

  insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by)
  values (v_me.tenant_id, p_area_id, p_day_of_week, p_active, v_me.profile_id)
  on conflict (tenant_id, area_id, day_of_week) do update
    set active = excluded.active, set_by = excluded.set_by
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_supply_day', 'monvelo_supply_days',
                             p_area_id::text || ':' || p_day_of_week::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('area_id', p_area_id, 'day_of_week', p_day_of_week, 'active', v_after.active));
end;
$function$
;

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

  perform public.write_audit(v_area.tenant_id, 'pledge_monvelo_funds', 'monvelo_pledges', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('pledge_id', v_after.id, 'amount', v_after.amount, 'remaining', v_after.remaining));
end;
$function$
;

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
  v_phone  text;
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
  -- the code goes to the owner's own verified phone (the profile's, as
  -- invite_tenant_user does), never to the shop's contact number
  select p.phone_number into v_phone
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.id = v_shop.owner_id and u.phone_confirmed_at is not null;
  if v_phone is null then
    raise exception 'the shop owner has no verified phone' using errcode = 'P0001';
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
    'challenge_id', v_row.id, 'expires_at', v_row.expires_at, 'destination_phone', v_phone));
  return v_reply || jsonb_build_object('code', v_code, 'replayed', false);
end;
$function$
;

