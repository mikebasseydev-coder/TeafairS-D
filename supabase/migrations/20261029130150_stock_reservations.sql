-- Addendum A6 §18.1 (Monvelo Step 2, Task 6b; user rulings 2026-10-30) — stock
-- is reserved when an order is placed (web and trade), deducted when it is
-- dispatched, and released when it is cancelled or refunded before dispatch.
-- Unpaid web orders, and cash trade orders still PENDING at the end of their
-- supply day, are cancelled by the stock-reservation-sweep. Goods that come back
-- after dispatch are restored by record_order_return, citing the order.
--
-- inventory_batches.quantity_reserved (user directive 2026-10-30) is the stored
-- sum of the batch's RESERVED stock_reservations rows; available stock is
-- quantity - quantity_reserved. Every path that opens, consumes or releases a
-- reservation moves both in the same transaction, with the batch rows locked.
-- Every stock change has evidence (§18.1): a contact-report decision (receipt,
-- transfer, adjustment) or the order itself (sale dispatch, return).

-- ── inventory_batches.quantity_reserved ─────────────────────────────────
alter table public.inventory_batches
  add column quantity_reserved numeric(14,3) not null default 0,
  add constraint inventory_batches_reserved_within_quantity
    check (quantity_reserved >= 0 and quantity_reserved <= quantity),
  add constraint inventory_batches_tenant_id_id_key unique (tenant_id, id);
-- the composite FK target for stock_reservations.order_item_id
alter table public.order_items
  add constraint order_items_tenant_id_id_key unique (tenant_id, id);

-- ── stock_movements: the two order kinds ────────────────────────────────
alter table public.stock_movements drop constraint stock_movements_kind_check;
alter table public.stock_movements
  add constraint stock_movements_kind_check
    check (kind in ('RECEIPT', 'TRANSFER', 'ADJUSTMENT', 'SALE_DISPATCH', 'ORDER_RETURN'));
alter table public.stock_movements alter column decision_id drop not null;
alter table public.stock_movements add column order_id uuid;
alter table public.stock_movements
  add constraint stock_movements_order_fkey
    foreign key (tenant_id, order_id) references public.orders (tenant_id, id) on delete restrict,
  -- a sale or return cites its order and no decision; the CSM and LM kinds cite a decision
  add constraint stock_movements_evidence
    check ((kind in ('SALE_DISPATCH', 'ORDER_RETURN')) = (order_id is not null and decision_id is null)),
  add constraint stock_movements_decision_kinds
    check (kind in ('SALE_DISPATCH', 'ORDER_RETURN') or (decision_id is not null and order_id is null));
create index idx_stock_movements_order on public.stock_movements (tenant_id, order_id);

-- ── tenant_settings.web_reservation_hours (set by migration only) ───────
alter table public.tenant_settings
  add column web_reservation_hours integer not null default 24
    check (web_reservation_hours between 1 and 720);
grant select (web_reservation_hours) on public.tenant_settings to authenticated;

-- ── stock_reservations ──────────────────────────────────────────────────
create table public.stock_reservations (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  order_id      uuid not null,
  order_item_id uuid not null,
  warehouse_id  uuid not null,
  batch_id      uuid not null,
  sku_code      text not null,
  quantity      numeric(14,3) not null check (quantity > 0),
  status        text not null default 'RESERVED' check (status in ('RESERVED', 'CONSUMED', 'RELEASED')),
  expires_at    timestamptz,
  created_at    timestamptz not null default now(),
  closed_at     timestamptz,
  close_reason  text,
  unique (tenant_id, id),
  check ((status = 'RESERVED') = (closed_at is null)),
  check ((status = 'RESERVED') = (close_reason is null)),
  foreign key (tenant_id, order_id)      references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, order_item_id) references public.order_items (tenant_id, id) on delete restrict,
  foreign key (tenant_id, warehouse_id)  references public.warehouses (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id)      references public.inventory_batches (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sku_code)      references public.central_products (tenant_id, sku_code) on delete restrict
);
create index idx_stock_reservations_order      on public.stock_reservations (tenant_id, order_id);
create index idx_stock_reservations_order_item on public.stock_reservations (tenant_id, order_item_id);
create index idx_stock_reservations_warehouse  on public.stock_reservations (tenant_id, warehouse_id);
create index idx_stock_reservations_batch      on public.stock_reservations (tenant_id, batch_id);
create index idx_stock_reservations_sku        on public.stock_reservations (tenant_id, sku_code);
create index idx_stock_reservations_open_batch on public.stock_reservations (batch_id) where status = 'RESERVED';
create index idx_stock_reservations_open_expiry on public.stock_reservations (expires_at) where status = 'RESERVED';

-- rows are never deleted; a RESERVED row closes once, as CONSUMED or RELEASED
create or replace function public.stock_reservations_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op <> 'UPDATE' then
    raise exception 'stock reservations are never deleted' using errcode = 'P0001';
  end if;
  if old.status <> 'RESERVED' or new.status not in ('CONSUMED', 'RELEASED') then
    raise exception 'a reservation closes once, from RESERVED to CONSUMED or RELEASED' using errcode = 'P0001';
  end if;
  if (new.id, new.tenant_id, new.order_id, new.order_item_id, new.warehouse_id, new.batch_id, new.sku_code,
      new.quantity, new.expires_at, new.created_at)
     is distinct from
     (old.id, old.tenant_id, old.order_id, old.order_item_id, old.warehouse_id, old.batch_id, old.sku_code,
      old.quantity, old.expires_at, old.created_at) then
    raise exception 'only the status of a reservation changes' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.stock_reservations_guard() from public, anon, authenticated, service_role;
