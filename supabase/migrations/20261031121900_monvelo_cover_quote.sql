-- Addendum A8 Task 3 (§6.1, §6.2, §6.4): the agent's yield quote, locked at
-- claim, paid at funding.
--
-- * monvelo_quote_agent_yield(financing) (internal) quotes the cover and the
--   rebate split: each brand's approved terms today, the shop's own verified
--   policy (no premium) or the approved STORAGE product (a premium per 30-day
--   block of the shortest interest-free period, out of the rebate), or no cover.
--   Rounded per line; the yield shown is rounded down (basis points, i.e. a
--   percentage to 2 decimals), so it never promises more than is paid.
-- * get_monvelo_offer_cover(financing, agent): the agent's read of that quote.
-- * claim_monvelo_financing now takes p_expected_net_yield_bps: the agent's
--   acknowledgement of the yield it saw, compared with the quote (never used
--   to compute anything). The claim locks the cover and the brand terms
--   (monvelo_financing_cover, monvelo_financing_line_cover). A held claim keeps
--   the acknowledged yield; the allow re-quotes and refuses if it moved.
-- * The terms lock moves from funding to claim (changes A6): funding copies
--   the locked terms onto the lines and pays the net rebate. The late route
--   (no live claim) and a claim locked before A8 quote at funding.
-- * request_monvelo_financing refuses an order whose brand rebate is below
--   the storage premium, naming the brand.

-- Fix to 20261031121700 (Task 1): the guard read new.declared_status on the
-- line-cover table, which has no such column; plpgsql resolves the field even
-- behind a false AND. Read it through to_jsonb.
CREATE OR REPLACE FUNCTION public.monvelo_financing_cover_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_fin_status text;
  v_declared   text;
  v_fixed      text[] := array['declared_status', 'updated_at'];
begin
  if tg_table_name = 'monvelo_financing_cover' then
    select f.status into v_fin_status from public.monvelo_financings f where f.id = new.financing_id;
    v_declared := case when tg_op = 'INSERT' then null else old.declared_status end;
  else
    select f.status, c.declared_status into v_fin_status, v_declared
      from public.monvelo_financing_cover c
      join public.monvelo_financings f on f.id = c.financing_id
     where c.financing_id = new.financing_id;
  end if;

  if tg_op = 'INSERT' then
    if tg_table_name = 'monvelo_financing_cover' and (to_jsonb(new) ->> 'declared_status') <> 'NOT_DUE' then
      raise exception 'a cover is created NOT_DUE' using errcode = 'P0001';
    end if;
    if v_fin_status not in ('OFFERED', 'HELD', 'CLAIMED') then
      raise exception 'cover is locked only while a financing is being claimed' using errcode = 'P0001';
    end if;
    return new;
  end if;

  if tg_table_name = 'monvelo_financing_cover' then
    if (to_jsonb(new) - v_fixed) is distinct from (to_jsonb(old) - v_fixed) then
      if v_fin_status not in ('OFFERED', 'HELD', 'CLAIMED') or old.declared_status <> 'NOT_DUE' then
        raise exception 'a financing''s cover is fixed once it is funded' using errcode = 'P0001';
      end if;
      if new.financing_id <> old.financing_id or new.tenant_id <> old.tenant_id then
        raise exception 'a cover''s financing never changes' using errcode = 'P0001';
      end if;
    end if;
    if new.declared_status <> old.declared_status and not (
         (old.declared_status = 'NOT_DUE' and new.declared_status in ('PENDING', 'CANCELLED'))
      or (old.declared_status = 'PENDING' and new.declared_status in ('ACCEPTED', 'REJECTED', 'CANCELLED'))) then
      raise exception 'a cover''s declaration cannot move from % to %', old.declared_status, new.declared_status
        using errcode = 'P0001';
    end if;
  else
    if (to_jsonb(new) - 'updated_at'::text) is distinct from (to_jsonb(old) - 'updated_at'::text) and (
         v_fin_status not in ('OFFERED', 'HELD', 'CLAIMED') or v_declared <> 'NOT_DUE'
         or new.financing_id <> old.financing_id or new.brand_key <> old.brand_key) then
      raise exception 'a financing''s cover is fixed once it is funded' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$function$

;

