-- Addendum A7 §4 and §5.1 — tenant support tickets and the email outbox.
--
-- A TENANT_ADMIN (the one write exception to A6 §16) opens a ticket to the
-- tenant's CSM; with no single ACTIVE CSM it waits in the MONVELO_OPERATOR
-- pool. Tenant tickets live apart from the A3 buyer tables. Emails are rows in
-- email_outbox written in the same transaction; the cron-invoked
-- email-outbox-send function drains them (migration 20261031121600). No email
-- payload ever carries a message body or a ticket secret.

-- ── the outbox ──────────────────────────────────────────────────────────
create table public.email_outbox (
  id               uuid primary key default gen_random_uuid(),
  template         text not null check (template in (
                     'BUYER_TICKET_OPENED', 'BUYER_TICKET_REPLY', 'BUYER_TICKET_STATUS',
                     'TENANT_TICKET_OPENED', 'TENANT_TICKET_REPLY', 'TENANT_TICKET_STATUS')),
  -- nulled on the buyer's redaction once the row is SENT or FAILED
  to_email         text check (to_email = lower(to_email)),
  payload          jsonb not null,
  source_table     text not null check (source_table in ('support_tickets', 'tenant_support_tickets')),
  source_id        uuid not null,
  status           text not null default 'PENDING' check (status in ('PENDING', 'SENDING', 'SENT', 'FAILED')),
  attempts         integer not null default 0 check (attempts >= 0),
  next_attempt_at  timestamptz not null default now(),
  sent_at          timestamptz,
  -- clock time, so rows written in one transaction keep their order
  created_at       timestamptz not null default clock_timestamp(),
  check (status not in ('PENDING', 'SENDING') or to_email is not null),
  check (status <> 'SENT' or sent_at is not null)
);
alter table public.email_outbox enable row level security;
-- no policy and no grant: only the SECURITY DEFINER functions touch it
revoke all on public.email_outbox from public, anon, authenticated, service_role;
create index idx_email_outbox_due on public.email_outbox (status, next_attempt_at);
create index idx_email_outbox_source on public.email_outbox (source_table, source_id);

create or replace function public.enqueue_email(
  p_template     text,
  p_to_email     text,
  p_payload      jsonb,
  p_source_table text,
  p_source_id    uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_to text := lower(btrim(coalesce(p_to_email, '')));
begin
  if v_to = '' then
    return;
  end if;
  insert into public.email_outbox (template, to_email, payload, source_table, source_id)
  values (p_template, v_to, p_payload, p_source_table, p_source_id);
end;
$$;
revoke all on function public.enqueue_email(text, text, jsonb, text, uuid)
  from public, anon, authenticated, service_role;

-- ── tenant tickets ──────────────────────────────────────────────────────
create table public.tenant_support_tickets (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants (id) on delete restrict,
  public_reference  text not null unique check (public_reference ~ '^TS-[0-9A-HJKMNP-TV-Z]{6}$'),
  category          text not null check (category in (
                      'TENANT_SETTLEMENT_DISCREPANCY', 'TENANT_STOCK_SHORTAGE',
                      'TENANT_ONBOARDING_ISSUE', 'TENANT_GENERAL_INQUIRY')),
  subject           text not null check (char_length(subject) between 3 and 160),
  opened_by         uuid not null references public.profiles (id) on delete restrict,
  assigned_csm_id   uuid references public.profiles (id) on delete restrict,
  status            text not null default 'OPEN' check (status in ('OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED')),
  priority          text not null default 'MEDIUM' check (priority in ('LOW', 'MEDIUM', 'HIGH', 'URGENT')),
  last_message_at   timestamptz not null default now(),
  resolved_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, id),
  check (status <> 'RESOLVED' or resolved_at is not null)
);
alter table public.tenant_support_tickets enable row level security;
create index idx_tenant_tickets_queue on public.tenant_support_tickets (tenant_id, status, last_message_at desc);
create index idx_tenant_tickets_csm on public.tenant_support_tickets (assigned_csm_id);
create index idx_tenant_tickets_opened_by on public.tenant_support_tickets (opened_by);
create trigger tenant_support_tickets_set_updated_at before update on public.tenant_support_tickets
  for each row execute function public.set_updated_at();

