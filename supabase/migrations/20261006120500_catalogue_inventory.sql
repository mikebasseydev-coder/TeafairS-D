-- Spec A §6.5 — catalogue and inventory, with brand-tier approval policies
-- (§5.4, decision 18).

create table public.warehouses (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  name          text not null check (length(btrim(name)) > 0),
  kind          public.warehouse_kind_enum not null,
  territory_id  uuid,
  location      extensions.geometry(Point, 4326),
  manager_id    uuid references public.profiles (id) on delete restrict,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.warehouses enable row level security;
create index idx_warehouses_territory on public.warehouses (tenant_id, territory_id);
create index idx_warehouses_manager on public.warehouses (manager_id);
create trigger warehouses_set_updated_at before update on public.warehouses
  for each row execute function public.set_updated_at();

-- ── brand_approval_policies ─────────────────────────────────────────────
-- Which ladder tier must sign off a requisition containing this brand.
-- Brands are matched case-insensitively; a brand with no row clears at DSM.
create table public.brand_approval_policies (
  tenant_id                uuid not null references public.tenants (id) on delete restrict,
  brand                    text not null check (brand = btrim(brand) and length(brand) > 0),
  required_approval_level  public.tenant_role_enum not null
                             check (required_approval_level in ('DSM', 'ASM', 'TM', 'ZSM')),
  updated_by               uuid not null references public.profiles (id) on delete restrict,
  updated_at               timestamptz not null default now(),
  primary key (tenant_id, brand)
);
alter table public.brand_approval_policies enable row level security;
create unique index brand_approval_policies_brand_ci
  on public.brand_approval_policies (tenant_id, lower(brand));
create index idx_brand_approval_policies_updated_by on public.brand_approval_policies (updated_by);
create trigger brand_approval_policies_set_updated_at before update on public.brand_approval_policies
  for each row execute function public.set_updated_at();

-- ── central_products ────────────────────────────────────────────────────
create table public.central_products (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  sku_code         text not null check (sku_code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'),
  product_name     text not null check (length(btrim(product_name)) > 0),
  brand            text not null check (brand = btrim(brand) and length(brand) > 0),
  category         text not null,
  unit_price       numeric(15,2) not null check (unit_price >= 0),
  wholesale_price  numeric(15,2) not null check (wholesale_price >= 0),
  description      text,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (tenant_id, sku_code)
);
alter table public.central_products enable row level security;
-- requisition_required_level() resolves SKU → brand → policy
create index idx_central_products_brand on public.central_products (tenant_id, lower(brand));
create trigger central_products_set_updated_at before update on public.central_products
  for each row execute function public.set_updated_at();

-- ── inventory_batches ───────────────────────────────────────────────────
-- Decision 10: quantity is authoritative, protected by SELECT … FOR UPDATE in
-- the RPCs; audit_logs carries the before/after history.
create table public.inventory_batches (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  warehouse_id  uuid not null,
  sku_code      text not null,
  batch_number  text not null,
  quantity      numeric(14,3) not null check (quantity >= 0),
  expires_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (warehouse_id, sku_code, batch_number),
  foreign key (tenant_id, warehouse_id) references public.warehouses (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sku_code) references public.central_products (tenant_id, sku_code) on delete restrict
);
alter table public.inventory_batches enable row level security;
create index idx_inventory_batches_warehouse on public.inventory_batches (tenant_id, warehouse_id);
create index idx_inventory_batches_sku on public.inventory_batches (tenant_id, sku_code);
create trigger inventory_batches_set_updated_at before update on public.inventory_batches
  for each row execute function public.set_updated_at();