create trigger stock_reservations_guard before update or delete on public.stock_reservations
  for each row execute function public.stock_reservations_guard();
create trigger stock_reservations_no_truncate before truncate on public.stock_reservations
  for each statement execute function public.stock_reservations_guard();

alter table public.stock_reservations enable row level security;
revoke all on public.stock_reservations from anon, authenticated, service_role;
grant select on public.stock_reservations to authenticated;
create policy stock_reservations_select on public.stock_reservations for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── internal: reserve, consume, release (the operational stock writers) ─
-- Each is called only inside an order transition (placement, dispatch,
-- cancel, refund); their evidence is the order. None has an API grant.

-- Reserve every line of the order from its fulfilment warehouse, first expiry
-- first out across the SKU's unexpired batches. Not enough is TF001 with
-- {sku_code, available, requested}, and the caller's transaction rolls back.
create or replace function public.stock_reserve_order(p_order public.orders, p_expires_at timestamptz)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item  record;
  v_batch record;
  v_avail numeric(14,3);
  v_left  numeric(14,3);
  v_take  numeric(14,3);
  v_rows  integer := 0;
begin
  if p_order.fulfilment_warehouse_id is null then
    raise exception 'this order has no fulfilment warehouse' using errcode = 'P0001';
  end if;

  -- every batch the order may draw on is locked, in id order, before any is
  -- read: concurrent placements queue here and cannot over-reserve
  perform 1 from public.inventory_batches b
   where b.tenant_id = p_order.tenant_id and b.warehouse_id = p_order.fulfilment_warehouse_id
     and b.sku_code in (select i.sku_code from public.order_items i
                         where i.tenant_id = p_order.tenant_id and i.order_id = p_order.id)
   order by b.id
     for update;

  for v_item in
    select i.id, i.sku_code, i.qty from public.order_items i
     where i.tenant_id = p_order.tenant_id and i.order_id = p_order.id
     order by i.sku_code
  loop
    select coalesce(sum(b.quantity - b.quantity_reserved), 0) into v_avail
      from public.inventory_batches b
     where b.tenant_id = p_order.tenant_id and b.warehouse_id = p_order.fulfilment_warehouse_id
       and b.sku_code = v_item.sku_code and (b.expires_at is null or b.expires_at > now());
    if v_avail < v_item.qty then
      perform public.stock_insufficient(v_item.sku_code, v_avail, v_item.qty);
    end if;

    v_left := v_item.qty;
    for v_batch in
      select b.id, b.quantity - b.quantity_reserved as avail
        from public.inventory_batches b
       where b.tenant_id = p_order.tenant_id and b.warehouse_id = p_order.fulfilment_warehouse_id
         and b.sku_code = v_item.sku_code and (b.expires_at is null or b.expires_at > now())
         and b.quantity > b.quantity_reserved
       order by b.expires_at nulls last, b.created_at, b.id
    loop
      exit when v_left <= 0;
      v_take := least(v_left, v_batch.avail);
      update public.inventory_batches set quantity_reserved = quantity_reserved + v_take where id = v_batch.id;
      insert into public.stock_reservations (tenant_id, order_id, order_item_id, warehouse_id, batch_id, sku_code,
                                             quantity, expires_at)
      values (p_order.tenant_id, p_order.id, v_item.id, p_order.fulfilment_warehouse_id, v_batch.id, v_item.sku_code,
              v_take, p_expires_at);
      v_left := v_left - v_take;
      v_rows := v_rows + 1;
    end loop;
  end loop;
  return v_rows;
end;
$$;
revoke all on function public.stock_reserve_order(public.orders, timestamptz) from public, anon, authenticated, service_role;

-- Consume the order's open reservations at dispatch: quantity and
-- quantity_reserved fall together, one SALE_DISPATCH movement per batch.
create or replace function public.stock_consume_order(p_order public.orders, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_line  record;
  v_batch public.inventory_batches;
  v_mov   uuid;
  v_out   jsonb := '[]'::jsonb;
begin
  if not exists (select 1 from public.stock_reservations r
                  where r.tenant_id = p_order.tenant_id and r.order_id = p_order.id and r.status = 'RESERVED') then
    raise exception 'this order has no stock reserved; reserve it first' using errcode = 'P0001';
  end if;

  perform 1 from public.inventory_batches b
   where b.id in (select r.batch_id from public.stock_reservations r
                   where r.tenant_id = p_order.tenant_id and r.order_id = p_order.id and r.status = 'RESERVED')
   order by b.id
     for update;

  for v_line in
    select r.batch_id, sum(r.quantity) as qty from public.stock_reservations r
     where r.tenant_id = p_order.tenant_id and r.order_id = p_order.id and r.status = 'RESERVED'
     group by r.batch_id
     order by r.batch_id
  loop
    update public.inventory_batches
       set quantity = quantity - v_line.qty, quantity_reserved = quantity_reserved - v_line.qty
     where id = v_line.batch_id
    returning * into v_batch;
    insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, order_id, recorded_by)
    values (p_order.tenant_id, 'SALE_DISPATCH', v_batch.warehouse_id, v_batch.sku_code, v_batch.batch_number, v_line.qty,
            p_order.id, p_actor)
    returning id into v_mov;
    v_out := v_out || jsonb_build_object('movement_id', v_mov, 'batch_id', v_batch.id, 'sku_code', v_batch.sku_code,
                                         'quantity', v_line.qty);
  end loop;

  update public.stock_reservations
     set status = 'CONSUMED', closed_at = now(), close_reason = 'IN_TRANSIT'
   where tenant_id = p_order.tenant_id and order_id = p_order.id and status = 'RESERVED';
  return v_out;
