-- Addendum A6 §23.2 and §23.3 (rulings 2026-11-27) — platform partner codes
-- and kinds, and the 200 m claim radius.
--
-- §23.2  Every Monvelo agent is a platform partner (no tenant) with:
--          partner_kind  LIQUIDITY_PARTNER (lends: pledges, claims, funds, is
--                        paired with shops) or RETAIL_INDEPENDENT_PARTNER
--                        (registered, coded and onboarded; no lending action)
--          partner_code  MP- + 8 base32 characters, drawn at registration,
--                        unique on the platform, never reused
--        Both are fixed for the life of the agent. The code is not the web
--        storefront's agent_codes (A1, tenant-scoped); A6 §15 keeps the two
--        apart. The kind rules are enforced on the tables, so every RPC that
--        writes a pledge or a pairing obeys them:
--          monvelo_pledges insert                     LIQUIDITY_PARTNER only
--          retail_shops.preferred_agent_id (pairing)  LIQUIDITY_PARTNER only
--        A claim, a hold, funding and a repayment all need a pledge, so a
--        retail independent partner reaches none of them.
--
-- §23.3  offer_radius_m: 200 m (was 1,000 m), platform-wide; the 100..50000
--        bounds and the paired (preferred) agent's exemption are unchanged.

-- ── partner kind and code ───────────────────────────────────────────────
alter table public.monvelo_agents
  add column partner_kind text not null default 'LIQUIDITY_PARTNER'
    check (partner_kind in ('LIQUIDITY_PARTNER', 'RETAIL_INDEPENDENT_PARTNER')),
  add column partner_code text unique check (partner_code ~ '^MP-[A-Z2-7]{8}$');

-- monvelo_agents is granted column by column (the settlement account is never readable)
grant select (partner_kind, partner_code) on public.monvelo_agents to authenticated;

-- Internal: MP- + 8 characters of RFC 4648 base32, uniform (the low five bits
-- of each random byte), redrawn on the rare collision.
create or replace function public.monvelo_draw_partner_code()
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  v_bytes bytea;
  v_code  text;
begin
  for v_try in 1 .. 5 loop
    v_bytes := extensions.gen_random_bytes(8);
    v_code := 'MP-';
    for i in 0 .. 7 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
    end loop;
    if not exists (select 1 from public.monvelo_agents a where a.partner_code = v_code) then
      return v_code;
    end if;
  end loop;
  raise exception 'could not draw a free partner code' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_draw_partner_code() from public, anon, authenticated, service_role;
-- the column default below runs with the inserting role's rights; service_role
-- (admin tooling, fixtures) may draw a code, nothing more (the trigger redraws anyway)
grant execute on function public.monvelo_draw_partner_code() to service_role;

-- The code is drawn on insert (whatever the caller passed); once set, neither
-- the kind nor the code changes.
create or replace function public.monvelo_agents_partner_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.partner_code := public.monvelo_draw_partner_code();
  elsif new.partner_kind is distinct from old.partner_kind
     or (old.partner_code is not null and new.partner_code is distinct from old.partner_code) then
    raise exception 'a partner''s kind and code never change' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.monvelo_agents_partner_guard() from public, anon, authenticated, service_role;
create trigger monvelo_agents_partner_guard before insert or update on public.monvelo_agents
  for each row execute function public.monvelo_agents_partner_guard();

-- every existing agent lends today, so each is a liquidity partner; draw its code
update public.monvelo_agents set partner_code = public.monvelo_draw_partner_code() where partner_code is null;
-- the default also covers an insert with triggers off (session_replication_role = replica)
alter table public.monvelo_agents
  alter column partner_code set default public.monvelo_draw_partner_code(),
  alter column partner_code set not null;

-- ── the kind rules, on the tables ───────────────────────────────────────
create or replace function public.monvelo_assert_liquidity_partner(p_agent_id uuid, p_action text)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if p_agent_id is not null and exists (select 1 from public.monvelo_agents a
                                         where a.id = p_agent_id and a.partner_kind <> 'LIQUIDITY_PARTNER') then
    raise exception 'only a liquidity partner may %', p_action using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.monvelo_assert_liquidity_partner(uuid, text) from public, anon, authenticated, service_role;

create or replace function public.monvelo_pledges_partner_kind()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.monvelo_assert_liquidity_partner(new.agent_id, 'pledge funds');
  return new;
end;
$$;
revoke all on function public.monvelo_pledges_partner_kind() from public, anon, authenticated, service_role;
create trigger monvelo_pledges_partner_kind before insert on public.monvelo_pledges
  for each row execute function public.monvelo_pledges_partner_kind();

create or replace function public.monvelo_shop_pairing_partner_kind()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.preferred_agent_id is distinct from old.preferred_agent_id then
    perform public.monvelo_assert_liquidity_partner(new.preferred_agent_id, 'be paired with a shop');
  end if;
  return new;
