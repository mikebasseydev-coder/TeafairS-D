-- Spec A §6.4 — geography and the shared network, plus tenant_users (§6.3),
-- which anchors to zones and territories.
--
-- Intra-tenant references use composite foreign keys on (tenant_id, <id>)
-- against a UNIQUE (tenant_id, id) on the parent. This makes it impossible
-- for a row to point at another tenant's zone, territory, route or manager,
-- whatever the write path does.

-- ── zones, territories ──────────────────────────────────────────────────
create table public.zones (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete restrict,
  zone_name   text not null check (length(btrim(zone_name)) > 0),
  zsm_id      uuid references public.profiles (id) on delete restrict,
  boundary    extensions.geometry(MultiPolygon, 4326),
  created_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, zone_name)
);
alter table public.zones enable row level security;
create index idx_zones_boundary on public.zones using gist (boundary);
create index idx_zones_zsm on public.zones (zsm_id);

create table public.territories (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  zone_id         uuid not null,
  territory_name  text not null check (length(btrim(territory_name)) > 0),
  tm_id           uuid references public.profiles (id) on delete restrict,
  boundary        extensions.geometry(MultiPolygon, 4326),
  created_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, zone_id, territory_name),
  foreign key (tenant_id, zone_id) references public.zones (tenant_id, id) on delete restrict
);
alter table public.territories enable row level security;
create index idx_territories_boundary on public.territories using gist (boundary);
create index idx_territories_tm on public.territories (tm_id);

-- ── tenant_users ────────────────────────────────────────────────────────
-- §5.2 scope model. tenant_users.role is authoritative; the JWT claim is a
-- routing cache (§4.4). PIN columns per §5.5.
create table public.tenant_users (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenants (id) on delete restrict,
  profile_id           uuid not null references public.profiles (id) on delete restrict,
  role                 public.tenant_role_enum not null,
  zone_id              uuid,
  territory_id         uuid,
  reports_to_id        uuid,
  is_primary           boolean not null default false,
  status               public.tenant_user_status_enum not null default 'INVITED',
  pin_hash             text check (pin_hash ~ '^\$2[aby]\$[0-9]{2}\$.{53}$'),  -- bcrypt only
  pin_failed_attempts  integer not null default 0 check (pin_failed_attempts >= 0),
  pin_locked_until     timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (tenant_id, profile_id),
  unique (tenant_id, id),
  foreign key (tenant_id, zone_id)       references public.zones (tenant_id, id) on delete restrict,
  foreign key (tenant_id, territory_id)  references public.territories (tenant_id, id) on delete restrict,
  foreign key (tenant_id, reports_to_id) references public.tenant_users (tenant_id, id) on delete restrict,
  -- geographic anchor per role (§5.2)
  constraint tenant_users_zsm_has_zone
    check (role <> 'ZSM' or zone_id is not null),
  constraint tenant_users_territory_roles_have_territory
    check (role not in ('TM', 'ASM', 'DSM', 'DSA', 'FINTECH_AGENT') or territory_id is not null),
  -- ASM, DSM and DSA are team tiers: they always report to someone
  constraint tenant_users_team_tiers_report
    check (role not in ('ASM', 'DSM', 'DSA') or reports_to_id is not null),
  constraint tenant_users_not_own_manager
    check (reports_to_id is null or reports_to_id <> id)
);
alter table public.tenant_users enable row level security;
create index idx_tenant_users_profile on public.tenant_users (profile_id, status);
create index idx_tenant_users_zone on public.tenant_users (tenant_id, zone_id);
create index idx_tenant_users_territory on public.tenant_users (tenant_id, territory_id);
create index idx_tenant_users_reports_to on public.tenant_users (tenant_id, reports_to_id);
-- at most one primary membership per person (the default active tenant)
create unique index tenant_users_one_primary
  on public.tenant_users (profile_id) where is_primary;
create trigger tenant_users_set_updated_at before update on public.tenant_users
  for each row execute function public.set_updated_at();

-- §6.9: zones.zsm_id / territories.tm_id must be a profile holding an ACTIVE
-- membership in the same tenant with the matching role.
create or replace function public.check_area_manager()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_manager uuid;
  v_role    public.tenant_role_enum;
