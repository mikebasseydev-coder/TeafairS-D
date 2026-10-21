-- Addendum A3 §9 — system tickets from D1 exceptions.
--
-- D1 is not edited. Its exceptions are already recorded as rows, so the
-- tickets are raised by triggers on those rows, inside the same transaction:
--   audit_logs      PAID_AFTER_CANCEL, LATE_SUCCESS
--   commission_records   -> DISPUTED (settle, refund, release, expire)
-- Bodies are built from ids, amounts, reasons and references only; never
-- from p_verified or contact data.

-- ── raise_system_ticket (internal) ──────────────────────────────────────
-- At most one ticket per system_key. A repeat adds a SYSTEM message to the
-- existing ticket instead. Returns the ticket id.
create or replace function public.raise_system_ticket(
  p_system_key text,
  p_order_id   uuid,
  p_body       text,
  p_priority   text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order  public.orders;
  v_id     uuid;
  v_ref    text;
  v_now    timestamptz := clock_timestamp();
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'raise_system_ticket: unknown order %', p_order_id using errcode = 'P0001';
  end if;

  loop
    v_ref := public.new_crockford_reference('TK');
    exit when not exists (select 1 from public.support_tickets where public_reference = v_ref);
  end loop;

  insert into public.support_tickets (tenant_id, public_reference, kind, category, order_id, territory_id,
                                      accountable_id, priority, system_key, last_message_at)
  values (v_order.tenant_id, v_ref, 'SYSTEM', 'SYSTEM', v_order.id, v_order.territory_id,
          null, p_priority, p_system_key, v_now)
  on conflict (system_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- already raised: the new fact joins the existing thread
    select id into v_id from public.support_tickets where system_key = p_system_key;
    update public.support_tickets set last_message_at = v_now where id = v_id;
  end if;

  insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body, created_at)
  select t.tenant_id, t.id, 'SYSTEM', t.territory_id, p_body, v_now
    from public.support_tickets t where t.id = v_id;

  return v_id;
end;
$$;
revoke all on function public.raise_system_ticket(text, uuid, text, text)
  from public, anon, authenticated, service_role;

-- ── a commission turning DISPUTED ───────────────────────────────────────
create or replace function public.support_ticket_on_commission_disputed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.raise_system_ticket(
    'COMMISSION_DISPUTED:' || new.id,
    new.order_id,
    'Commission ' || new.id || ' disputed (' || coalesce(new.dispute_reason, 'UNKNOWN') || '): '
      || new.amount || ' on payment ' || new.payment_id || '.',
    'HIGH');
  return new;
end;
$$;
revoke all on function public.support_ticket_on_commission_disputed()
  from public, anon, authenticated, service_role;

-- WHEN cannot reference tg_op, so the two events are two triggers on one function
create trigger commission_records_support_ticket_ins
  after insert on public.commission_records
  for each row
  when (new.status = 'DISPUTED')
  execute function public.support_ticket_on_commission_disputed();
create trigger commission_records_support_ticket_upd
  after update of status on public.commission_records
  for each row
  when (new.status = 'DISPUTED' and old.status is distinct from 'DISPUTED')
  execute function public.support_ticket_on_commission_disputed();

-- ── PAID_AFTER_CANCEL / LATE_SUCCESS ────────────────────────────────────
-- LATE_SUCCESS is audited on the payment (entity_id = payment id).
-- PAID_AFTER_CANCEL is audited on the order (entity_id = order id) with the
-- payment id in the after-image. Either way the key carries the payment id.
create or replace function public.support_ticket_on_payment_exception()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment_id uuid;
  v_payment    public.payments;
  v_order      public.orders;
begin
  v_payment_id := case when new.entity_type = 'payments' then new.entity_id::uuid
                       else (new.after ->> 'payment_id')::uuid end;
  select * into v_payment from public.payments where id = v_payment_id;
  if not found then
    return new;
  end if;
  select * into v_order from public.orders where id = v_payment.order_id;

  perform public.raise_system_ticket(
    new.operation || ':' || v_payment.id,
    v_order.id,
    new.operation || ' on payment ' || v_payment.id || ' for order '
      || coalesce(v_order.public_reference, v_order.id::text) || '.',
    case new.operation when 'PAID_AFTER_CANCEL' then 'URGENT' else 'HIGH' end);
  return new;
end;
$$;
revoke all on function public.support_ticket_on_payment_exception()
  from public, anon, authenticated, service_role;

create trigger audit_logs_support_ticket
  after insert on public.audit_logs
  for each row
  when (new.operation in ('PAID_AFTER_CANCEL', 'LATE_SUCCESS'))
  execute function public.support_ticket_on_payment_exception();