end;
$$;
revoke all on function public.monvelo_shop_pairing_partner_kind() from public, anon, authenticated, service_role;
create trigger monvelo_shop_pairing_partner_kind before update of preferred_agent_id on public.retail_shops
  for each row execute function public.monvelo_shop_pairing_partner_kind();

-- ── §23.3 the radius ────────────────────────────────────────────────────
alter table public.monvelo_platform_settings alter column offer_radius_m set default 200;
update public.monvelo_platform_settings set offer_radius_m = 200, updated_at = now();

-- ── register_monvelo_agent, recreated from its live definition ──────────
-- New: p_agent ->> 'partner_kind' (default LIQUIDITY_PARTNER); the reply
-- carries partner_code and partner_kind. Nothing else changes.
CREATE OR REPLACE FUNCTION public.register_monvelo_agent(p_idempotency_key uuid, p_gateway_proof text, p_agent jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_acct    jsonb;
  v_name    text := btrim(coalesce(p_agent ->> 'business_name', ''));
  v_net     public.pos_network_enum;
  v_netid   text := upper(btrim(coalesce(p_agent ->> 'network_agent_id', '')));
  v_phone   text := btrim(coalesce(p_agent ->> 'contact_phone', ''));
  v_addr    text := btrim(coalesce(p_agent ->> 'address_text', ''));
  v_kyc     text := btrim(coalesce(p_agent ->> 'network_kyc_reference', ''));
  v_lat     numeric;
  v_lng     numeric;
  v_row     public.monvelo_agents;
  v_cname   text;
  v_kind    text := coalesce(nullif(btrim(p_agent ->> 'partner_kind'), ''), 'LIQUIDITY_PARTNER');
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  perform public.assert_gateway_proof(p_gateway_proof);
  -- the client's request only: the bank-resolved holder name is not part of it
  v_prior := public.idempotency_begin(p_idempotency_key, 'register_monvelo_agent',
    public.monvelo_recruitment_request('register_monvelo_agent', p_agent));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_agent is null or jsonb_typeof(p_agent) <> 'object' then
    raise exception 'the agent details are required' using errcode = 'P0001';
  end if;
  if v_name = '' or v_netid = '' or v_phone = '' or v_addr = '' or v_kyc = '' then
    raise exception 'business name, network agent id, phone, address and network KYC reference are required'
      using errcode = 'P0001';
  end if;
  begin
    v_net := (p_agent ->> 'pos_network')::public.pos_network_enum;
  exception when invalid_text_representation then
    raise exception 'unknown POS network' using errcode = 'P0001';
  end;
  if v_net is null then
    raise exception 'unknown POS network' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_agent -> 'latitude') is distinct from 'number'
     or jsonb_typeof(p_agent -> 'longitude') is distinct from 'number' then
    raise exception 'latitude and longitude are required' using errcode = 'P0001';
  end if;
  v_lat := (p_agent ->> 'latitude')::numeric;
  v_lng := (p_agent ->> 'longitude')::numeric;
  if v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'the location is out of range' using errcode = 'P0001';
  end if;
  -- A6 §23.2: the partner kind is chosen at recruitment and never changes
  if v_kind not in ('LIQUIDITY_PARTNER', 'RETAIL_INDEPENDENT_PARTNER') then
    raise exception 'partner_kind must be LIQUIDITY_PARTNER or RETAIL_INDEPENDENT_PARTNER' using errcode = 'P0001';
  end if;
  v_acct := public.monvelo_clean_account(p_agent);

  -- Race-safe: the unique constraint decides, not a pre-check.
  begin
    insert into public.monvelo_agents (
      business_name, pos_network, network_agent_id, contact_phone, location, address_text,
      settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name,
      network_kyc_reference, recruited_by, partner_kind)
    values (
      v_name, v_net, v_netid, v_phone,
      extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography,
      v_addr,
      v_acct ->> 'settlement_account_number', v_acct ->> 'last4', v_acct ->> 'settlement_bank_code',
      v_acct ->> 'settlement_account_name', v_kyc, (select auth.uid()), v_kind)
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_cname = constraint_name;
    if v_cname = 'monvelo_agents_pos_network_network_agent_id_key' then
      raise exception 'this agent is already registered with Monvelo' using errcode = '23505';
    end if;
    raise;
  end;

  -- R19: the row names an agent, so no tenant reads it (A6 §16.2.2)
  perform public.write_audit(null, 'register_monvelo_agent', 'monvelo_agents', v_row.id::text,
                             null, public.monvelo_agent_audit(v_row), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'agent_id', v_row.id, 'status', v_row.status,
    'partner_code', v_row.partner_code, 'partner_kind', v_row.partner_kind,
    'name_matches', lower(btrim(v_acct ->> 'settlement_account_name')) = lower(btrim(v_name))));
end;
$function$;
