-- Transport fare on web orders (user decision 2026-10-24).
--
-- A flat fare per web order, set per tenant: TEAFAIR 750, every other tenant
-- 0 until set. It is added after any discount and is never discounted. The
-- payment partner's commission is cut from the goods only, so the fare stays
-- in the merchant's main Paystack account. Refunds: the fare is refunded only
-- when an order is cancelled before dispatch or never delivered (policy text).
-- Set by migration only, like the other platform settings.

alter table public.tenant_settings
  add column web_transport_fare numeric(15,2) not null default 0 check (web_transport_fare >= 0);
update public.tenant_settings set web_transport_fare = 750
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001';

alter table public.orders
  add column transport_fare numeric(15,2) not null default 0 check (transport_fare >= 0),
  add constraint orders_transport_fare_web_only check (channel = 'ONLINE' or transport_fare = 0),
  add constraint orders_transport_fare_within_total check (transport_fare <= total_amount);

-- ── web_price_cart: the D1 body; the fare is added after the split ───────
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
$$;

-- ── place_web_order: the A5 body; the order records its fare ───────────
create or replace function public.place_web_order(
  p_idempotency_key  uuid,
  p_code             text,
  p_items            jsonb,
  p_customer         jsonb,
  p_utm              jsonb,
  p_payment_route    text,
  p_expected_total   numeric,
  p_checkout         jsonb,
  p_lga_id           uuid,
  p_accepted_refund_policy   boolean,  -- A5 §3.6
  p_policy_version_tag       text,     -- A5 §3.3
  p_client_ip                inet,     -- A5 §3.3
  p_phone_verification_token text      -- A5 §3.5
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
  v_policy      public.refund_policies;          -- A5
  v_verif       public.web_phone_verifications;  -- A5
  v_now         timestamptz := now();
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total,
                       'lga_id', p_lga_id));  -- D1
  -- A5: the verification token and the client IP are left out of the request
  -- hash on purpose (as A3 leaves out its secret): a replay carries a token
  -- that is already consumed, and neither belongs in idempotency_logs.
  if v_prior is not null then
    return v_prior;  -- a replay keeps the original order and its original consent
  end if;

  -- A5 §3.6, §3.3: consent first, then the policy it was given against
  if p_accepted_refund_policy is distinct from true then
    raise exception 'You must accept the refund policy to place an order.' using errcode = 'P0001';
  end if;
  select * into v_policy from public.refund_policies where is_active;
  if not found or p_policy_version_tag is distinct from v_policy.version_tag then
    raise exception 'The refund policy has changed. Please review it and try again.' using errcode = 'P0001';
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

  -- A5 §3.1: every line must be in a category the active policy covers
  if exists (select 1 from jsonb_array_elements(v_cart -> 'lines') l
               join public.central_products cp
                 on cp.tenant_id = v_code.tenant_id and cp.sku_code = l ->> 'sku_code'
              where not public.web_category_sellable(cp.sale_category)) then
    raise exception 'This product is not available to order yet.' using errcode = 'P0001';
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

  -- A5 §3.5: the buyer proved this number on WhatsApp. The token is bound to
  -- the phone, single use and short lived; the row is locked and consumed.
  select * into v_verif from public.web_phone_verifications
   where token_hash = encode(extensions.digest(coalesce(p_phone_verification_token, ''), 'sha256'), 'hex')
     and verified_at is not null and consumed_at is null
     and token_expires_at > v_now and phone = v_phone
   for update;
  if not found then
    raise exception 'Please verify your WhatsApp number again.' using errcode = 'P0001';
  end if;
  update public.web_phone_verifications set consumed_at = v_now where id = v_verif.id;

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

  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, transport_fare, status,
                             agent_code_id, attributed_agent_id, attributed_terminal_id,
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference,
                             delivery_lga_id, territory_id, fulfilment_warehouse_id,
                             policy_version_tag, policy_accepted_at)
  values (v_code.tenant_id, 'ONLINE', v_route.accountable_id, v_total, (v_cart ->> 'discount')::numeric,
          (v_cart ->> 'transport_fare')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.terminal_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref,
          p_lga_id, v_route.territory_id, v_route.warehouse_id,
          v_policy.version_tag, v_now)
  returning * into v_order;

  -- A2; D1: the contacts territory is the order territory
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address,
                                     consent_ip, phone_verified_at, phone_verified_channel)
  values (v_order.id, v_order.tenant_id, v_route.territory_id, v_name, v_phone, v_email, v_address,
          p_client_ip, v_verif.verified_at, 'WHATSAPP');  -- A5: the IP lives on A2's table only

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
                               'has_address', v_address is not null),
                               -- A5: the consent and the fact of verification, never the IP
                               'policy_version_tag', v_order.policy_version_tag,
                               'policy_accepted_at', v_order.policy_accepted_at,
                               'phone_verified', true),
                             p_idempotency_key, 'WEB', v_route.accountable_id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id,
    'public_reference', v_ref,
    'total', v_total,
    'transport_fare', (v_cart ->> 'transport_fare')::numeric,
    'currency', v_cart ->> 'currency',
    'payment_route', p_payment_route,
    'paystack_reference', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'reference' end,
    'authorization_url', case when p_payment_route = 'PAYSTACK_WEB' then p_checkout ->> 'authorization_url' end));
