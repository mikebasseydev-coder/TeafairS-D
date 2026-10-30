-- Addendum A6 §18.3 (plan Task 1e; user ruling 2026-10-30, binding):
-- a ZSM's administrative and approval powers, and every ZSM-scoped read,
-- reach only the ZSM's own zones (zones.zsm_id, through zsm_zone_ids).
-- Cross-zone attempts are refused with 42501 (RPCs) or invisible (RLS).
--
-- Tenant-wide matters stay with any ACTIVE ZSM of the tenant (Claude's call):
-- brand terms and bridging approval, Monvelo settings, contact-report review,
-- web defaults, the brand approval policy, and objects with no zone (orders
-- and tickets without a territory, rows that name no zonal object).
--
-- Direct chat between two ACTIVE ZSMs of the same tenant is always open.
--
-- Every function below is recreated from its live pg_get_functiondef with
-- the same signature; CREATE OR REPLACE keeps its grants. Only the ZSM branch
-- changes: the LOGISTICS_MANAGER and warehouse-manager branches of the
-- fulfilment helpers are unchanged. Every policy keeps its name, command
-- (SELECT) and role; only its ZSM branch is narrowed.

-- ── helpers ─────────────────────────────────────────────────────────────

-- Whether a profile, as an ACTIVE ZSM of the tenant, covers the territory's
-- zone. False for a null territory: callers decide what "no zone" means.
create function public.zsm_covers_territory(p_tenant_id uuid, p_profile_id uuid, p_territory_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.territories t
     where t.tenant_id = p_tenant_id
       and t.id = p_territory_id
       and t.zone_id in (select public.zsm_zone_ids(p_tenant_id, p_profile_id)));
$$;
revoke all on function public.zsm_covers_territory(uuid, uuid, uuid) from public, anon, authenticated, service_role;

-- The territories in the caller's zones, in every tenant where the caller is
-- an ACTIVE ZSM (the same reach as my_tm_territory_ids for a TM). For policies.
create function public.my_zsm_territory_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.id
    from public.territories t
    join public.zones z on z.tenant_id = t.tenant_id and z.id = t.zone_id
   where z.zsm_id = (select auth.uid())
     and z.tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]));
$$;
revoke all on function public.my_zsm_territory_ids() from public, anon, service_role;
grant execute on function public.my_zsm_territory_ids() to authenticated;

-- The zonal objects, named as audit keys '<entity_type>:<entity_id>', that
-- lie in a zone of a tenant where the caller is an ACTIVE ZSM but that the
-- caller does not cover. Never returns a null, so NOT IN is safe. Objects
-- with no zone are never in it. For policies.
create function public.my_zsm_out_of_zone_keys()
returns setof text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with my_tenants as (
    select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]) as tenant_id
  ), other_zones as (
    select z.tenant_id, z.id
      from public.zones z
     where z.tenant_id in (select tenant_id from my_tenants)
       and z.zsm_id is distinct from (select auth.uid())
  ), other_territories as (
    select t.tenant_id, t.id
      from public.territories t
      join other_zones z on z.tenant_id = t.tenant_id and z.id = t.zone_id
  ), other_orders as (
    select o.tenant_id, o.id
      from public.orders o
      join other_territories t on t.tenant_id = o.tenant_id and t.id = o.territory_id
  )
  select 'zones:' || id from other_zones
  union all
  select 'territories:' || id from other_territories
  union all
  select 'areas:' || a.id from public.areas a
    join other_territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
  union all
  select 'territory_coverage:' || c.id from public.territory_coverage c
    join other_territories t on t.tenant_id = c.tenant_id and t.id = c.territory_id
  union all
  select 'web_pos_venues:' || v.id from public.web_pos_venues v
    join other_territories t on t.tenant_id = v.tenant_id and t.id = v.territory_id
  union all
  select 'support_tickets:' || s.id from public.support_tickets s
    join other_territories t on t.tenant_id = s.tenant_id and t.id = s.territory_id
  union all
  select 'orders:' || id from other_orders
  union all
  select 'order_fulfilments:' || id from other_orders
  union all
  select 'payments:' || p.id from public.payments p
    join other_orders o on o.tenant_id = p.tenant_id and o.id = p.order_id;
