-- Spec A §6.6 — commerce: requisitions, orders, retail stock pickups.
-- Child tables carry a denormalised tenant_id (§4.2) and reference their
-- parent through (tenant_id, parent_id), so the copy can never disagree.

-- ── requisitions ────────────────────────────────────────────────────────
-- required_approval_level is fixed at submission from brand-tier policy
-- (§5.4); total_value is reporting only.
create table public.requisitions (
  id                       uuid primary key default gen_random_uuid(),
  tenant_id                uuid not null references public.tenants (id) on delete restrict,
  source_warehouse_id      uuid not null,
  dest_warehouse_id        uuid not null,
  requested_by             uuid not null references public.profiles (id) on delete restrict,
  status                   text not null default 'DRAFT'
                             check (status in ('DRAFT', 'PENDING_APPROVAL', 'APPROVED',
                                               'REJECTED', 'FULFILLED', 'CANCELLED')),
  current_approval_level   public.tenant_role_enum
                             check (current_approval_level in ('DSM', 'ASM', 'TM', 'ZSM')),
  required_approval_level  public.tenant_role_enum not null default 'DSM'
                             check (required_approval_level in ('DSM', 'ASM', 'TM', 'ZSM')),
  total_value              numeric(15,2) not null default 0 check (total_value >= 0),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (tenant_id, id),
  constraint requisitions_distinct_warehouses check (source_warehouse_id <> dest_warehouse_id),
  foreign key (tenant_id, source_warehouse_id) references public.warehouses (tenant_id, id) on delete restrict,
  foreign key (tenant_id, dest_warehouse_id)   references public.warehouses (tenant_id, id) on delete restrict
);
alter table public.requisitions enable row level security;
create index idx_requisitions_status on public.requisitions (tenant_id, status, created_at desc);
create index idx_requisitions_source on public.requisitions (tenant_id, source_warehouse_id);
create index idx_requisitions_dest on public.requisitions (tenant_id, dest_warehouse_id);
create index idx_requisitions_requested_by on public.requisitions (requested_by);
create trigger requisitions_set_updated_at before update on public.requisitions
  for each row execute function public.set_updated_at();

create table public.requisition_items (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  requisition_id  uuid not null,
  sku_code        text not null,
  requested_qty   numeric(14,3) not null check (requested_qty > 0),
  approved_qty    numeric(14,3) check (approved_qty >= 0),
  fulfilled_qty   numeric(14,3) check (fulfilled_qty >= 0),
  unique (requisition_id, sku_code),
  constraint requisition_items_approved_le_requested
    check (approved_qty is null or approved_qty <= requested_qty),
  constraint requisition_items_fulfilled_le_approved
    check (fulfilled_qty is null or (approved_qty is not null and fulfilled_qty <= approved_qty)),
  foreign key (tenant_id, requisition_id) references public.requisitions (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sku_code) references public.central_products (tenant_id, sku_code) on delete restrict
);
alter table public.requisition_items enable row level security;
create index idx_requisition_items_requisition on public.requisition_items (tenant_id, requisition_id);
create index idx_requisition_items_sku on public.requisition_items (tenant_id, sku_code);

-- ── orders ──────────────────────────────────────────────────────────────
-- One revenue ledger behind a channel discriminator (§6.1). agent_id is who
-- placed it; teafair_agent_id is the staff member accountable (§6.10).
create table public.orders (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants (id) on delete restrict,
  channel             public.order_channel_enum not null,
  retail_shop_id      uuid references public.retail_shops (id) on delete restrict,
  agent_id            uuid references public.profiles (id) on delete restrict,
  teafair_agent_id    uuid not null references public.profiles (id) on delete restrict,
  customer_name       text,
  customer_phone      text check (customer_phone ~ '^\+[1-9][0-9]{7,14}$'),
  total_amount        numeric(15,2) not null check (total_amount >= 0),
  status              text not null default 'PENDING'
                        check (status in ('PENDING', 'PAID', 'IN_TRANSIT', 'DELIVERED',
                                          'CANCELLED', 'REFUNDED')),
  tracking_reference  text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (tenant_id, id)
);
alter table public.orders enable row level security;
create index idx_orders_status on public.orders (tenant_id, status, created_at desc);
create index idx_orders_shop on public.orders (retail_shop_id, tenant_id);
create index idx_orders_agent on public.orders (agent_id);
create index idx_orders_teafair_agent on public.orders (tenant_id, teafair_agent_id);
create trigger orders_set_updated_at before update on public.orders
  for each row execute function public.set_updated_at();

