-- Addendum A2 §4.1 — place_web_order writes contact details to
-- order_contacts, stamps the accountable territory, and audits a redacted
-- summary instead of the details. Signature, grants and idempotency are
-- unchanged from A1 §4.2.
create or replace function public.place_web_order(
  p_idempotency_key  uuid,
  p_code             text,
  p_items            jsonb,
  p_customer         jsonb,
  p_utm              jsonb,
  p_payment_route    text,
  p_expected_total   numeric,
  p_checkout         jsonb
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
  v_agent       public.tenant_users;
  v_terminal    public.fintech_terminals;
  v_territory   uuid;  -- A2
  v_accountable uuid;
  v_ref         text;
  v_order       public.orders;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'place_web_order',
    jsonb_build_object('code', upper(btrim(coalesce(p_code, ''))), 'items', p_items,
                       'customer', p_customer, 'utm', p_utm,
                       'payment_route', p_payment_route, 'expected_total', p_expected_total));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_payment_route is null or p_payment_route not in ('PAYSTACK_WEB', 'POS_AGENT') then
    raise exception 'payment route must be PAYSTACK_WEB or POS_AGENT' using errcode = 'P0001';
  end if;

  v_code := public.web_resolve_code(p_code);
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

  -- A2: the phone now lives on order_contacts
  if (select count(*) from public.order_contacts c
        join public.orders o on o.id = c.order_id
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour'
         and o.channel = 'ONLINE' and o.status = 'PENDING') >= 5 then
    raise exception 'Too many unpaid orders for this phone number. Try again later.' using errcode = 'P0001';
  end if;

  -- the accountable Teafair agent (Spec A §6.10): a staff code holder is
  -- their own; otherwise the TM of the terminal's (or the agent's) territory
  select * into v_agent from public.tenant_users
   where tenant_id = v_code.tenant_id and profile_id = v_code.agent_id and status = 'ACTIVE';
  if v_code.terminal_id is not null then
    select * into v_terminal from public.fintech_terminals
     where tenant_id = v_code.tenant_id and id = v_code.terminal_id;
  end if;
  v_territory := coalesce(v_terminal.territory_id, v_agent.territory_id);  -- A2
  if v_agent.role in ('DSA', 'DSM', 'ASM', 'TM', 'ZSM') then
    v_accountable := v_agent.profile_id;
  else
    select t.tm_id into v_accountable from public.territories t
     where t.tenant_id = v_code.tenant_id and t.id = v_territory;
  end if;
  if v_accountable is null then
    raise exception 'This link is not active yet' using errcode = 'P0001';
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
                             utm_source, utm_medium, utm_campaign, payment_route, public_reference)
  values (v_code.tenant_id, 'ONLINE', v_accountable, v_total, (v_cart ->> 'discount')::numeric, 'PENDING',
          v_code.id, v_code.agent_id, v_code.terminal_id,
          left(nullif(btrim(p_utm ->> 'source'), ''), 100),
          left(nullif(btrim(p_utm ->> 'medium'), ''), 100),
          left(nullif(btrim(p_utm ->> 'campaign'), ''), 100),
          p_payment_route, v_ref)
  returning * into v_order;

  -- A2
  insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone,
                                     customer_email, delivery_address)
  values (v_order.id, v_order.tenant_id, v_territory, v_name, v_phone, v_email, v_address);

  insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price)
  select v_order.tenant_id, v_order.id, l ->> 'sku_code', (l ->> 'qty')::numeric, (l ->> 'unit_price')::numeric
    from jsonb_array_elements(v_cart -> 'lines') l;

  if p_payment_route = 'PAYSTACK_WEB' then
    insert into public.payments (tenant_id, order_id, teafair_agent_id, fintech_partner_id, fintech_terminal_id,
                                 amount, payment_status, paystack_reference, gateway_response_payload)
    values (v_order.tenant_id, v_order.id, v_accountable, v_terminal.partner_id, v_code.terminal_id,
            v_total, 'INITIATED', p_checkout ->> 'reference',
            jsonb_build_object('checkout', jsonb_build_object(
              'access_code', p_checkout ->> 'access_code',
              'authorization_url', p_checkout ->> 'authorization_url')));
  end if;

  -- A2: the audit log is readable by every ZSM and TM, so it gets a summary
  perform public.write_audit(v_order.tenant_id, 'place_web_order', 'orders', v_order.id::text,
                             null,
                             to_jsonb(v_order) || jsonb_build_object('contact', jsonb_build_object(
                               'phone_last4', right(v_phone, 4),
                               'has_email', v_email is not null,
                               'has_address', v_address is not null)),
                             p_idempotency_key, 'WEB', v_accountable);

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

revoke execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb)
  from public, anon, authenticated;
grant execute on function public.place_web_order(uuid, text, jsonb, jsonb, jsonb, text, numeric, jsonb)
  to service_role;