end;
$$;
revoke all on function public.stock_consume_order(public.orders, uuid) from public, anon, authenticated, service_role;

-- Release the order's open reservations (cancelled, or refunded before
-- dispatch). After dispatch there are none, so it changes nothing.
create or replace function public.stock_release_order(p_tenant_id uuid, p_order_id uuid, p_reason text)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_line record;
  v_rows integer;
begin
  if p_reason is null or p_reason not in ('CANCELLED', 'REFUNDED') then
    raise exception 'a reservation is released only when its order is CANCELLED or REFUNDED' using errcode = 'P0001';
  end if;

  perform 1 from public.inventory_batches b
   where b.id in (select r.batch_id from public.stock_reservations r
                   where r.tenant_id = p_tenant_id and r.order_id = p_order_id and r.status = 'RESERVED')
   order by b.id
     for update;

  for v_line in
    select r.batch_id, sum(r.quantity) as qty from public.stock_reservations r
     where r.tenant_id = p_tenant_id and r.order_id = p_order_id and r.status = 'RESERVED'
     group by r.batch_id
     order by r.batch_id
  loop
    update public.inventory_batches set quantity_reserved = quantity_reserved - v_line.qty where id = v_line.batch_id;
  end loop;

  update public.stock_reservations
     set status = 'RELEASED', closed_at = now(), close_reason = p_reason
   where tenant_id = p_tenant_id and order_id = p_order_id and status = 'RESERVED';
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;
revoke all on function public.stock_release_order(uuid, uuid, text) from public, anon, authenticated, service_role;

-- ── recreated from their live definitions (signatures and grants unchanged) ─
-- place_web_order (Task 1f), place_trade_order (Task 6), mark_order_dispatched
-- (Task 1e), apply_paystack_refund (D1, §15 renames); each change is marked
-- "Task 6b".

