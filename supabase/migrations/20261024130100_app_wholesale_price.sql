-- App sales are wholesale (user decision 2026-10-24): every order line on a
-- channel other than ONLINE (company field agents selling to independent
-- retail shops) is priced at the product's per-unit wholesale price. Retail
-- prices apply only on the web storefront (ONLINE). Replaces the A5 break-bulk
-- order-line trigger function with one that checks the price as well.
create or replace function public.order_items_wholesale_pack()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product public.central_products;
begin
  if exists (select 1 from public.orders o
              where o.tenant_id = new.tenant_id and o.id = new.order_id and o.channel <> 'ONLINE') then
    perform public.assert_wholesale_pack(new.tenant_id, new.sku_code, new.qty);
    select * into v_product from public.central_products p
     where p.tenant_id = new.tenant_id and p.sku_code = new.sku_code;
    if new.unit_price is distinct from v_product.wholesale_price then
      raise exception 'App sales are at the wholesale price: % is % a unit, not %.',
        v_product.product_name, v_product.wholesale_price, new.unit_price
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.order_items_wholesale_pack() from public, anon, authenticated, service_role;

drop trigger order_items_wholesale_pack on public.order_items;
create trigger order_items_wholesale_pack
  before insert or update of sku_code, qty, unit_price on public.order_items
  for each row execute function public.order_items_wholesale_pack();
