-- Addendum A6 §4.2 — Monvelo tenant settings, per-brand contract terms and
-- Teafair's fee terms.
--
--   monvelo_tenant_settings    the tenant's on/off switch and limits (ZSM)
--   monvelo_brand_terms        rebate, interest-free days, late charge per brand;
--                              dated promotions proposed by one ZSM and approved
--                              by a different one
--   monvelo_tenant_fee_terms   Teafair's fee, recorded by a MONVELO_OPERATOR
--
-- `valid_to` is exclusive and null means open-ended. Overlap and immutability
-- are enforced by triggers (btree_gist is not installed). Steps 2-3 read terms
-- through monvelo_terms_at().

-- ── monvelo staff ───────────────────────────────────────────────────────
-- Platform staff of Monvelo, read live from profiles. Used by the SELECT
-- policies; Task 3 reuses it.
create or replace function public.is_monvelo_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.platform_role in ('MONVELO_OPERATOR', 'MONVELO_FINANCE')
  );
$$;
grant execute on function public.is_monvelo_staff() to authenticated;

-- ── monvelo_tenant_settings ─────────────────────────────────────────────
create table public.monvelo_tenant_settings (
  tenant_id      uuid primary key references public.tenants (id) on delete restrict,
  enabled        boolean not null default false,
  opening_limit  numeric(15,2) not null default 0 check (opening_limit >= 0),
  approval_cap   numeric(15,2) not null default 0 check (approval_cap >= 0),
  updated_at     timestamptz not null default now()
);
alter table public.monvelo_tenant_settings enable row level security;
create trigger monvelo_tenant_settings_set_updated_at before update on public.monvelo_tenant_settings
  for each row execute function public.set_updated_at();

create policy monvelo_tenant_settings_select on public.monvelo_tenant_settings
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()) or (select public.is_monvelo_staff()));

-- ── monvelo_brand_terms ─────────────────────────────────────────────────
create table public.monvelo_brand_terms (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants (id) on delete restrict,
  brand               text not null check (brand = btrim(brand) and length(brand) > 0),
  brand_key           text generated always as (lower(btrim(brand))) stored,
  rebate_bps          integer not null check (rebate_bps between 0 and 10000),
  interest_free_days  integer not null default 30 check (interest_free_days between 1 and 365),
  late_charge_bps     integer not null default 1000 check (late_charge_bps between 0 and 10000),
  valid_from          date not null,
  valid_to            date,
  status              text not null default 'PROPOSED' check (status in ('PROPOSED', 'APPROVED', 'WITHDRAWN')),
  proposed_by         uuid not null references public.profiles (id) on delete restrict,
  approved_by         uuid references public.profiles (id) on delete restrict,
  approved_at         timestamptz,
  created_at          timestamptz not null default now(),
  unique (tenant_id, id),
  check (valid_to is null or valid_to > valid_from)
);
alter table public.monvelo_brand_terms enable row level security;
create index idx_monvelo_brand_terms_brand on public.monvelo_brand_terms (tenant_id, brand_key, valid_from);
create index idx_monvelo_brand_terms_proposed_by on public.monvelo_brand_terms (proposed_by);
create index idx_monvelo_brand_terms_approved_by on public.monvelo_brand_terms (approved_by);

create policy monvelo_brand_terms_select on public.monvelo_brand_terms
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()) or (select public.is_monvelo_staff()));

-- ── monvelo_tenant_fee_terms ────────────────────────────────────────────
create table public.monvelo_tenant_fee_terms (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  fee_bps      integer not null check (fee_bps between 0 and 10000),
  valid_from   date not null,
  valid_to     date,
  recorded_by  uuid not null references public.profiles (id) on delete restrict,
  created_at   timestamptz not null default now(),
  unique (tenant_id, id),
  check (valid_to is null or valid_to > valid_from)
);
alter table public.monvelo_tenant_fee_terms enable row level security;
create index idx_monvelo_fee_terms_tenant on public.monvelo_tenant_fee_terms (tenant_id, valid_from);
create index idx_monvelo_fee_terms_recorded_by on public.monvelo_tenant_fee_terms (recorded_by);