$$;
revoke all on function public.my_zsm_out_of_zone_keys() from public, anon, service_role;
grant execute on function public.my_zsm_out_of_zone_keys() to authenticated;

-- ── tickets ─────────────────────────────────────────────────────────────

-- the ZSM override holds only for a ticket with no territory or one in the
-- ZSM's zones; any other ZSM falls through to the ordinary holder checks
CREATE OR REPLACE FUNCTION public.support_lock_ticket(p_ticket_id uuid, p_me tenant_users, p_zsm_only boolean)
 RETURNS support_tickets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_t        public.support_tickets;
  v_assignee uuid;
begin
  select * into v_t
    from public.support_tickets t
   where t.id = p_ticket_id and t.tenant_id = p_me.tenant_id
     for update;
  if v_t.id is null then
    raise exception 'ticket not found' using errcode = 'P0001';
  end if;

  if p_me.role = 'ZSM'
     and (v_t.territory_id is null
          or public.zsm_covers_territory(p_me.tenant_id, p_me.profile_id, v_t.territory_id)) then
    return v_t;
  end if;
  -- the live holder: the assignee while still an ACTIVE member, else nobody
  select tu.profile_id into v_assignee
    from public.tenant_users tu
   where tu.tenant_id = v_t.tenant_id and tu.profile_id = v_t.assigned_to and tu.status = 'ACTIVE';
  -- a claimed ticket is locked to its assignee and the ZSMs
  if v_assignee is not null and v_assignee <> p_me.profile_id then
    raise exception 'this ticket is held by someone else' using errcode = '42501';
  end if;
  if not p_zsm_only
     and ((p_me.role = 'TM' and p_me.territory_id is not null and p_me.territory_id is not distinct from v_t.territory_id)
          or (v_t.kind <> 'ORDER' and p_me.profile_id in (v_t.accountable_id, v_assignee))) then
    return v_t;
  end if;
  raise exception 'you may not act on this ticket' using errcode = '42501';
end;
$function$;

CREATE OR REPLACE FUNCTION public.assign_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_territory_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me          public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior       jsonb;
  v_t           public.support_tickets;
  v_before      jsonb;
  v_zone        uuid;
  v_accountable uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'assign_ticket',
                                      jsonb_build_object('ticket_id', p_ticket_id, 'territory_id', p_territory_id));
  if v_prior is not null then
    return v_prior;
  end if;

  -- the ticket must be in one of the ZSM's zones (or have none)
  v_t := public.support_lock_ticket(p_ticket_id, v_me, true);
  if v_t.status = 'CLOSED' then
    raise exception 'that ticket is closed' using errcode = 'P0001';
  end if;
  if v_t.kind <> 'PRE_PURCHASE' then
    raise exception 'only pre-purchase tickets can be re-routed' using errcode = 'P0001';
  end if;
  select zone_id into v_zone from public.territories
   where tenant_id = v_t.tenant_id and id = p_territory_id;
  if not found then
    raise exception 'territory not found' using errcode = 'P0001';
  end if;
  -- and so must the territory it goes to
  if not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, p_territory_id) then
    raise exception 'a ZSM routes tickets into their own zones only' using errcode = '42501';
  end if;

  select tu.profile_id into v_accountable
    from public.territories t
    join public.tenant_users tu on tu.tenant_id = t.tenant_id and tu.profile_id = t.tm_id and tu.status = 'ACTIVE'
   where t.tenant_id = v_t.tenant_id and t.id = p_territory_id;
  if v_accountable is null then
    select tu.profile_id into v_accountable
      from public.zones z
      join public.tenant_users tu on tu.tenant_id = z.tenant_id and tu.profile_id = z.zsm_id and tu.status = 'ACTIVE'
     where z.tenant_id = v_t.tenant_id and z.id = v_zone;
  end if;
  if v_accountable is null then
    select tu.profile_id into v_accountable
      from public.tenant_settings s
      join public.tenant_users tu on tu.tenant_id = s.tenant_id and tu.profile_id = s.web_default_agent_id
                                 and tu.status = 'ACTIVE'
     where s.tenant_id = v_t.tenant_id;
  end if;

  v_before := jsonb_build_object('territory_id', v_t.territory_id, 'accountable_id', v_t.accountable_id,
                                 'assigned_to', v_t.assigned_to, 'status', v_t.status);
  -- assigned_to is cleared, so an IN_PROGRESS ticket goes back to OPEN
  update public.support_tickets
     set territory_id = p_territory_id, accountable_id = v_accountable, assigned_to = null,
         status = case when status = 'IN_PROGRESS' then 'OPEN' else status end
   where id = v_t.id
  returning * into v_t;
  update public.support_ticket_contacts set territory_id = p_territory_id where ticket_id = v_t.id;
  update public.support_messages set territory_id = p_territory_id where ticket_id = v_t.id;

  perform public.write_audit(v_t.tenant_id, 'assign_ticket', 'support_tickets', v_t.id::text, v_before,
                             jsonb_build_object('territory_id', v_t.territory_id, 'accountable_id', v_t.accountable_id,
                                                'assigned_to', v_t.assigned_to, 'status', v_t.status),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$function$;

CREATE OR REPLACE FUNCTION public.my_support_message_ticket_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select t.id
    from public.support_tickets t
   where t.territory_id in (select public.my_zsm_territory_ids())
      or (t.territory_id is null
          and t.tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])))
      or t.territory_id in (select public.my_tm_territory_ids())
  union
  select h.id from public.my_support_history_ticket_ids() as h (id);
