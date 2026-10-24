-- Addendum A5 §5 — web-order fulfilment.
-- Dispatch with a 4-digit delivery PIN (bcrypt), the PIN-verified delivery by
-- field staff or, for a courier, by the fulfilment warehouse's manager, the
-- delivery photo in the private delivery-proofs bucket, and the 24-hour
-- damage window that ORDER tickets record.
--
-- Who acts (§5.2; there is no WAREHOUSE_MANAGER role, warehouses carry
-- manager_id):
--   dispatch  — any ZSM of the tenant, or the ACTIVE member who manages the
--               order's fulfilment warehouse;
--   delivery  — any ZSM, an ACTIVE TM/DSM/DSA of the order's territory
--               (FIELD_STAFF), or that warehouse manager (COURIER).
--
-- PIN protection (§5.2, rulings R5/R6):
--   5 wrong codes lock the PIN for 30 minutes and restart the window count;
--   10 wrong codes over the order's lifetime lock it until a ZSM resends.
--   Only a ZSM resend clears counters and locks. A wrong code or a locked
--   attempt is returned as data ({error: WRONG_PIN | LOCKED}) and completes
--   idempotency, so the counters commit; raising would roll them back.
--
-- Gateway proof (ruling R16): dispatch, resend and mark-sent set or send the
-- PIN, so they also require the gateway's secret (assert_gateway_proof).
-- Delivery and the photo slot stay directly callable: they need the PIN.
--
-- No PIN, PIN hash, phone or storage path reaches an audit row or a stored
-- idempotency reply. buyer_phone is returned to the gateway on the first call
-- only; a replay omits it, which is how the gateway knows to send nothing.

-- ── order_fulfilments (§5.1) ────────────────────────────────────────────
create table public.order_fulfilments (
  order_id              uuid primary key,
  tenant_id             uuid not null references public.tenants (id) on delete restrict,
  dispatched_at         timestamptz not null default now(),
  dispatched_by         uuid not null references public.profiles (id) on delete restrict,
  tracking_reference    text check (length(btrim(tracking_reference)) between 1 and 100),
  delivery_pin_hash     text not null check (delivery_pin_hash ~ '^\$2[aby]\$[0-9]{2}\$.{53}$'),
  pin_failed_attempts   integer not null default 0 check (pin_failed_attempts >= 0),
  pin_locked_until      timestamptz,
  pin_lifetime_failures integer not null default 0 check (pin_lifetime_failures >= 0),
  pin_zsm_lock          boolean not null default false,
  pin_sent_at           timestamptz,
  -- resends whose message was sent, on pin_resend_day (Africa/Lagos)
  pin_resends_today     integer not null default 0 check (pin_resends_today >= 0),
  pin_resend_day        date,
  -- a resend set a new code whose send is not yet confirmed
  pin_resend_pending    boolean not null default false,
  delivered_at          timestamptz,
  delivered_by          uuid references public.profiles (id) on delete restrict,
  delivered_via         text check (delivered_via in ('FIELD_STAFF', 'COURIER')),
  delivery_photo_path   text,
  damage_claim_deadline timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (tenant_id, order_id),
  foreign key (tenant_id, order_id) references public.orders (tenant_id, id) on delete restrict,
  check (num_nulls(delivered_at, delivered_by, delivered_via, damage_claim_deadline) in (0, 4)),
  check (damage_claim_deadline = delivered_at + interval '24 hours'),
  check (delivery_photo_path is null or delivered_at is not null)
);
alter table public.order_fulfilments enable row level security;
-- column grants: the PIN hash is never readable by an API role
revoke all on public.order_fulfilments from anon, authenticated, service_role;
grant select (order_id, tenant_id, dispatched_at, dispatched_by, tracking_reference,
              pin_failed_attempts, pin_locked_until, pin_lifetime_failures, pin_zsm_lock, pin_sent_at,
              pin_resends_today, pin_resend_day, pin_resend_pending,
              delivered_at, delivered_by, delivered_via, delivery_photo_path, damage_claim_deadline,
              created_at, updated_at)
  on public.order_fulfilments to authenticated;
