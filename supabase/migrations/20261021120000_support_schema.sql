-- Addendum A3 §3 — web chat and ticketing: tickets (headers, no personal
-- data), the hashed ticket secret, restricted buyer contacts and messages.
-- Staff read through RLS and Realtime; every write is a later RPC.

-- ── shared reference generator (extracted from place_web_order) ─────────
-- p_prefix || '-' || 6 Crockford base-32 characters. 256 is a multiple of
-- 32, so every character is uniform. Uniqueness is the caller's concern.
create or replace function public.new_crockford_reference(p_prefix text)
returns text
language sql
volatile
set search_path = public, pg_temp
as $$
  select p_prefix || '-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                                                       1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
                               from generate_series(1, 6));
$$;
revoke all on function public.new_crockford_reference(text) from public, anon, authenticated, service_role;

-- ── support_tickets ─────────────────────────────────────────────────────
create table public.support_tickets (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants (id) on delete restrict,
  public_reference  text not null unique check (public_reference ~ '^TK-[0-9A-HJKMNP-TV-Z]{6}$'),
  kind              text not null check (kind in ('ORDER', 'PRE_PURCHASE', 'SYSTEM')),
  category          text not null check (category in ('PAYMENT', 'DELIVERY', 'ORDER_CHANGE', 'PRODUCT', 'OTHER', 'SYSTEM')),
  order_id          uuid,
  territory_id      uuid,
  accountable_id    uuid references public.profiles (id) on delete restrict,
  assigned_to       uuid references public.profiles (id) on delete restrict,
  status            text not null default 'OPEN' check (status in ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED')),
  priority          text not null default 'MEDIUM' check (priority in ('LOW', 'MEDIUM', 'HIGH', 'URGENT')),
  -- one live (non-CLOSED) ticket per key for SYSTEM tickets: see
  -- support_tickets_open_system_key below
  system_key        text,
  -- the CLOSED ticket this one follows up (a repeat system fact, or a buyer's
  -- new ORDER ticket); its handler may read that history
  previous_ticket_id uuid,
  last_message_at   timestamptz not null default now(),
  resolved_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, order_id)     references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict,
  foreign key (tenant_id, previous_ticket_id) references public.support_tickets (tenant_id, id) on delete restrict,
  check (previous_ticket_id <> id),
  check (kind <> 'ORDER' or order_id is not null),
  check ((kind = 'SYSTEM') = (system_key is not null)),
  check (status <> 'RESOLVED' or resolved_at is not null)
);
alter table public.support_tickets enable row level security;
create index idx_support_tickets_inbox       on public.support_tickets (tenant_id, status, last_message_at desc);
create index idx_support_tickets_accountable on public.support_tickets (accountable_id);
create index idx_support_tickets_assigned    on public.support_tickets (assigned_to);
create index idx_support_tickets_order       on public.support_tickets (tenant_id, order_id, status);
create index idx_support_tickets_territory   on public.support_tickets (tenant_id, territory_id);
create index idx_support_tickets_previous    on public.support_tickets (tenant_id, previous_ticket_id);
-- a CLOSED ticket frees its key: a repeat fact then opens a new, linked ticket
create unique index support_tickets_open_system_key on public.support_tickets (system_key)
  where status <> 'CLOSED';
create trigger support_tickets_set_updated_at before update on public.support_tickets
  for each row execute function public.set_updated_at();

-- ── support_ticket_secrets: sha256(secret), no policy, no grant ─────────
create table public.support_ticket_secrets (
  ticket_id    uuid primary key,
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  secret_hash  text not null check (secret_hash ~ '^[0-9a-f]{64}$'),
  created_at   timestamptz not null default now(),
  foreign key (tenant_id, ticket_id) references public.support_tickets (tenant_id, id) on delete restrict
);
alter table public.support_ticket_secrets enable row level security;
-- default privileges grant SELECT on new tables to authenticated; withdraw it
revoke all on public.support_ticket_secrets from anon, authenticated, service_role;
create index idx_support_ticket_secrets_tenant on public.support_ticket_secrets (tenant_id, ticket_id);

