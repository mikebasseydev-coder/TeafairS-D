-- Domain separation, Task 3 (A6 section 15.4): the web domain gets its own names.
--   fintech_partners -> web_pos_partners   fintech_terminals -> web_pos_venues
--   agent_codes      -> web_referral_codes commission_records -> web_commissions
-- A pure rename: no behaviour or amount changes. Task 4 changes the commission rule.
-- ALTER ... RENAME keeps rows, grants, column privileges, RLS and constraint definitions.
-- Function bodies are not dependency-tracked, so every body naming an old identifier is
-- recreated below from its live definition, names only, with its grants re-issued.

-- ---------------------------------------------------------------------------
-- 1. Constraints and indexes (by their old table names, before the tables move)
-- ---------------------------------------------------------------------------
alter table public.fintech_partners rename constraint fintech_partners_commission_bps_check
  to web_pos_partners_commission_bps_check;  -- dropped with its column in Task 4
alter table public.orders rename constraint orders_agent_code_fk to orders_referral_code_fk;
alter table public.orders rename constraint orders_attributed_terminal_fk to orders_attributed_venue_fk;
alter table public.fintech_partners rename constraint fintech_partners_active_is_approved to web_pos_partners_active_is_approved;
alter table public.fintech_partners rename constraint fintech_partners_approved_by_fkey to web_pos_partners_approved_by_fkey;
alter table public.fintech_partners rename constraint fintech_partners_business_name_check to web_pos_partners_business_name_check;
alter table public.fintech_partners rename constraint fintech_partners_contact_phone_check to web_pos_partners_contact_phone_check;
alter table public.fintech_partners rename constraint fintech_partners_paystack_subaccount_code_check to web_pos_partners_paystack_subaccount_code_check;
alter table public.fintech_partners rename constraint fintech_partners_pkey to web_pos_partners_pkey;
alter table public.fintech_partners rename constraint fintech_partners_status_check to web_pos_partners_status_check;
alter table public.fintech_partners rename constraint fintech_partners_tenant_id_fkey to web_pos_partners_tenant_id_fkey;
alter table public.fintech_partners rename constraint fintech_partners_tenant_id_id_key to web_pos_partners_tenant_id_id_key;
alter table public.fintech_partners rename constraint fintech_partners_tenant_id_pos_network_business_name_key to web_pos_partners_tenant_id_pos_network_business_name_key;
alter table public.fintech_partners rename constraint fintech_partners_tenant_id_territory_id_fkey to web_pos_partners_tenant_id_territory_id_fkey;
alter table public.fintech_terminals rename constraint fintech_terminals_address_text_check to web_pos_venues_address_text_check;
alter table public.fintech_terminals rename constraint fintech_terminals_agent_id_fkey to web_pos_venues_agent_id_fkey;
alter table public.fintech_terminals rename constraint fintech_terminals_operating_hours_check to web_pos_venues_operating_hours_check;
alter table public.fintech_terminals rename constraint fintech_terminals_pkey to web_pos_venues_pkey;
alter table public.fintech_terminals rename constraint fintech_terminals_state_check to web_pos_venues_state_check;
alter table public.fintech_terminals rename constraint fintech_terminals_tenant_id_fkey to web_pos_venues_tenant_id_fkey;
alter table public.fintech_terminals rename constraint fintech_terminals_tenant_id_id_key to web_pos_venues_tenant_id_id_key;
alter table public.fintech_terminals rename constraint fintech_terminals_tenant_id_partner_id_fkey to web_pos_venues_tenant_id_partner_id_fkey;
alter table public.fintech_terminals rename constraint fintech_terminals_tenant_id_terminal_id_key to web_pos_venues_tenant_id_network_terminal_id_key;
alter table public.fintech_terminals rename constraint fintech_terminals_tenant_id_territory_id_fkey to web_pos_venues_tenant_id_territory_id_fkey;
alter table public.fintech_terminals rename constraint fintech_terminals_terminal_id_check to web_pos_venues_network_terminal_id_check;
alter table public.fintech_terminals rename constraint fintech_terminals_venue_complete to web_pos_venues_venue_complete;
alter table public.fintech_terminals rename constraint fintech_terminals_venue_name_check to web_pos_venues_venue_name_check;
alter table public.payments rename constraint payments_tenant_id_fintech_partner_id_fkey to payments_tenant_id_web_pos_partner_id_fkey;
alter table public.payments rename constraint payments_tenant_id_fintech_terminal_id_fkey to payments_tenant_id_web_pos_venue_id_fkey;
alter table public.commission_records rename constraint commission_records_amount_check to web_commissions_amount_check;
alter table public.commission_records rename constraint commission_records_bps_applied_check to web_commissions_bps_applied_check;
alter table public.commission_records rename constraint commission_records_disputed_has_reason to web_commissions_disputed_has_reason;
alter table public.commission_records rename constraint commission_records_paystack_subaccount_code_check to web_commissions_paystack_subaccount_code_check;
alter table public.commission_records rename constraint commission_records_pkey to web_commissions_pkey;
alter table public.commission_records rename constraint commission_records_settled_has_time to web_commissions_settled_has_time;
alter table public.commission_records rename constraint commission_records_teafair_agent_id_fkey to web_commissions_teafair_agent_id_fkey;
alter table public.commission_records rename constraint commission_records_tenant_id_fintech_partner_id_fkey to web_commissions_tenant_id_web_pos_partner_id_fkey;
alter table public.commission_records rename constraint commission_records_tenant_id_fkey to web_commissions_tenant_id_fkey;
alter table public.commission_records rename constraint commission_records_tenant_id_order_id_fkey to web_commissions_tenant_id_order_id_fkey;
alter table public.commission_records rename constraint commission_records_tenant_id_payment_id_fkey to web_commissions_tenant_id_payment_id_fkey;
alter table public.commission_records rename constraint commission_records_tenant_id_payment_id_key to web_commissions_tenant_id_payment_id_key;
alter table public.agent_codes rename constraint agent_codes_agent_id_fkey to web_referral_codes_agent_id_fkey;
alter table public.agent_codes rename constraint agent_codes_code_check to web_referral_codes_code_check;
alter table public.agent_codes rename constraint agent_codes_code_key to web_referral_codes_code_key;
alter table public.agent_codes rename constraint agent_codes_created_by_fkey to web_referral_codes_created_by_fkey;
alter table public.agent_codes rename constraint agent_codes_discount_pair to web_referral_codes_discount_pair;
alter table public.agent_codes rename constraint agent_codes_discount_type_check to web_referral_codes_discount_type_check;
alter table public.agent_codes rename constraint agent_codes_fixed_positive to web_referral_codes_fixed_positive;
alter table public.agent_codes rename constraint agent_codes_max_redemptions_check to web_referral_codes_max_redemptions_check;
alter table public.agent_codes rename constraint agent_codes_percent_range to web_referral_codes_percent_range;
alter table public.agent_codes rename constraint agent_codes_pkey to web_referral_codes_pkey;
alter table public.agent_codes rename constraint agent_codes_tenant_id_fkey to web_referral_codes_tenant_id_fkey;
alter table public.agent_codes rename constraint agent_codes_tenant_id_id_key to web_referral_codes_tenant_id_id_key;
alter table public.agent_codes rename constraint agent_codes_tenant_id_terminal_id_fkey to web_referral_codes_tenant_id_venue_id_fkey;
alter index public.idx_fintech_partners_territory rename to idx_web_pos_partners_territory;
alter index public.idx_fintech_partners_approved_by rename to idx_web_pos_partners_approved_by;
alter index public.idx_fintech_terminals_partner rename to idx_web_pos_venues_partner;
alter index public.idx_fintech_terminals_agent rename to idx_web_pos_venues_agent;
alter index public.idx_fintech_terminals_territory rename to idx_web_pos_venues_territory;
alter index public.idx_payments_partner rename to idx_payments_web_pos_partner;
alter index public.idx_payments_terminal rename to idx_payments_web_pos_venue;
alter index public.idx_commission_records_order rename to idx_web_commissions_order;
alter index public.idx_commission_records_partner rename to idx_web_commissions_partner;
alter index public.idx_commission_records_teafair_agent rename to idx_web_commissions_teafair_agent;
alter index public.idx_fintech_terminals_location rename to idx_web_pos_venues_location;
alter index public.idx_agent_codes_agent rename to idx_web_referral_codes_agent;
alter index public.idx_agent_codes_terminal rename to idx_web_referral_codes_venue;
alter index public.idx_agent_codes_created_by rename to idx_web_referral_codes_created_by;
alter index public.idx_orders_agent_code rename to idx_orders_referral_code;
alter index public.idx_orders_attributed_terminal rename to idx_orders_attributed_venue;
alter index public.idx_commission_records_split rename to idx_web_commissions_split;