-- ── the quote ───────────────────────────────────────────────────────────
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
      join public.monvelo_insurers i on i.id = p.insurer_id and i.status = 'ACTIVE'
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

-- writes the quote as the financing's cover (insert, or re-quote while still being claimed)
create or replace function public.monvelo_lock_cover(p_quote jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin public.monvelo_financings;
begin
  select * into v_fin from public.monvelo_financings where id = (p_quote ->> 'financing_id')::uuid;
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

-- ── the agent's read model ──────────────────────────────────────────────
-- An ACTIVE member of p_agent_id reads the quote of a financing still open to
-- claim (OFFERED, HELD, or CLAIMED by that agent). The label and the money,
-- never the shop's policy. A financing that cannot be quoted returns no row.
create or replace function public.get_monvelo_offer_cover(p_financing_id uuid, p_agent_id uuid)
returns table (cover_label text, gross_rebate numeric(15,2), storage_premium numeric(15,2), net_rebate numeric(15,2),
               net_yield_bps integer, net_yield_percent numeric(5,2), quote_valid_until timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_fin   public.monvelo_financings;
  v_quote jsonb;
begin
  if v_uid is null or p_agent_id is null
     or not exists (select 1 from public.monvelo_agent_members m
                     where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;
  select * into v_fin from public.monvelo_financings f where f.id = p_financing_id;
  if v_fin.id is null
     or not (v_fin.status in ('OFFERED', 'HELD')
             or (v_fin.status = 'CLAIMED' and v_fin.claimed_by_agent_id = p_agent_id)) then
    return;
  end if;
  begin
    v_quote := public.monvelo_quote_agent_yield(v_fin.id);
  exception when sqlstate 'P0001' then
    return;
  end;
  return query select
    case v_quote ->> 'cover_kind' when 'SHOP_POLICY' then 'VERIFIED_SHOP_COVER'
                                  when 'AUTO_POLICY' then 'AUTO_POLICY' else 'NO_COVER' end,
    (v_quote ->> 'gross_rebate')::numeric(15,2), (v_quote ->> 'storage_premium')::numeric(15,2),
    (v_quote ->> 'net_rebate')::numeric(15,2), (v_quote ->> 'net_yield_bps')::integer,
    (v_quote ->> 'net_yield_percent')::numeric(5,2),
    case when v_fin.status = 'CLAIMED' then v_fin.claim_expires_at
         else coalesce(v_fin.preferred_window_ends_at,
                       (v_fin.supply_date + 1)::timestamp at time zone 'Africa/Lagos') end;
end;
$$;

-- a held claim keeps the yield the agent acknowledged
alter table public.monvelo_claim_holds add column if not exists quoted_net_yield_bps integer
  check (quoted_net_yield_bps between 0 and 10000);

drop function if exists public.claim_monvelo_financing(uuid, uuid, uuid);

-- ── claim: the agent's acknowledgement and the lock (recreated from 20261031120800) ──
CREATE OR REPLACE FUNCTION public.claim_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_agent_id uuid, p_expected_net_yield_bps integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_hold     constant interval := interval '15 minutes';
  v_uid      uuid := (select auth.uid());
  v_prior    jsonb;
  v_fin      public.monvelo_financings;
  v_agent    public.monvelo_agents;
  v_ps       public.monvelo_platform_settings;
  v_pledge   public.monvelo_pledges;
  v_refusal  text;
  v_exposure numeric(15,2);
  v_hold     public.monvelo_claim_holds;
  v_quote    jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.monvelo_agent_members m
                  where m.agent_id = p_agent_id and m.profile_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'not an active member of this agent' using errcode = '42501';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'claim_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id, 'agent_id', p_agent_id,
                       'expected_net_yield_bps', p_expected_net_yield_bps));
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

  -- A6 §20: blocked only by the exposure cap, and within the market makers' limit
  if v_refusal like 'this request would take your open exposure above %'
     and public.monvelo_claim_refusal(v_fin, v_agent, v_uid, v_pledge, false, public.monvelo_allowance_ceiling()) is null then
    if exists (select 1 from public.monvelo_claim_holds h
                where h.financing_id = v_fin.id and h.agent_id = p_agent_id and h.status = 'LAPSED') then
      raise exception 'this request was already held for you' using errcode = 'P0001';
    end if;

    -- A8 §6.2: the agent acknowledges the quoted yield before anything is held
    v_quote := public.monvelo_quote_agent_yield(v_fin.id);
    if (v_quote ->> 'net_yield_bps')::integer is distinct from p_expected_net_yield_bps then
      raise exception 'cover changed; review the new yield' using errcode = 'P0001',
        detail = 'net_yield_bps=' || (v_quote ->> 'net_yield_bps');
    end if;
    v_exposure := public.monvelo_agent_open_exposure(p_agent_id);
    insert into public.monvelo_claim_holds (tenant_id, financing_id, agent_id, claimed_by, blocks,
                                            exposure_before, exposure_after, pledge_remaining, expires_at,
                                            quoted_net_yield_bps)
    values (v_fin.tenant_id, v_fin.id, p_agent_id, v_uid, array['EXPOSURE_CAP'],
            v_exposure, v_exposure + v_fin.principal, v_pledge.remaining, now() + c_hold,
            p_expected_net_yield_bps)
    returning * into v_hold;
    update public.monvelo_financings
       set status = 'HELD', preferred_window_ends_at = null
     where id = v_fin.id
    returning * into v_fin;

    -- R15: the row names the agent, so no tenant reads it
    perform public.write_audit(null, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'OFFERED'),
      jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id, 'agent_id', p_agent_id, 'blocks', v_hold.blocks,
                         'exposure_before', v_hold.exposure_before, 'exposure_after', v_hold.exposure_after,
                         'pledge_remaining', v_hold.pledge_remaining, 'expires_at', v_hold.expires_at),
      p_idempotency_key);

    perform public.monvelo_notify_hold(v_hold.id);

    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'held', true, 'hold_id', v_hold.id, 'expires_at', v_hold.expires_at,
      'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status, 'principal', v_fin.principal));
  end if;

  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;

  -- A8 §6.2: the yield the agent saw must still be the quote
  v_quote := public.monvelo_quote_agent_yield(v_fin.id);
  if (v_quote ->> 'net_yield_bps')::integer is distinct from p_expected_net_yield_bps then
    raise exception 'cover changed; review the new yield' using errcode = 'P0001',
      detail = 'net_yield_bps=' || (v_quote ->> 'net_yield_bps');
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
  -- the cover and the brand terms are locked now; funding pays exactly this
  perform public.monvelo_lock_cover(v_quote);

  -- R15: the row names the agent and its pledge, so no tenant reads it
  perform public.write_audit(null, 'claim_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'OFFERED'),
    jsonb_build_object('status', v_fin.status, 'agent_id', p_agent_id, 'pledge_id', v_pledge.id,
                       'claim_expires_at', v_fin.claim_expires_at),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'claim_expires_at', v_fin.claim_expires_at, 'principal', v_fin.principal,
    'net_rebate', (v_quote ->> 'net_rebate')::numeric, 'net_yield_bps', (v_quote ->> 'net_yield_bps')::integer));
