-- Addendum A3 §4–5 — buyer RPCs for web chat and ticketing: open, read, post.
-- All three are service_role only (the public gateways call them). The two
-- internal helpers are executable by no API role.

-- ── web_find_order_by_pair (extracted from web_order_status) ────────────
-- The order whose public reference matches and which has a payment whose
-- Paystack reference matches (the gateway accepts the uuid in either case).
-- Any order status. A miss returns null, so callers test `.id is null`.
create or replace function public.web_find_order_by_pair(p_public_reference text, p_paystack_reference text)
returns public.orders
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select o.*
    from public.orders o
   where o.public_reference = upper(btrim(p_public_reference))
     and o.channel = 'ONLINE'
     and exists (select 1 from public.payments p
                  where p.tenant_id = o.tenant_id and p.order_id = o.id
                    and lower(p.paystack_reference) = lower(btrim(p_paystack_reference)))
   limit 1;
$$;
revoke all on function public.web_find_order_by_pair(text, text) from public, anon, authenticated, service_role;

-- ── web_order_status: same reply, now through the shared lookup ─────────
create or replace function public.web_order_status(p_public_reference text, p_paystack_reference text)
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
    from public.web_find_order_by_pair(p_public_reference, p_paystack_reference) o
    join public.payments p on p.tenant_id = o.tenant_id and p.order_id = o.id
                          and lower(p.paystack_reference) = lower(p_paystack_reference)
   where o.id is not null;
$$;

-- ── support_notify_activity ─────────────────────────────────────────────
-- Tell whoever holds the ticket: assigned_to, else accountable_id, else every
-- ZSM of the tenant. No message text, ever.
create or replace function public.support_notify_activity(p_ticket public.support_tickets)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_to      uuid := coalesce(p_ticket.assigned_to, p_ticket.accountable_id);
  v_payload jsonb := jsonb_build_object('ticket_id', p_ticket.id, 'public_reference', p_ticket.public_reference);
  v_body    text := 'Ticket ' || p_ticket.public_reference || ' needs a reply.';
begin
  if v_to is not null then
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    values (p_ticket.tenant_id, v_to, 'SUPPORT_TICKET_ACTIVITY', 'New support message', v_body, v_payload);
  else
    perform public.notify_tenant_zsms(p_ticket.tenant_id, 'SUPPORT_TICKET_ACTIVITY',
                                      'New support message', v_body, v_payload);
  end if;
end;
$$;
revoke all on function public.support_notify_activity(public.support_tickets)
  from public, anon, authenticated, service_role;