-- ---------------------------------------------------------------------------
-- 2. Tables and columns
-- ---------------------------------------------------------------------------
alter table public.fintech_partners  rename to web_pos_partners;
alter table public.fintech_terminals rename to web_pos_venues;
alter table public.agent_codes       rename to web_referral_codes;
alter table public.commission_records rename to web_commissions;

alter table public.payments rename column fintech_partner_id  to web_pos_partner_id;
alter table public.payments rename column fintech_terminal_id to web_pos_venue_id;
alter table public.web_commissions rename column fintech_partner_id to web_pos_partner_id;
alter table public.web_referral_codes rename column terminal_id to venue_id;
alter table public.web_pos_venues rename column terminal_id to network_terminal_id;
alter table public.orders rename column agent_code_id to referral_code_id;
alter table public.orders rename column attributed_terminal_id to attributed_venue_id;

-- ---------------------------------------------------------------------------
-- 3. Policies, triggers and the trigger function
-- ---------------------------------------------------------------------------
alter policy fintech_partners_select_tenant_member  on public.web_pos_partners   rename to web_pos_partners_select_tenant_member;
alter policy fintech_terminals_select_tenant_member on public.web_pos_venues     rename to web_pos_venues_select_tenant_member;
alter policy agent_codes_select_tenant_member       on public.web_referral_codes rename to web_referral_codes_select_tenant_member;
alter policy commission_records_select_tenant_member on public.web_commissions   rename to web_commissions_select_tenant_member;

alter trigger fintech_partners_set_updated_at   on public.web_pos_partners   rename to web_pos_partners_set_updated_at;
alter trigger fintech_terminals_set_updated_at  on public.web_pos_venues     rename to web_pos_venues_set_updated_at;
alter trigger agent_codes_set_updated_at        on public.web_referral_codes rename to web_referral_codes_set_updated_at;
alter trigger commission_records_set_updated_at on public.web_commissions    rename to web_commissions_set_updated_at;
alter trigger agent_codes_no_discount           on public.web_referral_codes rename to web_referral_codes_no_discount;
alter trigger commission_records_support_ticket_ins on public.web_commissions rename to web_commissions_support_ticket_ins;
alter trigger commission_records_support_ticket_upd on public.web_commissions rename to web_commissions_support_ticket_upd;
alter function public.agent_codes_no_discount() rename to web_referral_codes_no_discount;

-- ---------------------------------------------------------------------------
-- 4. The two renamed staff RPCs (dropped and created; same grants)
-- ---------------------------------------------------------------------------
drop function public.upsert_agent_code(uuid, text, uuid, uuid, text, numeric, integer, timestamptz, boolean);
drop function public.set_terminal_venue(uuid, uuid, venue_channel_enum, text, text, text, text, double precision, double precision, jsonb);

-- ---------------------------------------------------------------------------
-- 5. Recreated bodies (names only)
-- ---------------------------------------------------------------------------