create index idx_order_fulfilments_dispatched_by on public.order_fulfilments (dispatched_by);
create index idx_order_fulfilments_delivered_by  on public.order_fulfilments (delivered_by);
create trigger order_fulfilments_set_updated_at before update on public.order_fulfilments
  for each row execute function public.set_updated_at();

-- a delivery-proof slot sits under its order: orders/<order_id>/<slot_id>.<ext>
alter table public.upload_slots
  add constraint upload_slots_delivery_proof_path_check
  check (purpose <> 'DELIVERY_PROOF'
         or storage_path ~ ('^orders/' || order_id::text || '/' || id::text || '\.(jpg|png|webp)$'));

-- the damage flag: set only on ORDER tickets about delivery or the product
alter table public.support_tickets
  add column within_damage_window boolean,
  add constraint support_tickets_damage_window_check
  check (within_damage_window is null or (kind = 'ORDER' and category in ('DELIVERY', 'PRODUCT')));

-- ── read helpers ────────────────────────────────────────────────────────
-- Orders in fulfilment the caller may follow: every one of a tenant where the
-- caller is a ZSM, those in a territory where the caller is the ACTIVE TM,
-- and those whose fulfilment warehouse the caller manages as an ACTIVE member.
create or replace function public.my_fulfilment_order_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select f.order_id
    from public.order_fulfilments f
   where f.tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
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
$$;
revoke all on function public.my_fulfilment_order_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_fulfilment_order_ids() to authenticated;

create policy order_fulfilments_select on public.order_fulfilments
  for select to authenticated
  using (order_id in (select public.my_fulfilment_order_ids()));

-- The live delivery-proof slot paths the caller may read: the orders above,
-- plus the caller's own uploads while they are an ACTIVE member of the
-- tenant. An object with no live slot is unreadable while it waits for the
-- Storage purge. Set-based, not a per-row correlated subquery.
create or replace function public.my_delivery_proof_paths()
returns setof text
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select s.storage_path
    from public.upload_slots s
   where s.purpose = 'DELIVERY_PROOF'
     and s.order_id in (select public.my_fulfilment_order_ids())
  union
  select s.storage_path
    from public.upload_slots s
   where s.purpose = 'DELIVERY_PROOF'
     and s.uploaded_by = (select auth.uid())
     and s.tenant_id in (select public.my_tenant_ids());
$$;
revoke all on function public.my_delivery_proof_paths() from public, anon, authenticated, service_role;
grant execute on function public.my_delivery_proof_paths() to authenticated;

create policy upload_slots_select_delivery_proof on public.upload_slots
  for select to authenticated
  using (storage_path in (select public.my_delivery_proof_paths()));

-- Storage: download through RLS only; no client write policy. The CHECK above
-- ties each path's folder to its slot's order, so the live-slot rule alone
-- decides; the name is compared as text, never cast.
create policy delivery_proofs_select on storage.objects
  for select to authenticated
  using (bucket_id = 'delivery-proofs'
         and name in (select public.my_delivery_proof_paths()));

-- ── permission internals (no grant) ─────────────────────────────────────
-- A ZSM of the order's tenant, or the ACTIVE member managing its warehouse.
create or replace function public.fulfilment_can_dispatch(p_me public.tenant_users, p_order public.orders)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(p_me.status = 'ACTIVE' and p_me.tenant_id = p_order.tenant_id
                  and (p_me.role = 'ZSM'
                       or exists (select 1 from public.warehouses w
                                   where w.tenant_id = p_order.tenant_id
                                     and w.id = p_order.fulfilment_warehouse_id
                                     and w.manager_id = p_me.profile_id)), false);
$$;
revoke all on function public.fulfilment_can_dispatch(public.tenant_users, public.orders)
  from public, anon, authenticated, service_role;