-- ── open_support_ticket (§4.1, §5) ──────────────────────────────────────
create or replace function public.open_support_ticket(
  p_idempotency_key        uuid,
  p_kind                   text,
  p_category               text,
  p_message                text,
  p_customer               jsonb,
  p_order_public_reference text,
  p_order_paystack_reference text,
  p_lga_id                 uuid,
  p_secret_hash            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior       jsonb;
  v_msg         text := btrim(coalesce(p_message, ''));
  v_name        text := nullif(btrim(p_customer ->> 'name'), '');
  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));
  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));
  v_has_order   boolean := p_order_public_reference is not null or p_order_paystack_reference is not null;
  v_order       public.orders;
  v_route       public.web_route;
  v_tenant      uuid;
  v_territory   uuid;
  v_accountable uuid;
  v_ref         text;
  v_prev        uuid;
  v_ticket      public.support_tickets;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'open_support_ticket',
    jsonb_build_object('kind', p_kind, 'category', p_category, 'message', p_message, 'customer', p_customer,
                       'order_public_reference', upper(btrim(coalesce(p_order_public_reference, ''))),
                       'order_paystack_reference', lower(btrim(coalesce(p_order_paystack_reference, ''))),
                       'lga_id', p_lga_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_kind is null or p_kind not in ('ORDER', 'PRE_PURCHASE') then
    raise exception 'kind must be ORDER or PRE_PURCHASE' using errcode = 'P0001';
  end if;
  if p_category is null or p_category not in ('PAYMENT', 'DELIVERY', 'ORDER_CHANGE', 'PRODUCT', 'OTHER') then
    raise exception 'category is not valid' using errcode = 'P0001';
  end if;
  if length(v_msg) not between 1 and 2000 then
    raise exception 'the message must be 1 to 2000 characters' using errcode = 'P0001';
  end if;
  if p_secret_hash is null or p_secret_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'secret hash is not valid' using errcode = 'P0001';
  end if;
  if v_has_order = (p_lga_id is not null) then
    raise exception 'give either an order or a delivery area' using errcode = 'P0001';
  end if;
  if (p_kind = 'ORDER') <> v_has_order then
    raise exception 'the ticket kind does not match what was given' using errcode = 'P0001';
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

  if p_kind = 'ORDER' then
    if p_order_public_reference is null or p_order_paystack_reference is null then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
    v_order := public.web_find_order_by_pair(p_order_public_reference, p_order_paystack_reference);
    if v_order.id is null then
      raise exception 'NOT_FOUND' using errcode = 'P0001';
    end if;
    -- serialise the per-order open-ticket count
    perform 1 from public.orders where id = v_order.id for update;
    v_tenant := v_order.tenant_id;
    v_territory := v_order.territory_id;
    v_accountable := v_order.teafair_agent_id;
    -- a follow-up links to the order's latest CLOSED ticket; its handler reads that history
    select t.id into v_prev
      from public.support_tickets t
     where t.tenant_id = v_tenant and t.order_id = v_order.id
       and t.kind = 'ORDER' and t.status = 'CLOSED'
     order by t.created_at desc, t.id desc
     limit 1;
  else
    if not exists (select 1 from public.ng_lgas where id = p_lga_id) then
      raise exception 'that delivery area is not valid' using errcode = 'P0001';
    end if;
    v_tenant := public.web_codeless_tenant();
    v_route := public.web_route_try(v_tenant, null, p_lga_id);
    if v_route.territory_id is not null and v_route.accountable_id is not null then
      v_territory := v_route.territory_id;
      v_accountable := v_route.accountable_id;
    else
      -- never refused for coverage: the default agent, else the ZSM queue
      v_territory := null;
      select tu.profile_id into v_accountable
        from public.tenant_settings s
        join public.tenant_users tu on tu.tenant_id = s.tenant_id and tu.profile_id = s.web_default_agent_id
                                   and tu.status = 'ACTIVE'
       where s.tenant_id = v_tenant;
    end if;
  end if;

  -- throttles count existing rows, after the replay check
  perform pg_advisory_xact_lock(hashtext('support_open:' || v_phone));
  if (select count(*) from public.support_ticket_contacts c
       where c.customer_phone = v_phone and c.created_at > now() - interval '1 hour') >= 3
     or (v_order.id is not null and (select count(*) from public.support_tickets t
                                      where t.tenant_id = v_tenant and t.order_id = v_order.id
                                        and t.status in ('OPEN', 'IN_PROGRESS')) >= 3) then
    raise exception 'Too many messages. Please wait a few minutes.' using errcode = 'P0001';
  end if;

  loop
    v_ref := public.new_crockford_reference('TK');
    exit when not exists (select 1 from public.support_tickets where public_reference = v_ref);
  end loop;

  insert into public.support_tickets (tenant_id, public_reference, kind, category, order_id, territory_id,
                                      accountable_id, previous_ticket_id, last_message_at)
  values (v_tenant, v_ref, p_kind, p_category, v_order.id, v_territory, v_accountable, v_prev, clock_timestamp())
  returning * into v_ticket;

  insert into public.support_ticket_secrets (ticket_id, tenant_id, secret_hash)
  values (v_ticket.id, v_ticket.tenant_id, p_secret_hash);

  insert into public.support_ticket_contacts (ticket_id, tenant_id, territory_id, customer_name,
                                              customer_phone, customer_email)
  values (v_ticket.id, v_ticket.tenant_id, v_ticket.territory_id, v_name, v_phone, v_email);

  insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body, created_at)
  values (v_ticket.tenant_id, v_ticket.id, 'CUSTOMER', v_ticket.territory_id, v_msg, clock_timestamp());

  perform public.support_notify_activity(v_ticket);

  perform public.write_audit(v_ticket.tenant_id, 'open_support_ticket', 'support_tickets', v_ticket.id::text,
                             null,
                             to_jsonb(v_ticket) || jsonb_build_object('phone_last4', right(v_phone, 4),
                                                                      'has_email', v_email is not null),
                             p_idempotency_key, 'WEB', v_accountable);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_ticket.id, 'public_reference', v_ticket.public_reference, 'status', v_ticket.status));