-- upsert_agent_code
CREATE OR REPLACE FUNCTION public.upsert_web_referral_code(p_idempotency_key uuid, p_code text, p_agent_id uuid, p_venue_id uuid, p_discount_type text, p_discount_value numeric, p_max_redemptions integer, p_expires_at timestamp with time zone, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_agent  public.tenant_users;
  v_before public.web_referral_codes;
  v_after  public.web_referral_codes;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_web_referral_code',
    jsonb_build_object('code', v_code, 'agent_id', p_agent_id, 'venue_id', p_venue_id,
                       'discount_type', p_discount_type, 'discount_value', p_discount_value,
                       'max_redemptions', p_max_redemptions, 'expires_at', p_expires_at,
                       'is_active', p_is_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_code !~ '^[A-Z0-9][A-Z0-9-]{3,31}$' then
    raise exception 'a code is 4 to 32 letters, digits or dashes' using errcode = 'P0001';
  end if;

  select * into v_agent from public.tenant_users
   where tenant_id = v_me.tenant_id and profile_id = p_agent_id
   order by (status = 'ACTIVE') desc
   limit 1;
  if not found then
    raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_agent.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM issues codes for agents in their own territory only' using errcode = '42501';
  end if;
  if p_venue_id is not null and not exists (
    select 1 from public.web_pos_venues ft
     where ft.tenant_id = v_me.tenant_id and ft.id = p_venue_id and ft.agent_id = p_agent_id
  ) then
    raise exception 'the terminal must belong to the agent' using errcode = 'P0001';
  end if;

  if (p_discount_type is null) <> (p_discount_value is null) then
    raise exception 'a discount needs both a type and a value' using errcode = 'P0001';
  end if;
  if p_discount_type is not null and p_discount_type not in ('PERCENT', 'FIXED') then
    raise exception 'discount type must be PERCENT or FIXED' using errcode = 'P0001';
  end if;
  if p_discount_type = 'PERCENT' and not (p_discount_value > 0 and p_discount_value <= 100) then
    raise exception 'a percentage discount is more than 0 and at most 100' using errcode = 'P0001';
  end if;
  if p_discount_type = 'FIXED' and not (p_discount_value > 0) then
    raise exception 'a fixed discount is more than 0' using errcode = 'P0001';
  end if;
  if p_max_redemptions is not null and p_max_redemptions < 1 then
    raise exception 'max_redemptions is at least 1' using errcode = 'P0001';
  end if;

  select * into v_before from public.web_referral_codes where code = v_code for update;
  if found then
    if v_before.tenant_id <> v_me.tenant_id then
      raise exception 'that code is already taken' using errcode = 'P0001';
    end if;
    if v_before.agent_id <> p_agent_id then
      raise exception 'a code''s agent never changes; deactivate it and issue a new code' using errcode = 'P0001';
    end if;
    if coalesce(p_is_active, v_before.is_active) and v_agent.status <> 'ACTIVE' then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    update public.web_referral_codes
       set venue_id        = p_venue_id,
           discount_type   = p_discount_type,
           discount_value  = p_discount_value,
           max_redemptions = p_max_redemptions,
           expires_at      = p_expires_at,
           is_active       = coalesce(p_is_active, v_before.is_active)
     where id = v_before.id
    returning * into v_after;
  else
    if v_agent.status <> 'ACTIVE' and coalesce(p_is_active, true) then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    insert into public.web_referral_codes (tenant_id, code, agent_id, venue_id, discount_type, discount_value,
                                    max_redemptions, expires_at, is_active, created_by)
    values (v_me.tenant_id, v_code, p_agent_id, p_venue_id, p_discount_type, p_discount_value,
            p_max_redemptions, p_expires_at, coalesce(p_is_active, true), v_me.profile_id)
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_web_referral_code', 'web_referral_codes', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('referral_code_id', v_after.id, 'code', v_after.code));
end;
$function$
;

-- set_terminal_venue
CREATE OR REPLACE FUNCTION public.set_web_pos_venue(p_idempotency_key uuid, p_venue_id uuid, p_venue_channel venue_channel_enum, p_venue_name text, p_address_text text, p_state text, p_lga text, p_latitude double precision, p_longitude double precision, p_operating_hours jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me       public.tenant_users := public.assert_tenant_role(
                array['ZSM', 'TM', 'POS_AGENT']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_before   public.web_pos_venues;
  v_after    public.web_pos_venues;
  v_point    extensions.geometry;
  v_boundary extensions.geometry;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_web_pos_venue',
    jsonb_build_object('venue_id', p_venue_id, 'venue_channel', p_venue_channel,
                       'venue_name', p_venue_name, 'address_text', p_address_text,
                       'state', p_state, 'lga', p_lga, 'latitude', p_latitude,
                       'longitude', p_longitude, 'operating_hours', p_operating_hours));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.web_pos_venues
   where id = p_venue_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'terminal not found' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_before.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM sets venues for terminals in their own territory only' using errcode = '42501';
  end if;
  if v_me.role = 'POS_AGENT' and v_before.agent_id is distinct from v_me.profile_id then
    raise exception 'an agent sets the venue of their own terminals only' using errcode = '42501';
  end if;

  if p_venue_channel is null
     or coalesce(btrim(p_venue_name), '') = ''
     or coalesce(btrim(p_address_text), '') = ''
     or coalesce(btrim(p_state), '') = '' then
    raise exception 'venue type, name, address and state are required' using errcode = 'P0001';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'a valid GPS location is required' using errcode = 'P0001';
  end if;
  if p_operating_hours is not null and (
       jsonb_typeof(p_operating_hours) <> 'object'
       or exists (
         select 1 from jsonb_each(p_operating_hours) e
          where e.key not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
             or jsonb_typeof(e.value) <> 'string'
             or (e.value #>> '{}') !~ '^(closed|([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9])$')) then
    raise exception 'operating hours use mon..sun keys with "HH:MM-HH:MM" or "closed"' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326);
  select t.boundary into v_boundary from public.territories t
   where t.tenant_id = v_me.tenant_id and t.id = v_before.territory_id;
  if v_boundary is not null and not extensions.st_covers(v_boundary, v_point) then
    raise exception 'the venue lies outside the terminal''s territory' using errcode = 'P0001';
  end if;

  update public.web_pos_venues
     set venue_channel   = p_venue_channel,
         venue_name      = btrim(p_venue_name),
         address_text    = btrim(p_address_text),
         state           = btrim(p_state),
         lga             = nullif(btrim(p_lga), ''),
         location        = v_point,
         operating_hours = p_operating_hours
   where id = v_before.id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_web_pos_venue', 'web_pos_venues', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('venue_id', v_after.id));
end;
$function$
;

-- web_resolve_code
CREATE OR REPLACE FUNCTION public.web_resolve_code(p_code text)
 RETURNS web_referral_codes
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_code public.web_referral_codes;
begin
  select ac.* into v_code
    from public.web_referral_codes ac
    join public.tenants t on t.id = ac.tenant_id and t.status = 'ACTIVE'
    join public.tenant_users tu
      on tu.tenant_id = ac.tenant_id and tu.profile_id = ac.agent_id and tu.status = 'ACTIVE'
    left join public.web_pos_venues ft on ft.tenant_id = ac.tenant_id and ft.id = ac.venue_id
   where ac.code = upper(btrim(coalesce(p_code, '')))
     and ac.is_active
     and (ac.expires_at is null or ac.expires_at > now())
     and (ac.venue_id is null or ft.is_active)
     and (ac.max_redemptions is null or (
           select count(*) from public.orders o
            where o.tenant_id = ac.tenant_id and o.referral_code_id = ac.id
              and o.status in ('PAID', 'IN_TRANSIT', 'DELIVERED')) < ac.max_redemptions);
  if not found then
    raise exception 'This link is no longer valid' using errcode = 'P0001';
  end if;
  return v_code;
end;
$function$
;

-- web_storefront_code
CREATE OR REPLACE FUNCTION public.web_storefront_code(p_code text)
 RETURNS web_referral_codes
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_code public.web_referral_codes;
begin
  if nullif(btrim(p_code), '') is null then
    v_code.tenant_id := public.web_codeless_tenant();
    return v_code;
  end if;
  return public.web_resolve_code(p_code);
end;
$function$
;

-- web_route_try
CREATE OR REPLACE FUNCTION public.web_route_try(p_tenant_id uuid, p_code web_referral_codes, p_lga_id uuid)
 RETURNS web_route
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_coded      boolean := p_code.id is not null;
  v_state      text;
  v_holder     public.tenant_users;
  v_terminal_t uuid;
  v_territory  uuid;
  v_zone       uuid;
  v_warehouse  uuid;
  v_acct       uuid;
  v_r          public.web_route;
begin
  select state_code into v_state from public.ng_lgas where id = p_lga_id;

  -- 1. territory
  if v_coded then
    select * into v_holder from public.tenant_users
     where tenant_id = p_tenant_id and profile_id = p_code.agent_id and status = 'ACTIVE';
    if p_code.venue_id is not null then
      select territory_id into v_terminal_t from public.web_pos_venues
       where tenant_id = p_tenant_id and id = p_code.venue_id;
    end if;
    v_territory := coalesce(v_terminal_t, v_holder.territory_id);
  end if;
  if v_territory is null and v_state is not null then
    select territory_id into v_territory from public.territory_coverage
     where tenant_id = p_tenant_id and state_code = v_state and lga_id = p_lga_id;
    if v_territory is null then
      select territory_id into v_territory from public.territory_coverage
       where tenant_id = p_tenant_id and state_code = v_state and lga_id is null;
    end if;
  end if;

  -- 2. warehouse
  select coalesce(
           (select t.web_fulfilment_warehouse_id from public.territories t
             where t.tenant_id = p_tenant_id and t.id = v_territory),
           (select s.web_default_warehouse_id from public.tenant_settings s
             where s.tenant_id = p_tenant_id))
    into v_warehouse;

  -- 3. accountable person; every candidate must be an ACTIVE member
  if v_coded then
    if v_holder.role in ('DSA', 'DSM', 'ASM', 'TM', 'ZSM') then
      v_acct := v_holder.profile_id;
    else
      select tu.profile_id into v_acct
        from public.territories t
        join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id
                                   and tu.status = 'ACTIVE'
       where t.tenant_id = p_tenant_id and t.id = v_territory;
    end if;
  else
    select tu.profile_id into v_acct
      from public.territories t
      join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id
                                 and tu.status = 'ACTIVE'
     where t.tenant_id = p_tenant_id and t.id = v_territory;
    if v_acct is null then
      select zone_id into v_zone from public.territories
       where tenant_id = p_tenant_id and id = v_territory;
      select tu.profile_id into v_acct
        from public.zones z
        join public.tenant_users tu on tu.tenant_id = z.tenant_id and tu.profile_id = z.zsm_id
                                   and tu.status = 'ACTIVE'
       where z.tenant_id = p_tenant_id and z.id = v_zone;
    end if;
    if v_acct is null then
      select tu.profile_id into v_acct
        from public.tenant_settings s
        join public.tenant_users tu on tu.tenant_id = s.tenant_id and tu.profile_id = s.web_default_agent_id
                                   and tu.status = 'ACTIVE'
       where s.tenant_id = p_tenant_id;
    end if;
  end if;

  v_r.territory_id := v_territory;
  v_r.warehouse_id := v_warehouse;
  v_r.accountable_id := v_acct;
  return v_r;
end;
$function$
;

-- web_price_cart
CREATE OR REPLACE FUNCTION public.web_price_cart(p_code web_referral_codes, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_count    integer;
  v_matched  integer;
  v_lines    jsonb;
  v_subtotal numeric(15,2);
  v_discount numeric(15,2);
  v_total    numeric(15,2);
  v_split    jsonb;
  v_fare     numeric(15,2);
begin
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'items must be a list' using errcode = 'P0001';
  end if;
  v_count := jsonb_array_length(p_items);
  if v_count < 1 or v_count > 50 then
    raise exception 'an order has between 1 and 50 items' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) e
     where jsonb_typeof(e) <> 'object'
        or jsonb_typeof(e -> 'sku_code') is distinct from 'string'
        or not (case when jsonb_typeof(e -> 'qty') = 'number' and (e ->> 'qty') ~ '^[0-9]{1,4}$'
                     then (e ->> 'qty')::integer between 1 and 1000
                     else false end)
  ) then
    raise exception 'each item needs a sku_code and a whole quantity from 1 to 1000' using errcode = 'P0001';
  end if;
  if (select count(distinct e ->> 'sku_code') from jsonb_array_elements(p_items) e) <> v_count then
    raise exception 'each product may appear only once' using errcode = 'P0001';
  end if;

  select count(*),
         jsonb_agg(jsonb_build_object(
           'sku_code', p.sku_code, 'product_name', p.product_name,
           'qty', (e ->> 'qty')::integer, 'unit_price', p.unit_price,
           'line_total', round((e ->> 'qty')::integer * p.unit_price, 2)) order by p.sku_code),
         coalesce(sum(round((e ->> 'qty')::integer * p.unit_price, 2)), 0)
    into v_matched, v_lines, v_subtotal
    from jsonb_array_elements(p_items) e
    join public.central_products p
      on p.tenant_id = p_code.tenant_id and p.sku_code = e ->> 'sku_code' and p.is_active;
  if v_matched <> v_count then
    raise exception 'a product in your cart is no longer available' using errcode = 'P0001';
  end if;

  v_discount := 0;  -- no web discounts: every line at unit_price
  v_total := v_subtotal;
  if v_total <= 0 then
    raise exception 'the order total must be more than zero' using errcode = 'P0001';
  end if;

  select s.split into v_split
    from (select jsonb_build_object('web_pos_partner_id', fp.id,
                                    'subaccount_code', fp.paystack_subaccount_code,
                                    'commission_bps', case when ts.web_agent_bounty is null then fp.commission_bps else 0 end,
                                    'partner_share', coalesce(ts.web_agent_bounty,
                                                              round(v_total * fp.commission_bps / 10000, 2))) as split
            from public.web_pos_venues ft
            join public.web_pos_partners fp
              on fp.tenant_id = ft.tenant_id and fp.id = ft.partner_id and fp.status = 'ACTIVE'
            left join public.tenant_settings ts on ts.tenant_id = ft.tenant_id
           where ft.tenant_id = p_code.tenant_id and ft.id = p_code.venue_id) s
   where (s.split ->> 'partner_share')::numeric > 0
     and (s.split ->> 'partner_share')::numeric < v_total;

  -- the tenant's flat transport fare: never discounted, never commissioned
  v_fare := coalesce((select s.web_transport_fare from public.tenant_settings s
                       where s.tenant_id = p_code.tenant_id), 0);

  return jsonb_build_object(
    'lines', v_lines,
    'subtotal', v_subtotal,
    'discount', v_discount,
    'goods_total', v_total,
    'transport_fare', v_fare,
    'total', v_total + v_fare,
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = p_code.tenant_id), 'NGN'),
    'split', v_split);
end;
$function$
;

-- storefront_catalogue
CREATE OR REPLACE FUNCTION public.storefront_catalogue(p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_code public.web_referral_codes := public.web_storefront_code(p_code);
begin
  return jsonb_build_object(
    'code', v_code.code,
    'tenant', (select jsonb_build_object('name', t.name, 'logo_url', t.logo_url)
                 from public.tenants t where t.id = v_code.tenant_id),
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_code.tenant_id), 'NGN'),
    'venue', (select case when ft.venue_name is null then null
                          else jsonb_build_object('name', ft.venue_name, 'channel', ft.venue_channel) end
                from public.web_pos_venues ft
               where ft.tenant_id = v_code.tenant_id and ft.id = v_code.venue_id),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', p.sku_code, 'product_name', p.product_name, 'brand', p.brand,
               'category', p.category, 'unit_price', p.unit_price, 'description', p.description)
             order by p.brand, p.product_name)
        from public.central_products p
       where p.tenant_id = v_code.tenant_id and p.is_active
         and public.web_category_sellable(p.sale_category)), '[]'::jsonb),
    'transport_fare', coalesce((select s.web_transport_fare from public.tenant_settings s
                                 where s.tenant_id = v_code.tenant_id), 0),
    'refund_policy', (select jsonb_build_object('version_tag', rp.version_tag)
                        from public.refund_policies rp where rp.is_active),
    'refund_notes', coalesce((
      select jsonb_object_agg(c, case c
               when 'FOOD' then 'Opened food items can''t be refunded. Report transit damage within 24 hours of delivery with photos.'
               when 'COSMETICS' then 'Opened or used cosmetics can''t be refunded. Patch-test before first use. Report damage or leaks within 24 hours of delivery with photos.'
             end)
        from public.refund_policies rp, unnest(rp.categories) as c
       where rp.is_active and c in ('FOOD', 'COSMETICS')), '{}'::jsonb));
