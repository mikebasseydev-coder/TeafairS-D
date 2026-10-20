-- Spec D1 §5.2, §8.3, §8.4 — the public storefront RPCs become codeless,
-- routed and split-snapshotted, plus the locations and order-status reads.
-- All five public RPCs are service_role only: the public gateways call them.
-- The old quote_web_order / place_web_order signatures are dropped, not
-- overloaded.

-- ── internal: the code a storefront request runs under ──────────────────
-- Decision 1: a null or blank code is codeless and belongs to TEAFAIR. The
-- synthetic row carries only tenant_id: no id, agent, terminal or discount.
create function public.web_storefront_code(p_code text)
returns public.agent_codes
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes;
begin
  if nullif(btrim(p_code), '') is null then
    v_code.tenant_id := public.web_codeless_tenant();
    return v_code;
  end if;
  return public.web_resolve_code(p_code);
end;
$$;

-- ── internal: price a cart on the server ────────────────────────────────
-- Unchanged from A1 except the split (Decision 4): it applies only when the
-- partner's share is more than zero and less than the total.
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

  select s.split into v_split
    from (select jsonb_build_object('fintech_partner_id', fp.id,
                                    'subaccount_code', fp.paystack_subaccount_code,
                                    'commission_bps', fp.commission_bps,
                                    'partner_share', round(v_total * fp.commission_bps / 10000, 2)) as split
            from public.fintech_terminals ft
            join public.fintech_partners fp
              on fp.tenant_id = ft.tenant_id and fp.id = ft.partner_id and fp.status = 'ACTIVE'
           where ft.tenant_id = p_code.tenant_id and ft.id = p_code.terminal_id) s
   where (s.split ->> 'partner_share')::numeric > 0
     and (s.split ->> 'partner_share')::numeric < v_total;

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
create or replace function public.storefront_catalogue(p_code text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes := public.web_storefront_code(p_code);
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
-- Decision 5: an order nobody can ship is refused here, before Paystack.
drop function public.quote_web_order(text, jsonb);
create function public.quote_web_order(p_code text, p_items jsonb, p_lga_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes := public.web_storefront_code(p_code);
begin
  perform public.web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id);
  return public.web_price_cart(v_code, p_items);
end;
$$;

-- ── place_web_order ─────────────────────────────────────────────────────
-- A2's body with four changes: lga_id in the idempotency request, routing
-- through web_route_order, the split snapshot checked against the quote,
-- and the routing columns and split stamped on the rows.
drop function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb);
create function public.place_web_order(
  p_idempotency_key  uuid,
  p_code             text,
  p_items            jsonb,
  p_customer         jsonb,
  p_utm              jsonb,
  p_payment_route    text,
  p_expected_total   numeric,
  p_checkout         jsonb,
  p_lga_id           uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior       jsonb;
  v_code        public.agent_codes;
  v_cart        jsonb;
  v_total       numeric(15,2);
  v_name        text := nullif(btrim(p_customer ->> 'name'), '');
  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));
  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));
  v_address     text := nullif(btrim(p_customer ->> 'delivery_address'), '');
  v_terminal    public.fintech_terminals;
  v_route       public.web_route;  -- D1
  v_split       jsonb;             -- D1
  v_ref         text;
  v_order       public.orders;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total,
                       'lga_id', p_lga_id));  -- D1
  if v_prior is not null then
    return v_prior;
  end if;

  if p_payment_route is null or p_payment_route not in ('PAYSTACK_WEB', 'POS_AGENT') then
    raise exception 'payment route must be PAYSTACK_WEB or POS_AGENT' using errcode = 'P0001';
  end if;

  v_code := public.web_storefront_code(p_code);  -- D1: null or blank is codeless
  if p_payment_route = 'POS_AGENT' and v_code.terminal_id is null then
    raise exception 'paying at an agent needs a link from a POS agent' using errcode = 'P0001';
  end if;

  v_cart := public.web_price_cart(v_code, p_items);
  v_total := (v_cart ->> 'total')::numeric;
  if p_expected_total is distinct from v_total then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  if v_name is null then
    raise exception 'your name is required' using errcode = 'P0001';
  end if;
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'a valid phone number is required' using errcode = 'P0001';
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'the email address is not valid' using errcode = 'P0001';
  end if;
  if v_address is null then
    raise exception 'a delivery address is required' using errcode = 'P0001';
  end if;
  if p_payment_route = 'PAYSTACK_WEB' and (
       coalesce(p_checkout ->> 'reference', '') = '' or coalesce(p_checkout ->> 'authorization_url', '') = '') then
    raise exception 'checkout details are missing' using errcode = 'P0001';
  end if;

  -- D1 Decision 6: the split Paystack was initialised with must be this
  -- quote split, or both JSON null. A missing key is not JSON null.
  v_split := nullif(v_cart -> 'split', 'null'::jsonb);
  if p_payment_route = 'PAYSTACK_WEB' and (p_checkout -> 'split') is distinct from
       (case when v_split is null then 'null'::jsonb
             else jsonb_build_object('subaccount_code', v_split -> 'subaccount_code',
                                     'commission_bps',  v_split -> 'commission_bps',
                                     'partner_share',   v_split -> 'partner_share') end) then
    raise exception 'Prices changed — refresh and try again' using errcode = 'P0001';
  end if;

  -- A2: the phone now lives on order_contacts
  if (select count(*) from public.order_contacts c
        join public.orders o on o.id = c.order_id
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour'
         and o.channel = 'ONLINE' and o.status = 'PENDING') >= 5 then
    raise exception 'Too many unpaid orders for this phone number. Try again later.' using errcode = 'P0001';
  end if;

  -- D1 §4: territory, warehouse and accountable person, or a refusal
  v_route := public.web_route_order(v_code.tenant_id, case when v_code.id is null then null else v_code end, p_lga_id);
  if v_code.terminal_id is not null then
    select * into v_terminal from public.fintech_terminals
     where tenant_id = v_code.tenant_id and id = v_code.terminal_id;
  end if;

  -- TF- + 6 Crockford base-32 characters; 256 is a multiple of 32, so uniform
  loop
    v_ref := 'TF-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',
                                                 1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')
                         from generate_series(1, 6));
    exit when not exists (select 1 from public.orders where public_reference = v_ref);
  end loop;

  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, status,
                             agent_code_id, attributed_agent_id, attributed_terminal_id,
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference,
                             delivery_lga_id, territory_id, fulfilment_warehouse_id)
  values (v_code.tenant_id, 'ONLINE', v_route.accountable_id, v_total, (v_cart ->> 'discount')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.terminal_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref,
          p_lga_id, v_route.territory_id, v_route.warehouse_id)
  returning * into v_order;

  -- A2; D1: the contacts territory is the order territory
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address)
  values (v_order.id, v_order.tenant_id, v_route.territory_id, v_name, v_phone, v_email, v_address);

  insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
  select v_order.tenant_id, v_order.id, l ->> 'sku_code', (l ->> 'qty')::numeric, (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_cart -> 'lines') l;

  if p_payment_route = 'PAYSTACK_WEB' then
    insert into public.payments (tenant_id, order_id, teafair_agent_id, fintech_partner_id, fintech_terminal_id,
                                 amount, payment_status, paystack_reference, gateway_response_payload,
                                 split_subaccount_code, split_bps, split_amount)
    values (v_order.tenant_id, v_order.id, v_route.accountable_id, v_terminal.partner_id, v_code.terminal_id,
            v_total, 'INITIATED', p_checkout ->> 'reference',
            jsonb_build_object('checkout', jsonb_build_object(
              'access_code', p_checkout ->> 'access_code',
              'authorization_url', p_checkout ->> 'authorization_url')),
            v_split ->> 'subaccount_code', (v_split ->> 'commission_bps')::integer,
            (v_split ->> 'partner_share')::numeric);
  end if;

  -- A2: the audit log is readable by every ZSM and TM, so it gets a summary
  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null,
                             to_jsonb(v_order) || jsonb_build_object('contact', jsonb_build_object(
                               'phone_last4', right(v_phone, 4),
                               'has_email', v_email is not null,
                               'has_address', v_address is not null)),
                             p_idempotency_key, 'WEB', v_route.accountable_id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id,
    'public_reference', v_ref,
    'total', v_total,
    'currency', v_cart ->> 'currency',
    'payment_route', p_payment_route,
    'paystack_reference', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'reference' end,
    'authorization_url', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'authorization_url' end));