-- ── support_ticket_contacts (restricted) ────────────────────────────────
create table public.support_ticket_contacts (
  ticket_id       uuid primary key,
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  -- copy of the ticket's territory, for RLS (A2 pattern)
  territory_id    uuid,
  customer_name   text check (customer_name is null or length(btrim(customer_name)) > 0),
  customer_phone  text check (customer_phone ~ '^\+[1-9][0-9]{7,14}$'),
  customer_email  text check (customer_email = lower(customer_email)),
  redacted_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (tenant_id, ticket_id)    references public.support_tickets (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.support_ticket_contacts enable row level security;
create index idx_support_ticket_contacts_tenant    on public.support_ticket_contacts (tenant_id, ticket_id);
create index idx_support_ticket_contacts_territory on public.support_ticket_contacts (tenant_id, territory_id);
-- the open-ticket throttle: tickets per phone, recent window
create index idx_support_ticket_contacts_phone     on public.support_ticket_contacts (customer_phone, created_at);
create trigger support_ticket_contacts_set_updated_at before update on public.support_ticket_contacts
  for each row execute function public.set_updated_at();

-- ── support_messages (restricted, append-only bar redaction) ────────────
create table public.support_messages (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  ticket_id     uuid not null,
  sender_type   text not null check (sender_type in ('CUSTOMER', 'STAFF', 'SYSTEM')),
  sender_id     uuid references public.profiles (id) on delete restrict,
  -- copy of the ticket's territory, for RLS
  territory_id  uuid,
  body          text not null check (length(btrim(body)) between 1 and 2000),
  redacted_at   timestamptz,
  created_at    timestamptz not null default now(),
  foreign key (tenant_id, ticket_id)    references public.support_tickets (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict,
  check ((sender_type = 'STAFF') = (sender_id is not null))
);
alter table public.support_messages enable row level security;
create index idx_support_messages_thread    on public.support_messages (ticket_id, created_at, id);
create index idx_support_messages_sender    on public.support_messages (ticket_id, sender_type, created_at);
create index idx_support_messages_tenant    on public.support_messages (tenant_id, ticket_id);
create index idx_support_messages_territory on public.support_messages (tenant_id, territory_id);
create index idx_support_messages_sender_id on public.support_messages (sender_id);

-- ── handler lookup (Spec A §9: a helper, never a per-row subquery) ──────
-- Tickets the caller is accountable for or assigned to, while they remain an
-- ACTIVE member of the ticket's tenant. Lets a non-TM fallback handler read
-- the ticket routed to them, and the CLOSED ticket it follows up
-- (previous_ticket_id), under the same membership check.
create or replace function public.my_support_ticket_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  with mine as (
    select t.id, t.previous_ticket_id
      from public.support_tickets t
     where (t.accountable_id = (select auth.uid()) or t.assigned_to = (select auth.uid()))
       and exists (select 1 from public.tenant_users tu
                    where tu.tenant_id = t.tenant_id
                      and tu.profile_id = (select auth.uid())
                      and tu.status = 'ACTIVE'))
  select id from mine
  union
  select previous_ticket_id from mine where previous_ticket_id is not null;
$$;
revoke all on function public.my_support_ticket_ids() from public, anon;
grant execute on function public.my_support_ticket_ids() to authenticated;

-- ── RLS and grants: SELECT only ─────────────────────────────────────────
grant select on public.support_tickets, public.support_ticket_contacts, public.support_messages
  to authenticated;

create policy support_tickets_select_member on public.support_tickets
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

create policy support_ticket_contacts_select_handler on public.support_ticket_contacts
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
         or territory_id in (select public.my_tm_territory_ids())
         or ticket_id in (select public.my_support_ticket_ids()));

create policy support_messages_select_handler on public.support_messages
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
         or territory_id in (select public.my_tm_territory_ids())
         or ticket_id in (select public.my_support_ticket_ids()));

-- ── Realtime: staff subscribe, RLS filters per subscriber ───────────────
alter publication supabase_realtime add table public.support_tickets, public.support_messages;
