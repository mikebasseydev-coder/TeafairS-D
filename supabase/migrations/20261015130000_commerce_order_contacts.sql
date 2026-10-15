-- Addendum A2 §3 — buyer contact details leave orders for order_contacts,
-- which only the tenant's ZSM and the order's TM can read. Paystack's raw
-- payload on payments is withheld from the app by column grant.

-- ── order_contacts ──────────────────────────────────────────────────────
create table public.order_contacts (
  order_id          uuid primary key,
  tenant_id         uuid not null references public.tenants (id) on delete restrict,
  -- the territory accountable for the order, stamped at checkout (A2 §2.5);
  -- null means only ZSMs can read the row
  territory_id      uuid,
  customer_name     text check (customer_name is null or length(btrim(customer_name)) > 0),
  customer_phone    text check (customer_phone ~ '^\+[1-9][0-9]{7,14}$'),
  customer_email    text check (customer_email = lower(customer_email)),
  delivery_address  text check (delivery_address is null or length(btrim(delivery_address)) > 0),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, order_id),
  foreign key (tenant_id, order_id)     references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.order_contacts enable row level security;
create index idx_order_contacts_territory on public.order_contacts (tenant_id, territory_id);
-- the place_web_order throttle: orders per phone, last hour
create index idx_order_contacts_phone on public.order_contacts (customer_phone, created_at);
create trigger order_contacts_set_updated_at before update on public.order_contacts
  for each row execute function public.set_updated_at();

-- Territories the caller manages as an ACTIVE TM.
create or replace function public.my_tm_territory_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select tu.territory_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role = 'TM';
$$;
grant execute on function public.my_tm_territory_ids() to authenticated;

create policy order_contacts_select_zsm_or_tm on public.order_contacts
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
         or territory_id in (select public.my_tm_territory_ids()));

-- ── move the data, then drop the columns ────────────────────────────────
insert into public.order_contacts (order_id, tenant_id, customer_name, customer_phone, customer_email,
                                   delivery_address, created_at)
select o.id, o.tenant_id, nullif(btrim(o.customer_name), ''), o.customer_phone, o.customer_email,
       o.delivery_address, o.created_at
  from public.orders o
 where num_nonnulls(o.customer_name, o.customer_phone, o.customer_email, o.delivery_address) > 0;

alter table public.orders drop constraint orders_web_attribution_complete;
drop index public.idx_orders_web_pending_phone;
alter table public.orders
  drop column customer_name,
  drop column customer_phone,
  drop column customer_email,
  drop column delivery_address,
  add constraint orders_web_attribution_complete
    check (channel <> 'ONLINE' or agent_code_id is null
           or num_nulls(payment_route, attributed_agent_id, public_reference) = 0);

-- ── payments: Paystack's verified transaction holds the buyer's email,
-- phone and card details. Every column but that one stays readable. A new
-- payments column must be added to this grant to become readable.
revoke select on public.payments from authenticated;
grant select (id, tenant_id, order_id, customer_id, teafair_agent_id, fintech_partner_id,
              fintech_terminal_id, amount, gateway_provider, payment_status, paystack_reference,
              otp_challenge_id, created_at, updated_at)
  on public.payments to authenticated;