end;
$$;

-- ── storefront_catalogue: the A5 body; shows the fare up front ─────────
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
       where p.tenant_id = v_code.tenant_id and p.is_active
         and public.web_category_sellable(p.sale_category)), '[]'::jsonb),
    'transport_fare', coalesce((select s.web_transport_fare from public.tenant_settings s
                                 where s.tenant_id = v_code.tenant_id), 0),
    'refund_policy', (select jsonb_build_object('version_tag', rp.version_tag)
                        from public.refund_policies rp where rp.is_active),
    'refund_notes', coalesce((
      select jsonb_object_agg(c, case c
               when 'FOOD' then 'Opened food items can''t be refunded. Report transit damage within 24 hours of delivery with photos.'
               when 'COSMETICS' then 'Opened or used cosmetics can''t be refunded. Patch-test before first use. Report damage or leaks within 24 hours of delivery with photos.'
             end)
        from public.refund_policies rp, unnest(rp.categories) as c
       where rp.is_active and c in ('FOOD', 'COSMETICS')), '{}'::jsonb));
end;
$$;

-- ── dispute evidence: the bundle with NAFDAC facts and the fare ────────
create or replace function public.get_order_dispute_evidence(p_order_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_order  public.orders;
  v_policy public.refund_policies;
  v_bundle jsonb;
begin
  -- a missing order and another tenant's order get the same answer
  select * into v_order from public.orders o where o.id = p_order_id;
  if not found or v_order.tenant_id <> v_me.tenant_id then
    raise exception 'not permitted to view the evidence for this order' using errcode = '42501';
  end if;

  select * into v_policy from public.refund_policies rp where rp.version_tag = v_order.policy_version_tag;

  v_bundle := jsonb_build_object(
    'order', jsonb_build_object(
      'order_id', v_order.id,
      'public_reference', v_order.public_reference,
      'channel', v_order.channel,
      'status', v_order.status,
      'payment_route', v_order.payment_route,
      'total_amount', v_order.total_amount,
      'transport_fare', v_order.transport_fare,
      'created_at', v_order.created_at),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', i.sku_code,
               'sale_category', cp.sale_category,
               'nafdac_regulated', cp.sale_category in ('FOOD', 'COSMETICS'),
               'nafdac_number', cp.nafdac_number,
               'qty', i.qty,
               'unit_price', i.unit_price,
               'line_total', i.line_total) order by i.sku_code)
        from public.order_items i
        join public.central_products cp on cp.tenant_id = i.tenant_id and cp.sku_code = i.sku_code
       where i.tenant_id = v_order.tenant_id and i.order_id = v_order.id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'payment_id', p.id,
               'paystack_reference', p.paystack_reference,
               'amount', p.amount,
               'payment_status', p.payment_status,
               'created_at', p.created_at,
               'settlement', (select jsonb_build_object('status', c.status, 'settled_at', c.settled_at)
                                from public.commission_records c
                               where c.tenant_id = p.tenant_id and c.payment_id = p.id))
             order by p.created_at, p.id)
        from public.payments p
       where p.tenant_id = v_order.tenant_id and p.order_id = v_order.id), '[]'::jsonb),
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'payment_id', a.entity_id,
               'refund_id', a.after ->> 'refund_id',
               'kind', case a.operation when 'PARTIAL_REFUND' then 'PARTIAL' else 'FULL' end,
               'reason', a.after ->> 'reason',
               'amount_minor', (a.after ->> 'amount_minor')::bigint,
               'currency', a.after ->> 'currency',
               'recorded_at', a.created_at) order by a.created_at, a.id)
        from public.audit_logs a
       where a.tenant_id = v_order.tenant_id
         and a.entity_type = 'payments'
         and a.operation in ('apply_paystack_refund', 'PARTIAL_REFUND')
         and a.entity_id in (select p.id::text from public.payments p
                              where p.tenant_id = v_order.tenant_id and p.order_id = v_order.id)), '[]'::jsonb),
    'consent', jsonb_build_object(
      'policy_version_tag', v_order.policy_version_tag,
      'policy_accepted_at', v_order.policy_accepted_at,
      'consent_ip', (select host(c.consent_ip) from public.order_contacts c
                      where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id),
      'policy_title', v_policy.title,
      'content', v_policy.content),
    'contact', (select jsonb_build_object(
                  'customer_name', c.customer_name,
                  'customer_phone', c.customer_phone,
                  'customer_email', c.customer_email,
                  'delivery_address', c.delivery_address,
                  'phone_verified_at', c.phone_verified_at,
                  'phone_verified_channel', c.phone_verified_channel)
                  from public.order_contacts c
                 where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id),
    'fulfilment', (select jsonb_build_object(
                     'dispatched_at', f.dispatched_at,
                     'tracking_reference', f.tracking_reference,
                     'delivered_at', f.delivered_at,
                     'delivered_via', f.delivered_via,
                     'damage_claim_deadline', f.damage_claim_deadline,
                     -- a delivery is recorded only after the right code
                     'pin_verified', f.delivered_at is not null,
                     'delivery_photo', case when f.delivery_photo_path is null then null
                                            else jsonb_build_object('bucket', 'delivery-proofs',
                                                                    'storage_path', f.delivery_photo_path) end)
                     from public.order_fulfilments f
                    where f.tenant_id = v_order.tenant_id and f.order_id = v_order.id),
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ticket_id', t.id,
               'public_reference', t.public_reference,
               'kind', t.kind,
               'category', t.category,
               'status', t.status,
               'within_damage_window', t.within_damage_window,
               'created_at', t.created_at,
               'messages', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'sender_type', m.sender_type,
                          'body', m.body,
                          'created_at', m.created_at,
                          'attachments', coalesce((
                            select jsonb_agg(jsonb_build_object(
                                     'attachment_id', u.id,
                                     'mime_type', u.mime_type,
                                     'size_bytes', u.size_bytes,
                                     'bucket', u.bucket,
                                     'storage_path', u.storage_path) order by u.claimed_at, u.id)
                              from public.upload_slots u
                             where u.tenant_id = m.tenant_id and u.ticket_id = m.ticket_id
                               and u.message_id = m.id), '[]'::jsonb))
                        order by m.created_at, m.id)
                   from public.support_messages m
                  where m.tenant_id = t.tenant_id and m.ticket_id = t.id), '[]'::jsonb))
             order by t.created_at, t.id)
        from public.support_tickets t
       where t.tenant_id = v_order.tenant_id and t.order_id = v_order.id), '[]'::jsonb));

  perform public.write_audit(v_order.tenant_id, 'DISPUTE_EVIDENCE_VIEWED', 'orders', v_order.id::text,
                             null, jsonb_build_object('order_id', v_order.id), null);
  return v_bundle;
end;
$$;
revoke all on function public.get_order_dispute_evidence(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_order_dispute_evidence(uuid) to authenticated;