CREATE OR REPLACE FUNCTION public.place_web_order(p_idempotency_key uuid, p_code text, p_items jsonb, p_customer jsonb, p_utm jsonb, p_payment_route text, p_expected_total numeric, p_checkout jsonb, p_lga_id uuid, p_accepted_refund_policy boolean, p_policy_version_tag text, p_client_ip inet, p_phone_verification_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

declare

  v_prior       jsonb;

  v_code        public.web_referral_codes;

  v_cart        jsonb;

  v_total       numeric(15,2);

  v_name        text := nullif(btrim(p_customer ->> 'name'), '');

  v_phone       text := btrim(coalesce(p_customer ->> 'phone', ''));

  v_email       text := lower(nullif(btrim(p_customer ->> 'email'), ''));

  v_address     text := nullif(btrim(p_customer ->> 'delivery_address'), '');

  v_terminal    public.web_pos_venues;

  v_route       public.web_route;  -- D1

  v_split       jsonb;             -- D1

  v_ref         text;

  v_order       public.orders;

  v_policy      public.refund_policies;          -- A5

  v_verif       public.web_phone_verifications;  -- A5

  v_now         timestamptz := now();

  v_state_code  text;

  v_state_name  text;

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

  if p_payment_route = 'POS_AGENT' and v_code.venue_id is null then

    raise exception 'paying at an agent needs a link from a POS agent' using errcode = 'P0001';

  end if;



  -- A6 §18.4: new web orders only where the platform and the brand are both switched on

  select s.code, s.name into v_state_code, v_state_name

    from public.ng_lgas l join public.ng_states s on s.code = l.state_code

   where l.id = p_lga_id;

  if found and not public.tenant_state_web_operational(v_code.tenant_id, v_state_code) then

    raise exception 'we do not deliver to % yet', v_state_name using errcode = 'P0001';

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

  if v_code.venue_id is not null then

    select * into v_terminal from public.web_pos_venues

     where tenant_id = v_code.tenant_id and id = v_code.venue_id;

  end if;



  -- TF- + 6 Crockford base-32 characters; 256 is a multiple of 32, so uniform

  loop

    v_ref := 'TF-' || (select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ',

                                                 1 + get_byte(extensions.gen_random_bytes(1), 0) % 32, 1), '')

                         from generate_series(1, 6));

    exit when not exists (select 1 from public.orders where public_reference = v_ref);

  end loop;



  insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, discount_amount, transport_fare, status,

                             referral_code_id, attributed_agent_id, attributed_venue_id,

                             utm_source, utm_medium, utm_campaign, payment_route, public_reference,

                             delivery_lga_id, territory_id, fulfilment_warehouse_id,

                             policy_version_tag, policy_accepted_at)

  values (v_code.tenant_id, 'ONLINE', v_route.accountable_id, v_total, (v_cart ->> 'discount')::numeric,

          (v_cart ->> 'transport_fare')::numeric, 'PENDING',

          v_code.id, v_code.agent_id, v_code.venue_id,

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

  -- A6 §18.1 (Task 6b): every line is reserved now, first expiry first out, or
  -- the order is refused (TF001); unpaid, it lapses after web_reservation_hours
  perform public.stock_reserve_order(v_order, v_now + make_interval(hours => coalesce(
    (select s.web_reservation_hours from public.tenant_settings s where s.tenant_id = v_order.tenant_id), 24)));



  if p_payment_route = 'PAYSTACK_WEB' then

    insert into public.payments (tenant_id, order_id, teafair_agent_id, web_pos_partner_id, web_pos_venue_id,

                                 amount, payment_status, paystack_reference, gateway_response_payload,

                                 split_subaccount_code, split_bps, split_amount)

    values (v_order.tenant_id, v_order.id, v_route.accountable_id, v_terminal.partner_id, v_code.venue_id,

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

$function$;

CREATE OR REPLACE FUNCTION public.place_trade_order(p_idempotency_key uuid, p_shop_id uuid, p_lines jsonb, p_territory_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- A6 §18.1 (Task 6b): reserved at placement, financed or not (financing
  -- approval finds the reservation in place); a cash order still PENDING at the
  -- end of its Lagos supply day is cancelled and released by the sweep
  perform public.stock_reserve_order(v_order,
    ((now() at time zone 'Africa/Lagos')::date + 1)::timestamp at time zone 'Africa/Lagos');

  perform public.write_audit(v_me.tenant_id, 'place_trade_order', 'orders', v_order.id::text,
    null,
    to_jsonb(v_order) - 'customer_name' - 'customer_phone'
      || jsonb_build_object('lines', p_lines),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id, 'total_amount', v_order.total_amount,
    'territory_id', v_terr, 'warehouse_id', v_wh));
end;
$function$;

CREATE OR REPLACE FUNCTION public.mark_order_dispatched(p_idempotency_key uuid, p_order_id uuid, p_tracking_reference text, p_pin text, p_gateway_proof text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

declare

  v_me    public.tenant_users := public.assert_tenant_role(null);

  v_prior jsonb;

  v_order public.orders;

  v_track text := nullif(btrim(coalesce(p_tracking_reference, '')), '');

  v_reply jsonb;
  v_stock jsonb;

begin

  perform public.assert_gateway_proof(p_gateway_proof);

  -- neither the PIN nor the proof is part of the stored request

  v_prior := public.idempotency_begin(p_idempotency_key, 'mark_order_dispatched',

    jsonb_build_object('order_id', p_order_id, 'tracking_reference', v_track));

  if v_prior is not null then

    return v_prior;

  end if;



  v_order := public.fulfilment_lock_order(v_me, p_order_id);

  if not public.fulfilment_can_dispatch(v_me, v_order) then

    raise exception 'not permitted to dispatch this order' using errcode = '42501';

  end if;

  if v_order.channel <> 'ONLINE' or v_order.status <> 'PAID' then

    raise exception 'only paid web orders can be dispatched' using errcode = 'P0001';

  end if;

  if p_pin is null or p_pin !~ '^[0-9]{4}$' then

    raise exception 'the delivery code must be 4 digits' using errcode = 'P0001';

  end if;

  if length(v_track) > 100 then

    raise exception 'the tracking reference must be at most 100 characters' using errcode = 'P0001';

  end if;



  -- A6 §18.1 (Task 6b): the reservations are consumed and the stock deducted
  -- now; an order with nothing reserved is refused, never dispatched silently
  v_stock := public.stock_consume_order(v_order, v_me.profile_id);

  insert into public.order_fulfilments (order_id, tenant_id, dispatched_by, tracking_reference, delivery_pin_hash)

  values (v_order.id, v_order.tenant_id, v_me.profile_id, v_track,

          extensions.crypt(p_pin, extensions.gen_salt('bf')));

  update public.orders set status = 'IN_TRANSIT' where id = v_order.id;



  perform public.write_audit(v_order.tenant_id, 'mark_order_dispatched', 'orders', v_order.id::text,

                             jsonb_build_object('status', v_order.status),

                             jsonb_build_object('order_id', v_order.id, 'status', 'IN_TRANSIT',

                                                'has_tracking', v_track is not null,
                                                'stock', v_stock),

                             p_idempotency_key);



  v_reply := jsonb_build_object('order_id', v_order.id, 'status', 'IN_TRANSIT',

                                'public_reference', v_order.public_reference);

  perform public.idempotency_complete(p_idempotency_key, v_reply);

  -- for the gateway, this call only

  return v_reply || jsonb_build_object('buyer_phone',

    (select c.customer_phone from public.order_contacts c where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id));

end;

$function$;

CREATE OR REPLACE FUNCTION public.apply_paystack_refund(p_source text, p_refund_id text, p_transaction_reference text, p_amount_minor bigint, p_currency text, p_reason text, p_verified jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_key       uuid;
  v_source    public.audit_source_enum;
  v_request   jsonb;
  v_matches   integer;
  v_payment   public.payments;
  v_order     public.orders;
  v_currency  text;
  v_paid      bigint;
  v_conflict  text;
  v_prior     jsonb;
  v_order_out text;
  v_comm      record;
  v_released  integer;
begin
  -- p_verified is accepted for the gateway contract but never stored: it can
  -- carry the customer's contact details (CLAUDE.md, addendum A2)
  if p_source is null or p_source not in ('webhook', 'sweep') then
    raise exception 'p_source must be webhook or sweep' using errcode = 'P0001';
  end if;
  if p_reason is null or p_reason not in ('REFUND', 'REVERSAL') then
    raise exception 'p_reason must be REFUND or REVERSAL' using errcode = 'P0001';
  end if;
  if p_refund_id is null or btrim(p_refund_id) = '' then
    raise exception 'p_refund_id is required' using errcode = 'P0001';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'p_amount_minor must be positive' using errcode = 'P0001';
  end if;

  v_key    := md5('paystack-refund:' || p_refund_id)::uuid;
  v_source := case when p_source = 'sweep' then 'CRON' else 'WEBHOOK' end;
  -- the refund itself, not who delivered it: the webhook and the refund pass
  -- may both deliver one refund, and the second must replay the first reply
  v_request := jsonb_build_object('refund_id', p_refund_id, 'reference', p_transaction_reference,
                                  'amount_minor', p_amount_minor, 'currency', p_currency, 'reason', p_reason);

  select count(*) into v_matches from public.payments where paystack_reference = p_transaction_reference;
  if v_matches <> 1 then
    -- zero or several payments: no single payment to refund. The key is taken
    -- (payment rows exist before their charge, so a retry cannot help).
    v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    perform public.write_audit(null, 'REFUND_CONFLICT', 'payments', p_transaction_reference, null,
      jsonb_build_object('reason', 'unknown_reference', 'refund_id', p_refund_id,
                         'reference', p_transaction_reference, 'matches', v_matches,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source);
    return public.idempotency_complete(v_key,
      jsonb_build_object('outcome', 'conflict', 'reason', 'unknown_reference'));
  end if;

  -- payment row first (§6.2 lock order), held across the status check so a
  -- concurrent settle cannot slip between the check and the key
  select * into v_payment from public.payments where paystack_reference = p_transaction_reference for update;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') and p_reason = 'REVERSAL' then
    -- the charge was reversed before Teafair recorded it: the money is gone,
    -- so the payment is REFUNDED and the order is left as it is (never PAID)
    v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
    if v_prior is not null then
      return v_prior;
    end if;
    v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
    v_paid     := (v_payment.amount * 100)::bigint;
    v_conflict := case
                    when p_currency is distinct from v_currency then 'currency_mismatch'
                    when p_amount_minor <> v_paid then 'amount_mismatch'
                  end;
    if v_conflict is not null then
      perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
        jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
        jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id,
                           'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
        v_key, v_source, v_payment.teafair_agent_id);
      return public.idempotency_complete(v_key, jsonb_build_object(
        'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
        'payment_status', v_payment.payment_status));
    end if;

    update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
      'order_status', (select o.status from public.orders o
                        where o.tenant_id = v_payment.tenant_id and o.id = v_payment.order_id),
      'reason', p_reason));
  end if;

  if v_payment.payment_status in ('INITIATED', 'PROCESSING', 'FAILED') then
    -- Decision 2 (REFUND only): no key, so the daily refund pass re-applies it after settle
    perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status),
      jsonb_build_object('reason', 'payment_not_success', 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      null, v_source, v_payment.teafair_agent_id);
    return jsonb_build_object('outcome', 'conflict', 'reason', 'payment_not_success',
                              'payment_id', v_payment.id, 'payment_status', v_payment.payment_status);
  end if;

  v_prior := public.idempotency_begin(v_key, 'apply_paystack_refund', v_request);
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_order from public.orders
   where tenant_id = v_payment.tenant_id and id = v_payment.order_id for update;
  v_currency := coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_payment.tenant_id), 'NGN');
  v_paid     := (v_payment.amount * 100)::bigint;

  v_conflict := case
                  -- REFUNDED is final: no later charge can make it SUCCESS
                  -- again, so this conflict takes its key
                  when v_payment.payment_status <> 'SUCCESS' then 'payment_not_success'
                  when p_currency is distinct from v_currency then 'currency_mismatch'
                  when p_amount_minor > v_paid then 'over_refund'
                end;
  if v_conflict is not null then
    perform public.write_audit(v_payment.tenant_id, 'REFUND_CONFLICT', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid, 'currency', v_currency),
      jsonb_build_object('reason', v_conflict, 'refund_id', p_refund_id,
                         'amount_minor', p_amount_minor, 'currency', p_currency, 'refund_reason', p_reason),
      v_key, v_source, v_payment.teafair_agent_id);
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'conflict', 'reason', v_conflict, 'payment_id', v_payment.id,
      'payment_status', v_payment.payment_status));
  end if;

  -- ── partial refund: no status change, the ZSMs are told ───────────────
  if p_amount_minor < v_paid then
    perform public.write_audit(v_payment.tenant_id, 'PARTIAL_REFUND', 'payments', v_payment.id::text,
      jsonb_build_object('payment_status', v_payment.payment_status, 'amount_minor', v_paid),
      jsonb_build_object('refund_id', p_refund_id, 'reason', p_reason,
                         'amount_minor', p_amount_minor, 'currency', p_currency),
      v_key, v_source, v_payment.teafair_agent_id);
    perform public.notify_tenant_zsms(v_payment.tenant_id, 'PAYMENT_PARTIALLY_REFUNDED', 'Partial refund',
      'Order ' || coalesce(v_order.public_reference, v_order.id::text) || ' was partly refunded ('
        || to_char(p_amount_minor / 100.0, 'FM999999999999990.00') || ' ' || p_currency || ').',
      jsonb_build_object('order_id', v_order.id, 'payment_id', v_payment.id,
                         'public_reference', v_order.public_reference,
                         'amount_minor', p_amount_minor, 'currency', p_currency));
    return public.idempotency_complete(v_key, jsonb_build_object(
      'outcome', 'partial', 'payment_id', v_payment.id, 'payment_status', v_payment.payment_status,
      'amount_minor', p_amount_minor));
  end if;

  -- ── full refund or reversal ───────────────────────────────────────────
  -- gateway_response_payload keeps the verified charge; the refund payload is
  -- not stored
  update public.payments set payment_status = 'REFUNDED' where id = v_payment.id;
  perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'payments', v_payment.id::text,
    jsonb_build_object('payment_status', v_payment.payment_status),
    jsonb_build_object('payment_status', 'REFUNDED', 'reason', p_reason, 'refund_id', p_refund_id,
                       'amount_minor', p_amount_minor, 'currency', p_currency),
    v_key, v_source, v_payment.teafair_agent_id);

  -- the order, ONLINE only (field-order transitions are Spec C / D2), and
  -- only once it was paid; any other status is left as it is
  v_order_out := v_order.status;
  if v_order.channel = 'ONLINE' and v_order.status in ('PAID', 'IN_TRANSIT', 'DELIVERED') then
    update public.orders set status = 'REFUNDED' where id = v_order.id;
    v_order_out := 'REFUNDED';
    -- A6 §18.1 (Task 6b): refunded before dispatch, the reservation is released;
    -- after dispatch nothing is RESERVED, so nothing changes
    v_released := public.stock_release_order(v_order.tenant_id, v_order.id, 'REFUNDED');
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'orders', v_order.id::text,
      jsonb_build_object('status', v_order.status),
      jsonb_build_object('status', 'REFUNDED', 'payment_id', v_payment.id, 'reason', p_reason,
                         'refund_id', p_refund_id, 'reservations_released', v_released),
      v_key, v_source, v_payment.teafair_agent_id);
  end if;

  -- Paystack does not claw the share back from the subaccount: the commission
  -- becomes DISPUTED and recovery is recorded work for D3
  for v_comm in
    update public.web_commissions c
       set status = 'DISPUTED', dispute_reason = 'ORDER_REFUNDED'
      from public.web_commissions old
     where c.id = old.id
       and c.tenant_id = v_payment.tenant_id and c.payment_id = v_payment.id
       and c.status in ('SPLIT', 'SETTLED')
    returning c.id, c.order_id, old.status as old_status
  loop
    perform public.write_audit(v_payment.tenant_id, 'apply_paystack_refund', 'web_commissions', v_comm.id::text,
      jsonb_build_object('status', v_comm.old_status),
      jsonb_build_object('status', 'DISPUTED', 'dispute_reason', 'ORDER_REFUNDED', 'payment_id', v_payment.id,
                         'refund_id', p_refund_id),
      v_key, v_source, v_payment.teafair_agent_id);
    perform public.notify_tenant_zsms(v_payment.tenant_id, 'COMMISSION_DISPUTED', 'Commission disputed',
      'A partner commission needs review (ORDER_REFUNDED).',
      jsonb_build_object('commission_id', v_comm.id, 'order_id', v_comm.order_id, 'reason', 'ORDER_REFUNDED'));
  end loop;

  return public.idempotency_complete(v_key, jsonb_build_object(
    'outcome', 'refunded', 'payment_id', v_payment.id, 'payment_status', 'REFUNDED',
    'order_status', v_order_out, 'reason', p_reason));