end;
$function$;

-- ── a hold's allow re-quotes (recreated from 20261031121300) ──
CREATE OR REPLACE FUNCTION public.decide_monvelo_claim_hold(p_idempotency_key uuid, p_hold_id uuid, p_allow boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA', 'ZSM']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_reason  text := nullif(btrim(p_reason), '');
  v_hold    public.monvelo_claim_holds;
  v_fin     public.monvelo_financings;
  v_offered public.monvelo_financings;
  v_agent   public.monvelo_agents;
  v_pledge  public.monvelo_pledges;
  v_ps      public.monvelo_platform_settings;
  v_refusal text;
  v_quote   jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'decide_monvelo_claim_hold',
    jsonb_build_object('hold_id', p_hold_id, 'allow', p_allow, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  -- in scope, never the raiser (decision 6); an unknown hold looks the same
  select h.* into v_hold from public.monvelo_claim_holds h
    join public.monvelo_financings f on f.tenant_id = h.tenant_id and f.id = h.financing_id
   where h.id = p_hold_id and h.tenant_id = v_me.tenant_id
     and v_me.profile_id in (select public.monvelo_hold_market_makers(f.tenant_id, f.area_id, f.raised_by, h.agent_id));
  if v_hold.id is null then
    raise exception 'this hold is not yours to decide' using errcode = '42501';
  end if;

  if p_allow is null then
    raise exception 'allow or decline' using errcode = '22023';
  end if;
  if p_allow and (v_reason is null or char_length(v_reason) < 10) then
    raise exception 'give a reason of at least 10 characters to allow' using errcode = '22023';
  end if;
  if char_length(v_reason) > 1000 then
    raise exception 'the reason is longer than 1000 characters' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('monvelo_agent:' || v_hold.agent_id::text, 0));
  select * into v_agent from public.monvelo_agents a where a.id = v_hold.agent_id for update;
  select * into v_fin from public.monvelo_financings f
   where f.tenant_id = v_hold.tenant_id and f.id = v_hold.financing_id for update;
  if p_allow then
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = v_agent.id
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date
       for update;
  end if;
  select * into v_hold from public.monvelo_claim_holds where id = v_hold.id for update;

  if v_hold.status <> 'HELD' or v_fin.status <> 'HELD' then
    raise exception 'this hold has already been decided' using errcode = 'P0001';
  end if;
  if v_hold.expires_at <= now() then
    raise exception 'this hold has lapsed' using errcode = 'P0001';
  end if;

  if not p_allow then
    update public.monvelo_claim_holds
       set status = 'DECLINED', decided_by = v_me.profile_id, decided_at = now(), reason = v_reason
     where id = v_hold.id
    returning * into v_hold;
    update public.monvelo_financings set status = 'OFFERED', preferred_window_ends_at = null where id = v_fin.id;

    -- R15: the row names the agent, so no tenant reads it
    perform public.write_audit(null, 'decide_monvelo_claim_hold', 'monvelo_financings', v_fin.id::text,
      jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id, 'agent_id', v_hold.agent_id),
      jsonb_build_object('status', 'OFFERED', 'hold_status', 'DECLINED', 'reason', v_reason),
      p_idempotency_key);
    perform public.monvelo_notify_hold_decided(v_hold.id);

    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'status', 'DECLINED', 'hold_id', v_hold.id, 'financing_reference', v_fin.reference));
  end if;

  -- allow: every check but the ₦100,000 cap, under the agent's lock (§20.4 step 4)
  v_offered := v_fin;
  v_offered.status := 'OFFERED';
  v_refusal := public.monvelo_claim_refusal(v_offered, v_agent, v_hold.claimed_by, v_pledge, false,
                                            public.monvelo_allowance_ceiling());
  if v_refusal is not null then
    raise exception '%', v_refusal using errcode = 'P0001';
  end if;
  -- A8 §6.2: the quote the agent acknowledged when held must still stand
  v_quote := public.monvelo_quote_agent_yield(v_fin.id);
  if v_hold.quoted_net_yield_bps is not null
     and (v_quote ->> 'net_yield_bps')::integer is distinct from v_hold.quoted_net_yield_bps then
    raise exception 'cover changed; the agent must claim again' using errcode = 'P0001';
  end if;

  update public.monvelo_claim_holds
     set status = 'ALLOWED', decided_by = v_me.profile_id, decided_at = now(), reason = v_reason
   where id = v_hold.id
  returning * into v_hold;

  select * into v_ps from public.monvelo_platform_settings;
  update public.monvelo_financings
     set status = 'CLAIMED', claimed_by_agent_id = v_hold.agent_id, claimed_by = v_hold.claimed_by,
         claim_expires_at = now() + make_interval(mins => v_ps.claim_minutes),
         pledge_id = v_pledge.id, preferred_window_ends_at = null
   where id = v_fin.id
  returning * into v_fin;
  insert into public.monvelo_financing_claims (tenant_id, financing_id, agent_id, claimed_by, pledge_id, expires_at)
  values (v_fin.tenant_id, v_fin.id, v_hold.agent_id, v_hold.claimed_by, v_pledge.id, v_fin.claim_expires_at);
  perform public.monvelo_lock_cover(v_quote);

  -- R15: the row names the agent and its pledge, so no tenant reads it
  perform public.write_audit(null, 'decide_monvelo_claim_hold', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', 'HELD', 'hold_id', v_hold.id),
    jsonb_build_object('status', 'CLAIMED', 'hold_status', 'ALLOWED', 'agent_id', v_hold.agent_id,
                       'pledge_id', v_pledge.id, 'claim_expires_at', v_fin.claim_expires_at, 'reason', v_reason),
    p_idempotency_key);
  perform public.monvelo_notify_hold_decided(v_hold.id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'status', 'ALLOWED', 'hold_id', v_hold.id, 'financing_reference', v_fin.reference,
    'claim_expires_at', v_fin.claim_expires_at));
