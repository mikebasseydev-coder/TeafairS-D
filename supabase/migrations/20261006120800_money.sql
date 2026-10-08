-- Spec A §6.7 — money and the liquidity engine.
-- Paystack is the exclusive collection engine and performs the partner split
-- natively via Subaccounts (decision 13); commission_records reconciles a
-- split that already happened.

-- ── fintech_partners ────────────────────────────────────────────────────
-- Third-party POS liquidity nodes. commission_bps is the single source of the
-- commission rate. A partner cannot be paid without a Paystack subaccount.
create table public.fintech_partners (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants (id) on delete restrict,
  business_name             text not null check (length(btrim(business_name)) > 0),
  pos_network               public.pos_network_enum not null,
  commission_bps            integer not null check (commission_bps between 0 and 10000),
  territory_id              uuid,
  contact_phone             text not null check (contact_phone ~ '^\+[1-9][0-9]{7,14}$'),
  paystack_subaccount_code  text not null check (paystack_subaccount_code ~ '^ACCT_[A-Za-z0-9]+$'),
  status                    text not null default 'PENDING'
                              check (status in ('PENDING', 'ACTIVE', 'SUSPENDED')),
  approved_by               uuid references public.profiles (id) on delete restrict,
  approved_at               timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, pos_network, business_name),
  constraint fintech_partners_active_is_approved
    check (status <> 'ACTIVE' or (approved_by is not null and approved_at is not null)),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.fintech_partners enable row level security;
create index idx_fintech_partners_territory on public.fintech_partners (tenant_id, territory_id);
create index idx_fintech_partners_approved_by on public.fintech_partners (approved_by);
create trigger fintech_partners_set_updated_at before update on public.fintech_partners
  for each row execute function public.set_updated_at();

create table public.fintech_terminals (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  partner_id    uuid not null,
  agent_id      uuid references public.profiles (id) on delete restrict,
  terminal_id   text not null check (length(btrim(terminal_id)) > 0),
  territory_id  uuid,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, terminal_id),
  foreign key (tenant_id, partner_id)   references public.fintech_partners (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.fintech_terminals enable row level security;
create index idx_fintech_terminals_partner on public.fintech_terminals (tenant_id, partner_id);
create index idx_fintech_terminals_agent on public.fintech_terminals (agent_id);
create index idx_fintech_terminals_territory on public.fintech_terminals (tenant_id, territory_id);
create trigger fintech_terminals_set_updated_at before update on public.fintech_terminals
  for each row execute function public.set_updated_at();

-- ── payments ────────────────────────────────────────────────────────────
-- Every row is a Paystack collection. Status is confirmed by the webhook fast
-- path or the reconcile-funds Verify-API sweep (§3.6), never by the client.
create table public.payments (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants (id) on delete restrict,
  order_id                  uuid not null,
  customer_id               uuid references public.profiles (id) on delete restrict,
  teafair_agent_id          uuid not null references public.profiles (id) on delete restrict,
  fintech_partner_id        uuid,
  fintech_terminal_id       uuid,
  amount                    numeric(15,2) not null check (amount > 0),
  gateway_provider          public.gateway_provider_enum not null default 'PAYSTACK',
  payment_status            public.payment_status_enum not null default 'INITIATED',
  paystack_reference        text not null check (length(btrim(paystack_reference)) > 0),
  otp_challenge_id          uuid references public.otp_challenges (id) on delete restrict,
  gateway_response_payload  jsonb,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, paystack_reference),
  foreign key (tenant_id, order_id)            references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, fintech_partner_id)  references public.fintech_partners (tenant_id, id) on delete restrict,
  foreign key (tenant_id, fintech_terminal_id) references public.fintech_terminals (tenant_id, id) on delete restrict
);
alter table public.payments enable row level security;
create index idx_payments_order on public.payments (tenant_id, order_id);
create index idx_payments_partner on public.payments (tenant_id, fintech_partner_id);
create index idx_payments_terminal on public.payments (tenant_id, fintech_terminal_id);
create index idx_payments_customer on public.payments (customer_id);
create index idx_payments_teafair_agent on public.payments (tenant_id, teafair_agent_id);
create index idx_payments_otp on public.payments (otp_challenge_id);
-- the reconcile-funds sweep: payments not yet confirmed (§3.6)
create index idx_payments_unconfirmed on public.payments (created_at)
  where payment_status in ('INITIATED', 'PROCESSING');
create trigger payments_set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