create policy monvelo_tenant_fee_terms_select on public.monvelo_tenant_fee_terms
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()) or (select public.is_monvelo_staff()));

-- ── triggers: brand terms ───────────────────────────────────────────────
create or replace function public.monvelo_brand_terms_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_old jsonb;
  v_new jsonb;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old) - 'brand_key';
    v_new := to_jsonb(new) - 'brand_key';  -- generated column not yet computed in BEFORE
    if old.status = 'WITHDRAWN' then
      raise exception 'withdrawn terms are immutable' using errcode = 'P0001';
    elsif old.status = 'APPROVED' then
      -- only to WITHDRAWN, or an end date later than today
      if not (
        (new.status = 'WITHDRAWN' and (v_old - 'status') = (v_new - 'status'))
        or (new.status = 'APPROVED' and new.valid_to is not null and new.valid_to > current_date
            and (old.valid_to is null or old.valid_to > current_date)
            and (v_old - 'valid_to') = (v_new - 'valid_to'))
      ) then
        raise exception 'approved terms are immutable' using errcode = 'P0001';
      end if;
    else
      -- PROPOSED: only a status change, with the approval stamp
      if (v_old - 'status' - 'approved_by' - 'approved_at') is distinct from
         (v_new - 'status' - 'approved_by' - 'approved_at') then
        raise exception 'proposed terms are changed by withdrawing and proposing again' using errcode = 'P0001';
      end if;
    end if;
  end if;

  if new.status = 'APPROVED' then
    -- serialise approvals per tenant and brand, then look at committed rows
    perform pg_advisory_xact_lock(hashtextextended('monvelo_brand_terms|' || new.tenant_id::text || '|' || lower(btrim(new.brand)), 0));
    if exists (
      select 1 from public.monvelo_brand_terms t
      where t.tenant_id = new.tenant_id
        and t.brand_key = lower(btrim(new.brand))
        and t.status = 'APPROVED'
        and t.id <> new.id
        and t.valid_from < coalesce(new.valid_to, 'infinity'::date)
        and new.valid_from < coalesce(t.valid_to, 'infinity'::date)
    ) then
      raise exception 'approved terms for this brand overlap in time' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
create trigger monvelo_brand_terms_guard before insert or update on public.monvelo_brand_terms
  for each row execute function public.monvelo_brand_terms_guard();

-- ── triggers: fee terms ─────────────────────────────────────────────────
create or replace function public.monvelo_fee_terms_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    if not (
      new.valid_to is not null and new.valid_to > current_date
      and (old.valid_to is null or old.valid_to > current_date)
      and (to_jsonb(old) - 'valid_to') = (to_jsonb(new) - 'valid_to')
    ) then
      raise exception 'fee terms are immutable except for an end date later than today' using errcode = 'P0001';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('monvelo_tenant_fee_terms|' || new.tenant_id::text, 0));
  if exists (
    select 1 from public.monvelo_tenant_fee_terms t
    where t.tenant_id = new.tenant_id
      and t.id <> new.id
      and t.valid_from < coalesce(new.valid_to, 'infinity'::date)
      and new.valid_from < coalesce(t.valid_to, 'infinity'::date)
  ) then
    raise exception 'fee terms for this tenant overlap in time' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger monvelo_fee_terms_guard before insert or update on public.monvelo_tenant_fee_terms
  for each row execute function public.monvelo_fee_terms_guard();

-- ── never delete ────────────────────────────────────────────────────────
create or replace function public.monvelo_terms_no_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'terms are never deleted' using errcode = 'P0001';
end;
$$;
create trigger monvelo_brand_terms_no_delete before delete on public.monvelo_brand_terms
  for each row execute function public.monvelo_terms_no_delete();
create trigger monvelo_brand_terms_no_truncate before truncate on public.monvelo_brand_terms
  for each statement execute function public.monvelo_terms_no_delete();
create trigger monvelo_fee_terms_no_delete before delete on public.monvelo_tenant_fee_terms
  for each row execute function public.monvelo_terms_no_delete();
