-- Addendum A6 §4.4, §7.2, §18.2 (Monvelo Step 2, Task 7) — financings and their
-- brand lines, per-brand shop limits with an insert-only history, the request
-- (ZSA, ASA or TM, on their own PENDING trade order), TM approval above the
-- limit, and cancel.
--
-- Credit rules are the tenant's (user, 2026-10-30): opening_limit, max_limit,
-- limit_growth_bps, and the recovery rules default_cure_days and
-- post_default_limit_bps, all set through set_monvelo_tenant_settings citing a
-- MONVELO_SETTINGS decision. The platform keeps the integrity checks and the
-- hard freeze: an unresolved default with any brand blocks new credit for every
-- brand, with a message that names no other tenant.
--
-- A cancelled financing cancels its PENDING trade order and releases its stock
-- (A6 §18.1) through monvelo_cancel_trade_order, which the expiry sweep (Task 8)
-- reuses.

-- ── the tenant's credit and recovery rules ──────────────────────────────
alter table public.monvelo_tenant_settings
  add column limit_growth_bps integer not null default 0
    check (limit_growth_bps between 0 and 10000),
  add column default_cure_days integer not null default 0
    check (default_cure_days between 0 and 365),
  add column post_default_limit_bps integer not null default 10000
    check (post_default_limit_bps between 0 and 10000);

-- ── shared: Monvelo records are never deleted (A6 §7.4) ─────────────────
create or replace function public.monvelo_no_delete()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'Monvelo records are never deleted' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_no_delete() from public, anon, authenticated, service_role;

-- ── monvelo_financings ──────────────────────────────────────────────────
-- Every column of §4.4 now, so Steps 3 and 4 add none.
create table public.monvelo_financings (
  id                       uuid primary key default gen_random_uuid(),
  tenant_id                uuid not null references public.tenants (id) on delete restrict,
  reference                text not null unique check (reference ~ '^MV-[A-Z2-7]{8}$'),
  shop_id                  uuid not null,
  order_id                 uuid not null,
  area_id                  uuid not null,
  territory_id             uuid not null,
  raised_by                uuid not null references public.profiles (id) on delete restrict,
  principal                numeric(15,2) not null check (principal > 0),
  supply_date              date not null,
  status                   text not null default 'REQUESTED' check (status in (
                             'REQUESTED', 'AWAITING_APPROVAL', 'OFFERED', 'CLAIMED', 'FUNDED', 'DELIVERED',
                             'REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE', 'REPAID_LATE', 'EXPIRED',
                             'CANCELLED', 'REFUND_DUE')),
  approval_required        boolean not null,
  approved_by              uuid references public.profiles (id) on delete restrict,
  approved_at              timestamptz,
  offered_at               timestamptz,
  preferred_agent_id       uuid references public.monvelo_agents (id) on delete restrict,
  preferred_window_ends_at timestamptz,
  claimed_by_agent_id      uuid references public.monvelo_agents (id) on delete restrict,
  claimed_by               uuid references public.profiles (id) on delete restrict,
  claim_expires_at         timestamptz,
  pledge_id                uuid,
  funder_agent_id          uuid references public.monvelo_agents (id) on delete restrict,
  paystack_reference       text unique,
  funded_at                timestamptz,
  delivered_at             timestamptz,
  due_at                   timestamptz,
  late_charge_amount       numeric(15,2) not null default 0 check (late_charge_amount >= 0),
  outstanding              numeric(15,2) check (outstanding >= 0),
  closed_at                timestamptz,
  cancelled_by             uuid references public.profiles (id) on delete restrict,
  cancelled_at             timestamptz,
  cancel_reason            text check (char_length(cancel_reason) <= 500),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, order_id)     references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, shop_id)      references public.monvelo_shop_enrolments (tenant_id, shop_id) on delete restrict,
  foreign key (tenant_id, area_id)      references public.areas (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict,
  foreign key (tenant_id, pledge_id)    references public.monvelo_pledges (tenant_id, id) on delete restrict,
  check (status <> 'CLAIMED' or num_nulls(claimed_by_agent_id, claimed_by, claim_expires_at, pledge_id) = 0),
  check ((status = 'CANCELLED') = (cancelled_at is not null))
);
create unique index monvelo_financings_one_live_per_order on public.monvelo_financings (tenant_id, order_id)
  where status not in ('CANCELLED', 'EXPIRED');