end;
$function$
;

-- storefront_locations
CREATE OR REPLACE FUNCTION public.storefront_locations(p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_code  public.web_referral_codes := public.web_storefront_code(p_code);
  v_coded public.web_referral_codes;
begin
  if v_code.id is not null then
    v_coded := v_code;
  end if;
  return (
    with lga as (
      select l.state_code, l.id, l.name,
             (r.territory_id is not null and r.warehouse_id is not null and r.accountable_id is not null) as deliverable
        from public.ng_lgas l
        cross join lateral public.web_route_try(v_code.tenant_id, v_coded, l.id) r
    )
    select jsonb_build_object('states', jsonb_agg(jsonb_build_object(
             'code', s.code, 'name', s.name,
             'lgas', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'deliverable', g.deliverable)
                                       order by g.name)
                        from lga g where g.state_code = s.code))
           order by s.name))
      from public.ng_states s);
end;
$function$
;

-- quote_web_order
CREATE OR REPLACE FUNCTION public.quote_web_order(p_code text, p_items jsonb, p_lga_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_code public.web_referral_codes := public.web_storefront_code(p_code);
begin
  perform public.web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id);
  return public.web_price_cart(v_code, p_items);
end;
$function$
;

-- place_web_order
CREATE OR REPLACE FUNCTION public.place_web_order(p_idempotency_key uuid, p_code text, p_items jsonb, p_customer jsonb, p_utm jsonb, p_payment_route text, p_expected_total numeric, p_checkout jsonb, p_lga_id uuid, p_accepted_refund_policy boolean, p_policy_version_tag text, p_client_ip inet, p_phone_verification_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_prior       jsonb;
  v_code        public.web_referral_codes;
  v_cart        jsonb;
  v_total       numeric(15,2);
  v_name        text := nullif(btrim(p_customer ->> 'name'), '');
  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));
  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));
  v_address     text := nullif(btrim(p_customer ->> 'delivery_address'), '');
  v_terminal    public.web_pos_venues;
  v_route       public.web_route;  -- D1
  v_split       jsonb;             -- D1
  v_ref         text;
  v_order       public.orders;
  v_policy      public.refund_policies;          -- A5
  v_verif       public.web_phone_verifications;  -- A5
  v_now         timestamptz := now();
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total,
                       'lga_id', p_lga_id));  -- D1
  -- A5: the verification token and the client IP are left out of the request
  -- hash on purpose (as A3 leaves out its secret): a replay carries a token
  -- that is already consumed, and neither belongs in idempotency_logs.
  if v_prior is not null then
    return v_prior;  -- a replay keeps the original order and its original consent
  end if;

  -- A5 §3.6, §3.3: consent first, then the policy it was given against
  if p_accepted_refund_policy is distinct from true then
    raise exception 'You must accept the refund policy to place an order.' using errcode = 'P0001';
  end if;
  select * into v_policy from public.refund_policies where is_active;
  if not found or p_policy_version_tag is distinct from v_policy.version_tag then
    raise exception 'The refund policy has changed. Please review it and try again.' using errcode = 'P0001';
  end if;

  if p_payment_route is null or p_payment_route not in ('PAYSTACK_WEB', 'POS_AGENT') then
    raise exception 'payment route must be PAYSTACK_WEB or POS_AGENT' using errcode = 'P0001';
  end if;

  v_code := public.web_storefront_code(p_code);  -- D1: null or blank is codeless
  if p_payment_route = 'POS_AGENT' and v_code.venue_id is null then
    raise exception 'paying at an agent needs a link from a POS agent' using errcode = 'P0001';
  end if;

  v_cart := public.web_price_cart(v_code, p_items);
  v_total := (v_cart ->> 'total')::numeric;
  if p_expected_total is distinct from v_total then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A5 §3.1: every line must be in a category the active policy covers
  if exists (select 1 from jsonb_array_elements(v_cart -> 'lines') l
               join public.central_products cp
                 on cp.tenant_id = v_code.tenant_id and cp.sku_code = l ->> 'sku_code'
              where not public.web_category_sellable(cp.sale_category)) then
    raise exception 'This product is not available to order yet.' using errcode = 'P0001';
  end if;

  if v_name is null then
    raise exception 'your name is required' using errcode = 'P0001';
  end if;
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'a valid phone number is required' using errcode = 'P0001';
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'the email address is not valid' using errcode = 'P0001';
  end if;
  if v_address is null then
    raise exception 'a delivery address is required' using errcode = 'P0001';
  end if;
  if p_payment_route = 'PAYSTACK_WEB' and (
       coalesce(p_checkout ->> 'reference', '') = '' or coalesce(p_checkout ->> 'authorization_url', '') = '') then
    raise exception 'checkout details are missing' using errcode = 'P0001';
  end if;

  -- D1 Decision 6: the split Paystack was initialised with must be this
  -- quote split, or both JSON null. A missing key is not JSON null.
  v_split := nullif(v_cart -> 'split', 'null'::jsonb);
  if p_payment_route = 'PAYSTACK_WEB' and (p_checkout -> 'split') is distinct from
       (case when v_split is null then 'null'::jsonb
             else jsonb_build_object('subaccount_code', v_split -> 'subaccount_code',
                                     'commission_bps',  v_split -> 'commission_bps',
                                     'partner_share',   v_split -> 'partner_share') end) then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A2: the phone now lives on order_contacts
  if (select count(*) from public.order_contacts c
        join public.orders o on o.id = c.order_id
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour'
         and o.channel = 'ONLINE' and o.status = 'PENDING') >= 5 then
    raise exception 'Too many unpaid orders for this phone number. Try again later.' using errcode = 'P0001';
  end if;

  -- A5 §3.5: the buyer proved this number on WhatsApp. The token is bound to
  -- the phone, single use and short lived; the row is locked and consumed.
  select * into v_verif from public.web_phone_verifications
   where token_hash = encode(extensions.digest(coalesce(p_phone_verification_token, ''), 'sha256'), 'hex')
     and verified_at is not null and consumed_at is null
     and token_expires_at > v_now and phone = v_phone
   for update;
  if not found then
    raise exception 'Please verify your WhatsApp number again.' using errcode = 'P0001';
  end if;
  update public.web_phone_verifications set consumed_at = v_now where id = v_verif.id;

  -- D1 §4: territory, warehouse and accountable person, or a refusal
  v_route := public.web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id);
  if v_code.venue_id is not null then
    select * into v_terminal from public.web_pos_venues
     where tenant_id = v_code.tenant_id and id = v_code.venue_id;
  end if;

  -- TF- + 6 Crockford base-32 characters; 256 is a multiple of 32, so uniform
  loop
    v_ref := 'TF-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                                                 1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
                         from generate_series(1, 6));
    exit when not exists (select 1 from public.orders where public_reference = v_ref);
  end loop;

  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, transport_fare, status,
                             referral_code_id, attributed_agent_id, attributed_venue_id,
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference,
                             delivery_lga_id, territory_id, fulfilment_warehouse_id,
                             policy_version_tag, policy_accepted_at)
  values (v_code.tenant_id, 'ONLINE', v_route.accountable_id, v_total, (v_cart ->> 'discount')::numeric,
          (v_cart ->> 'transport_fare')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.venue_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref,
          p_lga_id, v_route.territory_id, v_route.warehouse_id,
          v_policy.version_tag, v_now)
  returning * into v_order;

  -- A2; D1: the contacts territory is the order territory
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address,
                                     consent_ip, phone_verified_at, phone_verified_channel)
  values (v_order.id, v_order.tenant_id, v_route.territory_id, v_name, v_phone, v_email, v_address,
          p_client_ip, v_verif.verified_at, 'WHATSAPP');  -- A5: the IP lives on A2's table only

  insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
  select v_order.tenant_id, v_order.id, l ->> 'sku_code', (l ->> 'qty')::numeric, (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_cart -> 'lines') l;

  if p_payment_route = 'PAYSTACK_WEB' then
    insert into public.payments (tenant_id, order_id, teafair_agent_id, web_pos_partner_id, web_pos_venue_id,
                                 amount, payment_status, paystack_reference, gateway_response_payload,
                                 split_subaccount_code, split_bps, split_amount)
    values (v_order.tenant_id, v_order.id, v_route.accountable_id, v_terminal.partner_id, v_code.venue_id,
            v_total, 'INITIATED', p_checkout ->> 'reference',
            jsonb_build_object('checkout', jsonb_build_object(
              'access_code', p_checkout ->> 'access_code',
              'authorization_url', p_checkout ->> 'authorization_url')),
            v_split ->> 'subaccount_code', (v_split ->> 'commission_bps')::integer,
            (v_split ->> 'partner_share')::numeric);
  end if;

  -- A2: the audit log is readable by every ZSM and TM, so it gets a summary
  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null,
                             to_jsonb(v_order) || jsonb_build_object('contact', jsonb_build_object(
                               'phone_last4', right(v_phone, 4),
                               'has_email', v_email is not null,
                               'has_address', v_address is not null),
                               -- A5: the consent and the fact of verification, never the IP
                               'policy_version_tag', v_order.policy_version_tag,
                               'policy_accepted_at', v_order.policy_accepted_at,
                               'phone_verified', true),
                             p_idempotency_key, 'WEB', v_route.accountable_id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id,
    'public_reference', v_ref,
    'total', v_total,
    'transport_fare', (v_cart ->> 'transport_fare')::numeric,
    'currency', v_cart ->> 'currency',
    'payment_route', p_payment_route,
    'paystack_reference', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'reference' end,
    'authorization_url', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'authorization_url' end));
