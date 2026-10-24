-- Cartons and break-bulk wholesale packs.
--
-- Prices stay per unit (unit_price retail, wholesale_price wholesale). A
-- product may also declare how many units a carton holds and the smallest pack
-- the trade may buy (a break-bulk pack, e.g. a quarter carton). Sales to the
-- trade, meaning every order channel except ONLINE and every retail stock
-- pickup, must then come in whole packs. Web buyers still buy single units.
-- No RPC writes these lines yet (Spec C), so the rule sits on the tables and
-- every future writer inherits it.

alter table public.central_products
  add column carton_units integer check (carton_units > 0),
  add column break_bulk_units integer check (break_bulk_units > 0),
  add constraint central_products_break_bulk_fits_carton
    check (break_bulk_units is null or (carton_units is not null and carton_units % break_bulk_units = 0)),
  add column carton_wholesale_price numeric(15,2)
    generated always as (wholesale_price * carton_units) stored,
  add column break_bulk_wholesale_price numeric(15,2)
    generated always as (wholesale_price * break_bulk_units) stored;

-- ── internal: the smallest pack the trade may buy ───────────────────────
-- The break-bulk pack if set, else a full carton, else any quantity.
create function public.assert_wholesale_pack(p_tenant_id uuid, p_sku_code text, p_qty numeric)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_product public.central_products;
  v_pack    integer;
begin
  select * into v_product from public.central_products p
   where p.tenant_id = p_tenant_id and p.sku_code = p_sku_code;
  v_pack := coalesce(v_product.break_bulk_units, v_product.carton_units);
  if v_pack is not null and p_qty % v_pack <> 0 then
    raise exception '% sells to the trade in packs of % units; % is not a whole number of packs.',
      v_product.product_name, v_pack, trim_scale(p_qty)
      using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.assert_wholesale_pack(uuid, text, numeric) from public, anon, authenticated, service_role;

create function public.order_items_wholesale_pack()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from public.orders o
              where o.tenant_id = new.tenant_id and o.id = new.order_id and o.channel <> 'ONLINE') then
    perform public.assert_wholesale_pack(new.tenant_id, new.sku_code, new.qty);
  end if;
  return new;
end;
$$;
revoke all on function public.order_items_wholesale_pack() from public, anon, authenticated, service_role;

create trigger order_items_wholesale_pack
  before insert or update of sku_code, qty on public.order_items
  for each row execute function public.order_items_wholesale_pack();

create function public.retail_stock_pickup_items_wholesale_pack()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.assert_wholesale_pack(new.tenant_id, new.sku_code, new.quantity_picked);
  return new;
end;
$$;
revoke all on function public.retail_stock_pickup_items_wholesale_pack() from public, anon, authenticated, service_role;

create trigger retail_stock_pickup_items_wholesale_pack
  before insert or update of sku_code, quantity_picked on public.retail_stock_pickup_items
  for each row execute function public.retail_stock_pickup_items_wholesale_pack();

-- ── Purerigin Coconut Oil: cartons of 12 and 24, sold in quarter cartons ─
-- 200ml: carton 48,000, quarter carton (3 bottles) 12,000.
-- 100ml: carton 60,000, quarter carton (6 bottles) 15,000.
update public.central_products
   set carton_units = 12, break_bulk_units = 3
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-200ML';
update public.central_products
   set carton_units = 24, break_bulk_units = 6
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and sku_code = 'PURERIGIN-COCONUT-OIL-100ML';
