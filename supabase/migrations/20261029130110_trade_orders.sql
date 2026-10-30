-- Addendum A6 §6.1 (Monvelo Step 2, Task 6) — place_trade_order.
-- The FIELD_SALES order of the Teafair app: a street or territory seller orders
-- for a shop at wholesale, in whole packs, from the territory's REGIONAL
-- warehouse. RTM core: it names no monvelo_ object. Stock is not touched here
-- (Task 6b adds the reservation). The migration is numbered 20261029130110
-- because 20261029130100 is the wind-down fix.
create or replace function public.place_trade_order(
  p_idempotency_key uuid,
  p_shop_id         uuid,
  p_lines           jsonb,
  p_territory_id    uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me        public.tenant_users :=
    public.assert_tenant_role(array['ZSA', 'ASA', 'TM']::public.tenant_role_enum[]);
  v_prior     jsonb;
  v_terr      uuid;
  v_zone      uuid;
  v_wh        uuid;
  v_el        jsonb;
  v_sku       text;
  v_qty       numeric;
  v_product   public.central_products;
  v_skus      text[] := '{}';
  v_prices    numeric[] := '{}';
  v_qtys      numeric[] := '{}';
  v_total     numeric(15,2) := 0;
  v_order     public.orders;
  i           integer;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_trade_order',
    jsonb_build_object('shop_id', p_shop_id, 'lines', p_lines, 'territory_id', p_territory_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- territory: ASA and TM sell in their own; a ZSA names one in the zone
  if v_me.role = 'ZSA' then
    if p_territory_id is null then
      raise exception 'choose the territory for this order' using errcode = 'P0001';
    end if;
    select t.zone_id into v_zone from public.territories t
     where t.id = p_territory_id and t.tenant_id = v_me.tenant_id;
    if not found or v_zone is distinct from v_me.zone_id then
      raise exception 'that territory is outside your zone' using errcode = '42501';
    end if;
    v_terr := p_territory_id;
  else
    if p_territory_id is not null and p_territory_id is distinct from v_me.territory_id then
      raise exception 'you sell in your own territory' using errcode = '42501';
    end if;
    v_terr := v_me.territory_id;
  end if;

  -- a trade order is new app work (A6 §18.4): platform and brand must both be on
  perform public.assert_state_app_operational(v_me.tenant_id, v_terr);

  if not exists (select 1 from public.retail_shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0001';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) not between 1 and 50 then
    raise exception 'an order has 1 to 50 lines' using errcode = 'P0001';
  end if;
  for v_el in select e from jsonb_array_elements(p_lines) e loop
    if jsonb_typeof(v_el) <> 'object' or jsonb_typeof(v_el -> 'sku_code') is distinct from 'string'
       or jsonb_typeof(v_el -> 'qty') is distinct from 'number' then
      raise exception 'each line needs a sku_code and a numeric qty' using errcode = 'P0001';
    end if;
    v_sku := v_el ->> 'sku_code';
    v_qty := (v_el ->> 'qty')::numeric;
    if v_qty <= 0 or v_qty <> round(v_qty, 3) or v_qty >= 100000000000 then
      raise exception 'the quantity of % must be above 0, with at most 3 decimals', v_sku using errcode = 'P0001';
    end if;
    if v_sku = any (v_skus) then
      raise exception '% appears on more than one line', v_sku using errcode = 'P0001';
    end if;
    select * into v_product from public.central_products p
     where p.tenant_id = v_me.tenant_id and p.sku_code = v_sku and p.is_active;
    if not found then
      raise exception '% is not an active product', v_sku using errcode = 'P0001';
    end if;
    v_skus := v_skus || v_sku;
    v_qtys := v_qtys || v_qty;
    v_prices := v_prices || v_product.wholesale_price;
    v_total := v_total + round(v_qty * v_product.wholesale_price, 2);
  end loop;

  select w.id into v_wh from public.warehouses w
   where w.tenant_id = v_me.tenant_id and w.territory_id = v_terr and w.kind = 'REGIONAL'
   order by w.created_at, w.id
   limit 1;
  if v_wh is null then
    raise exception 'the territory has no regional warehouse' using errcode = 'P0001';
  end if;

  insert into public.orders (tenant_id, channel, retail_shop_id, agent_id, teafair_agent_id,
                             total_amount, status, territory_id, fulfilment_warehouse_id)
  values (v_me.tenant_id, 'FIELD_SALES', p_shop_id, v_me.profile_id, v_me.profile_id,
          v_total, 'PENDING', v_terr, v_wh)
  returning * into v_order;

  -- the order_items_wholesale_pack trigger enforces whole packs and the price
  for i in 1 .. coalesce(array_length(v_skus, 1), 0) loop
    insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
    values (v_me.tenant_id, v_order.id, v_skus[i], v_qtys[i], v_prices[i]);
  end loop;

  perform public.write_audit(v_me.tenant_id, 'place_trade_order', 'orders', v_order.id::text,
    null,
    to_jsonb(v_order) - 'customer_name' - 'customer_phone'
      || jsonb_build_object('lines', p_lines),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id, 'total_amount', v_order.total_amount,
    'territory_id', v_terr, 'warehouse_id', v_wh));
end;
$$;
revoke all on function public.place_trade_order(uuid, uuid, jsonb, uuid) from public, anon;
grant execute on function public.place_trade_order(uuid, uuid, jsonb, uuid) to authenticated;