end;
$function$
;

-- get_order_dispute_evidence
CREATE OR REPLACE FUNCTION public.get_order_dispute_evidence(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_order  public.orders;
  v_policy public.refund_policies;
  v_bundle jsonb;
begin
  -- a missing order and another tenant's order get the same answer
  select * into v_order from public.orders o where o.id = p_order_id;
  if not found or v_order.tenant_id <> v_me.tenant_id then
    raise exception 'not permitted to view the evidence for this order' using errcode = '42501';
  end if;

  select * into v_policy from public.refund_policies rp where rp.version_tag = v_order.policy_version_tag;

  v_bundle := jsonb_build_object(
    'order', jsonb_build_object(
      'order_id', v_order.id,
      'public_reference', v_order.public_reference,
      'channel', v_order.channel,
      'status', v_order.status,
      'payment_route', v_order.payment_route,
      'total_amount', v_order.total_amount,
      'goods_total', v_order.total_amount - v_order.transport_fare,
      'discount_amount', v_order.discount_amount,
      'transport_fare', v_order.transport_fare,
      'referral_code_id', v_order.referral_code_id,
      'created_at', v_order.created_at),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', i.sku_code,
               'sale_category', cp.sale_category,
               'nafdac_regulated', cp.sale_category in ('FOOD', 'COSMETICS'),
               'nafdac_number', cp.nafdac_number,
               'qty', i.qty,
               'unit_price', i.unit_price,
               'line_total', i.line_total) order by i.sku_code)
        from public.order_items i
        join public.central_products cp on cp.tenant_id = i.tenant_id and cp.sku_code = i.sku_code
       where i.tenant_id = v_order.tenant_id and i.order_id = v_order.id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'payment_id', p.id,
               'paystack_reference', p.paystack_reference,
               'amount', p.amount,
               'payment_status', p.payment_status,
               'agent_commission', p.split_amount,
               'created_at', p.created_at,
               'settlement', (select jsonb_build_object('status', c.status, 'settled_at', c.settled_at)
                                from public.web_commissions c
                               where c.tenant_id = p.tenant_id and c.payment_id = p.id))
             order by p.created_at, p.id)
        from public.payments p
       where p.tenant_id = v_order.tenant_id and p.order_id = v_order.id), '[]'::jsonb),
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'payment_id', a.entity_id,
               'refund_id', a.after ->> 'refund_id',
               'kind', case a.operation when 'PARTIAL_REFUND' then 'PARTIAL' else 'FULL' end,
               'reason', a.after ->> 'reason',
               'amount_minor', (a.after ->> 'amount_minor')::bigint,
               'currency', a.after ->> 'currency',
               'recorded_at', a.created_at) order by a.created_at, a.id)
        from public.audit_logs a
       where a.tenant_id = v_order.tenant_id
         and a.entity_type = 'payments'
         and a.operation in ('apply_paystack_refund', 'PARTIAL_REFUND')
         and a.entity_id in (select p.id::text from public.payments p
                              where p.tenant_id = v_order.tenant_id and p.order_id = v_order.id)), '[]'::jsonb),
    'consent', jsonb_build_object(
      'policy_version_tag', v_order.policy_version_tag,
      'policy_accepted_at', v_order.policy_accepted_at,
      'consent_ip', (select host(c.consent_ip) from public.order_contacts c
                      where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id),
      'policy_title', v_policy.title,
      'content', v_policy.content),
    'contact', (select jsonb_build_object(
                  'customer_name', c.customer_name,
                  'customer_phone', c.customer_phone,
                  'customer_email', c.customer_email,
                  'delivery_address', c.delivery_address,
                  'phone_verified_at', c.phone_verified_at,
                  'phone_verified_channel', c.phone_verified_channel)
                  from public.order_contacts c
                 where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id),
    'fulfilment', (select jsonb_build_object(
                     'dispatched_at', f.dispatched_at,
                     'tracking_reference', f.tracking_reference,
                     'delivered_at', f.delivered_at,
                     'delivered_via', f.delivered_via,
                     'damage_claim_deadline', f.damage_claim_deadline,
                     -- a delivery is recorded only after the right code
                     'pin_verified', f.delivered_at is not null,
                     'delivery_photo', case when f.delivery_photo_path is null then null
                                            else jsonb_build_object('bucket', 'delivery-proofs',
                                                                    'storage_path', f.delivery_photo_path) end)
                     from public.order_fulfilments f
                    where f.tenant_id = v_order.tenant_id and f.order_id = v_order.id),
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ticket_id', t.id,
               'public_reference', t.public_reference,
               'kind', t.kind,
               'category', t.category,
               'status', t.status,
               'within_damage_window', t.within_damage_window,
               'created_at', t.created_at,
               'messages', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'sender_type', m.sender_type,
                          'body', m.body,
                          'created_at', m.created_at,
                          'attachments', coalesce((
                            select jsonb_agg(jsonb_build_object(
                                     'attachment_id', u.id,
                                     'mime_type', u.mime_type,
                                     'size_bytes', u.size_bytes,
                                     'bucket', u.bucket,
                                     'storage_path', u.storage_path) order by u.claimed_at, u.id)
                              from public.upload_slots u
                             where u.tenant_id = m.tenant_id and u.ticket_id = m.ticket_id
                               and u.message_id = m.id), '[]'::jsonb))
                        order by m.created_at, m.id)
                   from public.support_messages m
                  where m.tenant_id = t.tenant_id and m.ticket_id = t.id), '[]'::jsonb))
             order by t.created_at, t.id)
        from public.support_tickets t
       where t.tenant_id = v_order.tenant_id and t.order_id = v_order.id), '[]'::jsonb));

  perform public.write_audit(v_order.tenant_id, 'DISPUTE_EVIDENCE_VIEWED', 'orders', v_order.id::text,
                             null, jsonb_build_object('order_id', v_order.id), null);
  return v_bundle;