-- FIELD_STAFF for a ZSM or a TM/DSM/DSA of the order's territory, COURIER for
-- the warehouse manager, otherwise null. An order with no territory goes
-- through the courier path or a ZSM.
create or replace function public.fulfilment_delivery_path(p_me public.tenant_users, p_order public.orders)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select case
           when not coalesce(p_me.status = 'ACTIVE' and p_me.tenant_id = p_order.tenant_id, false) then null
           when p_me.role = 'ZSM' then 'FIELD_STAFF'
           when p_me.role in ('TM', 'DSM', 'DSA') and p_me.territory_id = p_order.territory_id then 'FIELD_STAFF'
           when exists (select 1 from public.warehouses w
                         where w.tenant_id = p_order.tenant_id
                           and w.id = p_order.fulfilment_warehouse_id
                           and w.manager_id = p_me.profile_id) then 'COURIER'
         end;
$$;
revoke all on function public.fulfilment_delivery_path(public.tenant_users, public.orders)
  from public, anon, authenticated, service_role;

-- The order, locked, in the caller's tenant; anything else is 42501 so that
-- order ids in other tenants cannot be probed.
create or replace function public.fulfilment_lock_order(p_me public.tenant_users, p_order_id uuid)
returns public.orders
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_order public.orders;
begin
  select o.* into v_order from public.orders o
   where o.id = p_order_id and o.tenant_id = p_me.tenant_id
     for update;
  if v_order.id is null then
    raise exception 'not permitted to act on this order' using errcode = '42501';
  end if;
  return v_order;
end;
$$;
revoke all on function public.fulfilment_lock_order(public.tenant_users, uuid)
  from public, anon, authenticated, service_role;

-- The PIN-sending day.
create or replace function public.fulfilment_today()
returns date
language sql
stable
set search_path = public, pg_temp
as $$ select (now() at time zone 'Africa/Lagos')::date $$;
revoke all on function public.fulfilment_today() from public, anon, authenticated, service_role;

-- ── assert_gateway_proof (internal, ruling R16) ─────────────────────────
-- The PIN-setting and PIN-sending RPCs must come through their gateway, which
-- generates the PIN and sends it to the buyer: a staff member calling
-- PostgREST directly must not choose a PIN or read the buyer's phone. The
-- gateway passes GATEWAY_SECRET, which equals the Vault secret
-- 'gateway_secret' (created out of band per environment; never in a
-- migration). Fails closed: a missing, empty or different secret is 42501.
-- sha256 of both sides gives a fixed-length comparison.
create or replace function public.assert_gateway_proof(p_proof text)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'gateway_secret'
   order by created_at desc
   limit 1;
  if v_secret is null or v_secret = ''
     or extensions.digest(coalesce(p_proof, ''), 'sha256') <> extensions.digest(v_secret, 'sha256') then
    raise exception 'this operation must come through its gateway' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.assert_gateway_proof(text) from public, anon, authenticated, service_role;