create index idx_monvelo_financings_order        on public.monvelo_financings (tenant_id, order_id);
create index idx_monvelo_financings_shop         on public.monvelo_financings (tenant_id, shop_id);
-- the platform hard freeze and the owner's policy read a shop across tenants
create index idx_monvelo_financings_shop_status  on public.monvelo_financings (shop_id, status);
create index idx_monvelo_financings_area         on public.monvelo_financings (tenant_id, area_id);
create index idx_monvelo_financings_territory    on public.monvelo_financings (tenant_id, territory_id);
create index idx_monvelo_financings_territory_id on public.monvelo_financings (territory_id);
create index idx_monvelo_financings_pledge       on public.monvelo_financings (tenant_id, pledge_id);
create index idx_monvelo_financings_raised_by    on public.monvelo_financings (raised_by);
create index idx_monvelo_financings_approved_by  on public.monvelo_financings (approved_by);
create index idx_monvelo_financings_preferred    on public.monvelo_financings (preferred_agent_id);
create index idx_monvelo_financings_claimed_ag   on public.monvelo_financings (claimed_by_agent_id);
create index idx_monvelo_financings_claimed_by   on public.monvelo_financings (claimed_by);
create index idx_monvelo_financings_funder       on public.monvelo_financings (funder_agent_id);
create index idx_monvelo_financings_cancelled_by on public.monvelo_financings (cancelled_by);
create index idx_monvelo_financings_claim_expiry on public.monvelo_financings (status, claim_expires_at);
create index idx_monvelo_financings_supply_date  on public.monvelo_financings (status, supply_date);
create trigger monvelo_financings_set_updated_at before update on public.monvelo_financings
  for each row execute function public.set_updated_at();