end;
$function$
;

-- settle_paystack_payment
CREATE OR REPLACE FUNCTION public.settle_paystack_payment(p_event text, p_reference text, p_status text, p_amount_minor bigint, p_currency text, p_verified jsonb, p_transaction_id text, p_split_subaccount text, p_split_share_minor bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

-- apply_paystack_refund
CREATE OR REPLACE FUNCTION public.apply_paystack_refund(p_source text, p_refund_id text, p_transaction_reference text, p_amount_minor bigint, p_currency text, p_reason text, p_verified jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_key       uuid;
  v_source    public.audit_source_enum;
  v_request   jsonb;
  v_matches   integer;
  v_payment   public.payments;
  v_order     public.orders;
  v_currency  text;
  v_paid      bigint;
  v_conflict  text;
  v_prior     jsonb;
  v_order_out text;
  v_comm      record;
begin
  -- p_verified is accepted for the gateway contract but never stored: it can
  -- carry the customer's contact details (CLAUDE.md, addendum A2)
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

  v_key    := md5('paystack-refund:' || p_refund_id)::uuid;
  v_source := case when p_source = 'sweep' then 'CRON' else 'WEBHOOK' end;
  -- the refund itself, not who delivered it: the webhook and the refund pass
  -- may both deliver one refund, and the second must replay the first reply
  v_request := jsonb_build_object('refund_id', p_refund_id, 'reference', p_transaction_reference,
                                  'amount_minor', p_amount_minor, 'currency', p_currency, 'reason', p_reason);

  select count(*) into v_matches from public.payments where paystack_reference = p_transaction_reference;
  if v_matches <> 1 then
    -- zero or several payments: no single payment to refund. The key is taken
    -- (payment rows exist before their charge, so a retry cannot help).
    v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    perform public.write_audit(null, 'REFUND_CONFLICT', 'payments', p_transaction_reference, null,
      jsonb_build_object('reason', 'unknown_reference', 'refund_id', p_refund_id,
                         'reference', p_transaction_reference, 'matches', v_matches,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source);
    return public.idempotency_complete(v_key,
      jsonb_build_object('outcome', 'conflict', 'reason', 'unknown_reference'));
  end if;

  -- payment row first (§6.2 lock order), held across the status check so a
  -- concurrent settle cannot slip between the check and the key
  select * into v_payment from public.payments where paystack_reference = p_transaction_reference for update;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') and p_reason = 'REVERSAL' then
    -- the charge was reversed before Teafair recorded it: the money is gone,
    -- so the payment is REFUNDED and the order is left as it is (never PAID)
    v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
    v_paid     := (v_payment.amount * 100)::bigint;
    v_conflict := case
                    when p_currency is distinct from v_currency then 'currency_mismatch'
                    when p_amount_minor <> v_paid then 'amount_mismatch'
                  end;
    if v_conflict is not null then
      perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
        jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id,
                           'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
        v_key, v_source, v_payment.teafair_agent_id);
      return public.idempotency_complete(v_key, jsonb_build_object(
        'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
        'payment_status', v_payment.payment_status));
    end if;

    update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
      'order_status', (select o.status from public.orders o
                        where o.tenant_id = v_payment.tenant_id and o.id = v_payment.order_id),
      'reason', p_reason));
  end if;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') then
    -- Decision 2 (REFUND only): no key, so the daily refund pass re-applies it after settle
    perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('reason', 'payment_not_success', 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      null, v_source, v_payment.teafair_agent_id);
    return jsonb_build_object('outcome', 'conflict', 'reason', 'payment_not_success',
                              'payment_id', v_payment.id, 'payment_status', v_payment.payment_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_order from public.orders
   where tenant_id = v_payment.tenant_id and id = v_payment.order_id for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
  v_paid     := (v_payment.amount * 100)::bigint;

  v_conflict := case
                  -- REFUNDED is final: no later charge can make it SUCCESS
                  -- again, so this conflict takes its key
                  when v_payment.payment_status <> 'SUCCESS' then 'payment_not_success'
                  when p_currency is distinct from v_currency then 'currency_mismatch'
                  when p_amount_minor > v_paid then 'over_refund'
                end;
  if v_conflict is not null then
    perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
      jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
      'payment_status', v_payment.payment_status));
  end if;

  -- ── partial refund: no status change, the ZSMs are told ───────────────
  if p_amount_minor < v_paid then
    perform public.write_audit(v_payment.tenant_id, 'PARTIAL_REFUND', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid),
      jsonb_build_object('refund_id', p_refund_id, 'reason', p_reason,
                         'amount_minor', p_amount_minor, 'currency', p_currency),
      v_key, v_source, v_payment.teafair_agent_id);
    perform public.notify_tenant_zsms(v_payment.tenant_id, 'PAYMENT_PARTIALLY_REFUNDED', 'Partial refund',
      'Order ' || coalesce(v_order.public_reference, v_order.id::text) || ' was partly refunded ('
        || to_char(p_amount_minor / 100.0, 'FM999999999999990.00') || ' ' || p_currency || ').',
      jsonb_build_object('order_id', v_order.id, 'payment_id', v_payment.id,
                         'public_reference', v_order.public_reference,
                         'amount_minor', p_amount_minor, 'currency', p_currency));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'partial', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status,
      'amount_minor', p_amount_minor));
  end if;

  -- ── full refund or reversal ───────────────────────────────────────────
  -- gateway_response_payload keeps the verified charge; the refund payload is
  -- not stored
  update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
  perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                       'amount_minor', p_amount_minor, 'currency', p_currency),
    v_key, v_source, v_payment.teafair_agent_id);

  -- the order, ONLINE only (field-order transitions are Spec C / D2), and
  -- only once it was paid; any other status is left as it is
  v_order_out := v_order.status;
  if v_order.channel = 'ONLINE' and v_order.status in ('PAID', 'IN_TRANSIT', 'DELIVERED') then
    update public.orders set status = 'REFUNDED' where id = v_order.id;
    v_order_out := 'REFUNDED';
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'orders', v_order.id::text,
      jsonb_build_object('status', v_order.status),
      jsonb_build_object('status', 'REFUNDED', 'payment_id', v_payment.id, 'reason', p_reason,
                         'refund_id', p_refund_id),
      v_key, v_source, v_payment.teafair_agent_id);
  end if;

  -- Paystack does not claw the share back from the subaccount: the commission
  -- becomes DISPUTED and recovery is recorded work for D3
  for v_comm in
    update public.web_commissions c
       set status = 'DISPUTED', dispute_reason = 'ORDER_REFUNDED'
      from public.web_commissions old
     where c.id = old.id
       and c.tenant_id = v_payment.tenant_id and c.payment_id = v_payment.id
       and c.status in ('SPLIT', 'SETTLED')
    returning c.id, c.order_id, old.status as old_status
  loop
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'web_commissions', v_comm.id::text,
      jsonb_build_object('status', v_comm.old_status),
      jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'ORDER_REFUNDED', 'payment_id', v_payment.id,
                         'refund_id', p_refund_id),
      v_key, v_source, v_payment.teafair_agent_id);
    perform public.notify_tenant_zsms(v_payment.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
      'A partner commission needs review (ORDER_REFUNDED).',
      jsonb_build_object('commission_id', v_comm.id, 'order_id', v_comm.order_id, 'reason', 'ORDER_REFUNDED'));
  end loop;

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
    'order_status', v_order_out, 'reason', p_reason));