end;
$function$;

-- ── funding pays the locked net (recreated from 20261031120900) ──
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
  v_quote    jsonb;
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
    -- A6 §20 (call 7): an allowance for this agent and financing survives a late payment
    v_reason := public.monvelo_claim_refusal(v_fin, v_agent, v_payment.monvelo_started_by, v_pledge, true,
      case when exists (select 1 from public.monvelo_claim_holds h
                         where h.financing_id = v_fin.id and h.agent_id = v_agent.id and h.status = 'ALLOWED')
           then public.monvelo_allowance_ceiling() end);
  else
    v_reason := case
                  when v_fin.status = 'CLAIMED' then 'CLAIMED_BY_ANOTHER_AGENT'
                  when v_fin.status = 'OFFERED' then 'SUPPLY_DAY_ENDED'
                  else 'FINANCING_' || v_fin.status
                end;
  end if;

  -- A8 §6.2: the claim locked the cover and the brand terms. The late route
  -- (no live claim) and a claim locked before A8 are quoted now, as the agent pays.
  if v_reason is null
     and (v_route = 'LATE'
          or not exists (select 1 from public.monvelo_financing_cover c where c.financing_id = v_fin.id)) then
    begin
      v_quote := public.monvelo_quote_agent_yield(v_fin.id);
      perform public.monvelo_lock_cover(v_quote);
    exception when sqlstate 'P0001' then
      v_reason := case when sqlerrm like '%has no approved Monvelo terms' then 'NO_TERMS' else 'COVER_REFUSED' end;
    end;
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

  -- the terms locked at claim (A8 §6.2), not today's
  update public.monvelo_financing_lines l
     set (terms_id, rebate_bps, interest_free_days, late_charge_bps, terms_locked_at) =
         (select c.terms_id, c.rebate_bps, c.interest_free_days, c.late_charge_bps, fc.locked_at
            from public.monvelo_financing_line_cover c
            join public.monvelo_financing_cover fc on fc.financing_id = c.financing_id
           where c.financing_id = l.financing_id and c.brand_key = l.brand_key)
   where l.tenant_id = v_fin.tenant_id and l.financing_id = v_fin.id;

  update public.monvelo_pledges set remaining = remaining - v_fin.principal where id = v_pledge.id;

  update public.orders set status = 'PAID' where id = v_order.id;

  -- the net rebate: the gross less any auto-policy premium (A8 §6.1)
  select coalesce(sum(c.net_rebate), 0) into v_total
    from public.monvelo_financing_line_cover c where c.financing_id = v_fin.id;
  insert into public.monvelo_rebate_payables (tenant_id, financing_id, agent_id, amount, due_at, status)
  values (v_fin.tenant_id, v_fin.id, v_agent.id, v_total, now() + interval '24 hours', 'DUE')
  returning * into v_payable;
  insert into public.monvelo_rebate_payable_lines (payable_id, brand_key, amount)
  select v_payable.id, c.brand_key, c.net_rebate
    from public.monvelo_financing_line_cover c where c.financing_id = v_fin.id;

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

-- ── the request refuses a brand below the premium (recreated from 20261031120050) ──
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



  -- A8 §6.4: a brand whose rebate is below the storage premium is refused up
  -- front, by name (the quote raises), unless the shop's own cover exempts it
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

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.monvelo_quote_agent_yield(uuid), public.monvelo_lock_cover(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.get_monvelo_offer_cover(uuid, uuid),
  public.claim_monvelo_financing(uuid, uuid, uuid, integer) from public, anon, authenticated, service_role;
grant execute on function public.get_monvelo_offer_cover(uuid, uuid),
  public.claim_monvelo_financing(uuid, uuid, uuid, integer) to authenticated;