end;
$$;

-- ── storefront_locations (§8.3) ─────────────────────────────────────────
-- Every state and LGA, each LGA deliverable when §4 would route it for the
-- resolved tenant. One set-based pass over the 774 LGAs; names no
-- territory, warehouse or person.
create function public.storefront_locations(p_code text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_code  public.agent_codes := public.web_storefront_code(p_code);
  v_coded public.agent_codes;
begin
  if v_code.id is not null then
    v_coded := v_code;
  end if;
  return (
    with lga as (
      select l.state_code, l.id, l.name,
             (r.territory_id is not null and r.warehouse_id is not null and r.accountable_id is not null) as deliverable
        from public.ng_lgas l
        cross join lateral public.web_route_try(v_code.tenant_id, v_coded, l.id) r
    )
    select jsonb_build_object('states', jsonb_agg(jsonb_build_object(
             'code', s.code, 'name', s.name,
             'lgas', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'deliverable', g.deliverable)
                                       order by g.name)
                        from lga g where g.state_code = s.code))
           order by s.name))
      from public.ng_states s);
end;
$$;

-- ── web_order_status (§8.4) ─────────────────────────────────────────────
-- The pair must match one web order and its payment; anything else is null
-- (the gateway answers 404). No contact details, agent, territory or
-- warehouse. Read-only: never verifies, never settles.
create function public.web_order_status(p_public_reference text, p_paystack_reference text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'public_reference', o.public_reference,
           'order_status', o.status,
           'payment_status', p.payment_status,
           'total', o.total_amount,
           'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = o.tenant_id), 'NGN'),
           'lines', coalesce((
             select jsonb_agg(jsonb_build_object('name', cp.product_name, 'qty', trim_scale(oi.qty),
                                                 'unit_price', oi.unit_price) order by cp.product_name, oi.sku_code)
               from public.order_items oi
               join public.central_products cp on cp.tenant_id = oi.tenant_id and cp.sku_code = oi.sku_code
              where oi.tenant_id = o.tenant_id and oi.order_id = o.id), '[]'::jsonb))
    from public.orders o
    join public.payments p on p.tenant_id = o.tenant_id and p.order_id = o.id
                          and p.paystack_reference = p_paystack_reference
   where o.public_reference = upper(btrim(p_public_reference))
     and o.channel = 'ONLINE';
$$;

-- ── grants ──────────────────────────────────────────────────────────────
revoke execute on function public.web_storefront_code(text) from public, anon, authenticated, service_role;
revoke execute on function public.storefront_catalogue(text) from public, anon, authenticated;
revoke execute on function public.quote_web_order(text, jsonb, uuid) from public, anon, authenticated;
revoke execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb, uuid)
  from public, anon, authenticated;
revoke execute on function public.storefront_locations(text) from public, anon, authenticated;
revoke execute on function public.web_order_status(text, text) from public, anon, authenticated;
grant execute on function public.storefront_catalogue(text) to service_role;
grant execute on function public.quote_web_order(text, jsonb, uuid) to service_role;
grant execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb, uuid)
  to service_role;
grant execute on function public.storefront_locations(text) to service_role;
grant execute on function public.web_order_status(text, text) to service_role;
