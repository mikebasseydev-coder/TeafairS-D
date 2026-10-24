-- Per-tenant sale categories (NCC licence) and NAFDAC numbers on products.
--
-- A5 made a category sellable when the active refund policy covers it, for
-- every tenant at once. TELECOM may only ever be sold by Sureach Nigeria
-- Limited, which holds the NCC licence, so each tenant now carries its own
-- allowed categories. Regulated categories (FOOD, COSMETICS) need a NAFDAC
-- number before a product can be active.

-- ── tenant_allowed_categories ───────────────────────────────────────────
-- A platform decision per tenant, written by migration only (like
-- refund_policies): there is no RPC. Members read their own tenant's rows.
create table public.tenant_allowed_categories (
  tenant_id   uuid not null references public.tenants (id) on delete restrict,
  category    text not null check (category in ('FOOD', 'COSMETICS', 'ELECTRONICS', 'TELECOM')),
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, category)
);
alter table public.tenant_allowed_categories enable row level security;
revoke all on public.tenant_allowed_categories from anon, authenticated, service_role;
grant select on public.tenant_allowed_categories to authenticated;
create trigger tenant_allowed_categories_set_updated_at before update on public.tenant_allowed_categories
  for each row execute function public.set_updated_at();

create policy tenant_allowed_categories_select_tenant_member on public.tenant_allowed_categories
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── guard: TELECOM is Sureach's alone; no withdrawal under live products ─
-- Withdrawing a category while active products use it would leave them on
-- sale without permission, so the products are deactivated first.
create function public.tenant_allowed_categories_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and (new.tenant_id, new.category) is distinct from (old.tenant_id, old.category) then
    raise exception 'a tenant category row cannot be moved; delete it and insert a new one'
      using errcode = 'P0001';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.enabled and new.category = 'TELECOM'
     and new.tenant_id <> '5eac0000-0000-4000-8000-000000000001' then
    raise exception 'Only Sureach Nigeria Limited holds the NCC licence to sell TELECOM products.'
      using errcode = 'P0001';
  end if;
  if (tg_op = 'DELETE' and old.enabled) or (tg_op = 'UPDATE' and old.enabled and not new.enabled) then
    if exists (select 1 from public.central_products p
                where p.tenant_id = old.tenant_id and p.sale_category = old.category and p.is_active) then
      raise exception 'Deactivate this tenant''s % products before withdrawing the category.', old.category
        using errcode = 'P0001';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function public.tenant_allowed_categories_guard() from public, anon, authenticated, service_role;

create trigger tenant_allowed_categories_guard
  before insert or update or delete on public.tenant_allowed_categories
  for each row execute function public.tenant_allowed_categories_guard();

-- ── every tenant starts with FOOD and COSMETICS ─────────────────────────
create function public.tenants_default_categories()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.tenant_allowed_categories (tenant_id, category)
  values (new.id, 'FOOD'), (new.id, 'COSMETICS')
  on conflict do nothing;
  return null;
end;
$$;
revoke all on function public.tenants_default_categories() from public, anon, authenticated, service_role;

create trigger tenants_default_categories after insert on public.tenants
  for each row execute function public.tenants_default_categories();

insert into public.tenant_allowed_categories (tenant_id, category)
select t.id, c.category
  from public.tenants t
 cross join (values ('FOOD'), ('COSMETICS')) as c(category)
on conflict do nothing;

-- ── Sureach Nigeria Limited ─────────────────────────────────────────────
-- The NCC licence holder, wholly owned by Teafair's owner. Seeded here for the
-- same reason as TEAFAIR (20261006130600): a real business entity that must
-- exist in every environment, with a fixed id that the guard above names.
insert into public.tenants (id, name, code, status)
values ('5eac0000-0000-4000-8000-000000000001', 'Sureach Nigeria Limited', 'SUREACH', 'ACTIVE')
on conflict (id) do nothing;

insert into public.tenant_settings (tenant_id)
values ('5eac0000-0000-4000-8000-000000000001')
on conflict (tenant_id) do nothing;

insert into public.tenant_allowed_categories (tenant_id, category)
values ('5eac0000-0000-4000-8000-000000000001', 'ELECTRONICS'),
       ('5eac0000-0000-4000-8000-000000000001', 'TELECOM')
on conflict do nothing;

-- ── products: the category must be allowed for the tenant ───────────────
-- Checked on insert, on a category or tenant change, and on activation.
create function public.central_products_category_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (tg_op = 'INSERT'
      or new.tenant_id is distinct from old.tenant_id
      or new.sale_category is distinct from old.sale_category
      or (new.is_active and not old.is_active))
     and not exists (select 1 from public.tenant_allowed_categories a
                      where a.tenant_id = new.tenant_id and a.category = new.sale_category and a.enabled) then
    raise exception 'Tenant is not authorized to sell products in category %.', new.sale_category
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.central_products_category_guard() from public, anon, authenticated, service_role;

create trigger central_products_category_guard
  before insert or update of tenant_id, sale_category, is_active on public.central_products
  for each row execute function public.central_products_category_guard();

-- ── products: NAFDAC number ─────────────────────────────────────────────
-- Upper-case letters and digits in hyphenated groups (A7-0123, LG-IKJ-02-2134).
-- An active FOOD or COSMETICS product must carry one. The requirement is
-- NOT VALID: every new or changed row is checked at once, but products that
-- already exist on push (all FOOD by A5's default) are not, so the push cannot
-- fail on them. Once their numbers are loaded, validate it (supabase/CLAUDE.md).
alter table public.central_products
  add column nafdac_number text
    constraint central_products_nafdac_format
      check (length(nafdac_number) <= 32 and nafdac_number ~ '^[A-Z0-9]+(-[A-Z0-9]+){1,5}$');
alter table public.central_products
  add constraint central_products_nafdac_required
    check (not is_active or sale_category not in ('FOOD', 'COSMETICS') or nafdac_number is not null) not valid;

-- ── Purerigin Coconut Oil (Teafair house brand) ─────────────────────────
-- NAFDAC-registered and branded for skin, hair and body care; both sizes carry
-- the same number. Prices are per bottle (user, 2026-10-24): retail 5,000 and
-- 3,000; wholesale 4,000 (48,000 a carton of 12) and 2,500 (60,000 a carton
-- of 24). Carton sizes and break-bulk packs are set in 20261024130000.
insert into public.central_products (tenant_id, sku_code, product_name, brand, category,
                                     sale_category, nafdac_number, unit_price, wholesale_price, is_active)
values ('7eaf0000-0000-4000-8000-000000000001', 'PURERIGIN-COCONUT-OIL-200ML', 'Purerigin Coconut Oil - 200ml',
        'Purerigin', 'Skin and hair care', 'COSMETICS', 'LG-IKJ-02-2134', 5000, 4000, true),
       ('7eaf0000-0000-4000-8000-000000000001', 'PURERIGIN-COCONUT-OIL-100ML', 'Purerigin Coconut Oil - 100ml',
        'Purerigin', 'Skin and hair care', 'COSMETICS', 'LG-IKJ-02-2134', 3000, 2500, true)
on conflict (tenant_id, sku_code) do update
  set product_name = excluded.product_name, sale_category = excluded.sale_category,
      nafdac_number = excluded.nafdac_number, unit_price = excluded.unit_price,
      wholesale_price = excluded.wholesale_price, is_active = excluded.is_active;
