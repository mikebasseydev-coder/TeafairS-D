-- Addendum A6 §4.1 (Monvelo Step 1, Task 5) — shop enrolment with the owner's
-- consent, and shop-owner nominations of POS agents.
--
--   retail_shops.shop_code            SH- + 6 base32 characters, drawn at first enrolment
--   retail_shops.preferred_agent_id   the shop's trusted POS agent
--   monvelo_consent_challenges        the WhatsApp code that proves the owner agreed
--   monvelo_shop_enrolments           one row per (tenant, shop); ACTIVE/SUSPENDED/WITHDRAWN
--   monvelo_agent_nominations         an owner's lead for a street agent
--
-- Named 120600 (not 120300) because it reads monvelo_fintech_agents (120500)
-- and monvelo_tenant_settings (120400).
--
-- Consent (ruling 10, NDPA 2023). The owner agrees that Teafair may share the
-- shop's name, shop code, location and area with registered Monvelo fintech
-- agents for stock financing, and may withdraw at any time. The version is
-- recorded on the enrolment (consent_version = 'MV-SHARE-2026-10'). The words
-- are shown in the app; the WhatsApp message is the authentication OTP
-- template and carries no custom text.
--
-- Area guard (start_monvelo_consent). The area must belong to the caller's
-- tenant (else 42501). A ZSA needs the area's territory to lie in the ZSA's
-- zone. An ASA needs the area to be the ASA's OWN tenant_users.area_id: the
-- stricter of the two readings, because an ASA is anchored to one area.
--
-- Nominations keep the last four digits of the phone only. The full number is
-- normalised and dropped here; sending it to the street agent is a
-- notification concern (Step 6).

-- ── notification_logs: a new purpose ────────────────────────────────────
alter table public.notification_logs drop constraint notification_logs_purpose_check;
alter table public.notification_logs add constraint notification_logs_purpose_check
  check (purpose in ('OTP', 'DELIVERY_CODE', 'DELIVERY_CODE_RESEND', 'PHONE_VERIFY', 'AUTH_OTP', 'MONVELO_CONSENT'));

-- ── retail_shops ────────────────────────────────────────────────────────
alter table public.retail_shops
  add column shop_code text unique check (shop_code ~ '^SH-[A-Z2-7]{6}$'),
  add column preferred_agent_id uuid references public.monvelo_fintech_agents (id) on delete restrict;
create index idx_retail_shops_preferred_agent on public.retail_shops (preferred_agent_id);
-- retail_shops is granted column by column
grant select (shop_code, preferred_agent_id) on public.retail_shops to authenticated;

-- ── tables ──────────────────────────────────────────────────────────────
create table public.monvelo_consent_challenges (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  shop_id          uuid not null references public.retail_shops (id) on delete restrict,
  area_id          uuid not null,
  code_hash        text not null,
  expires_at       timestamptz not null,
  failed_attempts  integer not null default 0 check (failed_attempts >= 0),
  consumed_at      timestamptz,
  issued_by        uuid not null references public.profiles (id) on delete restrict,
  created_at       timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, area_id) references public.areas (tenant_id, id) on delete restrict
);
alter table public.monvelo_consent_challenges enable row level security;
create index idx_monvelo_consent_challenges_shop on public.monvelo_consent_challenges (shop_id, created_at);
create index idx_monvelo_consent_challenges_tenant_area on public.monvelo_consent_challenges (tenant_id, area_id);
create index idx_monvelo_consent_challenges_issued_by on public.monvelo_consent_challenges (issued_by);

create table public.monvelo_shop_enrolments (
  tenant_id             uuid not null references public.tenants (id) on delete restrict,
  shop_id               uuid not null references public.retail_shops (id) on delete restrict,
  area_id               uuid not null,
  recruited_by          uuid not null references public.profiles (id) on delete restrict,
  consent_at            timestamptz not null,
  consent_version       text not null,
  consent_challenge_id  uuid not null references public.monvelo_consent_challenges (id) on delete restrict,
  status                text not null default 'ACTIVE' check (status in ('ACTIVE', 'SUSPENDED', 'WITHDRAWN')),
  withdrawn_at          timestamptz,
  created_at            timestamptz not null default now(),
  primary key (tenant_id, shop_id),
  foreign key (tenant_id, area_id) references public.areas (tenant_id, id) on delete restrict,
  check ((status = 'WITHDRAWN') = (withdrawn_at is not null))
);
alter table public.monvelo_shop_enrolments enable row level security;
create index idx_monvelo_shop_enrolments_shop on public.monvelo_shop_enrolments (shop_id);
create index idx_monvelo_shop_enrolments_area on public.monvelo_shop_enrolments (tenant_id, area_id);
create index idx_monvelo_shop_enrolments_recruited_by on public.monvelo_shop_enrolments (recruited_by);
create index idx_monvelo_shop_enrolments_challenge on public.monvelo_shop_enrolments (consent_challenge_id);