begin
  if tg_table_name = 'zones' then
    v_manager := new.zsm_id;  v_role := 'ZSM';
  else
    v_manager := new.tm_id;   v_role := 'TM';
  end if;

  if v_manager is not null and not exists (
    select 1 from public.tenant_users tu
    where tu.tenant_id = new.tenant_id
      and tu.profile_id = v_manager
      and tu.role = v_role
      and tu.status = 'ACTIVE'
  ) then
    raise exception '% manager must be an ACTIVE % of the same tenant', tg_table_name, v_role
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger zones_check_manager
  before insert or update of zsm_id on public.zones
  for each row execute function public.check_area_manager();
create trigger territories_check_manager
  before insert or update of tm_id on public.territories
  for each row execute function public.check_area_manager();

-- ── retail_shops (global, class B) ──────────────────────────────────────
-- No tenant_id (§4.3). Carries its own contact fields so the owner's profile
-- stays behind shared membership.
create table public.retail_shops (
  id                uuid primary key default gen_random_uuid(),
  shop_name         text not null check (length(btrim(shop_name)) > 0),
  contact_phone     text not null check (contact_phone ~ '^\+[1-9][0-9]{7,14}$'),
  owner_id          uuid references public.profiles (id) on delete restrict,
  density_category  public.density_category_enum not null,
  location          extensions.geometry(Point, 4326) not null,
  address_text      text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
alter table public.retail_shops enable row level security;
create index idx_retail_shops_geo on public.retail_shops using gist (location);
create index idx_retail_shops_owner on public.retail_shops (owner_id);
create trigger retail_shops_set_updated_at before update on public.retail_shops
  for each row execute function public.set_updated_at();

create table public.tenant_shop_coverage (
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  retail_shop_id  uuid not null references public.retail_shops (id) on delete restrict,
  territory_id    uuid not null,
  assigned_by     uuid not null references public.profiles (id) on delete restrict,
  assigned_at     timestamptz not null default now(),
  primary key (tenant_id, retail_shop_id),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.tenant_shop_coverage enable row level security;
-- the retail_shops policy narrows by shop when allow_shared_network = false
create index idx_tenant_shop_coverage_shop on public.tenant_shop_coverage (retail_shop_id, tenant_id);
create index idx_tenant_shop_coverage_territory on public.tenant_shop_coverage (tenant_id, territory_id);

-- ── routes, waypoints, check-ins ────────────────────────────────────────
create table public.routes (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete restrict,
  territory_id       uuid not null,
  assigned_staff_id  uuid not null references public.profiles (id) on delete restrict,
  route_date         date not null,
  status             text not null default 'PLANNED'
                       check (status in ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, territory_id) references public.territories (tenant_id, id) on delete restrict
);
alter table public.routes enable row level security;
create index idx_routes_territory on public.routes (tenant_id, territory_id, route_date);
create index idx_routes_staff on public.routes (assigned_staff_id, route_date);
create trigger routes_set_updated_at before update on public.routes
  for each row execute function public.set_updated_at();

create table public.route_waypoints (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete restrict,
  route_id           uuid not null,
  seq                integer not null check (seq > 0),
  landmark_name      text not null,
  location           extensions.geometry(Point, 4326) not null,
  geofence_radius_m  integer not null default 100 check (geofence_radius_m between 10 and 5000),
  unique (tenant_id, id),
  unique (route_id, seq),
  foreign key (tenant_id, route_id) references public.routes (tenant_id, id) on delete restrict
);
alter table public.route_waypoints enable row level security;
create index idx_route_waypoints_geo on public.route_waypoints using gist (location);
create index idx_route_waypoints_route on public.route_waypoints (tenant_id, route_id);

-- captured_at is the device clock, recorded but never trusted (§7.5);
-- created_at is the server's authoritative time.
create table public.field_check_ins (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  route_id         uuid,
  waypoint_id      uuid,
  user_id          uuid not null references public.profiles (id) on delete restrict,
  location         extensions.geometry(Point, 4326) not null,
  captured_at      timestamptz not null,
  within_geofence  boolean not null,
  created_at       timestamptz not null default now(),
  foreign key (tenant_id, route_id)    references public.routes (tenant_id, id) on delete restrict,
  foreign key (tenant_id, waypoint_id) references public.route_waypoints (tenant_id, id) on delete restrict
);
alter table public.field_check_ins enable row level security;
create index idx_field_checkins_geo on public.field_check_ins using gist (location);
create index idx_field_checkins_user on public.field_check_ins (tenant_id, user_id, created_at desc);
create index idx_field_checkins_route on public.field_check_ins (tenant_id, route_id);
create index idx_field_checkins_waypoint on public.field_check_ins (tenant_id, waypoint_id);