end;
$function$
;

-- release_commission
CREATE OR REPLACE FUNCTION public.release_commission(p_settlement_id text, p_settled_at timestamp with time zone, p_reference text, p_subaccount_share_minor bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_key      uuid;
  v_request  jsonb;
  v_comm     public.web_commissions;
  v_prior    jsonb;
  v_expected bigint;
begin
  if p_settlement_id is null or btrim(p_settlement_id) = '' then
    raise exception 'p_settlement_id is required' using errcode = 'P0001';
  end if;
  if p_reference is null or btrim(p_reference) = '' then
    raise exception 'p_reference is required' using errcode = 'P0001';
  end if;
  if p_settled_at is null then
    raise exception 'p_settled_at is required' using errcode = 'P0001';
  end if;

  v_key     := md5('paystack-settlement:' || p_settlement_id || ':' || p_reference)::uuid;
  v_request := jsonb_build_object('settlement_id', p_settlement_id, 'reference', p_reference,
                                  'share_minor', p_subaccount_share_minor);

  select c.* into v_comm
    from public.web_commissions c
    join public.payments p on p.id = c.payment_id and p.tenant_id = c.tenant_id
   where p.paystack_reference = p_reference
   for update of c;

  if not found then
    return jsonb_build_object('outcome', 'no_match');
  end if;

  if v_comm.status <> 'SPLIT' then
    -- a replay of a settlement that already moved this row returns its first
    -- reply; anything else is no_match and takes no key
    if exists (select 1 from public.idempotency_logs where key = v_key) then
      return public.idempotency_begin(v_key, 'release_commission', v_request);
    end if;
    return jsonb_build_object('outcome', 'no_match');
  end if;

  v_prior := public.idempotency_begin(v_key, 'release_commission', v_request);
  if v_prior is not null then
    return v_prior;
  end if;

  v_expected := (v_comm.amount * 100)::bigint;

  -- a missing share settles on inclusion (Paystack fact F3), unverified
  if p_subaccount_share_minor is null or p_subaccount_share_minor = v_expected then
    update public.web_commissions
       set status = 'SETTLED', settled_at = p_settled_at, paystack_settlement_id = p_settlement_id
     where id = v_comm.id;
    perform public.write_audit(v_comm.tenant_id, 'release_commission', 'web_commissions', v_comm.id::text,
      jsonb_build_object('status', 'SPLIT'),
      jsonb_build_object('status', 'SETTLED', 'settlement_id', p_settlement_id, 'settled_at', p_settled_at,
                         'share_verified', p_subaccount_share_minor is not null),
      v_key, 'CRON', v_comm.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'settled', 'commission_id', v_comm.id, 'settlement_id', p_settlement_id));
  end if;

  update public.web_commissions
     set status = 'DISPUTED', dispute_reason = 'SETTLEMENT_MISMATCH'
   where id = v_comm.id;
  perform public.write_audit(v_comm.tenant_id, 'release_commission', 'web_commissions', v_comm.id::text,
    jsonb_build_object('status', 'SPLIT', 'share_minor', v_expected),
    jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'SETTLEMENT_MISMATCH',
                       'share_minor', p_subaccount_share_minor, 'settlement_id', p_settlement_id),
    v_key, 'CRON', v_comm.teafair_agent_id);
  perform public.notify_tenant_zsms(v_comm.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
    'A partner commission needs review (SETTLEMENT_MISMATCH).',
    jsonb_build_object('commission_id', v_comm.id, 'order_id', v_comm.order_id, 'reason', 'SETTLEMENT_MISMATCH'));
  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'mismatch', 'commission_id', v_comm.id, 'settlement_id', p_settlement_id));
