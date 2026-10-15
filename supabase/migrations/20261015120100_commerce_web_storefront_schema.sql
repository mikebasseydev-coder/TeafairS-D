-- Addendum A1 §3 — terminal venues, agent codes, web attribution on orders.

-- ── fintech_terminals: the venue a terminal sits in ─────────────────────
-- All-or-nothing: a venue is either fully described or absent. lga and
-- operating_hours are optional extras.
alter table public.fintech_terminals
  add column venue_channel    public.venue_channel_enum,
  add column venue_name       text check (venue_name is null or length(btrim(venue_name)) > 0),
  add column address_text     text check (address_text is null or length(btrim(address_text)) > 0),
  add column state            text check (state is null or length(btrim(state)) > 0),
  add column lga              text,
  add column location         extensions.geometry(Point, 4326),
  add column operating_hours  jsonb check (operating_hours is null or jsonb_typeof(operating_hours) = 'object'),
  add constraint fintech_terminals_venue_complete
    check (num_nulls(venue_channel, venue_name, address_text, state, location) in (0, 5));
create index idx_fintech_terminals_location on public.fintech_terminals using gist (location);

-- ── agent_codes (class A) ───────────────────────────────────────────────
-- The shareable link and the optional promo code are one thing (A1
-- decision 6). code is unique across tenants because the link alone must
-- resolve the tenant (decision 2). Membership and terminal ownership are
-- checked by upsert_agent_code, which is the only writer.
create table public.agent_codes (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  code             text not null unique check (code ~ '^[A-Z0-9][A-Z0-9-]{3,31}$'),
  agent_id         uuid not null references public.profiles (id) on delete restrict,
  terminal_id      uuid,
  discount_type    text check (discount_type in ('PERCENT', 'FIXED')),
  discount_value   numeric(15,2),
  max_redemptions  integer check (max_redemptions > 0),
  expires_at       timestamptz,
  is_active        boolean not null default true,
  created_by       uuid not null references public.profiles (id) on delete restrict,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, terminal_id) references public.fintech_terminals (tenant_id, id) on delete restrict,
  constraint agent_codes_discount_pair
    check ((discount_type is null) = (discount_value is null)),
  constraint agent_codes_percent_range
    check (discount_type is distinct from 'PERCENT' or (discount_value > 0 and discount_value <= 100)),
  constraint agent_codes_fixed_positive
    check (discount_type is distinct from 'FIXED' or discount_value > 0)
);
alter table public.agent_codes enable row level security;
create index idx_agent_codes_agent on public.agent_codes (tenant_id, agent_id);
create index idx_agent_codes_terminal on public.agent_codes (tenant_id, terminal_id);
create index idx_agent_codes_created_by on public.agent_codes (created_by);
create trigger agent_codes_set_updated_at before update on public.agent_codes
  for each row execute function public.set_updated_at();

create policy agent_codes_select_tenant_member on public.agent_codes
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── orders: attribution and web checkout ────────────────────────────────
-- attributed_* are snapshots taken at checkout, so history survives a code
-- being rebound or deactivated.
alter table public.orders
  add column agent_code_id           uuid,
  add column attributed_agent_id     uuid references public.profiles (id) on delete restrict,
  add column attributed_terminal_id  uuid,
  add column utm_source              text check (length(utm_source) <= 100),
  add column utm_medium              text check (length(utm_medium) <= 100),
  add column utm_campaign            text check (length(utm_campaign) <= 100),
  add column payment_route           text check (payment_route in ('PAYSTACK_WEB', 'POS_AGENT')),
  add column discount_amount         numeric(15,2) not null default 0 check (discount_amount >= 0),
  add column customer_email          text check (customer_email = lower(customer_email)),
  add column delivery_address        text check (delivery_address is null or length(btrim(delivery_address)) > 0),
  add column public_reference        text unique check (public_reference ~ '^TF-[0-9A-HJKMNP-TV-Z]{6}$'),
  add constraint orders_agent_code_fk
    foreign key (tenant_id, agent_code_id) references public.agent_codes (tenant_id, id) on delete restrict,
  add constraint orders_attributed_terminal_fk
    foreign key (tenant_id, attributed_terminal_id) references public.fintech_terminals (tenant_id, id) on delete restrict,
  add constraint orders_web_attribution_complete
    check (channel <> 'ONLINE' or agent_code_id is null
           or num_nulls(payment_route, attributed_agent_id, delivery_address, public_reference) = 0);
create index idx_orders_agent_code on public.orders (tenant_id, agent_code_id);
create index idx_orders_attributed_agent on public.orders (attributed_agent_id);
create index idx_orders_attributed_terminal on public.orders (tenant_id, attributed_terminal_id);
-- the place_web_order throttle: pending web orders per phone, last hour
create index idx_orders_web_pending_phone on public.orders (customer_phone, created_at)
  where channel = 'ONLINE' and status = 'PENDING';
