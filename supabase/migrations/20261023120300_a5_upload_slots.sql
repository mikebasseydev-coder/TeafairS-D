-- Addendum A5 §4, §5.4 — support photo attachments.
-- Private buckets, the shared upload_slots table, the staff download policy on
-- storage.objects, the slot RPCs, the claim on the A3 write RPCs, attachment
-- metadata on the buyer read, redaction of buyer photos, and the nightly
-- cleanup of slots that were never claimed.
--
-- Nobody writes to Storage directly: an RPC registers a pending slot, the
-- gateway signs a 10-minute upload URL for its path, the client uploads, and
-- posting the message claims the slot once the object is really there.
-- Paths and URLs never reach an audit row.
--
-- SQL never deletes from storage.objects (that would orphan the stored file):
-- objects to remove are queued in storage_purge_queue, and a service_role
-- purge job removes them through the Storage API. Until then, an object with
-- no live slot is unreadable, because the download policy requires one.

-- ── buckets (§4.1, §5.3) ────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('support-attachments', 'support-attachments', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('delivery-proofs',     'delivery-proofs',     false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
-- a bucket that already existed gets the same settings
update storage.buckets
   set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id in ('support-attachments', 'delivery-proofs');

-- a message is claimed together with its ticket: (tenant, ticket, message)
alter table public.support_messages
  add constraint support_messages_tenant_ticket_id_key unique (tenant_id, ticket_id, id);

-- ── upload_slots (§4.2, §5.4) ───────────────────────────────────────────
create table public.upload_slots (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete restrict,
  purpose          text not null check (purpose in ('SUPPORT_TICKET', 'DELIVERY_PROOF')),
  ticket_id        uuid,
  order_id         uuid,
  bucket           text not null generated always as
                     (case purpose when 'SUPPORT_TICKET' then 'support-attachments' else 'delivery-proofs' end) stored,
  storage_path     text not null unique,
  mime_type        text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp')),
  size_bytes       bigint not null check (size_bytes between 1 and 5242880),
  uploaded_by_type text not null check (uploaded_by_type in ('CUSTOMER', 'STAFF')),
  -- null for a customer
  uploaded_by      uuid references public.profiles (id) on delete restrict,
  -- the claiming message (support tickets); null while pending
  message_id       uuid,
  created_at       timestamptz not null default now(),
  claimed_at       timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, ticket_id) references public.support_tickets (tenant_id, id) on delete restrict,
  foreign key (tenant_id, order_id)  references public.orders (tenant_id, id) on delete restrict,
  foreign key (tenant_id, ticket_id, message_id)
    references public.support_messages (tenant_id, ticket_id, id) on delete restrict,
  check ((purpose = 'SUPPORT_TICKET' and ticket_id is not null and order_id is null)
      or (purpose = 'DELIVERY_PROOF' and order_id is not null and ticket_id is null and message_id is null)),
  check ((uploaded_by_type = 'STAFF') = (uploaded_by is not null)),
  check (purpose <> 'SUPPORT_TICKET' or (message_id is null) = (claimed_at is null)),
  check (purpose <> 'SUPPORT_TICKET'
         or storage_path ~ ('^tickets/' || ticket_id::text || '/' || id::text || '\.(jpg|png|webp)$'))
);
alter table public.upload_slots enable row level security;
-- default privileges grant table rights to API roles; keep SELECT for authenticated only
revoke all on public.upload_slots from anon, authenticated, service_role;
grant select on public.upload_slots to authenticated;
-- the throttle and the claim: a ticket's slots by uploader type, newest first
create index idx_upload_slots_ticket   on public.upload_slots (tenant_id, ticket_id, uploaded_by_type, created_at);
create index idx_upload_slots_message  on public.upload_slots (tenant_id, ticket_id, message_id);
create index idx_upload_slots_order    on public.upload_slots (tenant_id, order_id);
create index idx_upload_slots_uploader on public.upload_slots (uploaded_by);
-- the cleanup scans pending slots by age
create index idx_upload_slots_pending  on public.upload_slots (created_at) where claimed_at is null;

-- ── storage_purge_queue (internal): objects for the Storage API to remove ─
-- No policy and no grant: only the SECURITY DEFINER functions below touch it.
create table public.storage_purge_queue (
  id        uuid primary key default gen_random_uuid(),
  bucket    text not null,
  path      text not null,
  queued_at timestamptz not null default now(),
  unique (bucket, path)
);
alter table public.storage_purge_queue enable row level security;
revoke all on public.storage_purge_queue from anon, authenticated, service_role;
create index idx_storage_purge_queue_age on public.storage_purge_queue (queued_at, id);

-- ── my_support_message_ticket_ids ───────────────────────────────────────
-- Exactly the tickets whose messages the caller may read under
-- support_messages_select_handler: every ticket of a tenant where the caller
-- is a ZSM, every ticket in a territory where the caller is TM (messages copy
-- the ticket's territory and assign_ticket keeps them in step), and the
-- linked history of the PRE_PURCHASE/SYSTEM tickets they handle. ORDER
-- tickets stay A2-strict: never the selling agent.
create or replace function public.my_support_message_ticket_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select t.id
    from public.support_tickets t
   where t.tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
      or t.territory_id in (select public.my_tm_territory_ids())
  union
  select h.id from public.my_support_history_ticket_ids() as h (id);
$$;
revoke all on function public.my_support_message_ticket_ids() from public, anon, authenticated, service_role;
grant execute on function public.my_support_message_ticket_ids() to authenticated;

-- RLS: SELECT only. DELIVERY_PROOF rows get their own path in a later migration.
create policy upload_slots_select_ticket on public.upload_slots
  for select to authenticated
  using (ticket_id in (select public.my_support_message_ticket_ids()));

-- The live support slot paths of the tickets the caller may read. An object
-- with no live slot (redacted, cleaned up, or uploaded after its slot went)
-- is unreadable while it waits for the purge. Set-based, not a per-row
-- correlated subquery.
create or replace function public.my_support_attachment_paths()
returns setof text
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select s.storage_path
    from public.upload_slots s
   where s.purpose = 'SUPPORT_TICKET'
     and s.ticket_id in (select public.my_support_message_ticket_ids());
$$;
revoke all on function public.my_support_attachment_paths() from public, anon, authenticated, service_role;
grant execute on function public.my_support_attachment_paths() to authenticated;

-- ── Storage: staff download through RLS; no client write policy ─────────
-- The ticket id is the second folder of tickets/<ticket_id>/<slot>.<ext>.
-- It is compared as text so that no object name can make a cast fail.
create policy support_attachments_select on storage.objects
  for select to authenticated
  using (bucket_id = 'support-attachments'
         and (storage.foldername(name))[2] in (select t.id::text from public.my_support_message_ticket_ids() as t (id))
         and name in (select public.my_support_attachment_paths()));

-- ── internals ───────────────────────────────────────────────────────────
-- The JPEG/PNG/WebP and 1..5 MB limit, and the file extension for a type.
create or replace function public.upload_slot_extension(p_mime_type text, p_size_bytes bigint)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or p_mime_type is null or p_mime_type not in ('image/jpeg', 'image/png', 'image/webp') then
    raise exception 'Photos must be JPEG, PNG or WebP and at most 5 MB.' using errcode = 'P0001';
  end if;
  return case p_mime_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
end;
$$;
revoke all on function public.upload_slot_extension(text, bigint) from public, anon, authenticated, service_role;

-- Register a pending support slot on a locked ticket, after the CLOSED check:
-- the limits, then at most 10 pending slots per ticket and uploader type in
-- the last hour (the A3 throttle copy).
create or replace function public.support_new_slot(p_ticket public.support_tickets, p_uploader_type text,
                                                   p_uploaded_by uuid, p_mime_type text, p_size_bytes bigint)
returns public.upload_slots
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_ext  text := public.upload_slot_extension(p_mime_type, p_size_bytes);
  v_id   uuid := gen_random_uuid();
  v_slot public.upload_slots;
begin
  if (select count(*) from public.upload_slots s
       where s.tenant_id = p_ticket.tenant_id and s.ticket_id = p_ticket.id
         and s.uploaded_by_type = p_uploader_type and s.claimed_at is null
         and s.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many messages. Please wait a few minutes.' using errcode = 'P0001';
  end if;
  insert into public.upload_slots (id, tenant_id, purpose, ticket_id, storage_path, mime_type, size_bytes,
                                   uploaded_by_type, uploaded_by)
  values (v_id, p_ticket.tenant_id, 'SUPPORT_TICKET', p_ticket.id,
          'tickets/' || p_ticket.id || '/' || v_id || '.' || v_ext, p_mime_type, p_size_bytes,
          p_uploader_type, p_uploaded_by)
  returning * into v_slot;
  return v_slot;
end;
$$;
revoke all on function public.support_new_slot(public.support_tickets, text, uuid, text, bigint)
  from public, anon, authenticated, service_role;

-- ── claim_support_attachments (internal) ────────────────────────────────
-- Every id must be a pending slot of this ticket from this uploader type, and
-- its object must be in Storage with the registered size and type.
create or replace function public.claim_support_attachments(p_ticket_id uuid, p_message_id uuid, p_ids uuid[],
                                                            p_uploader_type text)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_n     integer := coalesce(cardinality(p_ids), 0);
  v_count integer;
begin
  if v_n = 0 then
    return 0;
  end if;
  if v_n > 3 then
    raise exception 'You can attach up to 3 photos.' using errcode = 'P0001';
  end if;
  if array_position(p_ids, null) is not null
     or (select count(distinct x) from unnest(p_ids) as x) <> v_n then
    raise exception 'That photo isn''t available.' using errcode = 'P0001';
  end if;

  perform 1 from public.upload_slots s
   where s.id = any (p_ids) and s.purpose = 'SUPPORT_TICKET' and s.ticket_id = p_ticket_id
     and s.uploaded_by_type = p_uploader_type and s.claimed_at is null
   order by s.id
     for update;
  get diagnostics v_count = row_count;
  if v_count <> v_n then
    raise exception 'That photo isn''t available.' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.upload_slots s
              where s.id = any (p_ids)
                and not exists (select 1 from storage.objects o
                                 where o.bucket_id = s.bucket and o.name = s.storage_path
                                   and o.metadata ->> 'size' = s.size_bytes::text
                                   and o.metadata ->> 'mimetype' = s.mime_type)) then
    raise exception 'That photo hasn''t finished uploading.' using errcode = 'P0001';
  end if;

  update public.upload_slots
     set message_id = p_message_id, claimed_at = now()
   where id = any (p_ids);
  return v_n;
end;
$$;
revoke all on function public.claim_support_attachments(uuid, uuid, uuid[], text)
  from public, anon, authenticated, service_role;

-- ── request_ticket_attachment (buyer, service_role) ─────────────────────
-- Order of checks as add_ticket_message: the pair (miss → NOT_FOUND), then
-- CLOSED, then the limits and the throttle.
create or replace function public.request_ticket_attachment(
  p_idempotency_key  uuid,
  p_public_reference text,
  p_secret           text,
  p_mime_type        text,
  p_size_bytes       bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior  jsonb;
  v_ticket public.support_tickets;
  v_slot   public.upload_slots;
begin
  select t.* into v_ticket
    from public.support_tickets t
    join public.support_ticket_secrets s on s.tenant_id = t.tenant_id and s.ticket_id = t.id
   where t.public_reference = upper(btrim(p_public_reference))
     and s.secret_hash = encode(extensions.digest(coalesce(p_secret, ''), 'sha256'), 'hex')
     for update of t;
  if v_ticket.id is null then
    raise exception 'NOT_FOUND' using errcode = 'P0001';
  end if;

  v_prior := public.idempotency_begin(p_idempotency_key, 'request_ticket_attachment',
    jsonb_build_object('public_reference', upper(btrim(p_public_reference)),
                       'mime_type', p_mime_type, 'size_bytes', p_size_bytes));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_ticket.status = 'CLOSED' then
    raise exception 'This conversation is closed. Open a new ticket if you still need help.' using errcode = 'P0001';
  end if;
  v_slot := public.support_new_slot(v_ticket, 'CUSTOMER', null, p_mime_type, p_size_bytes);

  perform public.write_audit(v_ticket.tenant_id, 'request_ticket_attachment', 'upload_slots', v_slot.id::text, null,
                             jsonb_build_object('ticket_id', v_ticket.id, 'uploaded_by_type', 'CUSTOMER',
                                                'mime_type', v_slot.mime_type, 'size_bytes', v_slot.size_bytes),
                             p_idempotency_key, 'WEB', v_ticket.accountable_id);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'attachment_id', v_slot.id, 'storage_path', v_slot.storage_path));
end;
$$;
revoke all on function public.request_ticket_attachment(uuid, text, text, text, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.request_ticket_attachment(uuid, text, text, text, bigint) to service_role;

-- ── request_staff_ticket_attachment (staff, authenticated) ──────────────
-- The same permission check as replying (support_lock_ticket, not ZSM-only).
create or replace function public.request_staff_ticket_attachment(
  p_idempotency_key uuid,
  p_ticket_id       uuid,
  p_mime_type       text,
  p_size_bytes      bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(null);
  v_prior jsonb;
  v_t     public.support_tickets;
  v_slot  public.upload_slots;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'request_staff_ticket_attachment',
    jsonb_build_object('ticket_id', p_ticket_id, 'mime_type', p_mime_type, 'size_bytes', p_size_bytes));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.support_lock_ticket(p_ticket_id, v_me, false);
  if v_t.status = 'CLOSED' then
    raise exception 'This conversation is closed. Open a new ticket if you still need help.' using errcode = 'P0001';
  end if;
  v_slot := public.support_new_slot(v_t, 'STAFF', v_me.profile_id, p_mime_type, p_size_bytes);

  perform public.write_audit(v_t.tenant_id, 'request_staff_ticket_attachment', 'upload_slots', v_slot.id::text, null,
                             jsonb_build_object('ticket_id', v_t.id, 'uploaded_by_type', 'STAFF',
                                                'mime_type', v_slot.mime_type, 'size_bytes', v_slot.size_bytes),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'attachment_id', v_slot.id, 'storage_path', v_slot.storage_path));
end;
$$;
revoke all on function public.request_staff_ticket_attachment(uuid, uuid, text, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.request_staff_ticket_attachment(uuid, uuid, text, bigint) to authenticated;

-- ── add_ticket_message: + p_attachment_ids (A3 behaviour unchanged) ─────
drop function public.add_ticket_message(uuid, text, text, text);
create function public.add_ticket_message(
  p_idempotency_key  uuid,
  p_public_reference text,
  p_secret           text,
  p_message          text,
  p_attachment_ids   uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior    jsonb;
  v_msg      text := btrim(coalesce(p_message, ''));
  v_ticket   public.support_tickets;
  v_msg_id   uuid;
  v_before   text;
  v_attached integer;
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
    jsonb_build_object('public_reference', upper(btrim(p_public_reference)), 'message', p_message,
                       'attachment_ids', to_jsonb(coalesce(p_attachment_ids, '{}'::uuid[]))));
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

  v_attached := public.claim_support_attachments(v_ticket.id, v_msg_id, p_attachment_ids, 'CUSTOMER');

  update public.support_tickets
     set status = case when status = 'RESOLVED' then 'OPEN' else status end,
         resolved_at = case when status = 'RESOLVED' then null else resolved_at end,
         last_message_at = clock_timestamp()
   where id = v_ticket.id
  returning * into v_ticket;

  perform public.support_notify_activity(v_ticket);

  perform public.write_audit(v_ticket.tenant_id, 'add_ticket_message', 'support_tickets', v_ticket.id::text,
                             jsonb_build_object('status', v_before),
                             jsonb_build_object('status', v_ticket.status, 'message_id', v_msg_id,
                                                'attachment_count', v_attached),
                             p_idempotency_key, 'WEB', v_ticket.accountable_id);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('message_id', v_msg_id, 'status', v_ticket.status));
end;
$$;
revoke all on function public.add_ticket_message(uuid, text, text, text, uuid[]) from public, anon, authenticated;
grant execute on function public.add_ticket_message(uuid, text, text, text, uuid[]) to service_role;

-- ── reply_ticket: + p_attachment_ids (A3 behaviour unchanged) ───────────
drop function public.reply_ticket(uuid, uuid, text);
create function public.reply_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_body text,
                                    p_attachment_ids uuid[] default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me       public.tenant_users := public.assert_tenant_role(null);
  v_prior    jsonb;
  v_body     text := btrim(coalesce(p_body, ''));
  v_t        public.support_tickets;
  v_before   text;
  v_msg_id   uuid;
  v_attached integer;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'reply_ticket',
                                      jsonb_build_object('ticket_id', p_ticket_id, 'body', p_body,
                                                         'attachment_ids', to_jsonb(coalesce(p_attachment_ids, '{}'::uuid[]))));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.support_lock_ticket(p_ticket_id, v_me, false);
  if v_t.status = 'CLOSED' then
    raise exception 'This conversation is closed. Open a new ticket if you still need help.' using errcode = 'P0001';
  end if;
  if length(v_body) not between 1 and 2000 then
    raise exception 'the message must be 1 to 2000 characters' using errcode = 'P0001';
  end if;

  insert into public.support_messages (tenant_id, ticket_id, sender_type, sender_id, territory_id, body, created_at)
  values (v_t.tenant_id, v_t.id, 'STAFF', v_me.profile_id, v_t.territory_id, v_body, clock_timestamp())
  returning id into v_msg_id;

  v_attached := public.claim_support_attachments(v_t.id, v_msg_id, p_attachment_ids, 'STAFF');

  v_before := v_t.status;
  update public.support_tickets
     set assigned_to = coalesce(assigned_to, v_me.profile_id),
         status = case when status in ('OPEN', 'RESOLVED') then 'IN_PROGRESS' else status end,
         resolved_at = case when status = 'RESOLVED' then null else resolved_at end,
         last_message_at = clock_timestamp()
   where id = v_t.id
  returning * into v_t;

  perform public.write_audit(v_t.tenant_id, 'reply_ticket', 'support_tickets', v_t.id::text,
                             jsonb_build_object('status', v_before),
                             jsonb_build_object('status', v_t.status, 'message_id', v_msg_id,
                                                'attachment_count', v_attached),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;
revoke all on function public.reply_ticket(uuid, uuid, text, uuid[]) from public, anon, authenticated;
grant execute on function public.reply_ticket(uuid, uuid, text, uuid[]) to authenticated;

-- ── read_support_ticket: + attachments per message ──────────────────────
-- The gateway turns each storage_path into a 10-minute signed URL and strips
-- the path before replying.
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
                      'created_at', m.created_at,
                      'attachments', coalesce((
                        select jsonb_agg(jsonb_build_object('attachment_id', u.id, 'mime_type', u.mime_type,
                                                            'storage_path', u.storage_path)
                                         order by u.claimed_at, u.id)
                          from public.upload_slots u
                         where u.tenant_id = m.tenant_id and u.ticket_id = m.ticket_id and u.message_id = m.id),
                        '[]'::jsonb)) order by m.created_at, m.id)
               from public.support_messages m
              where m.tenant_id = t.tenant_id and m.ticket_id = t.id), '[]'::jsonb))
    from public.support_tickets t
    join public.support_ticket_secrets s on s.tenant_id = t.tenant_id and s.ticket_id = t.id
   where t.public_reference = upper(btrim(p_public_reference))
     and s.secret_hash = encode(extensions.digest(coalesce(p_secret, ''), 'sha256'), 'hex');