end;
$function$
;

-- list_unsettled_subaccounts
CREATE OR REPLACE FUNCTION public.list_unsettled_subaccounts()
 RETURNS TABLE(subaccount_code text, oldest_at timestamp with time zone, payment_references text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select c.paystack_subaccount_code,
         min(c.created_at),
         array_agg(p.paystack_reference order by c.created_at, p.paystack_reference)
    from public.web_commissions c
    join public.payments p on p.id = c.payment_id and p.tenant_id = c.tenant_id
   where c.status = 'SPLIT'
     and c.created_at < now() - interval '24 hours'
     and p.paystack_reference is not null
   group by c.paystack_subaccount_code
   order by min(c.created_at), c.paystack_subaccount_code;
$function$
;

-- expire_unsettled_commissions
CREATE OR REPLACE FUNCTION public.expire_unsettled_commissions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    select c.id, c.tenant_id, c.order_id, c.teafair_agent_id
      from public.web_commissions c
     where c.status = 'SPLIT' and c.created_at < now() - interval '7 days'
     order by c.id
       for update
  loop
    update public.web_commissions
       set status = 'DISPUTED', dispute_reason = 'NOT_SETTLED'
     where id = v_row.id;
    perform public.write_audit(v_row.tenant_id, 'expire_unsettled_commissions', 'web_commissions',
      v_row.id::text, jsonb_build_object('status', 'SPLIT'),
      jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'NOT_SETTLED'),
      null, 'CRON', v_row.teafair_agent_id);
    perform public.notify_tenant_zsms(v_row.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
      'A partner commission needs review (NOT_SETTLED).',
      jsonb_build_object('commission_id', v_row.id, 'order_id', v_row.order_id, 'reason', 'NOT_SETTLED'));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$
;

-- ---------------------------------------------------------------------------
-- 6. Grants (the exact ACLs the old functions had; create or replace keeps the rest)
-- ---------------------------------------------------------------------------
revoke all on function public.upsert_web_referral_code(uuid, text, uuid, uuid, text, numeric, integer, timestamptz, boolean) from public, anon;
grant execute on function public.upsert_web_referral_code(uuid, text, uuid, uuid, text, numeric, integer, timestamptz, boolean) to authenticated, service_role;
revoke all on function public.set_web_pos_venue(uuid, uuid, venue_channel_enum, text, text, text, text, double precision, double precision, jsonb) from public, anon;
grant execute on function public.set_web_pos_venue(uuid, uuid, venue_channel_enum, text, text, text, text, double precision, double precision, jsonb) to authenticated, service_role;