create table public.monvelo_agent_nominations (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenants (id) on delete restrict,
  shop_id                uuid not null references public.retail_shops (id) on delete restrict,
  nominated_name         text not null check (length(btrim(nominated_name)) > 0),
  nominated_phone_last4  text not null check (nominated_phone_last4 ~ '^[0-9]{4}$'),
  pos_network            public.pos_network_enum not null,
  raised_by              uuid not null references public.profiles (id) on delete restrict,
  status                 text not null default 'OPEN' check (status in ('OPEN', 'RECRUITED', 'DECLINED')),
  recruited_agent_id     uuid references public.monvelo_fintech_agents (id) on delete restrict,
  created_at             timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, shop_id) references public.monvelo_shop_enrolments (tenant_id, shop_id) on delete restrict,
  check ((status = 'RECRUITED') = (recruited_agent_id is not null))
);
alter table public.monvelo_agent_nominations enable row level security;
create index idx_monvelo_agent_nominations_shop on public.monvelo_agent_nominations (tenant_id, shop_id);
create index idx_monvelo_agent_nominations_raised_by on public.monvelo_agent_nominations (raised_by);
create index idx_monvelo_agent_nominations_agent on public.monvelo_agent_nominations (recruited_agent_id);

-- ── grants: challenges have none; the rest are read-only ────────────────
revoke all on public.monvelo_consent_challenges from anon, authenticated;
revoke all on public.monvelo_shop_enrolments from anon, authenticated;
revoke all on public.monvelo_agent_nominations from anon, authenticated;
grant select on public.monvelo_shop_enrolments to authenticated;
grant select on public.monvelo_agent_nominations to authenticated;

-- ── policy helpers ──────────────────────────────────────────────────────
create or replace function public.my_owned_shop_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.id from public.retail_shops s where s.owner_id = (select auth.uid());
$$;
grant execute on function public.my_owned_shop_ids() to authenticated;