end;
$function$;

-- ── the CSM / LM stock RPCs respect reservations (Task 4, recreated) ────
-- A transfer or a negative adjustment can take only what is not reserved:
-- TF001 with available = quantity - quantity_reserved.
create or replace function public.record_stock_transfer(
  p_idempotency_key uuid, p_decision_id uuid, p_from_warehouse_id uuid, p_to_warehouse_id uuid,
  p_sku_code text, p_batch_number text, p_quantity numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(
              array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_src_id  uuid;
  v_src     public.inventory_batches;
  v_dst     public.inventory_batches;
  v_src_new public.inventory_batches;
  v_dst_new public.inventory_batches;
  v_mov     uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_stock_transfer',
    jsonb_build_object('decision_id', p_decision_id, 'from', p_from_warehouse_id, 'to', p_to_warehouse_id,
                       'sku_code', p_sku_code, 'batch_number', p_batch_number, 'quantity', p_quantity));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'quantity must be greater than zero' using errcode = 'P0001';
  end if;
  if p_from_warehouse_id is not distinct from p_to_warehouse_id then
    raise exception 'a transfer needs two different warehouses' using errcode = 'P0001';
  end if;
  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this stock movement' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'STOCK');
  perform public.stock_assert_warehouse(v_me.tenant_id, p_from_warehouse_id);
  perform public.stock_assert_warehouse(v_me.tenant_id, p_to_warehouse_id);
  perform public.stock_assert_sku(v_me.tenant_id, p_sku_code, p_batch_number);

  select id into v_src_id from public.inventory_batches
   where warehouse_id = p_from_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number;
  if v_src_id is null then
    perform public.stock_insufficient(p_sku_code, 0, p_quantity);
  end if;

  -- the destination batch exists before both rows are locked, in id order
  insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity, expires_at)
  select v_me.tenant_id, p_to_warehouse_id, p_sku_code, p_batch_number, 0, s.expires_at
    from public.inventory_batches s where s.id = v_src_id
  on conflict (warehouse_id, sku_code, batch_number) do nothing;

  perform 1 from public.inventory_batches
   where warehouse_id in (p_from_warehouse_id, p_to_warehouse_id) and sku_code = p_sku_code and batch_number = p_batch_number
   order by id for update;

  select * into v_src from public.inventory_batches where id = v_src_id;
  select * into v_dst from public.inventory_batches
   where warehouse_id = p_to_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number;

  -- A6 §18.1 (Task 6b): reserved stock is held for its orders
  if v_src.quantity - v_src.quantity_reserved < p_quantity then
    perform public.stock_insufficient(p_sku_code, v_src.quantity - v_src.quantity_reserved, p_quantity);
  end if;
  if v_src.expires_at is not null and v_dst.expires_at is not null and v_src.expires_at <> v_dst.expires_at then
    raise exception 'this batch already has a different expiry' using errcode = 'P0001';
  end if;

  update public.inventory_batches set quantity = quantity - p_quantity where id = v_src.id returning * into v_src_new;
  update public.inventory_batches set quantity = quantity + p_quantity, expires_at = coalesce(expires_at, v_src.expires_at)
   where id = v_dst.id returning * into v_dst_new;

  insert into public.stock_movements (tenant_id, kind, warehouse_id, to_warehouse_id, sku_code, batch_number, quantity,
                                      decision_id, recorded_by)
  values (v_me.tenant_id, 'TRANSFER', p_from_warehouse_id, p_to_warehouse_id, p_sku_code, p_batch_number, p_quantity,
          p_decision_id, v_me.profile_id)
  returning id into v_mov;

  perform public.write_audit(v_me.tenant_id, 'record_stock_transfer', 'stock_movements', v_mov::text,
                             jsonb_build_object('from', to_jsonb(v_src), 'to', to_jsonb(v_dst)),
                             jsonb_build_object('from', to_jsonb(v_src_new), 'to', to_jsonb(v_dst_new)),
                             p_idempotency_key);

  -- batch_id and quantity are the source batch; the destination is added alongside
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('movement_id', v_mov, 'batch_id', v_src_new.id, 'quantity', v_src_new.quantity,
                       'to_batch_id', v_dst_new.id, 'to_quantity', v_dst_new.quantity));