create table public.order_items (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete restrict,
  order_id    uuid not null,
  sku_code    text not null,
  qty         numeric(14,3) not null check (qty > 0),
  unit_price  numeric(15,2) not null check (unit_price >= 0),
  line_total  numeric(15,2) generated always as (round(qty * unit_price, 2)) stored,
  unique (order_id, sku_code),
  foreign key (tenant_id, order_id) references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sku_code) references public.central_products (tenant_id, sku_code) on delete restrict
);
alter table public.order_items enable row level security;
create index idx_order_items_order on public.order_items (tenant_id, order_id);
create index idx_order_items_sku on public.order_items (tenant_id, sku_code);

-- ── retail stock pickups ────────────────────────────────────────────────
-- One event, two entry points (§6.6): whichever of DSA or shop owner acts
-- first creates the row; the other's action confirms it. escalated_at is the
-- 24-hour escalation flag set by escalate_stale_pickups() (§7.4).
create table public.retail_stock_pickups (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete restrict,
  retail_shop_id     uuid not null references public.retail_shops (id) on delete restrict,
  dsa_agent_id       uuid not null references public.profiles (id) on delete restrict,
  dsm_supervisor_id  uuid references public.profiles (id) on delete restrict,
  event_tag          text,
  status             text not null default 'PENDING_CONFIRMATION'
                       check (status in ('PENDING_CONFIRMATION', 'CONFIRMED', 'DISPUTED')),
  confirmed_by       uuid references public.profiles (id) on delete restrict,
  confirmed_at       timestamptz,
  escalated_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (tenant_id, id),
  constraint retail_stock_pickups_confirmation_recorded
    check (status <> 'CONFIRMED' or (confirmed_by is not null and confirmed_at is not null))
);
alter table public.retail_stock_pickups enable row level security;
create index idx_pickups_shop on public.retail_stock_pickups (tenant_id, retail_shop_id, created_at desc);
create index idx_pickups_dsa on public.retail_stock_pickups (dsa_agent_id, created_at desc);
create index idx_pickups_dsm on public.retail_stock_pickups (dsm_supervisor_id);
create index idx_pickups_confirmed_by on public.retail_stock_pickups (confirmed_by);
-- the escalation job's scan: only rows still waiting and not yet escalated
create index idx_pickups_awaiting_escalation on public.retail_stock_pickups (created_at)
  where status = 'PENDING_CONFIRMATION' and escalated_at is null;
create trigger retail_stock_pickups_set_updated_at before update on public.retail_stock_pickups
  for each row execute function public.set_updated_at();

create table public.retail_stock_pickup_items (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  pickup_id        uuid not null,
  sku_code         text not null,
  quantity_picked  numeric(14,3) not null check (quantity_picked > 0),
  unique (pickup_id, sku_code),
  foreign key (tenant_id, pickup_id) references public.retail_stock_pickups (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sku_code) references public.central_products (tenant_id, sku_code) on delete restrict
);
alter table public.retail_stock_pickup_items enable row level security;
create index idx_pickup_items_pickup on public.retail_stock_pickup_items (tenant_id, pickup_id);
create index idx_pickup_items_sku on public.retail_stock_pickup_items (tenant_id, sku_code);
