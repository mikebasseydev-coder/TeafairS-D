-- Addendum A2 §4.2 — the till view of a pay-at-agent order. Only the order's
-- attributed agent may look it up, and they see the buyer's first name and
-- the last four digits of the phone, never the full contact details. A read:
-- no idempotency key and no audit row (as verify_pin). Every miss gives the
-- same message, so the lookup cannot probe which references exist.
create or replace function public.pos_order_lookup(p_public_reference text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_me  public.tenant_users := public.assert_tenant_role(null);
  v_out jsonb;
begin
  select jsonb_build_object(
           'public_reference', o.public_reference,
           'first_name',       split_part(c.customer_name, ' ', 1),
           'phone_last4',      right(c.customer_phone, 4),
           'total',            o.total_amount,
           'currency',         coalesce(s.currency, 'NGN'),
           'status',           o.status)
    into v_out
    from public.orders o
    left join public.order_contacts c on c.order_id = o.id
    left join public.tenant_settings s on s.tenant_id = o.tenant_id
   where o.tenant_id = v_me.tenant_id
     and o.public_reference = upper(btrim(coalesce(p_public_reference, '')))
     and o.payment_route = 'POS_AGENT'
     and o.attributed_agent_id = v_me.profile_id;

  if v_out is null then
    raise exception 'Order not found' using errcode = 'P0001';
  end if;
  return v_out;
end;
$$;

revoke execute on function public.pos_order_lookup(text) from public, anon;
grant execute on function public.pos_order_lookup(text) to authenticated;
