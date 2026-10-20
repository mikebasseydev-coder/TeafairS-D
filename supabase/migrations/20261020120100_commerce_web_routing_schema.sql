-- Spec D1 §3.2–3.4 — territory coverage, web routing columns, constraints.
-- Coverage maps a state (fallback) or one LGA to the territory that serves
-- it. Written only by set_territory_coverage (a later task); readable by
-- members of the tenant.

create table public.territory_coverage (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  state_code    text not null references public.ng_states (code) on delete restrict,
  lga_id        uuid references public.ng_lgas (id) on delete restrict,
  territory_id  uuid not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, id),
  unique nulls not distinct (tenant_id, state_code, lga_id),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.territory_coverage enable row level security;
create policy territory_coverage_select on public.territory_coverage
  for select to authenticated using (tenant_id in (select public.my_tenant_ids()));
grant select on public.territory_coverage to authenticated;
create index idx_territory_coverage_territory on public.territory_coverage (tenant_id, territory_id);
create index idx_territory_coverage_lga on public.territory_coverage (lga_id);
create trigger territory_coverage_set_updated_at before update on public.territory_coverage
  for each row execute function public.set_updated_at();

create function public.territory_coverage_lga_in_state()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.lga_id is not null and not exists (
    select 1 from public.ng_lgas where id = new.lga_id and state_code = new.state_code) then
    raise exception 'the LGA is not in that state';
  end if;
  return new;
end $$;
create trigger territory_coverage_lga_in_state before insert or update on public.territory_coverage
  for each row execute function public.territory_coverage_lga_in_state();

-- ── §3.3 new columns ────────────────────────────────────────────────────
alter table public.territories
  add column web_fulfilment_warehouse_id uuid,
  add constraint territories_web_warehouse_fk
    foreign key (tenant_id, web_fulfilment_warehouse_id)
    references public.warehouses (tenant_id, id) on delete restrict;
create index idx_territories_web_warehouse on public.territories (tenant_id, web_fulfilment_warehouse_id);

alter table public.tenant_settings
  add column web_default_warehouse_id uuid,
  add column web_default_agent_id     uuid references public.profiles (id) on delete restrict,
  add constraint tenant_settings_web_warehouse_fk
    foreign key (tenant_id, web_default_warehouse_id)
    references public.warehouses (tenant_id, id) on delete restrict;
create index idx_tenant_settings_web_warehouse on public.tenant_settings (tenant_id, web_default_warehouse_id);
create index idx_tenant_settings_web_agent on public.tenant_settings (web_default_agent_id);

alter table public.orders
  add column delivery_lga_id           uuid references public.ng_lgas (id) on delete restrict,
  add column territory_id              uuid,
  add column fulfilment_warehouse_id   uuid,
  add constraint orders_territory_fk
    foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict,
  add constraint orders_fulfilment_warehouse_fk
    foreign key (tenant_id, fulfilment_warehouse_id) references public.warehouses (tenant_id, id) on delete restrict;
create index idx_orders_delivery_lga on public.orders (delivery_lga_id);

alter table public.payments
  add column split_subaccount_code text check (split_subaccount_code ~ '^ACCT_[A-Za-z0-9]+$'),
  add column split_bps             integer check (split_bps between 0 and 10000),
  add column split_amount          numeric(15,2) check (split_amount > 0);

alter table public.commission_records add column paystack_settlement_id text;

-- ── guard triggers ──────────────────────────────────────────────────────
-- Each looks the target up inside the row's own tenant. A row that is not
-- there is left to the composite foreign key, which raises 23503.
create function public.territories_web_warehouse_check()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.web_fulfilment_warehouse_id is not null and exists (
    select 1 from public.warehouses w
     where w.tenant_id = new.tenant_id and w.id = new.web_fulfilment_warehouse_id)
     and not exists (
    select 1 from public.warehouses w
     where w.tenant_id = new.tenant_id and w.id = new.web_fulfilment_warehouse_id
       and w.kind = 'REGIONAL' and w.territory_id = new.id) then
    raise exception 'a territory ships web orders from its own regional warehouse';
  end if;
  return new;
end $$;
create trigger territories_web_warehouse_check before insert or update of web_fulfilment_warehouse_id
  on public.territories for each row execute function public.territories_web_warehouse_check();

create function public.tenant_settings_web_defaults_check()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.web_default_warehouse_id is not null and exists (
    select 1 from public.warehouses w
     where w.tenant_id = new.tenant_id and w.id = new.web_default_warehouse_id)
     and not exists (
    select 1 from public.warehouses w
     where w.tenant_id = new.tenant_id and w.id = new.web_default_warehouse_id
       and w.kind = 'CENTRAL') then
    raise exception 'the default web warehouse must be a CENTRAL warehouse';
  end if;
  if new.web_default_agent_id is not null and not exists (
    select 1 from public.tenant_users tu
     where tu.tenant_id = new.tenant_id and tu.profile_id = new.web_default_agent_id
       and tu.status = 'ACTIVE') then
    raise exception 'the default web agent must be an active member of this tenant';
  end if;
  return new;
end $$;
create trigger tenant_settings_web_defaults_check
  before insert or update of web_default_warehouse_id, web_default_agent_id
  on public.tenant_settings for each row execute function public.tenant_settings_web_defaults_check();

-- ── §3.4 legacy cancel, then the constraints ───────────────────────────
do $$
declare r record;
begin
  for r in select id, tenant_id, teafair_agent_id from public.orders
            where channel = 'ONLINE' and status = 'PENDING' and delivery_lga_id is null
              for update loop
    update public.orders set status = 'CANCELLED' where id = r.id;
    perform public.write_audit(r.tenant_id, 'D1_LEGACY_CANCEL', 'orders', r.id::text,
      '{"status":"PENDING"}'::jsonb, '{"status":"CANCELLED"}'::jsonb, null, 'SYSTEM', r.teafair_agent_id);
  end loop;
end $$;

alter table public.orders
  add constraint orders_online_routed
    check (channel <> 'ONLINE' or status = 'CANCELLED'
           or num_nulls(delivery_lga_id, territory_id, fulfilment_warehouse_id) = 0),
  add constraint orders_codeless_pays_online
    check (channel <> 'ONLINE' or agent_code_id is not null or payment_route = 'PAYSTACK_WEB');
alter table public.payments
  add constraint payments_split_snapshot_complete
    check (num_nulls(split_subaccount_code, split_bps, split_amount) in (0, 3)),
  add constraint payments_split_within_amount
    check (split_amount is null or split_amount < amount);

create index idx_orders_territory_status on public.orders (tenant_id, territory_id, status);
create index idx_orders_fulfilment_status on public.orders (tenant_id, fulfilment_warehouse_id, status);
create index idx_commission_records_split on public.commission_records (created_at) where status = 'SPLIT';

-- payments is granted column by column: re-issue with the split snapshot
revoke select on public.payments from authenticated;
grant select (id, tenant_id, order_id, customer_id, teafair_agent_id, fintech_partner_id,
              fintech_terminal_id, amount, gateway_provider, payment_status, paystack_reference,
              otp_challenge_id, created_at, updated_at,
              split_subaccount_code, split_bps, split_amount)
  on public.payments to authenticated;