-- inserted only as REQUESTED; the identity never changes; the status moves
-- only along the whitelist (a self-update keeping the status is allowed)
create or replace function public.monvelo_financings_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'REQUESTED' then
      raise exception 'a financing is created as REQUESTED' using errcode = 'P0001';
    end if;
    return new;
  end if;

  if (new.id, new.tenant_id, new.reference, new.shop_id, new.order_id, new.area_id, new.territory_id, new.raised_by,
      new.principal, new.supply_date, new.created_at)
     is distinct from
     (old.id, old.tenant_id, old.reference, old.shop_id, old.order_id, old.area_id, old.territory_id, old.raised_by,
      old.principal, old.supply_date, old.created_at) then
    raise exception 'a financing''s identity never changes' using errcode = 'P0001';
  end if;

  if new.status <> old.status and not (
       (old.status = 'REQUESTED' and new.status in ('OFFERED', 'AWAITING_APPROVAL', 'CANCELLED'))
    or (old.status = 'AWAITING_APPROVAL' and new.status in ('OFFERED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'OFFERED' and new.status in ('CLAIMED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'CLAIMED' and new.status in ('OFFERED', 'FUNDED'))
    or (old.status = 'FUNDED' and new.status in ('DELIVERED', 'REFUND_DUE'))
    or (old.status = 'DELIVERED' and new.status in ('REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE'))
    or (old.status = 'DEFAULTED_WITH_LATE_CHARGE' and new.status = 'REPAID_LATE')) then
    raise exception 'a financing cannot move from % to %', old.status, new.status using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.monvelo_financings_guard() from public, anon, authenticated, service_role;
create trigger monvelo_financings_guard before insert or update on public.monvelo_financings
  for each row execute function public.monvelo_financings_guard();
create trigger monvelo_financings_no_delete before delete on public.monvelo_financings
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_financings_no_truncate before truncate on public.monvelo_financings
  for each statement execute function public.monvelo_no_delete();

-- ── monvelo_financing_lines: one per brand ──────────────────────────────
-- The terms columns stay null until funding (Step 3) locks them, once.
create table public.monvelo_financing_lines (
  tenant_id          uuid not null references public.tenants (id) on delete restrict,
  financing_id       uuid not null,
  brand              text not null,
  brand_key          text not null check (brand_key = lower(btrim(brand))),
  amount             numeric(15,2) not null check (amount > 0),
  terms_id           uuid,
  rebate_bps         integer check (rebate_bps between 0 and 10000),
  interest_free_days integer check (interest_free_days >= 0),
  late_charge_bps    integer check (late_charge_bps between 0 and 10000),
  terms_locked_at    timestamptz,
  primary key (financing_id, brand_key),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  foreign key (tenant_id, terms_id)     references public.monvelo_brand_terms (tenant_id, id) on delete restrict,
  check (num_nulls(terms_id, rebate_bps, interest_free_days, late_charge_bps, terms_locked_at) in (0, 5))
);
create index idx_monvelo_financing_lines_financing on public.monvelo_financing_lines (tenant_id, financing_id);
create index idx_monvelo_financing_lines_terms     on public.monvelo_financing_lines (tenant_id, terms_id);

create or replace function public.monvelo_financing_lines_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.terms_locked_at is null and new.terms_locked_at is not null
     and (new.tenant_id, new.financing_id, new.brand, new.brand_key, new.amount)
         is not distinct from (old.tenant_id, old.financing_id, old.brand, old.brand_key, old.amount) then
    return new;
  end if;
  raise exception 'a financing line changes only once, when funding locks its terms' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_financing_lines_guard() from public, anon, authenticated, service_role;
create trigger monvelo_financing_lines_guard before update on public.monvelo_financing_lines
  for each row execute function public.monvelo_financing_lines_guard();
create trigger monvelo_financing_lines_no_delete before delete on public.monvelo_financing_lines
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_financing_lines_no_truncate before truncate on public.monvelo_financing_lines
  for each statement execute function public.monvelo_no_delete();

-- ── monvelo_shop_limits and their history (§7.2, §16.6) ─────────────────
create table public.monvelo_shop_limits (
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  shop_id      uuid not null,
  brand_key    text not null check (brand_key = lower(btrim(brand_key)) and brand_key <> ''),
  limit_amount numeric(15,2) not null check (limit_amount >= 0),
  status       text not null default 'ACTIVE' check (status in ('ACTIVE', 'FROZEN')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, shop_id, brand_key),
  foreign key (tenant_id, shop_id) references public.monvelo_shop_enrolments (tenant_id, shop_id) on delete restrict
);
create index idx_monvelo_shop_limits_shop on public.monvelo_shop_limits (shop_id);
create trigger monvelo_shop_limits_set_updated_at before update on public.monvelo_shop_limits
  for each row execute function public.set_updated_at();
create trigger monvelo_shop_limits_no_delete before delete on public.monvelo_shop_limits
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_shop_limits_no_truncate before truncate on public.monvelo_shop_limits
  for each statement execute function public.monvelo_no_delete();

create table public.monvelo_shop_limit_events (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  shop_id      uuid not null,
  brand_key    text not null,
  kind         text not null check (kind in ('OPENED', 'GROWN', 'FROZEN', 'RESET')),
  old_limit    numeric(15,2) check (old_limit >= 0),
  new_limit    numeric(15,2) not null check (new_limit >= 0),
  financing_id uuid,
  created_at   timestamptz not null default now(),
  unique (tenant_id, id),
  check ((kind = 'OPENED') = (old_limit is null)),
  foreign key (tenant_id, shop_id, brand_key)
    references public.monvelo_shop_limits (tenant_id, shop_id, brand_key) on delete restrict,
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict
);
create index idx_monvelo_shop_limit_events_limit     on public.monvelo_shop_limit_events (tenant_id, shop_id, brand_key);
create index idx_monvelo_shop_limit_events_shop      on public.monvelo_shop_limit_events (shop_id);
create index idx_monvelo_shop_limit_events_financing on public.monvelo_shop_limit_events (tenant_id, financing_id);

create or replace function public.monvelo_shop_limit_events_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'the limit history is insert-only' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_shop_limit_events_insert_only() from public, anon, authenticated, service_role;
create trigger monvelo_shop_limit_events_insert_only before update on public.monvelo_shop_limit_events
  for each row execute function public.monvelo_shop_limit_events_insert_only();
create trigger monvelo_shop_limit_events_no_delete before delete on public.monvelo_shop_limit_events
  for each row execute function public.monvelo_no_delete();
create trigger monvelo_shop_limit_events_no_truncate before truncate on public.monvelo_shop_limit_events
  for each statement execute function public.monvelo_no_delete();

-- ── grants and policies ─────────────────────────────────────────────────
-- service_role holds no write either: these are written by the RPCs below only
alter table public.monvelo_financings enable row level security;
alter table public.monvelo_financing_lines enable row level security;
alter table public.monvelo_shop_limits enable row level security;
alter table public.monvelo_shop_limit_events enable row level security;
revoke all on public.monvelo_financings, public.monvelo_financing_lines, public.monvelo_shop_limits,
              public.monvelo_shop_limit_events from anon, authenticated, service_role;
grant select on public.monvelo_financings, public.monvelo_financing_lines, public.monvelo_shop_limits,
               public.monvelo_shop_limit_events to authenticated;

-- the territories of the caller's ACTIVE TM and ASM memberships
create or replace function public.my_monvelo_territory_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.territory_id from public.tenant_users tu
   where tu.profile_id = (select auth.uid())
     and tu.status = 'ACTIVE'
     and tu.role in ('TM', 'ASM')
     and tu.territory_id is not null;
$$;
revoke all on function public.my_monvelo_territory_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_monvelo_territory_ids() to authenticated;

create policy monvelo_financings_select on public.monvelo_financings for select to authenticated
  using (
    shop_id in (select public.my_owned_shop_ids())
    or claimed_by_agent_id in (select public.my_monvelo_agent_ids())
    or funder_agent_id in (select public.my_monvelo_agent_ids())
    or raised_by = (select auth.uid())
    or territory_id in (select public.my_monvelo_territory_ids())
    or tenant_id in (select public.my_tenant_ids_with_role(
         array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]))
    -- a ZSM reads the financings of their zones (A6 §18.3)
    or territory_id in (select public.my_zsm_territory_ids())
    or (status = 'FUNDED' and tenant_id in (select public.my_tenant_ids_with_role(
         array['LOGISTICS_MANAGER']::public.tenant_role_enum[])))
    or (select public.is_monvelo_staff()));