-- ── commission_records ──────────────────────────────────────────────────
-- SPLIT at collection; SETTLED once matched against Paystack's settlement
-- report; DISPUTED on mismatch. One split per payment.
create table public.commission_records (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants (id) on delete restrict,
  order_id                  uuid not null,
  payment_id                uuid not null,
  fintech_partner_id        uuid not null,
  teafair_agent_id          uuid not null references public.profiles (id) on delete restrict,
  amount                    numeric(15,2) not null check (amount >= 0),
  bps_applied               integer not null check (bps_applied between 0 and 10000),
  paystack_split_reference  text,
  paystack_subaccount_code  text not null check (paystack_subaccount_code ~ '^ACCT_[A-Za-z0-9]+$'),
  status                    public.commission_status_enum not null default 'SPLIT',
  settled_at                timestamptz,
  dispute_reason            text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (tenant_id, payment_id),
  constraint commission_records_settled_has_time
    check (status <> 'SETTLED' or settled_at is not null),
  constraint commission_records_disputed_has_reason
    check (status <> 'DISPUTED' or dispute_reason is not null),
  foreign key (tenant_id, order_id)           references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, payment_id)         references public.payments (tenant_id, id) on delete restrict,
  foreign key (tenant_id, fintech_partner_id) references public.fintech_partners (tenant_id, id) on delete restrict
);
alter table public.commission_records enable row level security;
create index idx_commission_records_order on public.commission_records (tenant_id, order_id);
create index idx_commission_records_partner on public.commission_records (tenant_id, fintech_partner_id, status);
create index idx_commission_records_teafair_agent on public.commission_records (tenant_id, teafair_agent_id);
create trigger commission_records_set_updated_at before update on public.commission_records
  for each row execute function public.set_updated_at();

-- ── fintech_advances ────────────────────────────────────────────────────
-- Short-term working-capital float extended through the POS network. The
-- settlement account is snapshotted at disbursement (§6.1, no bank_accounts).
create table public.fintech_advances (
  id                          uuid primary key default gen_random_uuid(),
  tenant_id                   uuid not null references public.tenants (id) on delete restrict,
  partner_id                  uuid,
  agent_id                    uuid not null references public.profiles (id) on delete restrict,
  requested_amount            numeric(15,2) not null check (requested_amount > 0),
  repayment_duration_days     integer not null check (repayment_duration_days between 1 and 30),
  status                      text not null default 'PENDING'
                                check (status in ('PENDING', 'APPROVED', 'DISBURSED',
                                                  'REPAID', 'DEFAULTED', 'REJECTED')),
  disbursed_to_bank_code      text,
  disbursed_to_account_last4  text check (disbursed_to_account_last4 ~ '^[0-9]{4}$'),
  disbursed_at                timestamptz,
  repaid_at                   timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint fintech_advances_disbursement_recorded
    check (status not in ('DISBURSED', 'REPAID', 'DEFAULTED')
           or (disbursed_at is not null and disbursed_to_account_last4 is not null)),
  constraint fintech_advances_repayment_recorded
    check (status <> 'REPAID' or repaid_at is not null),
  foreign key (tenant_id, partner_id) references public.fintech_partners (tenant_id, id) on delete restrict
);
alter table public.fintech_advances enable row level security;
create index idx_fintech_advances_agent on public.fintech_advances (tenant_id, agent_id, created_at desc);
create index idx_fintech_advances_partner on public.fintech_advances (tenant_id, partner_id);
create index idx_fintech_advances_status on public.fintech_advances (tenant_id, status);
create trigger fintech_advances_set_updated_at before update on public.fintech_advances
  for each row execute function public.set_updated_at();

-- ── cash_audit_batches ──────────────────────────────────────────────────
-- Physical cash declared against digital Paystack collections.
create table public.cash_audit_batches (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants (id) on delete restrict,
  agent_id                  uuid not null references public.profiles (id) on delete restrict,
  teller_receipt_number     text not null check (length(btrim(teller_receipt_number)) > 0),
  declared_cash_amount      numeric(15,2) not null check (declared_cash_amount >= 0),
  digital_collection_total  numeric(15,2) not null check (digital_collection_total >= 0),
  variance_reason           text,
  is_reconciled             boolean not null default false,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (tenant_id, teller_receipt_number)
);
alter table public.cash_audit_batches enable row level security;
create index idx_cash_audit_batches_agent on public.cash_audit_batches (tenant_id, agent_id, created_at desc);
create trigger cash_audit_batches_set_updated_at before update on public.cash_audit_batches
  for each row execute function public.set_updated_at();