$function$;

-- ── orders: dispute evidence and fulfilment ─────────────────────────────

CREATE OR REPLACE FUNCTION public.get_order_dispute_evidence(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_order  public.orders;
  v_policy public.refund_policies;
  v_bundle jsonb;
begin
  -- a missing order, another tenant's order and an order in another ZSM's
  -- zone get the same answer
  select * into v_order from public.orders o where o.id = p_order_id;
  if not found or v_order.tenant_id <> v_me.tenant_id
     or (v_order.territory_id is not null
         and not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, v_order.territory_id)) then
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
      'goods_total', v_order.total_amount - v_order.transport_fare,
      'discount_amount', v_order.discount_amount,
      'transport_fare', v_order.transport_fare,
      'referral_code_id', v_order.referral_code_id,
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
               'agent_commission', p.split_amount,
               'created_at', p.created_at,
               'settlement', (select jsonb_build_object('status', c.status, 'settled_at', c.settled_at)
                                from public.web_commissions c
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
$function$;

-- the ZSM dispatches orders in their zones or with no territory; the
-- LOGISTICS_MANAGER and warehouse-manager branches are unchanged
CREATE OR REPLACE FUNCTION public.fulfilment_can_dispatch(p_me tenant_users, p_order orders)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(p_me.status = 'ACTIVE' and p_me.tenant_id = p_order.tenant_id
                  and (p_me.role = 'LOGISTICS_MANAGER'
                       or (p_me.role = 'ZSM'
                           and (p_order.territory_id is null
                                or public.zsm_covers_territory(p_me.tenant_id, p_me.profile_id, p_order.territory_id)))
                       or exists (select 1 from public.warehouses w
                                   where w.tenant_id = p_order.tenant_id
                                     and w.id = p_order.fulfilment_warehouse_id
                                     and w.manager_id = p_me.profile_id)), false);
$function$;

CREATE OR REPLACE FUNCTION public.fulfilment_delivery_path(p_me tenant_users, p_order orders)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
           when not coalesce(p_me.status = 'ACTIVE' and p_me.tenant_id = p_order.tenant_id, false) then null
           when p_me.role = 'ZSM'
                and (p_order.territory_id is null
                     or public.zsm_covers_territory(p_me.tenant_id, p_me.profile_id, p_order.territory_id))
             then 'FIELD_STAFF'
           when p_me.role = 'LOGISTICS_MANAGER' then 'COURIER'
           when p_me.role in ('TM', 'DSM', 'DSA') and p_me.territory_id = p_order.territory_id then 'FIELD_STAFF'
           when exists (select 1 from public.warehouses w
                         where w.tenant_id = p_order.tenant_id
                           and w.id = p_order.fulfilment_warehouse_id
                           and w.manager_id = p_me.profile_id) then 'COURIER'
         end;
$function$;

CREATE OR REPLACE FUNCTION public.my_fulfilment_order_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select f.order_id
    from public.order_fulfilments f
   where f.tenant_id in (select public.my_tenant_ids_with_role(array['LOGISTICS_MANAGER']::public.tenant_role_enum[]))
  union
  -- a ZSM: orders in their zones, and orders with no territory
  select f.order_id
    from public.order_fulfilments f
    join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
   where o.territory_id in (select public.my_zsm_territory_ids())
      or (o.territory_id is null
          and o.tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])))
  union
  select f.order_id
    from public.order_fulfilments f
    join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
   where o.territory_id in (select public.my_tm_territory_ids())
  union
  select f.order_id
    from public.order_fulfilments f
    join public.orders o on o.tenant_id = f.tenant_id and o.id = f.order_id
    join public.warehouses w on w.tenant_id = o.tenant_id and w.id = o.fulfilment_warehouse_id
   where w.manager_id = (select auth.uid())
     and w.tenant_id in (select public.my_tenant_ids());