create table public.tenant_support_ticket_messages (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete restrict,
  ticket_id    uuid not null,
  sender_id    uuid not null references public.profiles (id) on delete restrict,
  sender_side  text not null check (sender_side in ('TENANT', 'TEAFAIR')),
  body         text not null check (char_length(body) between 1 and 4000),
  created_at   timestamptz not null default clock_timestamp(),
  unique (tenant_id, id),
  foreign key (tenant_id, ticket_id) references public.tenant_support_tickets (tenant_id, id) on delete restrict
);
alter table public.tenant_support_ticket_messages enable row level security;
create index idx_tenant_ticket_messages_ticket on public.tenant_support_ticket_messages (tenant_id, ticket_id, created_at);
create index idx_tenant_ticket_messages_sender on public.tenant_support_ticket_messages (sender_id);

-- SELECT only; the RPCs write
revoke all on public.tenant_support_tickets, public.tenant_support_ticket_messages from anon, authenticated;
grant select on public.tenant_support_tickets, public.tenant_support_ticket_messages to authenticated;

-- ── read helpers ────────────────────────────────────────────────────────
create or replace function public.is_monvelo_operator()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.profiles p
                  where p.id = (select auth.uid()) and p.platform_role = 'MONVELO_OPERATOR');
$$;
revoke all on function public.is_monvelo_operator() from public, anon;
grant execute on function public.is_monvelo_operator() to authenticated;

-- The JWT tenant, when the caller holds an ACTIVE TENANT_ADMIN or CSM
-- membership there (Spec A §9: claims propose, tenant_users decides).
create or replace function public.my_tenant_ticket_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tu.tenant_id from public.tenant_users tu
   where tu.tenant_id = public.jwt_tenant_id()
     and tu.profile_id = (select auth.uid())
     and tu.status = 'ACTIVE'
     and tu.role in ('TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER');
$$;
revoke all on function public.my_tenant_ticket_tenant_ids() from public, anon;
grant execute on function public.my_tenant_ticket_tenant_ids() to authenticated;

create policy tenant_support_tickets_read on public.tenant_support_tickets
  for select to authenticated
  using ((select public.is_monvelo_operator())
         or tenant_id in (select public.my_tenant_ticket_tenant_ids()));
create policy tenant_support_ticket_messages_read on public.tenant_support_ticket_messages
  for select to authenticated
  using ((select public.is_monvelo_operator())
         or tenant_id in (select public.my_tenant_ticket_tenant_ids()));