-- Tenants where the caller is an ACTIVE staff member (shop owners and fintech
-- agent logins are members too, but they must not read other shops' rows).
create or replace function public.my_monvelo_staff_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.tenant_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role in ('ZSM', 'TM', 'ASM', 'DSM', 'DSA', 'ZSA', 'ASA');
$$;
grant execute on function public.my_monvelo_staff_tenant_ids() to authenticated;

create policy monvelo_shop_enrolments_select on public.monvelo_shop_enrolments
  for select to authenticated
  using (
    tenant_id in (select public.my_monvelo_staff_tenant_ids())
    or shop_id in (select public.my_owned_shop_ids())
    or (select public.is_monvelo_staff())
  );

create function public.my_monvelo_nomination_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.tenant_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role in ('ZSA', 'ASA', 'TM', 'ZSM');
$$;
grant execute on function public.my_monvelo_nomination_tenant_ids() to authenticated;

create policy monvelo_agent_nominations_select on public.monvelo_agent_nominations
  for select to authenticated
  using (
    tenant_id in (select public.my_monvelo_nomination_tenant_ids())
    or shop_id in (select public.my_owned_shop_ids())
    or (select public.is_monvelo_staff())
  );

-- ── internal: draw a unique shop code (no grants) ───────────────────────
-- SH- + 6 characters of RFC 4648 base32 (A-Z, 2-7). Each character is the low
-- five bits of a random byte, so the draw is uniform. A collision retries.
create or replace function public.monvelo_assign_shop_code(p_shop_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  v_existing text;
  v_bytes    bytea;
  v_code     text;
  v_stored   text;
  v_try      integer := 0;
begin
  select shop_code into v_existing from public.retail_shops where id = p_shop_id;
  if v_existing is not null then
    return v_existing;
  end if;
  loop
    v_try := v_try + 1;
    v_bytes := extensions.gen_random_bytes(6);
    v_code := 'SH-';
    for i in 0..5 loop
      v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
    end loop;
    begin
      update public.retail_shops set shop_code = v_code
       where id = p_shop_id and shop_code is null
      returning shop_code into v_stored;
      if v_stored is null then
        -- a racing enrolment stored a code first: return that one
        select shop_code into v_stored from public.retail_shops where id = p_shop_id;
      end if;
      return v_stored;
    exception when unique_violation then
      if v_try >= 20 then
        raise exception 'could not draw a free shop code' using errcode = 'P0001';
      end if;
    end;
  end loop;
end;
$$;
revoke all on function public.monvelo_assign_shop_code(uuid) from public, anon, authenticated;

-- ── start_monvelo_consent ───────────────────────────────────────────────
create or replace function public.start_monvelo_consent(
  p_idempotency_key uuid,
  p_gateway_proof   text,
  p_shop_id         uuid,
  p_area_id         uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── enrol_monvelo_shop ──────────────────────────────────────────────────
-- A wrong code, an expired code and a lock come back as data, so the attempt
-- counter commits (A5 R9). The code is never part of the stored request.
create or replace function public.enrol_monvelo_shop(
  p_idempotency_key uuid,
  p_challenge_id    uuid,
  p_code            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_version      constant text    := 'MV-SHARE-2026-10';
  c_max_attempts constant integer := 5;
  v_me      public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_ch      public.monvelo_consent_challenges;
  v_before  public.monvelo_shop_enrolments;
  v_after   public.monvelo_shop_enrolments;
  v_shopcode text;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'enrol_monvelo_shop',
    jsonb_build_object('challenge_id', p_challenge_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_ch from public.monvelo_consent_challenges where id = p_challenge_id for update;
  if not found or v_ch.tenant_id <> v_me.tenant_id then
    raise exception 'unknown consent code request' using errcode = '42501';
  end if;
  if v_ch.issued_by <> v_me.profile_id then
    raise exception 'this consent code was requested by someone else' using errcode = '42501';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'the consent code must be 6 digits' using errcode = 'P0001';
  end if;

  -- concurrent first enrolments of one shop serialise here, so the second
  -- sees the first row instead of hitting 23505
  perform pg_advisory_xact_lock(hashtextextended('enrol_monvelo_shop:' || v_ch.tenant_id || ':' || v_ch.shop_id, 0));
  select * into v_before from public.monvelo_shop_enrolments e
   where e.tenant_id = v_ch.tenant_id and e.shop_id = v_ch.shop_id for update;

  -- this very challenge already enrolled the shop: return the existing row
  if v_ch.consumed_at is not null then
    if v_before.shop_id is not null and v_before.status = 'ACTIVE' and v_before.consent_challenge_id = v_ch.id then
      select shop_code into v_shopcode from public.retail_shops where id = v_ch.shop_id;
      return public.idempotency_complete(p_idempotency_key,
        jsonb_build_object('enrolled', true, 'shop_code', v_shopcode));
    end if;
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'INVALID'));
  end if;
  if v_ch.failed_attempts >= c_max_attempts then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'LOCKED'));
  end if;
  if v_ch.expires_at <= now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false, 'reason', 'EXPIRED'));
  end if;

  if v_ch.code_hash <> extensions.crypt(p_code, v_ch.code_hash) then
    update public.monvelo_consent_challenges set failed_attempts = failed_attempts + 1
     where id = v_ch.id returning * into v_ch;
    perform public.write_audit(v_ch.tenant_id, 'MONVELO_CONSENT_FAILED', 'monvelo_consent_challenges', v_ch.id::text,
                               null, jsonb_build_object('failed_attempts', v_ch.failed_attempts, 'shop_id', v_ch.shop_id),
                               p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', false,
      'reason', case when v_ch.failed_attempts >= c_max_attempts then 'LOCKED' else 'INVALID' end));
  end if;

  -- the right code
  update public.monvelo_consent_challenges set consumed_at = now() where id = v_ch.id;
  if v_before.shop_id is not null and v_before.status in ('ACTIVE', 'SUSPENDED') then
    -- already enrolled by another route: keep the existing row
    v_after := v_before;
  elsif v_before.shop_id is not null then
    -- WITHDRAWN: a fresh code brings it back
    update public.monvelo_shop_enrolments
       set status = 'ACTIVE', withdrawn_at = null, area_id = v_ch.area_id, recruited_by = v_ch.issued_by,
           consent_at = clock_timestamp(), consent_version = c_version, consent_challenge_id = v_ch.id
     where tenant_id = v_ch.tenant_id and shop_id = v_ch.shop_id
    returning * into v_after;
  else
    insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at,
                                                consent_version, consent_challenge_id, status)
    values (v_ch.tenant_id, v_ch.shop_id, v_ch.area_id, v_ch.issued_by, clock_timestamp(), c_version, v_ch.id, 'ACTIVE')
    returning * into v_after;
  end if;
  v_shopcode := public.monvelo_assign_shop_code(v_ch.shop_id);

  perform public.write_audit(v_ch.tenant_id, 'enrol_monvelo_shop', 'monvelo_shop_enrolments', v_ch.shop_id::text,
                             case when v_before.shop_id is null then null else to_jsonb(v_before) end,
                             to_jsonb(v_after) || jsonb_build_object('shop_code', v_shopcode), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('enrolled', true, 'shop_code', v_shopcode));