$function$;

-- the ZSM's lock-clearing and uncapped resend hold only in the ZSM's zones;
-- an out-of-zone ZSM who also manages the order's warehouse acts as courier
CREATE OR REPLACE FUNCTION public.resend_delivery_pin(p_idempotency_key uuid, p_order_id uuid, p_pin text, p_gateway_proof text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_order public.orders;
  v_f     public.order_fulfilments;
  v_zsm   boolean := v_me.role = 'ZSM';
  v_reply jsonb;
begin
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'resend_delivery_pin',
    jsonb_build_object('order_id', p_order_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_order := public.fulfilment_lock_order(v_me, p_order_id);
  if not public.fulfilment_can_dispatch(v_me, v_order)
     and public.fulfilment_delivery_path(v_me, v_order) is null then
    raise exception 'not permitted to act on this order' using errcode = '42501';
  end if;
  v_zsm := v_zsm and (v_order.territory_id is null
                      or public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, v_order.territory_id));
  if v_order.channel <> 'ONLINE' or v_order.status <> 'IN_TRANSIT' then
    raise exception 'only orders in transit can get a new delivery code' using errcode = 'P0001';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'the delivery code must be 4 digits' using errcode = 'P0001';
  end if;
  select * into v_f from public.order_fulfilments where order_id = v_order.id for update;
  if v_f.order_id is null then
    raise exception 'this order has no delivery record' using errcode = 'P0001';
  end if;
  if not v_zsm and v_f.pin_resend_day = public.fulfilment_today() and v_f.pin_resends_today >= 3 then
    raise exception 'Too many codes sent today. Ask a ZSM.' using errcode = 'P0001';
  end if;

  update public.order_fulfilments
     set delivery_pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')),
         pin_resend_pending = true,
         pin_failed_attempts = case when v_zsm then 0 else pin_failed_attempts end,
         pin_locked_until = case when v_zsm then null else pin_locked_until end,
         pin_lifetime_failures = case when v_zsm then 0 else pin_lifetime_failures end,
         pin_zsm_lock = case when v_zsm then false else pin_zsm_lock end
   where order_id = v_order.id;

  perform public.write_audit(v_order.tenant_id, 'resend_delivery_pin', 'order_fulfilments', v_order.id::text,
                             jsonb_build_object('pin_failed_attempts', v_f.pin_failed_attempts,
                                                'pin_lifetime_failures', v_f.pin_lifetime_failures,
                                                'pin_zsm_lock', v_f.pin_zsm_lock,
                                                'locked', v_f.pin_locked_until > now()),
                             jsonb_build_object('order_id', v_order.id, 'by_zsm', v_zsm, 'locks_cleared', v_zsm),
                             p_idempotency_key);

  v_reply := jsonb_build_object('order_id', v_order.id, 'public_reference', v_order.public_reference);
  perform public.idempotency_complete(p_idempotency_key, v_reply);
  return v_reply || jsonb_build_object('buyer_phone',
    (select c.customer_phone from public.order_contacts c where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id));
end;
$function$;

-- ── web: coverage, warehouses, venues, referral codes ───────────────────

CREATE OR REPLACE FUNCTION public.set_territory_coverage(p_idempotency_key uuid, p_state_code text, p_lga_id uuid, p_territory_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.territory_coverage;
  v_after  public.territory_coverage;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_territory_coverage',
    jsonb_build_object('state_code', p_state_code, 'lga_id', p_lga_id, 'territory_id', p_territory_id));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_state_code is null or not exists (select 1 from public.ng_states where code = p_state_code) then
    raise exception 'choose a state from the list' using errcode = 'P0001';
  end if;
  if p_lga_id is not null and not exists (
       select 1 from public.ng_lgas where id = p_lga_id and state_code = p_state_code) then
    raise exception 'the LGA is not in that state' using errcode = 'P0001';
  end if;

  select * into v_before from public.territory_coverage
   where tenant_id = v_me.tenant_id and state_code = p_state_code and lga_id is not distinct from p_lga_id
     for update;
  -- a ZSM changes or removes only coverage that points into their zones
  if v_before.id is not null
     and not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, v_before.territory_id) then
    raise exception 'that coverage belongs to another ZSM''s zone' using errcode = '42501';
  end if;

  if p_territory_id is null then
    delete from public.territory_coverage where id = v_before.id;
    perform public.write_audit(v_me.tenant_id, 'set_territory_coverage', 'territory_coverage',
      coalesce(v_before.id::text, p_state_code), to_jsonb(v_before), null, p_idempotency_key);
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object('coverage_id', null));
  end if;

  if not exists (select 1 from public.territories where tenant_id = v_me.tenant_id and id = p_territory_id) then
    raise exception 'the territory does not belong to this tenant' using errcode = 'P0001';
  end if;
  if not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, p_territory_id) then
    raise exception 'a ZSM sets coverage for territories in their own zones only' using errcode = '42501';
  end if;

  insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
  values (v_me.tenant_id, p_state_code, p_lga_id, p_territory_id)
  on conflict (tenant_id, state_code, lga_id)
  do update set territory_id = excluded.territory_id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_territory_coverage', 'territory_coverage',
    v_after.id::text, to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('coverage_id', v_after.id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_territory_web_warehouse(p_idempotency_key uuid, p_territory_id uuid, p_warehouse_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_territory_web_warehouse',
    jsonb_build_object('territory_id', p_territory_id, 'warehouse_id', p_warehouse_id));
  if v_prior is not null then
    return v_prior;
  end if;

  select web_fulfilment_warehouse_id into v_before from public.territories
   where tenant_id = v_me.tenant_id and id = p_territory_id for update;
  if not found then
    raise exception 'the territory does not belong to this tenant' using errcode = 'P0001';
  end if;
  if not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, p_territory_id) then
    raise exception 'a ZSM sets the web warehouse of territories in their own zones only' using errcode = '42501';
  end if;
  if p_warehouse_id is not null and not exists (
       select 1 from public.warehouses where tenant_id = v_me.tenant_id and id = p_warehouse_id) then
    raise exception 'the warehouse does not belong to this tenant' using errcode = 'P0001';
  end if;

  update public.territories set web_fulfilment_warehouse_id = p_warehouse_id
   where tenant_id = v_me.tenant_id and id = p_territory_id;

  perform public.write_audit(v_me.tenant_id, 'set_territory_web_warehouse', 'territories', p_territory_id::text,
    jsonb_build_object('warehouse_id', v_before), jsonb_build_object('warehouse_id', p_warehouse_id),
    p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('territory_id', p_territory_id, 'warehouse_id', p_warehouse_id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_web_pos_venue(p_idempotency_key uuid, p_venue_id uuid, p_venue_channel venue_channel_enum, p_venue_name text, p_address_text text, p_state text, p_lga text, p_latitude double precision, p_longitude double precision, p_operating_hours jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me       public.tenant_users := public.assert_tenant_role(
                array['ZSM', 'TM', 'POS_AGENT']::public.tenant_role_enum[]);
  v_prior    jsonb;
  v_before   public.web_pos_venues;
  v_after    public.web_pos_venues;
  v_point    extensions.geometry;
  v_boundary extensions.geometry;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_web_pos_venue',
    jsonb_build_object('venue_id', p_venue_id, 'venue_channel', p_venue_channel,
                       'venue_name', p_venue_name, 'address_text', p_address_text,
                       'state', p_state, 'lga', p_lga, 'latitude', p_latitude,
                       'longitude', p_longitude, 'operating_hours', p_operating_hours));
  if v_prior is not null then
    return v_prior;
  end if;

  select * into v_before from public.web_pos_venues
   where id = p_venue_id and tenant_id = v_me.tenant_id
   for update;
  if not found then
    raise exception 'terminal not found' using errcode = 'P0001';
  end if;
  if v_me.role = 'ZSM' and v_before.territory_id is not null
     and not public.zsm_covers_territory(v_me.tenant_id, v_me.profile_id, v_before.territory_id) then
    raise exception 'a ZSM sets venues for terminals in their own zones only' using errcode = '42501';
  end if;
  if v_me.role = 'TM' and v_before.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM sets venues for terminals in their own territory only' using errcode = '42501';
  end if;
  if v_me.role = 'POS_AGENT' and v_before.agent_id is distinct from v_me.profile_id then
    raise exception 'an agent sets the venue of their own terminals only' using errcode = '42501';
  end if;

  if p_venue_channel is null
     or coalesce(btrim(p_venue_name), '') = ''
     or coalesce(btrim(p_address_text), '') = ''
     or coalesce(btrim(p_state), '') = '' then
    raise exception 'venue type, name, address and state are required' using errcode = 'P0001';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'a valid GPS location is required' using errcode = 'P0001';
  end if;
  if p_operating_hours is not null and (
       jsonb_typeof(p_operating_hours) <> 'object'
       or exists (
         select 1 from jsonb_each(p_operating_hours) e
          where e.key not in ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
             or jsonb_typeof(e.value) <> 'string'
             or (e.value #>> '{}') !~ '^(closed|([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9])$')) then
    raise exception 'operating hours use mon..sun keys with "HH:MM-HH:MM" or "closed"' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326);
  select t.boundary into v_boundary from public.territories t
   where t.tenant_id = v_me.tenant_id and t.id = v_before.territory_id;
  if v_boundary is not null and not extensions.st_covers(v_boundary, v_point) then
    raise exception 'the venue lies outside the terminal''s territory' using errcode = 'P0001';
  end if;

  update public.web_pos_venues
     set venue_channel   = p_venue_channel,
         venue_name      = btrim(p_venue_name),
         address_text    = btrim(p_address_text),
         state           = btrim(p_state),
         lga             = nullif(btrim(p_lga), ''),
         location        = v_point,
         operating_hours = p_operating_hours
   where id = v_before.id
  returning * into v_after;

  perform public.write_audit(v_me.tenant_id, 'set_web_pos_venue', 'web_pos_venues', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object('venue_id', v_after.id));
end;
$function$;

-- a ZSM issues codes only for agents and terminals in their zones: the zone
-- is the venue's territory's, else the agent's territory's, area's or zone;
-- an agent with none of these (a zone-less member) stays tenant-wide
CREATE OR REPLACE FUNCTION public.upsert_web_referral_code(p_idempotency_key uuid, p_code text, p_agent_id uuid, p_venue_id uuid, p_discount_type text, p_discount_value numeric, p_max_redemptions integer, p_expires_at timestamp with time zone, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM', 'TM']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_agent  public.tenant_users;
  v_before public.web_referral_codes;
  v_after  public.web_referral_codes;
  v_zone   uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_web_referral_code',
    jsonb_build_object('code', v_code, 'agent_id', p_agent_id, 'venue_id', p_venue_id,
                       'discount_type', p_discount_type, 'discount_value', p_discount_value,
                       'max_redemptions', p_max_redemptions, 'expires_at', p_expires_at,
                       'is_active', p_is_active));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_code !~ '^[A-Z0-9][A-Z0-9-]{3,31}$' then
    raise exception 'a code is 4 to 32 letters, digits or dashes' using errcode = 'P0001';
  end if;

  select * into v_agent from public.tenant_users
   where tenant_id = v_me.tenant_id and profile_id = p_agent_id
   order by (status = 'ACTIVE') desc
   limit 1;
  if not found then
    raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
  end if;
  if v_me.role = 'TM' and v_agent.territory_id is distinct from v_me.territory_id then
    raise exception 'a TM issues codes for agents in their own territory only' using errcode = '42501';
  end if;
  if p_venue_id is not null and not exists (
    select 1 from public.web_pos_venues ft
     where ft.tenant_id = v_me.tenant_id and ft.id = p_venue_id and ft.agent_id = p_agent_id
  ) then
    raise exception 'the terminal must belong to the agent' using errcode = 'P0001';
  end if;
  if p_venue_id is not null and v_agent.role <> 'POS_AGENT' then
    raise exception 'a venue-bound code needs a POS agent' using errcode = 'P0001';
  end if;
  if v_me.role = 'ZSM' then
    v_zone := coalesce(
      (select t.zone_id from public.web_pos_venues ft
         join public.territories t on t.tenant_id = ft.tenant_id and t.id = ft.territory_id
        where ft.tenant_id = v_me.tenant_id and ft.id = p_venue_id),
      (select t.zone_id from public.territories t
        where t.tenant_id = v_me.tenant_id and t.id = v_agent.territory_id),
      (select t.zone_id from public.areas a
         join public.territories t on t.tenant_id = a.tenant_id and t.id = a.territory_id
        where a.tenant_id = v_me.tenant_id and a.id = v_agent.area_id),
      v_agent.zone_id);
    if v_zone is not null
       and v_zone not in (select public.zsm_zone_ids(v_me.tenant_id, v_me.profile_id)) then
      raise exception 'a ZSM issues codes for agents in their own zones only' using errcode = '42501';
    end if;
  end if;

  if (p_discount_type is null) <> (p_discount_value is null) then
    raise exception 'a discount needs both a type and a value' using errcode = 'P0001';
  end if;
  if p_discount_type is not null and p_discount_type not in ('PERCENT', 'FIXED') then
    raise exception 'discount type must be PERCENT or FIXED' using errcode = 'P0001';
  end if;
  if p_discount_type = 'PERCENT' and not (p_discount_value > 0 and p_discount_value <= 100) then
    raise exception 'a percentage discount is more than 0 and at most 100' using errcode = 'P0001';
  end if;
  if p_discount_type = 'FIXED' and not (p_discount_value > 0) then
    raise exception 'a fixed discount is more than 0' using errcode = 'P0001';
  end if;
  if p_max_redemptions is not null and p_max_redemptions < 1 then
    raise exception 'max_redemptions is at least 1' using errcode = 'P0001';
  end if;

  select * into v_before from public.web_referral_codes where code = v_code for update;
  if found then
    if v_before.tenant_id <> v_me.tenant_id then
      raise exception 'that code is already taken' using errcode = 'P0001';
    end if;
    if v_before.agent_id <> p_agent_id then
      raise exception 'a code''s agent never changes; deactivate it and issue a new code' using errcode = 'P0001';
    end if;
    if coalesce(p_is_active, v_before.is_active) and v_agent.status <> 'ACTIVE' then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    update public.web_referral_codes
       set venue_id        = p_venue_id,
           discount_type   = p_discount_type,
           discount_value  = p_discount_value,
           max_redemptions = p_max_redemptions,
           expires_at      = p_expires_at,
           is_active       = coalesce(p_is_active, v_before.is_active)
     where id = v_before.id
    returning * into v_after;
  else
    if v_agent.status <> 'ACTIVE' and coalesce(p_is_active, true) then
      raise exception 'the agent must be an active member of this tenant' using errcode = 'P0001';
    end if;
    insert into public.web_referral_codes (tenant_id, code, agent_id, venue_id, discount_type, discount_value,
                                    max_redemptions, expires_at, is_active, created_by)
    values (v_me.tenant_id, v_code, p_agent_id, p_venue_id, p_discount_type, p_discount_value,
            p_max_redemptions, p_expires_at, coalesce(p_is_active, true), v_me.profile_id)
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_web_referral_code', 'web_referral_codes', v_after.id::text,
                             to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('referral_code_id', v_after.id, 'code', v_after.code));
end;
$function$;

-- ── chat: two ACTIVE ZSMs of a tenant may always open a direct channel ──

CREATE OR REPLACE FUNCTION public.get_or_create_direct_channel(p_idempotency_key uuid, p_target_profile_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me      public.tenant_users := public.assert_tenant_role(
              array['ZSM', 'TM', 'ASM', 'DSM', 'DSA']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_target  public.tenant_users;
  v_my_zones    uuid[];
  v_their_zones uuid[];
  v_shared  boolean;
  v_low     uuid := least(v_me.profile_id, p_target_profile_id);
  v_high    uuid := greatest(v_me.profile_id, p_target_profile_id);
  v_id      uuid;
  v_created boolean;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'get_or_create_direct_channel',
               jsonb_build_object('target', p_target_profile_id));
  if v_prior is not null then return v_prior; end if;

  if p_target_profile_id = v_me.profile_id then
    raise exception 'you cannot message yourself' using errcode = 'P0001';
  end if;
  if not public.chat_is_available(v_me.tenant_id, p_target_profile_id) then
    raise exception 'that person is not available' using errcode = 'P0001';
  end if;

  -- an existing pair is reopened without the scope rule (§4.1)
  select c.id into v_id from public.chat_channels c
   where c.tenant_id = v_me.tenant_id and c.channel_type = 'DIRECT'
     and c.direct_low_id = v_low and c.direct_high_id = v_high;
  if found then
    return public.idempotency_complete(p_idempotency_key,
      jsonb_build_object('channel_id', v_id, 'created', false));
  end if;

  select * into v_target from public.tenant_users tu
   where tu.tenant_id = v_me.tenant_id and tu.profile_id = p_target_profile_id and tu.status = 'ACTIVE';
  v_my_zones    := array(select public.chat_staff_zone_ids(v_me.tenant_id, v_me.profile_id));
  v_their_zones := array(select public.chat_staff_zone_ids(v_me.tenant_id, p_target_profile_id));
  v_shared      := v_my_zones && v_their_zones;

  if not (
       (v_me.territory_id is not null and v_me.territory_id = v_target.territory_id)
    -- A6 §18.3: ZSM-to-ZSM direct chat has no zone barrier
    or (v_me.role = 'ZSM' and v_target.role = 'ZSM')
    or (v_me.role = 'ZSM' and v_shared)
    or (v_target.role = 'ZSM' and v_shared)
    or (v_me.role in ('TM', 'ZSM') and v_target.role in ('TM', 'ZSM') and v_shared)
  ) then
    raise exception 'you may not message that person' using errcode = '42501';
  end if;

  insert into public.chat_channels (tenant_id, channel_type, direct_low_id, direct_high_id)
  values (v_me.tenant_id, 'DIRECT', v_low, v_high)
  on conflict (tenant_id, direct_low_id, direct_high_id) where channel_type = 'DIRECT' do nothing
  returning id into v_id;
  v_created := v_id is not null;

  -- lost a race with a concurrent create of the same pair
  if not v_created then
    select c.id into v_id from public.chat_channels c
     where c.tenant_id = v_me.tenant_id and c.channel_type = 'DIRECT'
       and c.direct_low_id = v_low and c.direct_high_id = v_high;
  end if;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('channel_id', v_id, 'created', v_created));
end;
$function$;

-- ── policies: ZSM rows limited to the ZSM's zones ───────────────────────

-- A2: buyer contacts are read by the ZSM covering the order's zone and by
-- the order's TM; a contact with no territory by any ZSM of the tenant
alter policy order_contacts_select_zsm_or_tm on public.order_contacts
  using ((territory_id in (select public.my_zsm_territory_ids()))
         or (territory_id is null
             and tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])))
         or (territory_id in (select public.my_tm_territory_ids())));