end;
$$;

-- ── read_support_ticket (§4.2) ──────────────────────────────────────────
-- A miss (unknown reference or wrong secret) is null; the gateway answers 404.
-- The stored value is sha256(secret): comparing digests leaks nothing about
-- the secret, so the equality needs no constant-time primitive.
create or replace function public.read_support_ticket(p_public_reference text, p_secret text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'public_reference', t.public_reference,
           'status', t.status,
           'category', t.category,
           'order_public_reference', (select o.public_reference from public.orders o
                                       where o.tenant_id = t.tenant_id and o.id = t.order_id),
           'messages', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'sender', case m.sender_type when 'CUSTOMER' then 'you' else 'teafair' end,
                      'body', m.body,
                      'created_at', m.created_at) order by m.created_at, m.id)
               from public.support_messages m
              where m.tenant_id = t.tenant_id and m.ticket_id = t.id), '[]'::jsonb))
    from public.support_tickets t
    join public.support_ticket_secrets s on s.tenant_id = t.tenant_id and s.ticket_id = t.id
   where t.public_reference = upper(btrim(p_public_reference))
     and s.secret_hash = encode(extensions.digest(coalesce(p_secret, ''), 'sha256'), 'hex');
$$;

-- ── add_ticket_message (§4.3) ───────────────────────────────────────────
-- Order of checks: the pair (miss → NOT_FOUND), then CLOSED, then the throttle.
create or replace function public.add_ticket_message(
  p_idempotency_key uuid,
  p_public_reference text,
  p_secret           text,
  p_message          text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior   jsonb;
  v_msg     text := btrim(coalesce(p_message, ''));
  v_ticket  public.support_tickets;
  v_msg_id  uuid;
  v_before  text;
begin
  -- the pair first: any miss is NOT_FOUND, replay included
  select t.* into v_ticket
    from public.support_tickets t
    join public.support_ticket_secrets s on s.tenant_id = t.tenant_id and s.ticket_id = t.id
   where t.public_reference = upper(btrim(p_public_reference))
     and s.secret_hash = encode(extensions.digest(coalesce(p_secret, ''), 'sha256'), 'hex')
     for update of t;
  if v_ticket.id is null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'add_ticket_message',
    jsonb_build_object('public_reference', upper(btrim(p_public_reference)), 'message', p_message));
  if v_prior is not null then
    return v_prior;
  end if;

  if length(v_msg) not between 1 and 2000 then
    raise exception 'the message must be 1 to 2000 characters' using errcode = 'P0001';
  end if;
  if v_ticket.status = 'CLOSED' then
    raise exception 'This conversation is closed. Open a new ticket if you still need help.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.support_messages m
       where m.ticket_id = v_ticket.id and m.sender_type = 'CUSTOMER'
         and m.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many messages. Please wait a few minutes.' using errcode = 'P0001';
  end if;

  v_before := v_ticket.status;
  insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body, created_at)
  values (v_ticket.tenant_id, v_ticket.id, 'CUSTOMER', v_ticket.territory_id, v_msg, clock_timestamp())
  returning id into v_msg_id;

  update public.support_tickets
     set status = case when status = 'RESOLVED' then 'OPEN' else status end,
         resolved_at = case when status = 'RESOLVED' then null else resolved_at end,
         last_message_at = clock_timestamp()
   where id = v_ticket.id
  returning * into v_ticket;

  perform public.support_notify_activity(v_ticket);

  perform public.write_audit(v_ticket.tenant_id, 'add_ticket_message', 'support_tickets', v_ticket.id::text,
                             jsonb_build_object('status', v_before),
                             jsonb_build_object('status', v_ticket.status, 'message_id', v_msg_id),
                             p_idempotency_key, 'WEB', v_ticket.accountable_id);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('message_id', v_msg_id, 'status', v_ticket.status));
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.open_support_ticket(uuid, text, text, text, jsonb, text, text, uuid, text)
  from public, anon, authenticated;
revoke all on function public.read_support_ticket(text, text) from public, anon, authenticated;
revoke all on function public.add_ticket_message(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.open_support_ticket(uuid, text, text, text, jsonb, text, text, uuid, text)
  to service_role;
grant execute on function public.read_support_ticket(text, text) to service_role;
grant execute on function public.add_ticket_message(uuid, text, text, text) to service_role;
