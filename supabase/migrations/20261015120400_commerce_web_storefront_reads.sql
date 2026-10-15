-- Addendum A1 §4.2 — the public reads. The public gateways call them as
-- service_role; the app and anon cannot. The agent code alone decides the
-- tenant (A1 decision 2), and no agent PII is ever returned.

-- ── internal: resolve a code, or refuse with one message ────────────────
-- Every reason (unknown, inactive, expired, agent gone, terminal off, used
-- up) gives the same message, so a link reveals nothing about why.
create or replace function public.web_resolve_code(p_code text)
returns public.agent_codes
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes;
begin
  select ac.* into v_code
    from public.agent_codes ac
    join public.tenants t on t.id = ac.tenant_id and t.status = 'ACTIVE'
    join public.tenant_users tu
      on tu.tenant_id = ac.tenant_id and tu.profile_id = ac.agent_id and tu.status = 'ACTIVE'
    left join public.fintech_terminals ft on ft.tenant_id = ac.tenant_id and ft.id = ac.terminal_id
   where ac.code = upper(btrim(coalesce(p_code, '')))
     and ac.is_active
     and (ac.expires_at is null or ac.expires_at > now())
     and (ac.terminal_id is null or ft.is_active)
     and (ac.max_redemptions is null or (
           select count(*) from public.orders o
            where o.tenant_id = ac.tenant_id and o.agent_code_id = ac.id
              and o.status in ('PAID', 'IN_TRANSIT', 'DELIVERED')) < ac.max_redemptions);
  if not found then
    raise exception 'This link is no longer valid' using errcode = 'P0001';
  end if;
  return v_code;
end;
$$;

-- ── internal: price a cart on the server ────────────────────────────────
-- Items: 1–50 distinct active SKUs of the code's tenant, whole quantities
-- 1–1000, priced at central_products.unit_price. The discount is capped at
-- the subtotal and the total must stay above zero. A split applies when the
-- code's terminal belongs to an ACTIVE partner (A1 decision 9).
create or replace function public.web_price_cart(p_code public.agent_codes, p_items jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_count    integer;
  v_matched  integer;
  v_lines    jsonb;
  v_subtotal numeric(15,2);
  v_discount numeric(15,2);
  v_total    numeric(15,2);
  v_split    jsonb;
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

  v_discount := case p_code.discount_type
                  when 'PERCENT' then round(v_subtotal * p_code.discount_value / 100, 2)
                  when 'FIXED'   then p_code.discount_value
                  else 0
                end;
  v_discount := least(v_discount, v_subtotal);
  v_total := v_subtotal - v_discount;
  if v_total <= 0 then
    raise exception 'the order total must be more than zero' using errcode = 'P0001';
  end if;

  select jsonb_build_object('fintech_partner_id', fp.id,
                            'subaccount_code', fp.paystack_subaccount_code,
                            'commission_bps', fp.commission_bps,
                            'partner_share', round(v_total * fp.commission_bps / 10000, 2))
    into v_split
    from public.fintech_terminals ft
    join public.fintech_partners fp
      on fp.tenant_id = ft.tenant_id and fp.id = ft.partner_id and fp.status = 'ACTIVE'
   where ft.tenant_id = p_code.tenant_id and ft.id = p_code.terminal_id;

  return jsonb_build_object(
    'lines', v_lines,
    'subtotal', v_subtotal,
    'discount', v_discount,
    'total', v_total,
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = p_code.tenant_id), 'NGN'),
    'split', v_split);
end;
$$;

-- ── storefront_catalogue ────────────────────────────────────────────────
create or replace function public.storefront_catalogue(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes := public.web_resolve_code(p_code);
begin
  return jsonb_build_object(
    'code', v_code.code,
    'tenant', (select jsonb_build_object('name', t.name, 'logo_url', t.logo_url)
                 from public.tenants t where t.id = v_code.tenant_id),
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_code.tenant_id), 'NGN'),
    'discount', case when v_code.discount_type is null then null
                     else jsonb_build_object('type', v_code.discount_type, 'value', v_code.discount_value) end,
    'venue', (select case when ft.venue_name is null then null
                          else jsonb_build_object('name', ft.venue_name, 'channel', ft.venue_channel) end
                from public.fintech_terminals ft
               where ft.tenant_id = v_code.tenant_id and ft.id = v_code.terminal_id),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', p.sku_code, 'product_name', p.product_name, 'brand', p.brand,
               'category', p.category, 'unit_price', p.unit_price, 'description', p.description)
             order by p.brand, p.product_name)
        from public.central_products p
       where p.tenant_id = v_code.tenant_id and p.is_active), '[]'::jsonb));
end;
$$;

-- ── quote_web_order ─────────────────────────────────────────────────────
create or replace function public.quote_web_order(p_code text, p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  return public.web_price_cart(public.web_resolve_code(p_code), p_items);
end;
$$;

revoke execute on function public.web_resolve_code(text) from public, anon, authenticated, service_role;
revoke execute on function public.web_price_cart(public.agent_codes, jsonb) from public, anon, authenticated, service_role;
revoke execute on function public.storefront_catalogue(text) from public, anon, authenticated;
revoke execute on function public.quote_web_order(text, jsonb) from public, anon, authenticated;
grant execute on function public.storefront_catalogue(text) to service_role;
grant execute on function public.quote_web_order(text, jsonb) to service_role;