-- ── internal helpers ────────────────────────────────────────────────────
-- The caller: an operator (any tenant's ticket), else an ACTIVE TENANT_ADMIN
-- or CSM of the JWT tenant. Anyone else is 42501.
create or replace function public.tenant_ticket_caller()
returns table (is_operator boolean, role public.tenant_role_enum)
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_me public.tenant_users;
begin
  if public.is_monvelo_operator() then
    return query select true, null::public.tenant_role_enum;
    return;
  end if;
  v_me := public.assert_tenant_role(array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  return query select false, v_me.role;
end;
$$;

-- Locks the ticket. A ticket outside the caller's reach is "not found", so a
-- reference never leaks across tenants.
create or replace function public.tenant_ticket_lock(p_ticket_id uuid, p_operator boolean)
returns public.tenant_support_tickets
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_t public.tenant_support_tickets;
begin
  select * into v_t from public.tenant_support_tickets t
   where t.id = p_ticket_id and (p_operator or t.tenant_id = public.jwt_tenant_id())
   for update;
  if not found then
    raise exception 'ticket not found' using errcode = 'P0001';
  end if;
  return v_t;
end;
$$;

-- The assignee while they still hold an ACTIVE CSM membership of the ticket's
-- tenant; otherwise null (the ticket counts as unassigned).
create or replace function public.tenant_ticket_live_csm(p_t public.tenant_support_tickets)
returns uuid
language sql
stable
set search_path = public, pg_temp
as $$
  select p_t.assigned_csm_id
   where p_t.assigned_csm_id is not null
     and exists (select 1 from public.tenant_users tu
                  where tu.tenant_id = p_t.tenant_id and tu.profile_id = p_t.assigned_csm_id
                    and tu.role = 'CLIENT_SERVICE_MANAGER' and tu.status = 'ACTIVE');
$$;

-- Activity for Teafair: the live CSM, else every MONVELO_OPERATOR.
create or replace function public.tenant_ticket_notify_teafair(p_t public.tenant_support_tickets)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_csm     uuid := public.tenant_ticket_live_csm(p_t);
  v_payload jsonb := jsonb_build_object('ticket_id', p_t.id, 'public_reference', p_t.public_reference);
  v_body    text := 'Tenant ticket ' || p_t.public_reference || ' needs a reply.';
begin
  if v_csm is not null then
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    values (p_t.tenant_id, v_csm, 'TENANT_TICKET_ACTIVITY', 'New tenant support message', v_body, v_payload);
  else
    insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
    select p_t.tenant_id, p.id, 'TENANT_TICKET_ACTIVITY', 'New tenant support message', v_body, v_payload
      from public.profiles p where p.platform_role = 'MONVELO_OPERATOR';
  end if;
end;
$$;

-- An update for the tenant: the opener, in-app.
create or replace function public.tenant_ticket_notify_opener(p_t public.tenant_support_tickets, p_title text)
returns void
language sql
set search_path = public, pg_temp
as $$
  insert into public.notifications (tenant_id, user_id, kind, title, body, payload)
  values (p_t.tenant_id, p_t.opened_by, 'TENANT_TICKET_UPDATE', p_title,
          'Support ticket ' || p_t.public_reference || ': ' || p_title,
          jsonb_build_object('ticket_id', p_t.id, 'public_reference', p_t.public_reference));
$$;

-- An email to the opener's profile address (none when they have none).
create or replace function public.tenant_ticket_email(p_t public.tenant_support_tickets, p_template text)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_payload jsonb := jsonb_build_object('public_reference', p_t.public_reference,
                                        'category', p_t.category, 'subject', p_t.subject);
begin
  if p_template = 'TENANT_TICKET_STATUS' then
    v_payload := v_payload || jsonb_build_object('status', p_t.status);
  end if;
  perform public.enqueue_email(p_template, (select p.email from public.profiles p where p.id = p_t.opened_by),
                               v_payload, 'tenant_support_tickets', p_t.id);
end;
$$;

revoke all on function public.tenant_ticket_caller() from public, anon, authenticated, service_role;
revoke all on function public.tenant_ticket_lock(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function public.tenant_ticket_live_csm(public.tenant_support_tickets) from public, anon, authenticated, service_role;
revoke all on function public.tenant_ticket_notify_teafair(public.tenant_support_tickets) from public, anon, authenticated, service_role;
revoke all on function public.tenant_ticket_notify_opener(public.tenant_support_tickets, text) from public, anon, authenticated, service_role;
revoke all on function public.tenant_ticket_email(public.tenant_support_tickets, text) from public, anon, authenticated, service_role;

-- Audit rows of tenant tickets are tenant-null (as A6 R15): audit_logs is
-- read tenant-wide by the tenant's ZSMs and TMs, who see no tenant ticket
-- (§4.2). The entity id still names the ticket for platform staff.

-- ── open_tenant_ticket ──────────────────────────────────────────────────
create or replace function public.open_tenant_ticket(
  p_idempotency_key uuid,
  p_category        text,
  p_subject         text,
  p_message         text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['TENANT_ADMIN']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_subject text := btrim(coalesce(p_subject, ''));
  v_msg     text := btrim(coalesce(p_message, ''));
  v_csm     uuid;
  v_ref     text;
  v_t       public.tenant_support_tickets;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'open_tenant_ticket',
               jsonb_build_object('category', p_category, 'subject', v_subject, 'message', md5(v_msg)));
  if v_prior is not null then
    return v_prior;
  end if;

  if char_length(v_subject) not between 3 and 160 then
    raise exception 'the subject must be 3 to 160 characters' using errcode = 'P0001';
  end if;
  if char_length(v_msg) not between 1 and 4000 then
    raise exception 'the message must be 1 to 4000 characters' using errcode = 'P0001';
  end if;

  -- auto-assign only when the tenant has exactly one ACTIVE CSM
  select case when count(*) = 1 then min(tu.profile_id::text)::uuid end into v_csm
    from public.tenant_users tu
   where tu.tenant_id = v_me.tenant_id and tu.role = 'CLIENT_SERVICE_MANAGER' and tu.status = 'ACTIVE';

  loop
    v_ref := public.new_crockford_reference('TS');
    exit when not exists (select 1 from public.tenant_support_tickets where public_reference = v_ref);
  end loop;

  insert into public.tenant_support_tickets (tenant_id, public_reference, category, subject, opened_by,
                                             assigned_csm_id, last_message_at)
  values (v_me.tenant_id, v_ref, p_category, v_subject, v_me.profile_id, v_csm, clock_timestamp())
  returning * into v_t;

  insert into public.tenant_support_ticket_messages (tenant_id, ticket_id, sender_id, sender_side, body)
  values (v_t.tenant_id, v_t.id, v_me.profile_id, 'TENANT', v_msg);

  perform public.tenant_ticket_notify_teafair(v_t);
  perform public.tenant_ticket_email(v_t, 'TENANT_TICKET_OPENED');

  perform public.write_audit(null, 'open_tenant_ticket', 'tenant_support_tickets', v_t.id::text, null,
                             jsonb_build_object('category', v_t.category, 'assigned_csm_id', v_t.assigned_csm_id),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'public_reference', v_t.public_reference, 'status', v_t.status,
    'assigned_csm_id', v_t.assigned_csm_id));
end;
$$;

-- ── reply_tenant_ticket ─────────────────────────────────────────────────
create or replace function public.reply_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      record;
  v_uid    uuid := (select auth.uid());
  v_prior  jsonb;
  v_body   text := btrim(coalesce(p_body, ''));
  v_t      public.tenant_support_tickets;
  v_side   text;
  v_before text;
  v_msg    uuid;
begin
  select * into v_c from public.tenant_ticket_caller();
  v_prior := public.idempotency_begin(p_idempotency_key, 'reply_tenant_ticket',
               jsonb_build_object('ticket_id', p_ticket_id, 'body', md5(v_body)));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.tenant_ticket_lock(p_ticket_id, v_c.is_operator);
  if v_c.is_operator then
    v_side := 'TEAFAIR';
  elsif v_c.role = 'TENANT_ADMIN' then
    v_side := 'TENANT';
  elsif public.tenant_ticket_live_csm(v_t) is not distinct from v_uid then
    v_side := 'TEAFAIR';
  else
    raise exception 'only the assigned CSM or an operator replies for Teafair' using errcode = '42501';
  end if;
  if v_t.status = 'CLOSED' then
    raise exception 'this ticket is closed' using errcode = 'P0001';
  end if;
  if char_length(v_body) not between 1 and 4000 then
    raise exception 'the message must be 1 to 4000 characters' using errcode = 'P0001';
  end if;

  insert into public.tenant_support_ticket_messages (tenant_id, ticket_id, sender_id, sender_side, body)
  values (v_t.tenant_id, v_t.id, v_uid, v_side, v_body)
  returning id into v_msg;

  v_before := v_t.status;
  update public.tenant_support_tickets
     set last_message_at = clock_timestamp(),
         status = case when v_side = 'TEAFAIR' and status = 'OPEN' then 'IN_PROGRESS'
                       when v_side = 'TENANT' and status = 'RESOLVED' then 'OPEN'
                       else status end,
         resolved_at = case when v_side = 'TENANT' and status = 'RESOLVED' then null else resolved_at end
   where id = v_t.id
  returning * into v_t;

  if v_side = 'TENANT' then
    perform public.tenant_ticket_notify_teafair(v_t);
  else
    perform public.tenant_ticket_notify_opener(v_t, 'Teafair replied');
    perform public.tenant_ticket_email(v_t, 'TENANT_TICKET_REPLY');
  end if;

  perform public.write_audit(null, 'reply_tenant_ticket', 'tenant_support_tickets', v_t.id::text,
                             jsonb_build_object('status', v_before),
                             jsonb_build_object('status', v_t.status, 'message_id', v_msg, 'sender_side', v_side),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'message_id', v_msg, 'status', v_t.status));
end;
$$;

-- ── claim_tenant_ticket / release_tenant_ticket ─────────────────────────
create or replace function public.claim_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      record;
  v_uid    uuid := (select auth.uid());
  v_prior  jsonb;
  v_t      public.tenant_support_tickets;
  v_before uuid;
begin
  select * into v_c from public.tenant_ticket_caller();
  if v_c.is_operator or v_c.role <> 'CLIENT_SERVICE_MANAGER' then
    raise exception 'only a CSM of the tenant claims a ticket' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'claim_tenant_ticket',
                                      jsonb_build_object('ticket_id', p_ticket_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.tenant_ticket_lock(p_ticket_id, false);
  if v_t.status = 'CLOSED' then
    raise exception 'this ticket is closed' using errcode = 'P0001';
  end if;
  if public.tenant_ticket_live_csm(v_t) is not null then
    raise exception 'this ticket is already assigned' using errcode = 'P0001';
  end if;

  v_before := v_t.assigned_csm_id;
  update public.tenant_support_tickets set assigned_csm_id = v_uid where id = v_t.id returning * into v_t;

  perform public.write_audit(null, 'claim_tenant_ticket', 'tenant_support_tickets', v_t.id::text,
                             jsonb_build_object('assigned_csm_id', v_before),
                             jsonb_build_object('assigned_csm_id', v_t.assigned_csm_id), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'assigned_csm_id', v_t.assigned_csm_id));
end;
$$;

create or replace function public.release_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c     record;
  v_uid   uuid := (select auth.uid());
  v_prior jsonb;
  v_t     public.tenant_support_tickets;
begin
  select * into v_c from public.tenant_ticket_caller();
  if v_c.is_operator or v_c.role <> 'CLIENT_SERVICE_MANAGER' then
    raise exception 'only the assigned CSM releases a ticket' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'release_tenant_ticket',
                                      jsonb_build_object('ticket_id', p_ticket_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.tenant_ticket_lock(p_ticket_id, false);
  if public.tenant_ticket_live_csm(v_t) is distinct from v_uid then
    raise exception 'only the assigned CSM releases a ticket' using errcode = '42501';
  end if;

  update public.tenant_support_tickets set assigned_csm_id = null where id = v_t.id returning * into v_t;
  perform public.tenant_ticket_notify_teafair(v_t);

  perform public.write_audit(null, 'release_tenant_ticket', 'tenant_support_tickets', v_t.id::text,
                             jsonb_build_object('assigned_csm_id', v_uid),
                             jsonb_build_object('assigned_csm_id', null), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'assigned_csm_id', null));
end;
$$;

-- ── assign_tenant_ticket (MONVELO_OPERATOR) ─────────────────────────────
create or replace function public.assign_tenant_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_csm_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior  jsonb;
  v_t      public.tenant_support_tickets;
  v_before uuid;
begin
  perform public.assert_platform_role(array['MONVELO_OPERATOR']::public.platform_role_enum[]);
  v_prior := public.idempotency_begin(p_idempotency_key, 'assign_tenant_ticket',
               jsonb_build_object('ticket_id', p_ticket_id, 'csm_profile_id', p_csm_profile_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.tenant_ticket_lock(p_ticket_id, true);
  if v_t.status = 'CLOSED' then
    raise exception 'this ticket is closed' using errcode = 'P0001';
  end if;
  if p_csm_profile_id is not null and not exists (
       select 1 from public.tenant_users tu
        where tu.tenant_id = v_t.tenant_id and tu.profile_id = p_csm_profile_id
          and tu.role = 'CLIENT_SERVICE_MANAGER' and tu.status = 'ACTIVE') then
    raise exception 'that person is not an active CSM of this tenant' using errcode = 'P0001';
  end if;

  v_before := v_t.assigned_csm_id;
  update public.tenant_support_tickets set assigned_csm_id = p_csm_profile_id where id = v_t.id returning * into v_t;
  perform public.tenant_ticket_notify_teafair(v_t);

  perform public.write_audit(null, 'assign_tenant_ticket', 'tenant_support_tickets', v_t.id::text,
                             jsonb_build_object('assigned_csm_id', v_before),
                             jsonb_build_object('assigned_csm_id', v_t.assigned_csm_id), p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'assigned_csm_id', v_t.assigned_csm_id));
end;
$$;

-- ── update_tenant_ticket_status ─────────────────────────────────────────
create or replace function public.update_tenant_ticket_status(p_idempotency_key uuid, p_ticket_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      record;
  v_uid    uuid := (select auth.uid());
  v_prior  jsonb;
  v_t      public.tenant_support_tickets;
  v_before text;
begin
  select * into v_c from public.tenant_ticket_caller();
  if not v_c.is_operator and v_c.role <> 'CLIENT_SERVICE_MANAGER' then
    raise exception 'only the assigned CSM or an operator changes the status' using errcode = '42501';
  end if;
  v_prior := public.idempotency_begin(p_idempotency_key, 'update_tenant_ticket_status',
                                      jsonb_build_object('ticket_id', p_ticket_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.tenant_ticket_lock(p_ticket_id, v_c.is_operator);
  if not v_c.is_operator and public.tenant_ticket_live_csm(v_t) is distinct from v_uid then
    raise exception 'only the assigned CSM or an operator changes the status' using errcode = '42501';
  end if;
  if not (   (v_t.status = 'IN_PROGRESS' and p_status = 'RESOLVED')
          or (v_t.status in ('OPEN', 'IN_PROGRESS', 'RESOLVED') and p_status = 'CLOSED')) then
    raise exception 'that status change is not allowed' using errcode = 'P0001';
  end if;

  v_before := v_t.status;
  update public.tenant_support_tickets
     set status = p_status,
         resolved_at = case when p_status = 'RESOLVED' then now() else resolved_at end
   where id = v_t.id
  returning * into v_t;

  perform public.tenant_ticket_notify_opener(v_t, 'Ticket ' || lower(v_t.status));
  perform public.tenant_ticket_email(v_t, 'TENANT_TICKET_STATUS');

  perform public.write_audit(null, 'update_tenant_ticket_status', 'tenant_support_tickets', v_t.id::text,
                             jsonb_build_object('status', v_before), jsonb_build_object('status', v_t.status),
                             p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status));
end;
$$;

-- ── the nightly auto-close (as A3's close_resolved_support_tickets) ────
create or replace function public.close_resolved_tenant_tickets()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t     public.tenant_support_tickets;
  v_count integer := 0;
begin
  for v_t in
    update public.tenant_support_tickets
       set status = 'CLOSED'
     where status = 'RESOLVED' and resolved_at < now() - interval '7 days'
    returning *
  loop
    v_count := v_count + 1;
    perform public.tenant_ticket_notify_opener(v_t, 'Ticket closed');
    perform public.tenant_ticket_email(v_t, 'TENANT_TICKET_STATUS');
    perform public.write_audit(null, 'close_resolved_tenant_tickets', 'tenant_support_tickets',
                               v_t.id::text, jsonb_build_object('status', 'RESOLVED'),
                               jsonb_build_object('status', 'CLOSED'), null, 'CRON', null);
  end loop;
  return v_count;
end;
$$;
revoke all on function public.close_resolved_tenant_tickets() from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('close-resolved-tenant-tickets', '35 0 * * *',
  $$select public.close_resolved_tenant_tickets()$$);

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.open_tenant_ticket(uuid, text, text, text) from public, anon;
revoke all on function public.reply_tenant_ticket(uuid, uuid, text) from public, anon;
revoke all on function public.claim_tenant_ticket(uuid, uuid) from public, anon;
revoke all on function public.release_tenant_ticket(uuid, uuid) from public, anon;
revoke all on function public.assign_tenant_ticket(uuid, uuid, uuid) from public, anon;
revoke all on function public.update_tenant_ticket_status(uuid, uuid, text) from public, anon;
grant execute on function public.open_tenant_ticket(uuid, text, text, text) to authenticated;
grant execute on function public.reply_tenant_ticket(uuid, uuid, text) to authenticated;
grant execute on function public.claim_tenant_ticket(uuid, uuid) to authenticated;
grant execute on function public.release_tenant_ticket(uuid, uuid) to authenticated;
grant execute on function public.assign_tenant_ticket(uuid, uuid, uuid) to authenticated;
grant execute on function public.update_tenant_ticket_status(uuid, uuid, text) to authenticated;