create trigger monvelo_fee_terms_no_truncate before truncate on public.monvelo_tenant_fee_terms
  for each statement execute function public.monvelo_terms_no_delete();

-- ── monvelo_terms_at ────────────────────────────────────────────────────
-- Internal: the APPROVED terms in force for a brand on a date, else null.
create or replace function public.monvelo_terms_at(p_tenant_id uuid, p_brand text, p_at date)
returns public.monvelo_brand_terms
language sql
stable
set search_path = public, pg_temp
as $$
  select t.* from public.monvelo_brand_terms t
  where t.tenant_id = p_tenant_id
    and t.brand_key = lower(btrim(p_brand))
    and t.status = 'APPROVED'
    and t.valid_from <= p_at
    and (t.valid_to is null or p_at < t.valid_to)
  limit 1;
$$;

-- ── set_monvelo_tenant_settings ─────────────────────────────────────────
create or replace function public.set_monvelo_tenant_settings(
  p_idempotency_key uuid,
  p_enabled         boolean,
  p_opening_limit   numeric,
  p_approval_cap    numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_tenant_settings;
  v_after  public.monvelo_tenant_settings;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_tenant_settings',
    jsonb_build_object('enabled', p_enabled, 'opening_limit', p_opening_limit, 'approval_cap', p_approval_cap));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_enabled is null or p_opening_limit is null or p_approval_cap is null
     or p_opening_limit < 0 or p_approval_cap < 0 then
    raise exception 'enabled, a non-negative opening limit and a non-negative approval cap are required'
      using errcode = 'P0001';
  end if;

  select * into v_before from public.monvelo_tenant_settings
   where tenant_id = v_me.tenant_id for update;

  insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap)
  values (v_me.tenant_id, p_enabled, p_opening_limit, p_approval_cap)
  on conflict (tenant_id) do update
    set enabled = excluded.enabled,
        opening_limit = excluded.opening_limit,
        approval_cap = excluded.approval_cap
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_tenant_settings', 'monvelo_tenant_settings',
                             v_me.tenant_id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_id', v_me.tenant_id, 'enabled', v_after.enabled));
end;
$$;

-- ── propose_monvelo_brand_terms ─────────────────────────────────────────
create or replace function public.propose_monvelo_brand_terms(
  p_idempotency_key     uuid,
  p_brand               text,
  p_rebate_bps          integer,
  p_interest_free_days  integer,
  p_late_charge_bps     integer,
  p_valid_from          date,
  p_valid_to            date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior jsonb;
  v_brand text := btrim(coalesce(p_brand, ''));
  v_days  integer := coalesce(p_interest_free_days, 30);
  v_late  integer := coalesce(p_late_charge_bps, 1000);
  v_after public.monvelo_brand_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'propose_monvelo_brand_terms',
    jsonb_build_object('brand', v_brand, 'rebate_bps', p_rebate_bps, 'interest_free_days', v_days,
                       'late_charge_bps', v_late, 'valid_from', p_valid_from, 'valid_to', p_valid_to));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_brand = '' or p_rebate_bps is null or p_rebate_bps not between 0 and 10000
     or v_days not between 1 and 365 or v_late not between 0 and 10000 then
    raise exception 'brand, a rebate of 0-10000 bps, 1-365 interest-free days and a late charge of 0-10000 bps are required'
      using errcode = 'P0001';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to <= p_valid_from) then
    raise exception 'valid_from is required and valid_to must be later than it' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.central_products cp
    where cp.tenant_id = v_me.tenant_id and cp.is_active
      and lower(btrim(cp.brand)) = lower(v_brand)
  ) then
    raise exception 'no active product of this brand' using errcode = 'P0001';
  end if;

  insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps,
                                          valid_from, valid_to, status, proposed_by)
  values (v_me.tenant_id, v_brand, p_rebate_bps, v_days, v_late, p_valid_from, p_valid_to,
          'PROPOSED', v_me.profile_id)
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'propose_monvelo_brand_terms', 'monvelo_brand_terms',
                             v_after.id::text, null, to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('terms_id', v_after.id, 'status', v_after.status));
