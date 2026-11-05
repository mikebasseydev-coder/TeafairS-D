-- Addendum A7 §5 — buyer ticket emails, the sender's RPCs, the purge, cron.
--
-- Buyer emails are enqueued by AFTER triggers on the A3 tables, in the same
-- transaction as the write that caused them. An idempotent replay writes
-- nothing, so it enqueues nothing, and the A3 RPCs stay as they are (a later
-- redefinition cannot drop the email). The payload is the reference (plus the
-- status): never the ticket secret, never a message body. The buyer reads the
-- messages on the ticket page with the secret they were given at open.
--
-- The cron-invoked system function email-outbox-send claims due rows,
-- sends them through Resend with the row id as the idempotency key, and
-- completes them.

-- ── buyer enqueue triggers ──────────────────────────────────────────────
-- opened: the contact row is written once, inside open_support_ticket
create or replace function public.support_email_on_contact_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t public.support_tickets;
begin
  select * into v_t from public.support_tickets t where t.id = new.ticket_id;
  if v_t.kind <> 'SYSTEM' and new.redacted_at is null then
    perform public.enqueue_email('BUYER_TICKET_OPENED', new.customer_email,
                                 jsonb_build_object('public_reference', v_t.public_reference),
                                 'support_tickets', v_t.id);
  end if;
  return null;
end;
$$;

-- a staff reply
create or replace function public.support_email_on_staff_message()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ref   text;
  v_email text;
begin
  select t.public_reference, c.customer_email into v_ref, v_email
    from public.support_tickets t
    join public.support_ticket_contacts c on c.ticket_id = t.id and c.redacted_at is null
   where t.id = new.ticket_id and t.kind <> 'SYSTEM';
  if found then
    perform public.enqueue_email('BUYER_TICKET_REPLY', v_email, jsonb_build_object('public_reference', v_ref),
                                 'support_tickets', new.ticket_id);
  end if;
  return null;
end;
$$;

-- RESOLVED or CLOSED, by staff or by the nightly close
create or replace function public.support_email_on_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text;
begin
  if new.kind = 'SYSTEM' then
    return null;
  end if;
  select c.customer_email into v_email
    from public.support_ticket_contacts c where c.ticket_id = new.id and c.redacted_at is null;
  perform public.enqueue_email('BUYER_TICKET_STATUS', v_email,
                               jsonb_build_object('public_reference', new.public_reference, 'status', new.status),
                               'support_tickets', new.id);
  return null;
end;
$$;

-- redaction: the buyer's address leaves the outbox too
create or replace function public.support_email_on_redaction()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.email_outbox
   where source_table = 'support_tickets' and source_id = new.ticket_id and status in ('PENDING', 'SENDING');
  update public.email_outbox set to_email = null
   where source_table = 'support_tickets' and source_id = new.ticket_id and to_email is not null;
  return null;
end;
$$;

revoke all on function public.support_email_on_contact_insert() from public, anon, authenticated, service_role;
revoke all on function public.support_email_on_staff_message() from public, anon, authenticated, service_role;
revoke all on function public.support_email_on_status() from public, anon, authenticated, service_role;
revoke all on function public.support_email_on_redaction() from public, anon, authenticated, service_role;

create trigger support_ticket_contacts_email_opened
  after insert on public.support_ticket_contacts
  for each row execute function public.support_email_on_contact_insert();
create trigger support_messages_email_staff_reply
  after insert on public.support_messages
  for each row when (new.sender_type = 'STAFF')
  execute function public.support_email_on_staff_message();
create trigger support_tickets_email_status
  after update of status on public.support_tickets
  for each row when (new.status in ('RESOLVED', 'CLOSED') and old.status is distinct from new.status)
  execute function public.support_email_on_status();
create trigger support_ticket_contacts_email_redacted
  after update of redacted_at on public.support_ticket_contacts
  for each row when (old.redacted_at is null and new.redacted_at is not null)
  execute function public.support_email_on_redaction();

-- ── the sender's RPCs (service_role: email-outbox-send) ────────────────
-- Due rows, oldest first: PENDING whose next attempt has come, and SENDING
-- rows a crashed sender left for 10 minutes (the Resend idempotency key, the
-- row id, stops a double delivery).
create or replace function public.claim_email_outbox(p_limit integer)
returns setof public.email_outbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  with due as (
    select o.id from public.email_outbox o
     where (o.status = 'PENDING' and o.next_attempt_at <= now())
        or (o.status = 'SENDING' and o.next_attempt_at <= now() - interval '10 minutes')
     order by o.next_attempt_at, o.id
     for update skip locked
     limit greatest(coalesce(p_limit, 0), 0)
  )
  update public.email_outbox o
     set status = 'SENDING', attempts = o.attempts + 1, next_attempt_at = now()
    from due
   where o.id = due.id
  returning o.*;
end;
$$;

-- SENT; RETRY (back off 1, 5, 15, 60 minutes; FAILED after the fifth
-- attempt); PERMANENT (FAILED now: Resend will never accept it). Only a
-- SENDING row moves.
create or replace function public.complete_email_outbox(p_id uuid, p_result text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_result is null or p_result not in ('SENT', 'RETRY', 'PERMANENT') then
    raise exception 'unknown result %', p_result using errcode = '22023';
  end if;
  update public.email_outbox o
     set status = case when p_result = 'SENT' then 'SENT'
                       when p_result = 'PERMANENT' or o.attempts >= 5 then 'FAILED'
                       else 'PENDING' end,
         sent_at = case when p_result = 'SENT' then now() else o.sent_at end,
         next_attempt_at = case when p_result = 'RETRY' and o.attempts < 5
                                then now() + make_interval(mins => (array[1, 5, 15, 60])[greatest(o.attempts, 1)])
                                else o.next_attempt_at end
   where o.id = p_id and o.status = 'SENDING';
end;
$$;

-- SENT and FAILED rows go after 30 days (addresses are not kept longer)
create or replace function public.purge_email_outbox()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  delete from public.email_outbox
   where status in ('SENT', 'FAILED') and created_at < now() - interval '30 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.claim_email_outbox(integer) from public, anon, authenticated;
revoke all on function public.complete_email_outbox(uuid, text) from public, anon, authenticated;
revoke all on function public.purge_email_outbox() from public, anon, authenticated, service_role;
grant execute on function public.claim_email_outbox(integer) to service_role;
grant execute on function public.complete_email_outbox(uuid, text) to service_role;

-- ── cron ────────────────────────────────────────────────────────────────
-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('email-outbox-send', '* * * * *',
  $$select public.invoke_system_function('email-outbox-send', '{}'::jsonb)$$);
select cron.schedule('purge-email-outbox', '45 0 * * *',
  $$select public.purge_email_outbox()$$);