end;
$$;
revoke all on function public.record_stock_transfer(uuid, uuid, uuid, uuid, text, text, numeric) from public, anon, authenticated, service_role;
grant execute on function public.record_stock_transfer(uuid, uuid, uuid, uuid, text, text, numeric) to authenticated, service_role;

create or replace function public.record_stock_adjustment(
  p_idempotency_key uuid, p_decision_id uuid, p_warehouse_id uuid, p_sku_code text,
  p_batch_number text, p_quantity_delta numeric, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(
             array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.inventory_batches;
  v_batch  public.inventory_batches;
  v_mov    uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_stock_adjustment',
    jsonb_build_object('decision_id', p_decision_id, 'warehouse_id', p_warehouse_id, 'sku_code', p_sku_code,
                       'batch_number', p_batch_number, 'quantity_delta', p_quantity_delta, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'an adjustment must change the quantity' using errcode = 'P0001';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'a reason is required for an adjustment' using errcode = 'P0001';
  end if;
  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this stock movement' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'STOCK');
  perform public.stock_assert_warehouse(v_me.tenant_id, p_warehouse_id);
  perform public.stock_assert_sku(v_me.tenant_id, p_sku_code, p_batch_number);

  if p_quantity_delta > 0 then
    insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
    values (v_me.tenant_id, p_warehouse_id, p_sku_code, p_batch_number, 0)
    on conflict (warehouse_id, sku_code, batch_number) do nothing;
  end if;

  select * into v_before from public.inventory_batches
   where warehouse_id = p_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number for update;
  if not found then
    perform public.stock_insufficient(p_sku_code, 0, -p_quantity_delta);
  end if;
  -- A6 §18.1 (Task 6b): a batch never goes below its reserved quantity
  if v_before.quantity - v_before.quantity_reserved + p_quantity_delta < 0 then
    perform public.stock_insufficient(p_sku_code, v_before.quantity - v_before.quantity_reserved, -p_quantity_delta);
  end if;

  update public.inventory_batches set quantity = quantity + p_quantity_delta where id = v_before.id returning * into v_batch;

  insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, reason,
                                      decision_id, recorded_by)
  values (v_me.tenant_id, 'ADJUSTMENT', p_warehouse_id, p_sku_code, p_batch_number, p_quantity_delta, btrim(p_reason),
          p_decision_id, v_me.profile_id)
  returning id into v_mov;

  perform public.write_audit(v_me.tenant_id, 'record_stock_adjustment', 'stock_movements', v_mov::text,
                             to_jsonb(v_before), to_jsonb(v_batch), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('movement_id', v_mov, 'batch_id', v_batch.id, 'quantity', v_batch.quantity));
end;
$$;
revoke all on function public.record_stock_adjustment(uuid, uuid, uuid, text, text, numeric, text) from public, anon, authenticated, service_role;
grant execute on function public.record_stock_adjustment(uuid, uuid, uuid, text, text, numeric, text) to authenticated, service_role;

-- ── the sweep: unpaid web orders and unfinished cash trade orders ───────
-- A PENDING order whose open reservation has expired is cancelled and its stock
-- released: an ONLINE order web_reservation_hours after placement, a trade
-- order at the end of its (Lagos) supply day. An order with a SUCCESS payment
-- is never touched; a payment landing after the cancel is settle's
-- PAID_AFTER_CANCEL path (the ZSMs refund or reinstate it).
create or replace function public.stock_reservation_sweep()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders;
  v_rel   integer;
  v_count integer := 0;
begin
  for v_order in
    select o.* from public.orders o
     where o.status = 'PENDING'
       and exists (select 1 from public.stock_reservations r
                    where r.tenant_id = o.tenant_id and r.order_id = o.id
                      and r.status = 'RESERVED' and r.expires_at <= now())
       and not exists (select 1 from public.payments p
                        where p.tenant_id = o.tenant_id and p.order_id = o.id and p.payment_status = 'SUCCESS')
     order by o.id
       for update of o skip locked
  loop
    update public.orders set status = 'CANCELLED' where id = v_order.id;
    v_rel := public.stock_release_order(v_order.tenant_id, v_order.id, 'CANCELLED');
    perform public.write_audit(v_order.tenant_id, 'stock_reservation_sweep', 'orders', v_order.id::text,
      jsonb_build_object('status', v_order.status),
      jsonb_build_object('status', 'CANCELLED', 'reason', 'RESERVATION_EXPIRED', 'channel', v_order.channel,
                         'reservations_released', v_rel),
      null, 'CRON', v_order.teafair_agent_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.stock_reservation_sweep() from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('stock-reservation-sweep', '*/15 * * * *',
  $$select public.stock_reservation_sweep()$$);

-- ── record_order_return: goods back after dispatch ──────────────────────
-- The LM or CSM restores goods that came back (a failed delivery, a Monvelo
-- REFUND_DUE). The evidence is the order: each line goes back to the batches
-- it was dispatched from, first expiry first, never more than was dispatched.
create or replace function public.record_order_return(p_idempotency_key uuid, p_order_id uuid, p_lines jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(
             array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_order  public.orders;
  v_el     jsonb;
  v_sku    text;
  v_qty    numeric;
  v_skus   text[] := '{}';
  v_out    numeric(14,3);
  v_left   numeric(14,3);
  v_take   numeric(14,3);
  v_src    record;
  v_batch  public.inventory_batches;
  v_mov    uuid;
  v_moves  jsonb := '[]'::jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_order_return',
    jsonb_build_object('order_id', p_order_id, 'lines', p_lines));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_order from public.orders o
   where o.id = p_order_id and o.tenant_id = v_me.tenant_id
     for update;
  if not found then
    raise exception 'order not found in this tenant' using errcode = '42501';
  end if;
  if not exists (select 1 from public.stock_reservations r
                  where r.tenant_id = v_order.tenant_id and r.order_id = v_order.id and r.status = 'CONSUMED') then
    raise exception 'this order has not been dispatched' using errcode = 'P0001';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) not between 1 and 50 then
    raise exception 'a return has 1 to 50 lines' using errcode = 'P0001';
  end if;

  -- the batches the order was dispatched from, locked in id order
  perform 1 from public.inventory_batches b
   where b.id in (select r.batch_id from public.stock_reservations r
                   where r.tenant_id = v_order.tenant_id and r.order_id = v_order.id and r.status = 'CONSUMED')
   order by b.id
     for update;

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
    v_skus := v_skus || v_sku;

    -- dispatched less already returned, per batch
    select coalesce(sum(x.outstanding), 0) into v_out
      from (select r.batch_id,
                   sum(r.quantity) - coalesce((select sum(m.quantity) from public.stock_movements m
                                                join public.inventory_batches b2 on b2.id = r.batch_id
                                               where m.tenant_id = v_order.tenant_id and m.order_id = v_order.id
                                                 and m.kind = 'ORDER_RETURN' and m.warehouse_id = b2.warehouse_id
                                                 and m.sku_code = b2.sku_code and m.batch_number = b2.batch_number), 0)
                     as outstanding
              from public.stock_reservations r
             where r.tenant_id = v_order.tenant_id and r.order_id = v_order.id
               and r.status = 'CONSUMED' and r.sku_code = v_sku
             group by r.batch_id) x;
    if v_qty > v_out then
      raise exception 'you cannot return more % than was dispatched (% left to return)', v_sku, trim_scale(v_out)
        using errcode = 'P0001';
    end if;

    v_left := v_qty;
    for v_src in
      select b.id,
             sum(r.quantity) - coalesce((select sum(m.quantity) from public.stock_movements m
                                          where m.tenant_id = v_order.tenant_id and m.order_id = v_order.id
                                            and m.kind = 'ORDER_RETURN' and m.warehouse_id = b.warehouse_id
                                            and m.sku_code = b.sku_code and m.batch_number = b.batch_number), 0)
               as outstanding
        from public.stock_reservations r
        join public.inventory_batches b on b.id = r.batch_id
       where r.tenant_id = v_order.tenant_id and r.order_id = v_order.id
         and r.status = 'CONSUMED' and r.sku_code = v_sku
       group by b.id, b.warehouse_id, b.sku_code, b.batch_number, b.expires_at, b.created_at
       order by b.expires_at nulls last, b.created_at, b.id
    loop
      exit when v_left <= 0;
      continue when v_src.outstanding <= 0;
      v_take := least(v_left, v_src.outstanding);
      update public.inventory_batches set quantity = quantity + v_take where id = v_src.id
      returning * into v_batch;
      insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, order_id, recorded_by)
      values (v_order.tenant_id, 'ORDER_RETURN', v_batch.warehouse_id, v_batch.sku_code, v_batch.batch_number, v_take,
              v_order.id, v_me.profile_id)
      returning id into v_mov;
      v_moves := v_moves || jsonb_build_object('movement_id', v_mov, 'batch_id', v_batch.id, 'sku_code', v_sku,
                                               'quantity', v_take);
      v_left := v_left - v_take;
    end loop;
  end loop;

  perform public.write_audit(v_me.tenant_id, 'record_order_return', 'orders', v_order.id::text,
    jsonb_build_object('status', v_order.status),
    jsonb_build_object('order_id', v_order.id, 'status', v_order.status, 'returned', v_moves),
    p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('order_id', v_order.id, 'movements', v_moves));
end;
$$;
revoke all on function public.record_order_return(uuid, uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.record_order_return(uuid, uuid, jsonb) to authenticated, service_role;