alter policy support_ticket_contacts_select_handler on public.support_ticket_contacts
  using ((territory_id in (select public.my_zsm_territory_ids()))
         or (territory_id is null
             and tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])))
         or (territory_id in (select public.my_tm_territory_ids()))
         or (ticket_id in (select public.my_support_ticket_ids())));

alter policy support_messages_select_handler on public.support_messages
  using ((territory_id in (select public.my_zsm_territory_ids()))
         or (territory_id is null
             and tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[])))
         or (territory_id in (select public.my_tm_territory_ids()))
         or (ticket_id in (select public.my_support_history_ticket_ids())));

-- audit rows: a ZSM sees the tenant's rows except those naming a zonal object
-- in another ZSM's zone; the TM branch is unchanged
alter policy audit_logs_select_zsm_tm on public.audit_logs
  using ((tenant_id in (select public.my_tenant_ids_with_role(array['TM']::public.tenant_role_enum[])))
         or (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
             and (entity_type || ':' || coalesce(entity_id, '')) not in (select public.my_zsm_out_of_zone_keys())));

-- notification rows: related_id is an order (delivery codes) or a challenge;
-- a row about an order in another ZSM's zone is hidden
alter policy notification_logs_select_zsm on public.notification_logs
  using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
         and (related_id is null
              or ('orders:' || related_id::text) not in (select public.my_zsm_out_of_zone_keys())));
