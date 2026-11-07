-- Addendum A8 §5: Monvelo cover. Goods in transit (the tenant's, GIT) and stock
-- in the shop (the funding agent's capital: the shop's own verified policy,
-- or an auto-policy whose premium comes out of the agent's rebate).
--
-- Schema only (plan Task 1). The RPCs that write these tables arrive in
-- 121800-122500. Every table here is SELECT-only for the API; writes come
-- from SECURITY DEFINER functions, and guard triggers hold each status
-- machine. A tenant never reads a row that names a lender (A6 §16.2.2).
--
-- Names follow A6 §15 (`monvelo_*`), statuses are text + CHECK (Spec A §9),
-- and UNVERIFIED is not stored: it is what a shop without a policy reports.

-- ── a generic status guard ─────────────────────────────────────────────
-- tg_argv[0]: allowed initial statuses, comma-separated
-- tg_argv[1]: allowed transitions, 'FROM>TO' comma-separated
-- tg_argv[2]: columns that may change on update besides status/updated_at
-- Every other column is fixed once written.
create or replace function public.monvelo_cover_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_init    text[] := string_to_array(tg_argv[0], ',');
  v_trans   text[] := string_to_array(tg_argv[1], ',');
  v_mutable text[] := string_to_array(tg_argv[2], ',') || array['status', 'updated_at'];
  v_new     jsonb  := to_jsonb(new);
  v_old     jsonb;
begin
  if tg_op = 'INSERT' then
    if not ((v_new ->> 'status') = any (v_init)) then
      raise exception '% rows are created %', tg_table_name, array_to_string(v_init, ' or ')
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  if (v_new - v_mutable) is distinct from (v_old - v_mutable) then
    raise exception '% fixed columns never change', tg_table_name using errcode = 'P0001';
  end if;
  if (v_new ->> 'status') is distinct from (v_old ->> 'status')
     and not ((v_old ->> 'status') || '>' || (v_new ->> 'status') = any (v_trans)) then
    raise exception '% cannot move from % to %', tg_table_name, v_old ->> 'status', v_new ->> 'status'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.monvelo_cover_guard() from public, anon, authenticated, service_role;

create or replace function public.monvelo_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '% rows never change', tg_table_name using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_insert_only() from public, anon, authenticated, service_role;

-- ── changes to existing tables ─────────────────────────────────────────
alter table public.monvelo_financings drop constraint monvelo_financings_status_check;
alter table public.monvelo_financings add constraint monvelo_financings_status_check check (status in (
  'REQUESTED', 'AWAITING_APPROVAL', 'OFFERED', 'HELD', 'CLAIMED', 'FUNDED', 'DELIVERED',
  'REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE', 'REPAID_LATE', 'EXPIRED',
  'CANCELLED', 'REFUND_DUE', 'CLOSED_BY_CLAIM'));
alter table public.monvelo_financings add constraint monvelo_financings_closed_by_claim
  check (status <> 'CLOSED_BY_CLAIM' or (outstanding = 0 and closed_at is not null));

-- Recreated from 20261031120800 (its latest body). A8 §5.6: a delivered or
-- defaulted financing may close by an insurance claim; CLOSED_BY_CLAIM is terminal.
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
    or (old.status = 'OFFERED' and new.status in ('HELD', 'CLAIMED', 'CANCELLED', 'EXPIRED', 'FUNDED'))
    or (old.status = 'HELD' and new.status in ('CLAIMED', 'OFFERED', 'CANCELLED', 'EXPIRED'))
    or (old.status = 'CLAIMED' and new.status in ('OFFERED', 'FUNDED'))
    or (old.status = 'FUNDED' and new.status in ('DELIVERED', 'REFUND_DUE'))
    or (old.status = 'DELIVERED' and new.status in ('REPAID_WITHIN_WINDOW', 'DEFAULTED_WITH_LATE_CHARGE',
                                                   'CLOSED_BY_CLAIM'))
    or (old.status = 'DEFAULTED_WITH_LATE_CHARGE' and new.status in ('REPAID_LATE', 'CLOSED_BY_CLAIM'))) then
    raise exception 'a financing cannot move from % to %', old.status, new.status using errcode = 'P0001';
  end if;
  return new;
end;
$$;

alter table public.monvelo_tenant_ledger_entries drop constraint monvelo_tenant_ledger_entries_entry_type_check;
alter table public.monvelo_tenant_ledger_entries add constraint monvelo_tenant_ledger_entries_entry_type_check
  check (entry_type in ('FUNDED_GROSS', 'REBATE', 'FEE', 'REFUND', 'REMITTANCE', 'GIT_PREMIUM'));

alter table public.monvelo_tenant_settings
  add column git_cover_enabled boolean not null default false;

-- A8 plan correction 1: the shop owner's consent to share a policy uses the
-- enrolment consent challenges, which already carry tenant, shop and area.
alter table public.monvelo_consent_challenges
  add column purpose text not null default 'ENROLMENT' check (purpose in ('ENROLMENT', 'SHOP_POLICY'));

alter table public.email_outbox drop constraint email_outbox_template_check;
alter table public.email_outbox add constraint email_outbox_template_check check (template in (
  'BUYER_TICKET_OPENED', 'BUYER_TICKET_REPLY', 'BUYER_TICKET_STATUS',
  'TENANT_TICKET_OPENED', 'TENANT_TICKET_REPLY', 'TENANT_TICKET_STATUS',
  'MONVELO_SHOP_COVER_EXPIRING'));
alter table public.email_outbox drop constraint email_outbox_source_table_check;
alter table public.email_outbox add constraint email_outbox_source_table_check check (source_table in (
  'support_tickets', 'tenant_support_tickets', 'monvelo_shop_policies'));

alter table public.monvelo_flags drop constraint monvelo_flags_kind_check;
alter table public.monvelo_flags add constraint monvelo_flags_kind_check
  check (kind in ('PAYER_MISMATCH', 'LATE_PAYMENT', 'AMOUNT_MISMATCH', 'REPAYMENT_REJECTED', 'REPAYMENT_UNCONFIRMED',
                  'FUNDING_REFUNDED',
                  'DECLARATION_FAILED', 'DECLARATION_STALE', 'DECLARATION_REJECTED', 'CLAIM_SHORTFALL',
                  'CLAIM_SETTLED_AFTER_CLOSE', 'POLICY_WITHDRAWN_OPEN_FINANCING', 'PREMIUM_RECOVERY'));

-- ── insurers and their products (platform-level) ────────────────────────
create table public.monvelo_insurers (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique check (code ~ '^[A-Z0-9_]{2,32}$'),
  legal_name         text not null check (length(btrim(legal_name)) > 0),
  naicom_licence_no  text not null check (length(btrim(naicom_licence_no)) > 0),
  api_provider       text not null check (api_provider in ('MOCK', 'MYCOVER', 'MANUAL')),
  status             text not null default 'ACTIVE' check (status in ('ACTIVE', 'SUSPENDED')),
  created_by         uuid not null references public.profiles (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.monvelo_insurance_products (
  id                   uuid primary key default gen_random_uuid(),
  insurer_id           uuid not null references public.monvelo_insurers (id) on delete restrict,
  kind                 text not null check (kind in ('GIT', 'STORAGE')),
  -- GIT: per shipment. STORAGE: per 30-day block. The market ranges (A8 §2)
  -- are not limits: the insurer's approved quote is what applies.
  rate_bps             integer not null check (rate_bps between 1 and 1000),
  -- the disclosed share of the premium the insurer pays Monvelo; never deducted by Monvelo
  facilitator_fee_bps  integer not null check (facilitator_fee_bps between 0 and 10000),
  valid_from           date not null,
  valid_to             date,
  status               text not null default 'PROPOSED' check (status in ('PROPOSED', 'APPROVED', 'WITHDRAWN')),
  proposed_by          uuid not null references public.profiles (id) on delete restrict,
  approved_by          uuid references public.profiles (id) on delete restrict,
  approved_at          timestamptz,
  withdrawn_by         uuid references public.profiles (id) on delete restrict,
  withdrawn_at         timestamptz,
  withdraw_reason      text check (char_length(withdraw_reason) <= 1000),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  check ((approved_by is null) = (approved_at is null)),
  check (approved_by is null or approved_by <> proposed_by),
  check (status = 'PROPOSED' or status = 'WITHDRAWN' or approved_by is not null),
  check ((status = 'WITHDRAWN') = (withdrawn_at is not null))
);
create index idx_monvelo_insurance_products_insurer on public.monvelo_insurance_products (insurer_id);
create index idx_monvelo_insurance_products_live on public.monvelo_insurance_products (kind, valid_from)
  where status = 'APPROVED';

-- ── a shop's own policy (platform-level: retail_shops is the shared registry) ──
create table public.monvelo_shop_policies (
  id                        uuid primary key default gen_random_uuid(),
  shop_id                   uuid not null references public.retail_shops (id) on delete restrict,
  insurer_name              text not null check (length(btrim(insurer_name)) > 0),
  policy_number             text not null check (length(btrim(policy_number)) between 1 and 64),
  covers_fire_perils        boolean not null,
  covers_burglary           boolean not null,
  sum_insured               numeric(15,2) not null check (sum_insured > 0),
  -- A8 §5.2.1: an interested-party / loss-payee endorsement in favour of
  -- "lenders financing stock through Monvelo"; without it the policy never exempts
  lender_interest_endorsed  boolean not null,
  starts_on                 date not null,
  expires_on                date not null,
  document_path             text not null,
  status                    text not null default 'PENDING'
                              check (status in ('PENDING', 'VERIFIED', 'REJECTED', 'EXPIRED', 'WITHDRAWN')),
  submitted_by              uuid not null references public.profiles (id) on delete restrict,
  consent_challenge_id      uuid not null references public.monvelo_consent_challenges (id) on delete restrict,
  reviewed_by               uuid references public.profiles (id) on delete restrict,
  reviewed_at               timestamptz,
  review_note               text check (char_length(review_note) <= 1000),
  withdrawn_at              timestamptz,
  withdraw_reason           text check (char_length(withdraw_reason) <= 1000),
  expiry_notice_sent_at     timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  check (expires_on > starts_on),
  check (document_path like shop_id::text || '/%'),
  check ((reviewed_by is null) = (reviewed_at is null)),
  check (reviewed_by is null or reviewed_by <> submitted_by),
  check (status = 'PENDING' or reviewed_by is not null),
  check (status in ('PENDING', 'REJECTED') or (covers_fire_perils and covers_burglary and lender_interest_endorsed)),
  check ((status = 'WITHDRAWN') = (withdrawn_at is not null))
);
create index idx_monvelo_shop_policies_shop on public.monvelo_shop_policies (shop_id, status);
create index idx_monvelo_shop_policies_challenge on public.monvelo_shop_policies (consent_challenge_id);
create index idx_monvelo_shop_policies_expiry on public.monvelo_shop_policies (expires_on) where status = 'VERIFIED';
-- one live row per real policy; an expired, withdrawn or rejected one does not block a resubmission
create unique index monvelo_shop_policies_live_number
  on public.monvelo_shop_policies (lower(btrim(insurer_name)), policy_number) where status in ('PENDING', 'VERIFIED');

-- ── the cover locked into a financing at claim ───────────────────────────
create table public.monvelo_financing_cover (
  financing_id      uuid primary key,
  tenant_id         uuid not null references public.tenants (id) on delete restrict,
  cover_kind        text not null check (cover_kind in ('SHOP_POLICY', 'AUTO_POLICY', 'NONE')),
  shop_policy_id    uuid references public.monvelo_shop_policies (id) on delete restrict,
  product_id        uuid references public.monvelo_insurance_products (id) on delete restrict,
  storage_rate_bps  integer not null default 0 check (storage_rate_bps between 0 and 1000),
  blocks            integer not null check (blocks >= 1),
  storage_premium   numeric(15,2) not null check (storage_premium >= 0),
  gross_rebate      numeric(15,2) not null check (gross_rebate >= 0),
  net_rebate        numeric(15,2) not null check (net_rebate >= 0),
  declared_status   text not null default 'NOT_DUE'
                      check (declared_status in ('NOT_DUE', 'PENDING', 'ACCEPTED', 'REJECTED', 'CANCELLED')),
  locked_at         timestamptz not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, financing_id),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  check ((cover_kind = 'SHOP_POLICY') = (shop_policy_id is not null)),
  check ((cover_kind = 'AUTO_POLICY') = (product_id is not null)),
  check (cover_kind = 'AUTO_POLICY' or (storage_rate_bps = 0 and storage_premium = 0)),
  check (net_rebate = gross_rebate - storage_premium),
  check (cover_kind = 'AUTO_POLICY' or declared_status = 'NOT_DUE')
);
create index idx_monvelo_financing_cover_policy on public.monvelo_financing_cover (shop_policy_id);
create index idx_monvelo_financing_cover_product on public.monvelo_financing_cover (product_id);

-- per brand: the terms the claim locked, and the rebate split (A8 §5.3; Task 3
-- copies the terms onto monvelo_financing_lines at funding)
create table public.monvelo_financing_line_cover (
  financing_id        uuid not null references public.monvelo_financing_cover (financing_id) on delete restrict,
  brand_key           text not null,
  tenant_id           uuid not null references public.tenants (id) on delete restrict,
  terms_id            uuid,
  rebate_bps          integer not null check (rebate_bps between 0 and 10000),
  interest_free_days  integer not null check (interest_free_days >= 1),
  late_charge_bps     integer not null check (late_charge_bps between 0 and 10000),
  gross_rebate        numeric(15,2) not null check (gross_rebate >= 0),
  storage_premium     numeric(15,2) not null check (storage_premium >= 0),
  net_rebate          numeric(15,2) not null check (net_rebate >= 0),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  primary key (financing_id, brand_key),
  foreign key (financing_id, brand_key) references public.monvelo_financing_lines (financing_id, brand_key)
    on delete restrict,
  foreign key (tenant_id, terms_id) references public.monvelo_brand_terms (tenant_id, id) on delete restrict,
  check (net_rebate = gross_rebate - storage_premium)
);
create index idx_monvelo_financing_line_cover_terms on public.monvelo_financing_line_cover (tenant_id, terms_id);

-- the cover is quoted again only while the financing is still being claimed
create or replace function public.monvelo_financing_cover_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
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
    if tg_table_name = 'monvelo_financing_cover' and new.declared_status <> 'NOT_DUE' then
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
$$;
revoke all on function public.monvelo_financing_cover_guard() from public, anon, authenticated, service_role;

-- ── GIT cover per financed order (the tenant's) ─────────────────────────
create table public.monvelo_order_git_cover (
  order_id         uuid primary key,
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  financing_id     uuid not null unique,
  product_id       uuid not null references public.monvelo_insurance_products (id) on delete restrict,
  rate_bps         integer not null check (rate_bps between 1 and 1000),
  insured_value    numeric(15,2) not null check (insured_value > 0),
  premium          numeric(15,2) not null check (premium > 0),
  declared_status  text not null default 'PENDING' check (declared_status in ('PENDING', 'ACCEPTED', 'REJECTED')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (tenant_id, order_id),
  foreign key (tenant_id, order_id) references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict
);
create index idx_monvelo_order_git_cover_tenant on public.monvelo_order_git_cover (tenant_id, financing_id);
create index idx_monvelo_order_git_cover_product on public.monvelo_order_git_cover (product_id);

-- ── premium payables (to the insurer) and rebate top-ups (to the agent) ──
create table public.monvelo_premium_payables (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  kind            text not null check (kind in ('STORAGE', 'GIT')),
  financing_id    uuid not null,
  insurer_id      uuid not null references public.monvelo_insurers (id) on delete restrict,
  amount          numeric(15,2) not null check (amount > 0),
  due_at          timestamptz not null,
  status          text not null default 'DUE' check (status in ('DUE', 'PAID', 'CANCELLED')),
  paid_reference  text check (length(btrim(paid_reference)) between 1 and 128),
  paid_by         uuid references public.profiles (id) on delete restrict,
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (financing_id, kind),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  check ((status = 'PAID') = (paid_reference is not null and paid_by is not null and paid_at is not null))
);
create index idx_monvelo_premium_payables_due on public.monvelo_premium_payables (status, due_at);
create index idx_monvelo_premium_payables_insurer on public.monvelo_premium_payables (insurer_id);
create index idx_monvelo_premium_payables_tenant on public.monvelo_premium_payables (tenant_id, financing_id);

create table public.monvelo_rebate_topups (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  financing_id    uuid not null,
  agent_id        uuid not null references public.monvelo_agents (id) on delete restrict,
  amount          numeric(15,2) not null check (amount > 0),
  reason          text not null check (reason in ('DECLARATION_REJECTED')),
  due_at          timestamptz not null,
  status          text not null default 'DUE' check (status in ('DUE', 'PAID', 'CANCELLED')),
  paid_reference  text check (length(btrim(paid_reference)) between 1 and 128),
  paid_by         uuid references public.profiles (id) on delete restrict,
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (financing_id, reason),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  check ((status = 'PAID') = (paid_reference is not null and paid_by is not null and paid_at is not null))
);
create index idx_monvelo_rebate_topups_agent on public.monvelo_rebate_topups (agent_id, status);
create index idx_monvelo_rebate_topups_tenant on public.monvelo_rebate_topups (tenant_id, financing_id);

-- ── loss claims ─────────────────────────────────────────────────────────
create table public.monvelo_insurance_claims (
  id                       uuid primary key default gen_random_uuid(),
  reference                text not null unique check (reference ~ '^IC-[A-Z2-7]{8}$'),
  tenant_id                uuid not null references public.tenants (id) on delete restrict,
  kind                     text not null check (kind in ('GIT', 'STORAGE')),
  financing_id             uuid not null,
  -- null for a claim on the shop's own policy (filed by hand with the shop's insurer)
  insurer_id               uuid references public.monvelo_insurers (id) on delete restrict,
  peril                    text not null check (peril in ('FIRE', 'SPECIAL_PERILS', 'BURGLARY', 'THEFT_IN_TRANSIT',
                                                          'ACCIDENT_IN_TRANSIT', 'OTHER')),
  incident_at              timestamptz not null,
  description              text check (char_length(description) <= 2000),
  evidence_paths           text[] not null default '{}',
  reported_by              uuid not null references public.profiles (id) on delete restrict,
  payee_kind               text not null check (payee_kind in ('AGENT', 'TENANT')),
  payee_agent_id           uuid references public.monvelo_agents (id) on delete restrict,
  status                   text not null default 'REPORTED'
                             check (status in ('REPORTED', 'FILED', 'UNDER_REVIEW', 'SETTLED', 'REJECTED', 'WITHDRAWN')),
  insurer_claim_reference  text check (length(btrim(insurer_claim_reference)) between 1 and 128),
  claimed_amount           numeric(15,2) not null check (claimed_amount > 0),
  settled_amount           numeric(15,2) check (settled_amount >= 0),
  shortfall                numeric(15,2) generated always as (
                             case when status = 'SETTLED' then greatest(claimed_amount - settled_amount, 0) end) stored,
  late_charge_waived       numeric(15,2) check (late_charge_waived >= 0),
  payout_reference         text check (length(btrim(payout_reference)) between 1 and 128),
  filed_by                 uuid references public.profiles (id) on delete restrict,
  filed_at                 timestamptz,
  settled_at               timestamptz,
  closed_reason            text check (char_length(closed_reason) <= 1000),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict,
  check ((kind = 'STORAGE' and payee_kind = 'AGENT') or (kind = 'GIT' and payee_kind = 'TENANT')),
  check ((payee_kind = 'AGENT') = (payee_agent_id is not null)),
  check ((status = 'SETTLED') = (settled_amount is not null and settled_at is not null)),
  check (status in ('REPORTED', 'WITHDRAWN') or filed_at is not null)
);
create unique index monvelo_insurance_claims_one_open
  on public.monvelo_insurance_claims (financing_id, kind) where status in ('REPORTED', 'FILED', 'UNDER_REVIEW');
create index idx_monvelo_insurance_claims_tenant on public.monvelo_insurance_claims (tenant_id, kind, status);
create index idx_monvelo_insurance_claims_agent on public.monvelo_insurance_claims (payee_agent_id);
create index idx_monvelo_insurance_claims_insurer on public.monvelo_insurance_claims (insurer_id, insurer_claim_reference);

-- ── the declarations outbox and insurer events (no API reader) ──────────
create table public.monvelo_insurance_declarations (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete restrict,
  kind               text not null check (kind in ('GIT_DECLARE', 'STORAGE_DECLARE', 'STORAGE_CANCEL', 'CLAIM_FILE')),
  insurer_id         uuid not null references public.monvelo_insurers (id) on delete restrict,
  subject_table      text not null check (subject_table in ('monvelo_order_git_cover', 'monvelo_financing_cover',
                                                            'monvelo_insurance_claims')),
  subject_id         uuid not null,
  -- built by the database at enqueue time: references, amounts and dates; never a name, phone or address
  payload            jsonb not null,
  status             text not null default 'PENDING'
                       check (status in ('PENDING', 'SENDING', 'ACCEPTED', 'REJECTED', 'FAILED')),
  attempts           integer not null default 0 check (attempts >= 0),
  next_attempt_at    timestamptz not null default now(),
  insurer_reference  text check (length(btrim(insurer_reference)) between 1 and 128),
  last_error         text check (char_length(last_error) <= 2000),
  completed_at       timestamptz,
  -- clock time, so rows written in one transaction keep their order (as email_outbox)
  created_at         timestamptz not null default clock_timestamp(),
  updated_at         timestamptz not null default now(),
  check ((status in ('ACCEPTED', 'REJECTED', 'FAILED')) = (completed_at is not null))
);
create index idx_monvelo_insurance_declarations_due on public.monvelo_insurance_declarations (status, next_attempt_at);
create index idx_monvelo_insurance_declarations_subject
  on public.monvelo_insurance_declarations (subject_table, subject_id);
create index idx_monvelo_insurance_declarations_insurer on public.monvelo_insurance_declarations (insurer_id);
create index idx_monvelo_insurance_declarations_tenant on public.monvelo_insurance_declarations (tenant_id);

create table public.monvelo_insurer_events (
  insurer_id   uuid not null references public.monvelo_insurers (id) on delete restrict,
  event_id     text not null check (length(event_id) between 1 and 200),
  payload      jsonb not null,
  received_at  timestamptz not null default now(),
  primary key (insurer_id, event_id)
);

-- ── triggers: updated_at, status machines, never deleted ────────────────
create trigger monvelo_insurers_set_updated_at before update on public.monvelo_insurers
  for each row execute function public.set_updated_at();
create trigger monvelo_insurers_guard before insert or update on public.monvelo_insurers
  for each row execute function public.monvelo_cover_guard('ACTIVE', 'ACTIVE>SUSPENDED,SUSPENDED>ACTIVE', '');

create trigger monvelo_insurance_products_set_updated_at before update on public.monvelo_insurance_products
  for each row execute function public.set_updated_at();
create trigger monvelo_insurance_products_guard before insert or update on public.monvelo_insurance_products
  for each row execute function public.monvelo_cover_guard('PROPOSED',
    'PROPOSED>APPROVED,PROPOSED>WITHDRAWN,APPROVED>WITHDRAWN',
    'approved_by,approved_at,withdrawn_by,withdrawn_at,withdraw_reason');

create trigger monvelo_shop_policies_set_updated_at before update on public.monvelo_shop_policies
  for each row execute function public.set_updated_at();
create trigger monvelo_shop_policies_guard before insert or update on public.monvelo_shop_policies
  for each row execute function public.monvelo_cover_guard('PENDING',
    'PENDING>VERIFIED,PENDING>REJECTED,VERIFIED>EXPIRED,VERIFIED>WITHDRAWN',
    'reviewed_by,reviewed_at,review_note,withdrawn_at,withdraw_reason,expiry_notice_sent_at');

create trigger monvelo_financing_cover_set_updated_at before update on public.monvelo_financing_cover
  for each row execute function public.set_updated_at();
create trigger monvelo_financing_cover_guard before insert or update on public.monvelo_financing_cover
  for each row execute function public.monvelo_financing_cover_guard();
create trigger monvelo_financing_line_cover_set_updated_at before update on public.monvelo_financing_line_cover
  for each row execute function public.set_updated_at();
create trigger monvelo_financing_line_cover_guard before insert or update on public.monvelo_financing_line_cover
  for each row execute function public.monvelo_financing_cover_guard();

-- GIT cover reuses the generic guard on its declaration status
create or replace function public.monvelo_git_cover_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.declared_status <> 'PENDING' then
      raise exception 'a GIT cover is created PENDING' using errcode = 'P0001';
    end if;
    return new;
  end if;
  if (to_jsonb(new) - array['declared_status', 'updated_at']) is distinct from
     (to_jsonb(old) - array['declared_status', 'updated_at']) then
    raise exception 'a GIT cover''s fixed columns never change' using errcode = 'P0001';
  end if;
  if new.declared_status <> old.declared_status and old.declared_status <> 'PENDING' then
    raise exception 'a GIT cover''s declaration cannot move from % to %', old.declared_status, new.declared_status
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.monvelo_git_cover_guard() from public, anon, authenticated, service_role;
create trigger monvelo_order_git_cover_set_updated_at before update on public.monvelo_order_git_cover
  for each row execute function public.set_updated_at();
create trigger monvelo_order_git_cover_guard before insert or update on public.monvelo_order_git_cover
  for each row execute function public.monvelo_git_cover_guard();

create trigger monvelo_premium_payables_set_updated_at before update on public.monvelo_premium_payables
  for each row execute function public.set_updated_at();
create trigger monvelo_premium_payables_guard before insert or update on public.monvelo_premium_payables
  for each row execute function public.monvelo_cover_guard('DUE', 'DUE>PAID,DUE>CANCELLED',
    'paid_reference,paid_by,paid_at');

create trigger monvelo_rebate_topups_set_updated_at before update on public.monvelo_rebate_topups
  for each row execute function public.set_updated_at();
create trigger monvelo_rebate_topups_guard before insert or update on public.monvelo_rebate_topups
  for each row execute function public.monvelo_cover_guard('DUE', 'DUE>PAID,DUE>CANCELLED',
    'paid_reference,paid_by,paid_at');

create trigger monvelo_insurance_claims_set_updated_at before update on public.monvelo_insurance_claims
  for each row execute function public.set_updated_at();
create trigger monvelo_insurance_claims_guard before insert or update on public.monvelo_insurance_claims
  for each row execute function public.monvelo_cover_guard('REPORTED',
    'REPORTED>FILED,REPORTED>WITHDRAWN,FILED>UNDER_REVIEW,FILED>SETTLED,FILED>REJECTED,FILED>WITHDRAWN,'
    'UNDER_REVIEW>SETTLED,UNDER_REVIEW>REJECTED,UNDER_REVIEW>WITHDRAWN',
    'insurer_claim_reference,settled_amount,shortfall,late_charge_waived,payout_reference,filed_by,filed_at,'
    'settled_at,closed_reason');

create trigger monvelo_insurance_declarations_set_updated_at before update on public.monvelo_insurance_declarations
  for each row execute function public.set_updated_at();
create trigger monvelo_insurance_declarations_guard before insert or update on public.monvelo_insurance_declarations
  for each row execute function public.monvelo_cover_guard('PENDING',
    'PENDING>SENDING,SENDING>PENDING,SENDING>SENDING,SENDING>ACCEPTED,SENDING>REJECTED,SENDING>FAILED,'
    'PENDING>ACCEPTED,PENDING>REJECTED,PENDING>FAILED',
    'attempts,next_attempt_at,insurer_reference,last_error,completed_at');

create trigger monvelo_insurer_events_insert_only before update on public.monvelo_insurer_events
  for each row execute function public.monvelo_insert_only();

do $$
declare t text;
begin
  foreach t in array array['monvelo_insurers', 'monvelo_insurance_products', 'monvelo_shop_policies',
    'monvelo_financing_cover', 'monvelo_financing_line_cover', 'monvelo_order_git_cover', 'monvelo_premium_payables',
    'monvelo_rebate_topups', 'monvelo_insurance_claims', 'monvelo_insurance_declarations', 'monvelo_insurer_events']
  loop
    execute format('create trigger %1$s_no_delete before delete on public.%1$s
                      for each row execute function public.monvelo_no_delete()', t);
    execute format('create trigger %1$s_no_truncate before truncate on public.%1$s
                      for each statement execute function public.monvelo_no_delete()', t);
    execute format('alter table public.%s enable row level security', t);
    execute format('revoke all on public.%s from anon, authenticated, service_role', t);
  end loop;
end;
$$;

-- ── read rules (FOR SELECT only) ─────────────────────────────────────────
-- The shops whose policies the caller may read as a field agent: an ACTIVE ZSA
-- of the enrolment area's zone, or an ACTIVE ASA of that area, in any tenant
-- where the shop is ACTIVE-ly enrolled. A policy is the shop's, not a tenant's,
-- so no tenant role reads it (A8 §5.2).
create or replace function public.my_monvelo_policy_shop_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select distinct e.shop_id
    from public.monvelo_shop_enrolments e
    join public.areas a on a.tenant_id = e.tenant_id and a.id = e.area_id
    join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
    join public.tenant_users tu on tu.tenant_id = e.tenant_id
   where e.status = 'ACTIVE'
     and tu.profile_id = (select auth.uid())
     and tu.status = 'ACTIVE'
     and ((tu.role = 'ASA' and tu.area_id = e.area_id) or (tu.role = 'ZSA' and tu.zone_id = t.zone_id));
$$;
revoke all on function public.my_monvelo_policy_shop_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_monvelo_policy_shop_ids() to authenticated;

grant select on public.monvelo_insurers, public.monvelo_insurance_products, public.monvelo_shop_policies,
  public.monvelo_financing_cover, public.monvelo_financing_line_cover, public.monvelo_order_git_cover,
  public.monvelo_premium_payables, public.monvelo_rebate_topups, public.monvelo_insurance_claims
  to authenticated;
-- monvelo_insurance_declarations and monvelo_insurer_events: RLS on, no policy, no grant.

create policy monvelo_insurers_select on public.monvelo_insurers for select to authenticated
  using ((select public.is_monvelo_staff()));
create policy monvelo_insurance_products_select on public.monvelo_insurance_products for select to authenticated
  using ((select public.is_monvelo_staff()));
create policy monvelo_shop_policies_select on public.monvelo_shop_policies for select to authenticated
  using ((select public.is_monvelo_staff()) or shop_id in (select public.my_monvelo_policy_shop_ids()));
-- lender-bearing rows: Monvelo staff only (agents read their cover through Task 3's read model)
create policy monvelo_financing_cover_select on public.monvelo_financing_cover for select to authenticated
  using ((select public.is_monvelo_staff()));
create policy monvelo_financing_line_cover_select on public.monvelo_financing_line_cover for select to authenticated
  using ((select public.is_monvelo_staff()));
create policy monvelo_premium_payables_select on public.monvelo_premium_payables for select to authenticated
  using ((select public.is_monvelo_staff()));
-- a top-up is owed to the agent: its members read it, as they read their rebate payables
create policy monvelo_rebate_topups_select on public.monvelo_rebate_topups for select to authenticated
  using (agent_id in (select public.my_monvelo_agent_ids()) or (select public.is_monvelo_staff()));
-- GIT is the tenant's own cover: its CSM, TENANT_ADMIN and LOGISTICS_MANAGER read it
create policy monvelo_order_git_cover_select on public.monvelo_order_git_cover for select to authenticated
  using ((select public.is_monvelo_staff())
         or tenant_id in (select public.my_tenant_ids_with_role(
              array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[])));
-- a STORAGE claim names the lender (payee): Monvelo staff only. A GIT claim pays
-- the tenant and carries no agent (CHECK), so the tenant's roles read it whole.
create policy monvelo_insurance_claims_select on public.monvelo_insurance_claims for select to authenticated
  using ((select public.is_monvelo_staff())
         or (kind = 'GIT' and tenant_id in (select public.my_tenant_ids_with_role(
              array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]))));

-- ── private buckets (as 20261029120250) ──────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('monvelo-shop-policies', 'monvelo-shop-policies', false, 10485760,
   array['application/pdf', 'image/jpeg', 'image/png']),
  ('monvelo-claim-evidence', 'monvelo-claim-evidence', false, 10485760,
   array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;
update storage.buckets
   set public = false, file_size_limit = 10485760,
       allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png']
 where id in ('monvelo-shop-policies', 'monvelo-claim-evidence');
-- No storage.objects policy: Task 9's upload gateway signs uploads, and reads go through signed URLs.