create policy monvelo_financing_lines_select on public.monvelo_financing_lines for select to authenticated
  using ((tenant_id, financing_id) in (select f.tenant_id, f.id from public.monvelo_financings f));

create policy monvelo_shop_limits_select on public.monvelo_shop_limits for select to authenticated
  using (
    shop_id in (select public.my_owned_shop_ids())
    or tenant_id in (select public.my_tenant_ids_with_role(
         array['ZSM', 'TM', 'ASM', 'ZSA', 'ASA', 'TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]))
    or (select public.is_monvelo_staff()));

create policy monvelo_shop_limit_events_select on public.monvelo_shop_limit_events for select to authenticated
  using (
    shop_id in (select public.my_owned_shop_ids())
    or tenant_id in (select public.my_tenant_ids_with_role(
         array['ZSM', 'TM', 'ASM', 'ZSA', 'ASA', 'TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]))
    or (select public.is_monvelo_staff()));

-- ── internal helpers (no API grant) ─────────────────────────────────────

-- MV- and eight RFC 4648 base32 characters
create or replace function public.monvelo_draw_reference()
returns text
language sql
volatile
set search_path = public, pg_temp
as $$
  select 'MV-' || string_agg(substr('ABCDEFGHIJKLMNOPQRSTUVWXYZ234567',
                                    1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
    from generate_series(1, 8);
$$;
revoke all on function public.monvelo_draw_reference() from public, anon, authenticated, service_role;

-- the shop's current limit for a brand, opened at the tenant's opening_limit
-- (with an OPENED event) on first use; returned locked
create or replace function public.monvelo_shop_limit_for(p_tenant_id uuid, p_shop_id uuid, p_brand_key text)
returns public.monvelo_shop_limits
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit public.monvelo_shop_limits;
begin
  select * into v_limit from public.monvelo_shop_limits
   where tenant_id = p_tenant_id and shop_id = p_shop_id and brand_key = p_brand_key
     for update;
  if found then
    return v_limit;
  end if;
  insert into public.monvelo_shop_limits (tenant_id, shop_id, brand_key, limit_amount)
  select p_tenant_id, p_shop_id, p_brand_key, s.opening_limit
    from public.monvelo_tenant_settings s where s.tenant_id = p_tenant_id
  returning * into v_limit;
  if v_limit.tenant_id is null then
    raise exception 'Monvelo is not switched on for this tenant' using errcode = 'P0001';
  end if;
  insert into public.monvelo_shop_limit_events (tenant_id, shop_id, brand_key, kind, old_limit, new_limit)
  values (p_tenant_id, p_shop_id, p_brand_key, 'OPENED', null, v_limit.limit_amount);
  return v_limit;
end;
$$;
revoke all on function public.monvelo_shop_limit_for(uuid, uuid, text) from public, anon, authenticated, service_role;

-- what the shop already owes, or may soon owe, the brand: the line amounts of
-- its live financings (Step 4 replaces this with outstanding-based exposure)
create or replace function public.monvelo_brand_exposure(p_tenant_id uuid, p_shop_id uuid, p_brand_key text, p_exclude uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(l.amount), 0)
    from public.monvelo_financing_lines l
    join public.monvelo_financings f on f.tenant_id = l.tenant_id and f.id = l.financing_id
   where f.tenant_id = p_tenant_id and f.shop_id = p_shop_id and l.brand_key = p_brand_key
     and f.status in ('AWAITING_APPROVAL', 'OFFERED', 'CLAIMED', 'FUNDED', 'DELIVERED', 'DEFAULTED_WITH_LATE_CHARGE')
     and f.id is distinct from p_exclude;
$$;
revoke all on function public.monvelo_brand_exposure(uuid, uuid, text, uuid) from public, anon, authenticated, service_role;

-- Offer a financing to the agents. The shop's preferred agent gets a head start
-- of preferred_window_minutes only while it is ACTIVE and its pledge for the
-- financing's area and supply day, less what it has claimed against it, covers
-- the principal.
create or replace function public.monvelo_offer(p_id uuid)
returns public.monvelo_financings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fin     public.monvelo_financings;
  v_agent   uuid;
  v_pledge  public.monvelo_pledges;
  v_claimed numeric(15,2);
begin
  select * into v_fin from public.monvelo_financings where id = p_id for update;
  if not found then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;

  select s.preferred_agent_id into v_agent
    from public.retail_shops s
    join public.monvelo_agents a on a.id = s.preferred_agent_id and a.status = 'ACTIVE'
   where s.id = v_fin.shop_id;
  if v_agent is not null then
    select * into v_pledge from public.monvelo_pledges p
     where p.tenant_id = v_fin.tenant_id and p.agent_id = v_agent
       and p.area_id = v_fin.area_id and p.supply_date = v_fin.supply_date;
    if not found then
      v_agent := null;
    else
      select coalesce(sum(f.principal), 0) into v_claimed from public.monvelo_financings f
       where f.tenant_id = v_pledge.tenant_id and f.pledge_id = v_pledge.id and f.status = 'CLAIMED' and f.id <> v_fin.id;
      if v_pledge.remaining - v_claimed < v_fin.principal then
        v_agent := null;
      end if;
    end if;
  end if;

  update public.monvelo_financings
     set status = 'OFFERED', offered_at = now(), preferred_agent_id = v_agent,
         preferred_window_ends_at = case when v_agent is not null then
           now() + make_interval(mins => (select ps.preferred_window_minutes from public.monvelo_platform_settings ps))
         end
   where id = v_fin.id
  returning * into v_fin;
  return v_fin;
end;
$$;
revoke all on function public.monvelo_offer(uuid) from public, anon, authenticated, service_role;

-- A financing that ends before funding (CANCELLED here, EXPIRED in Task 8)
-- cancels its trade order while it is still PENDING, and releases its stock
-- (A6 §18.1). Returns the reservations released, or null when the order was no
-- longer PENDING and is left as it is.
create or replace function public.monvelo_cancel_trade_order(p_tenant_id uuid, p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
begin
  select o.status into v_status from public.orders o
   where o.tenant_id = p_tenant_id and o.id = p_order_id
     for update;
  if v_status is distinct from 'PENDING' then
    return null;
  end if;
  update public.orders set status = 'CANCELLED' where tenant_id = p_tenant_id and id = p_order_id;
  return public.stock_release_order(p_tenant_id, p_order_id, 'CANCELLED');
end;
$$;
revoke all on function public.monvelo_cancel_trade_order(uuid, uuid) from public, anon, authenticated, service_role;

-- ── request_monvelo_financing ───────────────────────────────────────────
create or replace function public.request_monvelo_financing(p_idempotency_key uuid, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me        public.tenant_users :=
    public.assert_tenant_role(array['ZSA', 'ASA', 'TM']::public.tenant_role_enum[]);
  v_prior     jsonb;
  v_settings  public.monvelo_tenant_settings;
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
                       'preferred_agent_id', v_fin.preferred_agent_id,
                       'lines', (select jsonb_agg(jsonb_build_object('brand', b, 'amount', a))
                                   from unnest(v_brands, v_amounts) as x (b, a))),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'financing_id', v_fin.id, 'reference', v_fin.reference, 'status', v_fin.status,
    'principal', v_fin.principal, 'approval_required', v_approval));
end;
$$;
revoke all on function public.request_monvelo_financing(uuid, uuid) from public, anon;
grant execute on function public.request_monvelo_financing(uuid, uuid) to authenticated;

-- ── approve_monvelo_financing: the territory's TM, above the limit ──────
create or replace function public.approve_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
    jsonb_build_object('status', v_fin.status, 'approved_by', v_fin.approved_by,
                       'preferred_agent_id', v_fin.preferred_agent_id),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('financing_id', v_fin.id, 'status', v_fin.status));
end;
$$;
revoke all on function public.approve_monvelo_financing(uuid, uuid) from public, anon;
grant execute on function public.approve_monvelo_financing(uuid, uuid) to authenticated;

-- ── cancel_monvelo_financing: the raiser or the territory's TM ──────────
create or replace function public.cancel_monvelo_financing(p_idempotency_key uuid, p_financing_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       public.tenant_users :=
    public.assert_tenant_role(array['ZSA', 'ASA', 'TM']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_fin      public.monvelo_financings;
  v_from     text;
  v_released integer;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'cancel_monvelo_financing',
    jsonb_build_object('financing_id', p_financing_id, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_fin from public.monvelo_financings f
   where f.tenant_id = v_me.tenant_id and f.id = p_financing_id
     for update;
  if not found then
    raise exception 'financing not found' using errcode = 'P0001';
  end if;
  if v_fin.raised_by is distinct from v_me.profile_id
     and not (v_me.role = 'TM' and v_me.territory_id is not distinct from v_fin.territory_id) then
    raise exception 'only the raiser or the territory''s TM cancels this financing' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' or char_length(btrim(p_reason)) > 500 then
    raise exception 'give a reason for the cancellation' using errcode = 'P0001';
  end if;
  if v_fin.status not in ('REQUESTED', 'AWAITING_APPROVAL', 'OFFERED') then
    raise exception 'this financing can no longer be cancelled' using errcode = 'P0001';
  end if;

  v_from := v_fin.status;
  update public.monvelo_financings
     set status = 'CANCELLED', cancelled_by = v_me.profile_id, cancelled_at = now(), cancel_reason = btrim(p_reason)
   where id = v_fin.id
  returning * into v_fin;
  -- the trade order goes with it (A6 §18.1)
  v_released := public.monvelo_cancel_trade_order(v_fin.tenant_id, v_fin.order_id);

  perform public.write_audit(v_me.tenant_id, 'cancel_monvelo_financing', 'monvelo_financings', v_fin.id::text,
    jsonb_build_object('status', v_from),
    jsonb_build_object('status', v_fin.status, 'reason', v_fin.cancel_reason, 'order_id', v_fin.order_id,
                       'order_cancelled', v_released is not null, 'reservations_released', v_released),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('financing_id', v_fin.id, 'status', v_fin.status));
end;
$$;
revoke all on function public.cancel_monvelo_financing(uuid, uuid, text) from public, anon;
grant execute on function public.cancel_monvelo_financing(uuid, uuid, text) to authenticated;

-- ── set_monvelo_tenant_settings: plus the credit and recovery rules ─────
-- Recreated from its live definition (20261029120300) with three trailing
-- parameters; null keeps the current value (or the column default on first set).
drop function public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric, numeric, uuid);
create or replace function public.set_monvelo_tenant_settings(
  p_idempotency_key uuid, p_enabled boolean, p_opening_limit numeric, p_approval_cap numeric,
  p_max_limit numeric default null, p_decision_id uuid default null,
  p_limit_growth_bps integer default null, p_default_cure_days integer default null,
  p_post_default_limit_bps integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.monvelo_tenant_settings;
  v_after  public.monvelo_tenant_settings;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_monvelo_tenant_settings',
    jsonb_build_object('enabled', p_enabled, 'opening_limit', p_opening_limit, 'approval_cap', p_approval_cap,
                       'max_limit', p_max_limit, 'decision_id', p_decision_id,
                       'limit_growth_bps', p_limit_growth_bps, 'default_cure_days', p_default_cure_days,
                       'post_default_limit_bps', p_post_default_limit_bps));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_me.role <> 'CLIENT_SERVICE_MANAGER' and public.monvelo_tenant_has_csm(v_me.tenant_id) then
    raise exception 'Monvelo settings are set by the client service manager' using errcode = '42501';
  end if;

  if p_enabled is null or p_opening_limit is null or p_approval_cap is null
     or p_opening_limit < 0 or p_approval_cap < 0 then
    raise exception 'enabled, a non-negative opening limit and a non-negative approval cap are required'
      using errcode = 'P0001';
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed these settings' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'MONVELO_SETTINGS');

  select * into v_before from public.monvelo_tenant_settings
   where tenant_id = v_me.tenant_id for update;

  insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap, max_limit, decision_id,
                                              limit_growth_bps, default_cure_days, post_default_limit_bps)
  values (v_me.tenant_id, p_enabled, p_opening_limit, p_approval_cap, p_max_limit, p_decision_id,
          coalesce(p_limit_growth_bps, v_before.limit_growth_bps, 0),
          coalesce(p_default_cure_days, v_before.default_cure_days, 0),
          coalesce(p_post_default_limit_bps, v_before.post_default_limit_bps, 10000))
  on conflict (tenant_id) do update
    set enabled = excluded.enabled,
        opening_limit = excluded.opening_limit,
        approval_cap = excluded.approval_cap,
        max_limit = excluded.max_limit,
        decision_id = excluded.decision_id,
        limit_growth_bps = excluded.limit_growth_bps,
        default_cure_days = excluded.default_cure_days,
        post_default_limit_bps = excluded.post_default_limit_bps
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_monvelo_tenant_settings', 'monvelo_tenant_settings',
                             v_me.tenant_id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_id', v_me.tenant_id, 'enabled', v_after.enabled));
end;
$$;
revoke all on function public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric, numeric, uuid, integer, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.set_monvelo_tenant_settings(uuid, boolean, numeric, numeric, numeric, uuid, integer, integer, integer)
  to authenticated, service_role;