$$;

-- ── redact_ticket_customer_data: + delete the buyer's photos ────────────
-- Staff photos stay; the buyer's are queued for the Storage purge. Repeating
-- it with nothing new to redact (contact already
-- redacted, no new buyer message, no buyer photo) is still a no-op.
create or replace function public.redact_ticket_customer_data(p_idempotency_key uuid, p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me        public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior     jsonb;
  v_t         public.support_tickets;
  v_had_email boolean;
  v_already   boolean;
  v_count     integer;
  v_photos    integer;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'redact_ticket_customer_data',
                                      jsonb_build_object('ticket_id', p_ticket_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.support_lock_ticket(p_ticket_id, v_me, true);

  select coalesce(c.customer_email is not null, false), c.redacted_at is not null into v_had_email, v_already
    from public.support_ticket_contacts c where c.ticket_id = v_t.id;
  v_had_email := coalesce(v_had_email, false);
  v_already := coalesce(v_already, false);

  update public.support_ticket_contacts
     set customer_name = null, customer_phone = null, customer_email = null,
         redacted_at = coalesce(redacted_at, now())
   where ticket_id = v_t.id;

  update public.support_messages
     set body = '[redacted]', redacted_at = now()
   where ticket_id = v_t.id and sender_type = 'CUSTOMER' and redacted_at is null;
  get diagnostics v_count = row_count;

  -- the buyer's photos (pending or claimed): the slots go now, which makes
  -- the objects unreadable at once; the objects are queued for the Storage
  -- API purge (a data-modifying CTE always runs, referenced or not)
  with gone as (
    delete from public.upload_slots
     where tenant_id = v_t.tenant_id and ticket_id = v_t.id and uploaded_by_type = 'CUSTOMER'
    returning bucket, storage_path
  ), queued as (
    insert into public.storage_purge_queue (bucket, path)
    select bucket, storage_path from gone
    on conflict (bucket, path) do nothing
  )
  select count(*)::int into v_photos from gone;

  if not (v_already and v_count = 0 and v_photos = 0) then
    perform public.write_audit(v_t.tenant_id, 'TICKET_DATA_REDACTED', 'support_tickets', v_t.id::text, null,
                               jsonb_build_object('ticket_id', v_t.id, 'had_email', v_had_email,
                                                  'messages_redacted', v_count,
                                                  'attachments_deleted', v_photos),
                               p_idempotency_key);
  end if;

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;

-- ── cleanup_pending_upload_slots (cron) ─────────────────────────────────
-- Slots never claimed within 24 hours go, and their paths are queued for the
-- purge. Objects older than 24 hours in either bucket with no slot (say, an
-- upload that landed after its slot was redacted) are queued too. Storage is
-- only read here, never deleted from. Transient rows: no audit. Returns the
-- number of slots deleted.
create or replace function public.cleanup_pending_upload_slots()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  with gone as (
    delete from public.upload_slots
     where claimed_at is null and created_at < now() - interval '24 hours'
    returning bucket, storage_path
  ), queued as (
    insert into public.storage_purge_queue (bucket, path)
    select bucket, storage_path from gone
    on conflict (bucket, path) do nothing
  )
  select count(*)::int into v_count from gone;

  insert into public.storage_purge_queue (bucket, path)
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('support-attachments', 'delivery-proofs')
     and o.created_at < now() - interval '24 hours'
     and not exists (select 1 from public.upload_slots s where s.storage_path = o.name)
  on conflict (bucket, path) do nothing;

  return v_count;
end;
$$;
revoke all on function public.cleanup_pending_upload_slots() from public, anon, authenticated, service_role;

-- ── the purge job's queue API (service_role, for the cron Edge Function) ─
-- Oldest first. The job removes each object through the Storage API, then
-- reports the ids it finished; a failed removal stays queued for next time.
create or replace function public.storage_purge_batch(p_limit integer default 100)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'bucket', q.bucket, 'path', q.path)
                            order by q.queued_at, q.id), '[]'::jsonb)
    from (select * from public.storage_purge_queue
           order by queued_at, id
           limit greatest(1, least(coalesce(p_limit, 100), 1000))) q;
$$;
revoke all on function public.storage_purge_batch(integer) from public, anon, authenticated, service_role;
grant execute on function public.storage_purge_batch(integer) to service_role;

create or replace function public.storage_purge_done(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  delete from public.storage_purge_queue where id = any (coalesce(p_ids, '{}'::uuid[]));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.storage_purge_done(uuid[]) from public, anon, authenticated, service_role;
grant execute on function public.storage_purge_done(uuid[]) to service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('cleanup-upload-slots', '45 0 * * *',
  $$select public.cleanup_pending_upload_slots()$$);
