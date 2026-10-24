-- Addendum A5 §6 — the ZSM's dispute evidence bundle for a web order.
--
-- One call collects everything a chargeback or refund dispute needs: the
-- order and its lines, the Paystack payments and refunds, the consent the
-- buyer gave (with the policy text as accepted), the buyer's contact and
-- WhatsApp verification, the fulfilment and delivery proof, and every support
-- ticket on the order.
--
-- Ruling R8: the function is VOLATILE because each call writes a
-- DISPUTE_EVIDENCE_VIEWED audit row; the bundle collects personal data, so
-- looking is itself recorded. The after-image is {order_id} only, and there
-- is no idempotency: a read has nothing to replay.
--
-- Storage paths do leave the database here, for the gateway only. Every
-- attachment carries its bucket so the gateway signs against the right one;
-- the gateway then returns signed URLs and no path.
--
-- Refunds: D1 keeps no refunds table. apply_paystack_refund records each
-- refund in audit_logs (entity payments), so the refunds block reads those
-- rows. Settlement is the payment's commission record.

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
      'created_at', v_order.created_at),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', i.sku_code,
               'sale_category', cp.sale_category,
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