end;
$$;

-- ── approve_monvelo_brand_terms ─────────────────────────────────────────
create or replace function public.approve_monvelo_brand_terms(
  p_idempotency_key uuid,
  p_terms_id        uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_brand_terms;
  v_after  public.monvelo_brand_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'approve_monvelo_brand_terms',
    jsonb_build_object('terms_id', p_terms_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_brand_terms
   where id = p_terms_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'terms not found' using errcode = 'P0001';
  end if;
  if v_before.status <> 'PROPOSED' then
    raise exception 'only proposed terms can be approved' using errcode = 'P0001';
  end if;
  if v_before.proposed_by = v_me.profile_id then
    raise exception 'terms are approved by a second ZSM' using errcode = '42501';
  end if;

  update public.monvelo_brand_terms
     set status = 'APPROVED', approved_by = v_me.profile_id, approved_at = now()
   where id = p_terms_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'approve_monvelo_brand_terms', 'monvelo_brand_terms',
                             v_after.id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('terms_id', v_after.id, 'status', v_after.status));
end;
$$;

-- ── withdraw_monvelo_brand_terms ────────────────────────────────────────
create or replace function public.withdraw_monvelo_brand_terms(
  p_idempotency_key uuid,
  p_terms_id        uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_brand_terms;
  v_after  public.monvelo_brand_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'withdraw_monvelo_brand_terms',
    jsonb_build_object('terms_id', p_terms_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.monvelo_brand_terms
   where id = p_terms_id and tenant_id = v_me.tenant_id for update;
  if not found then
    raise exception 'terms not found' using errcode = 'P0001';
  end if;
  if v_before.status = 'WITHDRAWN' then
    raise exception 'terms are already withdrawn' using errcode = 'P0001';
  end if;

  update public.monvelo_brand_terms set status = 'WITHDRAWN'
   where id = p_terms_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'withdraw_monvelo_brand_terms', 'monvelo_brand_terms',
                             v_after.id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('terms_id', v_after.id, 'status', v_after.status));
end;
$$;

-- ── record_monvelo_fee_terms ────────────────────────────────────────────
-- p_tenant_id is allowed here only because the caller is a platform role
-- acting on a tenant (the same documented exception as set_active_tenant).
create or replace function public.record_monvelo_fee_terms(
  p_idempotency_key uuid,
  p_tenant_id       uuid,
  p_fee_bps         integer,
  p_valid_from      date,
  p_valid_to        date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior jsonb;
  v_after public.monvelo_tenant_fee_terms;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_monvelo_fee_terms',
    jsonb_build_object('tenant_id', p_tenant_id, 'fee_bps', p_fee_bps,
                       'valid_from', p_valid_from, 'valid_to', p_valid_to));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_tenant_id is null or not exists (select 1 from public.tenants t where t.id = p_tenant_id) then
    raise exception 'tenant not found' using errcode = 'P0001';
  end if;
  if p_fee_bps is null or p_fee_bps not between 0 and 10000 then
    raise exception 'a fee of 0-10000 bps is required' using errcode = 'P0001';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to <= p_valid_from) then
    raise exception 'valid_from is required and valid_to must be later than it' using errcode = 'P0001';
  end if;

  insert into public.monvelo_tenant_fee_terms (tenant_id, fee_bps, valid_from, valid_to, recorded_by)
  values (p_tenant_id, p_fee_bps, p_valid_from, p_valid_to, v_actor)
  returning * into v_after;

  perform public.write_audit(p_tenant_id, 'record_monvelo_fee_terms', 'monvelo_tenant_fee_terms',
                             v_after.id::text, null, to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('fee_terms_id', v_after.id));
end;
$$;

grant execute on function
  public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric),
  public.propose_monvelo_brand_terms(uuid, text, integer, integer, integer, date, date),
  public.approve_monvelo_brand_terms(uuid, uuid),
  public.withdraw_monvelo_brand_terms(uuid, uuid),
  public.record_monvelo_fee_terms(uuid, uuid, integer, date, date)
to authenticated;