-- ── mark_order_dispatched (§5.3) ────────────────────────────────────────
create or replace function public.mark_order_dispatched(
  p_idempotency_key    uuid,
  p_order_id           uuid,
  p_tracking_reference text,
  p_pin                text,
  p_gateway_proof      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_order public.orders;
  v_track text := nullif(btrim(coalesce(p_tracking_reference, '')), '');
  v_reply jsonb;
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

  insert into public.order_fulfilments (order_id, tenant_id, dispatched_by, tracking_reference, delivery_pin_hash)
  values (v_order.id, v_order.tenant_id, v_me.profile_id, v_track,
          extensions.crypt(p_pin, extensions.gen_salt('bf')));
  update public.orders set status = 'IN_TRANSIT' where id = v_order.id;

  perform public.write_audit(v_order.tenant_id, 'mark_order_dispatched', 'orders', v_order.id::text,
                             jsonb_build_object('status', v_order.status),
                             jsonb_build_object('order_id', v_order.id, 'status', 'IN_TRANSIT',
                                                'has_tracking', v_track is not null),
                             p_idempotency_key);

  v_reply := jsonb_build_object('order_id', v_order.id, 'status', 'IN_TRANSIT',
                                'public_reference', v_order.public_reference);
  perform public.idempotency_complete(p_idempotency_key, v_reply);
  -- for the gateway, this call only
  return v_reply || jsonb_build_object('buyer_phone',
    (select c.customer_phone from public.order_contacts c where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id));
end;
$$;
revoke all on function public.mark_order_dispatched(uuid, uuid, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.mark_order_dispatched(uuid, uuid, text, text, text) to authenticated;

-- ── mark_delivery_pin_sent (§5.2) ───────────────────────────────────────
-- Called by the gateway after a successful send. A send that follows a
-- resend counts toward the day's limit; the first send after dispatch does not.
create or replace function public.mark_delivery_pin_sent(p_idempotency_key uuid, p_order_id uuid, p_channel text,
                                                         p_gateway_proof text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_order  public.orders;
  v_f      public.order_fulfilments;
  v_today  date := public.fulfilment_today();
  v_resend boolean;
begin
  perform public.assert_gateway_proof(p_gateway_proof);
  v_prior := public.idempotency_begin(p_idempotency_key, 'mark_delivery_pin_sent',
    jsonb_build_object('order_id', p_order_id, 'channel', p_channel));
  if v_prior is not null then
    return v_prior;
  end if;

  v_order := public.fulfilment_lock_order(v_me, p_order_id);
  if not public.fulfilment_can_dispatch(v_me, v_order)
     and public.fulfilment_delivery_path(v_me, v_order) is null then
    raise exception 'not permitted to act on this order' using errcode = '42501';
  end if;
  if p_channel is null or p_channel not in ('WHATSAPP', 'SMS') then
    raise exception 'channel must be WHATSAPP or SMS' using errcode = 'P0001';
  end if;
  if v_order.status <> 'IN_TRANSIT' then
    raise exception 'only orders in transit have a delivery code' using errcode = 'P0001';
  end if;
  select * into v_f from public.order_fulfilments where order_id = v_order.id for update;
  v_resend := v_f.pin_resend_pending;

  update public.order_fulfilments
     set pin_sent_at = now(),
         pin_resend_pending = false,
         pin_resends_today = case when not v_resend then pin_resends_today
                                  when pin_resend_day = v_today then pin_resends_today + 1
                                  else 1 end,
         pin_resend_day = case when v_resend then v_today else pin_resend_day end
   where order_id = v_order.id
  returning * into v_f;

  perform public.write_audit(v_order.tenant_id, 'mark_delivery_pin_sent', 'order_fulfilments', v_order.id::text, null,
                             jsonb_build_object('order_id', v_order.id, 'channel', p_channel, 'resend', v_resend),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'order_id', v_order.id, 'channel', p_channel, 'resend', v_resend, 'resends_today', v_f.pin_resends_today));
end;
$$;
revoke all on function public.mark_delivery_pin_sent(uuid, uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.mark_delivery_pin_sent(uuid, uuid, text, text) to authenticated;

-- ── resend_delivery_pin (§5.3) ──────────────────────────────────────────
-- Anyone who may dispatch or deliver; 3 sent resends a day, a ZSM unlimited.
-- Only a ZSM resend clears the counters and both locks.
create or replace function public.resend_delivery_pin(p_idempotency_key uuid, p_order_id uuid, p_pin text,
                                                      p_gateway_proof text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  if v_order.status <> 'IN_TRANSIT' then
    raise exception 'only orders in transit can get a new delivery code' using errcode = 'P0001';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'the delivery code must be 4 digits' using errcode = 'P0001';
  end if;
  select * into v_f from public.order_fulfilments where order_id = v_order.id for update;
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
$$;
revoke all on function public.resend_delivery_pin(uuid, uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.resend_delivery_pin(uuid, uuid, text, text) to authenticated;

-- ── request_delivery_photo (§5.3) ───────────────────────────────────────
-- A pending DELIVERY_PROOF slot for someone allowed to deliver the order,
-- while it is in transit; the A5 photo limits and at most 10 pending slots
-- per order an hour.
create or replace function public.request_delivery_photo(p_idempotency_key uuid, p_order_id uuid,
                                                         p_mime_type text, p_size_bytes bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_order public.orders;
  v_ext   text;
  v_id    uuid := gen_random_uuid();
  v_slot  public.upload_slots;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_delivery_photo',
    jsonb_build_object('order_id', p_order_id, 'mime_type', p_mime_type, 'size_bytes', p_size_bytes));
  if v_prior is not null then
    return v_prior;
  end if;

  v_order := public.fulfilment_lock_order(v_me, p_order_id);
  if public.fulfilment_delivery_path(v_me, v_order) is null then
    raise exception 'not permitted to deliver this order' using errcode = '42501';
  end if;
  if v_order.status <> 'IN_TRANSIT' then
    raise exception 'only orders in transit can have a delivery photo' using errcode = 'P0001';
  end if;
  v_ext := public.upload_slot_extension(p_mime_type, p_size_bytes);
  if (select count(*) from public.upload_slots s
       where s.tenant_id = v_order.tenant_id and s.order_id = v_order.id and s.claimed_at is null
         and s.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many messages. Please wait a few minutes.' using errcode = 'P0001';
  end if;

  insert into public.upload_slots (id, tenant_id, purpose, order_id, storage_path, mime_type, size_bytes,
                                   uploaded_by_type, uploaded_by)
  values (v_id, v_order.tenant_id, 'DELIVERY_PROOF', v_order.id,
          'orders/' || v_order.id || '/' || v_id || '.' || v_ext, p_mime_type, p_size_bytes,
          'STAFF', v_me.profile_id)
  returning * into v_slot;

  perform public.write_audit(v_order.tenant_id, 'request_delivery_photo', 'upload_slots', v_slot.id::text, null,
                             jsonb_build_object('order_id', v_order.id, 'mime_type', v_slot.mime_type,
                                                'size_bytes', v_slot.size_bytes),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'attachment_id', v_slot.id, 'storage_path', v_slot.storage_path));
end;
$$;
revoke all on function public.request_delivery_photo(uuid, uuid, text, bigint) from public, anon, authenticated, service_role;
grant execute on function public.request_delivery_photo(uuid, uuid, text, bigint) to authenticated;

-- ── mark_order_delivered (§5.3) ─────────────────────────────────────────
-- Staff call it directly. A wrong code or a locked PIN is a reply, not an
-- exception: {order_id, status: 'IN_TRANSIT', error: 'WRONG_PIN' | 'LOCKED'}.
-- The photo slot is claimed only on a correct code; after a wrong one it
-- stays pending and reusable.
create or replace function public.mark_order_delivered(p_idempotency_key uuid, p_order_id uuid, p_pin text,
                                                       p_photo_attachment_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_order  public.orders;
  v_via    text;
  v_f      public.order_fulfilments;
  v_slot   public.upload_slots;
  v_locked boolean;
  v_reply  jsonb;
begin
  -- the PIN is never part of the stored request
  v_prior := public.idempotency_begin(p_idempotency_key, 'mark_order_delivered',
    jsonb_build_object('order_id', p_order_id, 'photo_attachment_id', p_photo_attachment_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_order := public.fulfilment_lock_order(v_me, p_order_id);
  v_via := public.fulfilment_delivery_path(v_me, v_order);
  if v_via is null then
    raise exception 'not permitted to deliver this order' using errcode = '42501';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'the delivery code must be 4 digits' using errcode = 'P0001';
  end if;
  if v_order.status <> 'IN_TRANSIT' then
    raise exception 'only orders in transit can be delivered' using errcode = 'P0001';
  end if;
  select * into v_f from public.order_fulfilments where order_id = v_order.id for update;

  -- locked: refused without counting
  if v_f.pin_zsm_lock or v_f.pin_locked_until > now() then
    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'order_id', v_order.id, 'status', v_order.status, 'error', 'LOCKED'));
  end if;

  -- wrong code: count it, lock at 5 (window) and 10 (lifetime), reply
  if v_f.delivery_pin_hash <> extensions.crypt(p_pin, v_f.delivery_pin_hash) then
    update public.order_fulfilments
       set pin_lifetime_failures = pin_lifetime_failures + 1,
           pin_zsm_lock = pin_zsm_lock or pin_lifetime_failures + 1 >= 10,
           pin_locked_until = case when pin_failed_attempts + 1 >= 5 then now() + interval '30 minutes'
                                   else pin_locked_until end,
           pin_failed_attempts = case when pin_failed_attempts + 1 >= 5 then 0 else pin_failed_attempts + 1 end
     where order_id = v_order.id
    returning * into v_f;
    v_locked := v_f.pin_zsm_lock or coalesce(v_f.pin_locked_until > now(), false);

    perform public.write_audit(v_order.tenant_id, 'DELIVERY_PIN_FAILED', 'order_fulfilments', v_order.id::text, null,
                               jsonb_build_object('order_id', v_order.id,
                                                  'pin_failed_attempts', v_f.pin_failed_attempts,
                                                  'pin_lifetime_failures', v_f.pin_lifetime_failures,
                                                  'locked', v_locked, 'pin_zsm_lock', v_f.pin_zsm_lock),
                               p_idempotency_key);

    return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
      'order_id', v_order.id, 'status', v_order.status,
      'error', case when v_locked then 'LOCKED' else 'WRONG_PIN' end));
  end if;

  -- right code: claim the photo (if any), then deliver
  if p_photo_attachment_id is not null then
    select s.* into v_slot from public.upload_slots s
     where s.id = p_photo_attachment_id and s.purpose = 'DELIVERY_PROOF'
       and s.tenant_id = v_order.tenant_id and s.order_id = v_order.id
       and s.uploaded_by = v_me.profile_id and s.claimed_at is null
       for update;
    if v_slot.id is null then
      raise exception 'That photo isn''t available.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from storage.objects o
                    where o.bucket_id = v_slot.bucket and o.name = v_slot.storage_path
                      and o.metadata ->> 'size' = v_slot.size_bytes::text
                      and o.metadata ->> 'mimetype' = v_slot.mime_type) then
      raise exception 'That photo hasn''t finished uploading.' using errcode = 'P0001';
    end if;
    update public.upload_slots set claimed_at = now() where id = v_slot.id;
  end if;

  update public.order_fulfilments
     set delivered_at = now(),
         delivered_by = v_me.profile_id,
         delivered_via = v_via,
         damage_claim_deadline = now() + interval '24 hours',
         delivery_photo_path = v_slot.storage_path
   where order_id = v_order.id
  returning * into v_f;
  update public.orders set status = 'DELIVERED' where id = v_order.id;

  perform public.write_audit(v_order.tenant_id, 'mark_order_delivered', 'orders', v_order.id::text,
                             jsonb_build_object('status', v_order.status),
                             jsonb_build_object('order_id', v_order.id, 'status', 'DELIVERED', 'pin_verified', true,
                                                'has_photo', v_slot.id is not null, 'delivered_via', v_via),
                             p_idempotency_key);

  v_reply := jsonb_build_object('order_id', v_order.id, 'status', 'DELIVERED', 'delivered_at', v_f.delivered_at,
                                'damage_claim_deadline', v_f.damage_claim_deadline, 'delivered_via', v_via);
  return public.idempotency_complete(p_idempotency_key, v_reply);
end;
$$;
revoke all on function public.mark_order_delivered(uuid, uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.mark_order_delivered(uuid, uuid, text, uuid) to authenticated;

-- ── open_support_ticket: + within_damage_window (A3 signature, body and ─
-- grants unchanged otherwise). ORDER tickets about DELIVERY or PRODUCT
-- record whether they were opened by the damage deadline; null before
-- delivery and for every other ticket.
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
  v_window      boolean;
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
    -- A5: inside the 24-hour damage window? (null before delivery)
    if p_category in ('DELIVERY', 'PRODUCT') then
      select now() <= f.damage_claim_deadline into v_window
        from public.order_fulfilments f
       where f.tenant_id = v_tenant and f.order_id = v_order.id;
    end if;
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
                                        and t.kind = 'ORDER'
                                        and t.status in ('OPEN', 'IN_PROGRESS')) >= 3) then
    raise exception 'Too many messages. Please wait a few minutes.' using errcode = 'P0001';
  end if;

  loop
    v_ref := public.new_crockford_reference('TK');
    exit when not exists (select 1 from public.support_tickets where public_reference = v_ref);
  end loop;

  insert into public.support_tickets (tenant_id, public_reference, kind, category, order_id, territory_id,
                                      accountable_id, previous_ticket_id, last_message_at, within_damage_window)
  values (v_tenant, v_ref, p_kind, p_category, v_order.id, v_territory, v_accountable, v_prev, clock_timestamp(),
          v_window)
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
