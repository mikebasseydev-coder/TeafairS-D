-- Domain separation, Task 4 (A6 section 15.5): the web POS commission is one tenant
-- rate in basis points, replacing the flat web_agent_bounty and the per-partner
-- commission_bps. Only orders through a POS referral link (a code whose venue's
-- partner is ACTIVE) earn it; codeless orders and DSA/DSM links pay 0%. The share is
-- round(goods_total * bps / 10000, 2), never on the transport fare. A rate of 0, or a
-- share that rounds to 0, is no split. Every tenant starts at 0 (TEAFAIR included, which
-- ends its 500 bounty); the rate is set by migration only.

alter table public.tenant_settings
  add column web_agent_commission_bps integer not null default 0;
alter table public.tenant_settings
  add constraint tenant_settings_web_agent_commission_bps_check
  check (web_agent_commission_bps between 0 and 10000);
comment on column public.tenant_settings.web_agent_commission_bps is
  'set by migration only; 0 until rates are agreed (A6 §15.5)';

-- web_price_cart
CREATE OR REPLACE FUNCTION public.web_price_cart(p_code web_referral_codes, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_count    integer;
  v_matched  integer;
  v_lines    jsonb;
  v_subtotal numeric(15,2);
  v_discount numeric(15,2);
  v_total    numeric(15,2);
  v_split    jsonb;
  v_fare     numeric(15,2);
begin
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'items must be a list' using errcode = 'P0001';
  end if;
  v_count := jsonb_array_length(p_items);
  if v_count < 1 or v_count > 50 then
    raise exception 'an order has between 1 and 50 items' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) e
     where jsonb_typeof(e) <> 'object'
        or jsonb_typeof(e -> 'sku_code') is distinct from 'string'
        or not (case when jsonb_typeof(e -> 'qty') = 'number' and (e ->> 'qty') ~ '^[0-9]{1,4}$'
                     then (e ->> 'qty')::integer between 1 and 1000
                     else false end)
  ) then
    raise exception 'each item needs a sku_code and a whole quantity from 1 to 1000' using errcode = 'P0001';
  end if;
  if (select count(distinct e ->> 'sku_code') from jsonb_array_elements(p_items) e) <> v_count then
    raise exception 'each product may appear only once' using errcode = 'P0001';
  end if;

  select count(*),
         jsonb_agg(jsonb_build_object(
           'sku_code', p.sku_code, 'product_name', p.product_name,
           'qty', (e ->> 'qty')::integer, 'unit_price', p.unit_price,
           'line_total', round((e ->> 'qty')::integer * p.unit_price, 2)) order by p.sku_code),
         coalesce(sum(round((e ->> 'qty')::integer * p.unit_price, 2)), 0)
    into v_matched, v_lines, v_subtotal
    from jsonb_array_elements(p_items) e
    join public.central_products p
      on p.tenant_id = p_code.tenant_id and p.sku_code = e ->> 'sku_code' and p.is_active;
  if v_matched <> v_count then
    raise exception 'a product in your cart is no longer available' using errcode = 'P0001';
  end if;

  v_discount := 0;  -- no web discounts: every line at unit_price
  v_total := v_subtotal;
  if v_total <= 0 then
    raise exception 'the order total must be more than zero' using errcode = 'P0001';
  end if;

  -- A6 15.5: only a code tied to a venue of an ACTIVE POS partner earns, at the
  -- tenant's rate, on goods only. Codeless and staff links have no venue: no split.
  -- A rate of 0, or a share that rounds to 0 or reaches the total, is no split.
  select s.split into v_split
    from (select jsonb_build_object('web_pos_partner_id', fp.id,
                                    'subaccount_code', fp.paystack_subaccount_code,
                                    'commission_bps', ts.web_agent_commission_bps,
                                    'partner_share', round(v_total * ts.web_agent_commission_bps / 10000, 2)) as split
            from public.web_pos_venues ft
            join public.web_pos_partners fp
              on fp.tenant_id = ft.tenant_id and fp.id = ft.partner_id and fp.status = 'ACTIVE'
            join public.tenant_settings ts on ts.tenant_id = ft.tenant_id
           where ft.tenant_id = p_code.tenant_id and ft.id = p_code.venue_id) s
   where (s.split ->> 'partner_share')::numeric > 0
     and (s.split ->> 'partner_share')::numeric < v_total;

  -- the tenant's flat transport fare: never discounted, never commissioned
  v_fare := coalesce((select s.web_transport_fare from public.tenant_settings s
                       where s.tenant_id = p_code.tenant_id), 0);

  return jsonb_build_object(
    'lines', v_lines,
    'subtotal', v_subtotal,
    'discount', v_discount,
    'goods_total', v_total,
    'transport_fare', v_fare,
    'total', v_total + v_fare,
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = p_code.tenant_id), 'NGN'),
    'split', v_split);
end;
$function$
;

-- The old sources go (no CASCADE: web_price_cart above no longer reads them)
alter table public.web_pos_partners drop constraint web_pos_partners_commission_bps_check;
alter table public.web_pos_partners drop column commission_bps;
alter table public.tenant_settings drop column web_agent_bounty;