end;
$$;

-- ── withdraw_monvelo_shop_consent ───────────────────────────────────────
-- Only the shop's owner. Every ACTIVE or SUSPENDED enrolment of the shop,
-- in every tenant, becomes WITHDRAWN.
create or replace function public.withdraw_monvelo_shop_consent(p_idempotency_key uuid, p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_prior   jsonb;
  v_owner   uuid;
  v_row     public.monvelo_shop_enrolments;
  v_count   integer := 0;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'withdraw_monvelo_shop_consent',
    jsonb_build_object('shop_id', p_shop_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select owner_id into v_owner from public.retail_shops where id = p_shop_id;
  if v_owner is distinct from v_uid then
    raise exception 'only the shop owner can withdraw consent' using errcode = '42501';
  end if;

  for v_row in
    select * from public.monvelo_shop_enrolments
     where shop_id = p_shop_id and status in ('ACTIVE', 'SUSPENDED')
     order by tenant_id
     for update
  loop
    update public.monvelo_shop_enrolments set status = 'WITHDRAWN', withdrawn_at = now()
     where tenant_id = v_row.tenant_id and shop_id = v_row.shop_id;
    perform public.write_audit(v_row.tenant_id, 'withdraw_monvelo_shop_consent', 'monvelo_shop_enrolments',
                               v_row.shop_id::text, jsonb_build_object('status', v_row.status),
                               jsonb_build_object('status', 'WITHDRAWN', 'shop_id', v_row.shop_id,
                                                  'consent_version', v_row.consent_version),
                               p_idempotency_key);
    v_count := v_count + 1;
  end loop;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('shop_id', p_shop_id, 'withdrawn', v_count));
end;
$$;

-- ── nominate_monvelo_agent ──────────────────────────────────────────────
-- A ZSA/ASA of the shop's tenant, or the shop's owner. The owner must be an
-- ACTIVE RETAIL_SHOP_OWNER member of the tenant of their session (live check),
-- and that tenant must hold an ACTIVE enrolment of the shop. The phone is reduced to its last four digits here.
create or replace function public.nominate_monvelo_agent(
  p_idempotency_key uuid,
  p_shop_id         uuid,
  p_name            text,
  p_phone           text,
  p_pos_network     public.pos_network_enum
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_owner   uuid;
  v_tenant  uuid;
  v_prior   jsonb;
  v_name    text := btrim(coalesce(p_name, ''));
  v_digits  text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_row     public.monvelo_agent_nominations;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select owner_id into v_owner from public.retail_shops where id = p_shop_id;
  if v_owner is not null and v_owner = v_uid then
    -- re-verified live: the owner must be an ACTIVE RETAIL_SHOP_OWNER member of
    -- the tenant in their session (assert_tenant_role reads tenant_users)
    v_tenant := (public.assert_tenant_role(array['RETAIL_SHOP_OWNER']::public.tenant_role_enum[])).tenant_id;
  else
    v_tenant := (public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[])).tenant_id;
  end if;
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_tenant and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'nominate_monvelo_agent',
    jsonb_build_object('shop_id', p_shop_id, 'name', v_name, 'phone_last4', right(v_digits, 4),
                       'pos_network', p_pos_network));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_name = '' then
    raise exception 'the agent''s name is required' using errcode = 'P0001';
  end if;
  if length(v_digits) < 7 or length(v_digits) > 15 then
    raise exception 'enter a valid phone number' using errcode = 'P0001';
  end if;
  if p_pos_network is null then
    raise exception 'the POS network is required' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.monvelo_shop_enrolments e
                  where e.tenant_id = v_tenant and e.shop_id = p_shop_id and e.status = 'ACTIVE') then
    raise exception 'this shop is not enrolled' using errcode = 'P0001';
  end if;

  insert into public.monvelo_agent_nominations (tenant_id, shop_id, nominated_name, nominated_phone_last4,
                                                pos_network, raised_by)
  values (v_tenant, p_shop_id, v_name, right(v_digits, 4), p_pos_network, v_uid)
  returning * into v_row;

  perform public.write_audit(v_tenant, 'nominate_monvelo_agent', 'monvelo_agent_nominations', v_row.id::text,
                             null, to_jsonb(v_row), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('nomination_id', v_row.id, 'status', v_row.status));
end;
$$;

-- ── close_monvelo_nomination ────────────────────────────────────────────
create or replace function public.close_monvelo_nomination(
  p_idempotency_key uuid,
  p_nomination_id   uuid,
  p_agent_id        uuid,
  p_status          text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSA', 'ASA']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_agent_nominations;
  v_after  public.monvelo_agent_nominations;
  v_agent  public.monvelo_fintech_agents;
begin
  if not exists (select 1 from public.monvelo_tenant_settings st where st.tenant_id = v_me.tenant_id and st.enabled) then
    raise exception 'Monvelo is not enabled for this tenant' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'close_monvelo_nomination',
    jsonb_build_object('nomination_id', p_nomination_id, 'agent_id', p_agent_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;
  if p_status is null or p_status not in ('RECRUITED', 'DECLINED') then
    raise exception 'a nomination closes as RECRUITED or DECLINED' using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_agent_nominations
   where id = p_nomination_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'unknown nomination' using errcode = 'P0001';
  end if;
  if v_before.status <> 'OPEN' then
    raise exception 'this nomination is already closed' using errcode = 'P0001';
  end if;

  if p_status = 'RECRUITED' then
    if p_agent_id is null then
      raise exception 'the recruited agent is required' using errcode = 'P0001';
    end if;
    select * into v_agent from public.monvelo_fintech_agents where id = p_agent_id;
    if not found then
      raise exception 'unknown fintech agent' using errcode = 'P0001';
    end if;
    if v_agent.status <> 'ACTIVE' then
      raise exception 'the agent is not active yet' using errcode = 'P0001';
    end if;
    if v_agent.pos_network is distinct from v_before.pos_network then
      raise exception 'the agent is on a different network' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.monvelo_shop_enrolments e
                    where e.tenant_id = v_me.tenant_id and e.shop_id = v_before.shop_id and e.status = 'ACTIVE') then
      raise exception 'this shop is not enrolled' using errcode = 'P0001';
    end if;
    update public.retail_shops set preferred_agent_id = p_agent_id where id = v_before.shop_id;
  elsif p_agent_id is not null then
    raise exception 'a declined nomination has no agent' using errcode = 'P0001';
  end if;

  update public.monvelo_agent_nominations
     set status = p_status, recruited_agent_id = case when p_status = 'RECRUITED' then p_agent_id end
   where id = p_nomination_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'close_monvelo_nomination', 'monvelo_agent_nominations', p_nomination_id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'nomination_id', p_nomination_id, 'status', v_after.status, 'recruited_agent_id', v_after.recruited_agent_id));
end;
$$;

grant execute on function
  public.start_monvelo_consent(uuid, text, uuid, uuid),
  public.enrol_monvelo_shop(uuid, uuid, text),
  public.withdraw_monvelo_shop_consent(uuid, uuid),
  public.nominate_monvelo_agent(uuid, uuid, text, text, public.pos_network_enum),
  public.close_monvelo_nomination(uuid, uuid, uuid, text)
to authenticated;
