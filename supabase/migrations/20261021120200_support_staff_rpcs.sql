-- Addendum A3 §6 — staff RPCs for web chat and ticketing: claim, reply,
-- status, priority, assign, redaction, and the 7-day auto-close.
-- Standard write contract: assert_tenant_role -> idempotency_begin -> writes
-- -> write_audit (USER) -> idempotency_complete. No audit row or reply carries
-- a message body.

-- ── support_lock_ticket (internal) ──────────────────────────────────────
-- Lock the ticket and check the caller may act on it. A ticket outside the
-- caller's tenant is "not found"; everyone else who may not act is 42501.
-- Who may act: a ZSM; the TM of the ticket's territory; and, on PRE_PURCHASE
-- and SYSTEM tickets only, the accountable or assigned person. ORDER tickets
-- follow A2 (user decision 2026-10-21): never the order's selling agent.
-- Once claimed (assigned_to set), only the assignee and ZSMs may act. The
-- hold lapses when the assignee is no longer an ACTIVE member of the tenant:
-- the ticket is then treated as unassigned, and a permitted claim takes it.
create or replace function public.support_lock_ticket(
  p_ticket_id uuid,
  p_me        public.tenant_users,
  p_zsm_only  boolean
)
returns public.support_tickets
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

  if p_me.role = 'ZSM' then
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
$$;
revoke all on function public.support_lock_ticket(uuid, public.tenant_users, boolean)
  from public, anon, authenticated, service_role;

-- ── claim_ticket ────────────────────────────────────────────────────────
create or replace function public.claim_ticket(p_idempotency_key uuid, p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_t      public.support_tickets;
  v_before jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'claim_ticket',
                                      jsonb_build_object('ticket_id', p_ticket_id));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.support_lock_ticket(p_ticket_id, v_me, false);
  if v_t.status = 'CLOSED' then
    raise exception 'this ticket is closed' using errcode = 'P0001';
  end if;
  -- support_lock_ticket already refuses a non-ZSM on a ticket someone else
  -- holds; a ZSM takeover is audited below with before.assigned_to

  v_before := jsonb_build_object('status', v_t.status, 'assigned_to', v_t.assigned_to);
  update public.support_tickets
     set assigned_to = v_me.profile_id,
         status = case when status = 'OPEN' then 'IN_PROGRESS' else status end
   where id = v_t.id
  returning * into v_t;

  perform public.write_audit(v_t.tenant_id, 'claim_ticket', 'support_tickets', v_t.id::text, v_before,
                             jsonb_build_object('status', v_t.status, 'assigned_to', v_t.assigned_to),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;

-- ── reply_ticket ────────────────────────────────────────────────────────
create or replace function public.reply_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_body   text := btrim(coalesce(p_body, ''));
  v_t      public.support_tickets;
  v_before text;
  v_msg_id uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'reply_ticket',
                                      jsonb_build_object('ticket_id', p_ticket_id, 'body', p_body));
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
                             jsonb_build_object('status', v_t.status, 'message_id', v_msg_id),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;

-- ── update_ticket_status ────────────────────────────────────────────────
create or replace function public.update_ticket_status(p_idempotency_key uuid, p_ticket_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_t      public.support_tickets;
  v_before text;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'update_ticket_status',
                                      jsonb_build_object('ticket_id', p_ticket_id, 'status', p_status));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.support_lock_ticket(p_ticket_id, v_me, false);
  if not (   (v_t.status = 'IN_PROGRESS' and p_status = 'RESOLVED')
          or (v_t.status in ('OPEN', 'IN_PROGRESS', 'RESOLVED') and p_status = 'CLOSED')) then
    raise exception 'that status change is not allowed' using errcode = 'P0001';
  end if;

  v_before := v_t.status;
  update public.support_tickets
     set status = p_status,
         resolved_at = case when p_status = 'RESOLVED' then now() else resolved_at end
   where id = v_t.id
  returning * into v_t;

  perform public.write_audit(v_t.tenant_id, 'update_ticket_status', 'support_tickets', v_t.id::text,
                             jsonb_build_object('status', v_before),
                             jsonb_build_object('status', v_t.status),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;

-- ── set_ticket_priority ─────────────────────────────────────────────────
create or replace function public.set_ticket_priority(p_idempotency_key uuid, p_ticket_id uuid, p_priority text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(null);
  v_prior  jsonb;
  v_t      public.support_tickets;
  v_before text;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'set_ticket_priority',
                                      jsonb_build_object('ticket_id', p_ticket_id, 'priority', p_priority));
  if v_prior is not null then
    return v_prior;
  end if;

  v_t := public.support_lock_ticket(p_ticket_id, v_me, false);
  if p_priority is null or p_priority not in ('LOW', 'MEDIUM', 'HIGH', 'URGENT') then
    raise exception 'priority is not valid' using errcode = 'P0001';
  end if;

  v_before := v_t.priority;
  update public.support_tickets set priority = p_priority where id = v_t.id returning * into v_t;

  perform public.write_audit(v_t.tenant_id, 'set_ticket_priority', 'support_tickets', v_t.id::text,
                             jsonb_build_object('priority', v_before),
                             jsonb_build_object('priority', v_t.priority),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;

-- ── assign_ticket (ZSM, PRE_PURCHASE only) ──────────────────────────────
-- D1's chain: the territory's TM, else the zone's ZSM, else
-- web_default_agent_id, each only if an ACTIVE member; else the ZSM queue.
create or replace function public.assign_ticket(p_idempotency_key uuid, p_ticket_id uuid, p_territory_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── redact_ticket_customer_data (ZSM) ───────────────────────────────────
-- Blank the contact record and every buyer message body. Staff replies,
-- SYSTEM messages and the ticket's structure stay. The audit row is a
-- summary. Repeating it on an already redacted contact with no new buyer
-- message is a no-op: no audit row, the normal reply.
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

  if not (v_already and v_count = 0) then
    perform public.write_audit(v_t.tenant_id, 'TICKET_DATA_REDACTED', 'support_tickets', v_t.id::text, null,
                               jsonb_build_object('ticket_id', v_t.id, 'had_email', v_had_email,
                                                  'messages_redacted', v_count),
                               p_idempotency_key);
  end if;

  return public.idempotency_complete(p_idempotency_key, jsonb_build_object(
    'ticket_id', v_t.id, 'status', v_t.status, 'priority', v_t.priority, 'assigned_to', v_t.assigned_to));
end;
$$;

-- ── close_resolved_support_tickets (cron) ───────────────────────────────
create or replace function public.close_resolved_support_tickets()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    update public.support_tickets
       set status = 'CLOSED'
     where status = 'RESOLVED' and resolved_at < now() - interval '7 days'
    returning id, tenant_id, accountable_id
  loop
    v_count := v_count + 1;
    perform public.write_audit(v_row.tenant_id, 'close_resolved_support_tickets', 'support_tickets',
                               v_row.id::text,
                               jsonb_build_object('status', 'RESOLVED'), jsonb_build_object('status', 'CLOSED'),
                               null, 'CRON', v_row.accountable_id);
  end loop;
  return v_count;
end;
$$;
revoke all on function public.close_resolved_support_tickets()
  from public, anon, authenticated, service_role;

-- cron.schedule upserts by name, so re-running this migration is harmless.
select cron.schedule('close-resolved-support-tickets', '30 0 * * *',
  $$select public.close_resolved_support_tickets()$$);

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.claim_ticket(uuid, uuid) from public, anon, authenticated;
revoke all on function public.reply_ticket(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.update_ticket_status(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.set_ticket_priority(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.assign_ticket(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.redact_ticket_customer_data(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_ticket(uuid, uuid) to authenticated;
grant execute on function public.reply_ticket(uuid, uuid, text) to authenticated;
grant execute on function public.update_ticket_status(uuid, uuid, text) to authenticated;
grant execute on function public.set_ticket_priority(uuid, uuid, text) to authenticated;
grant execute on function public.assign_ticket(uuid, uuid, uuid) to authenticated;
grant execute on function public.redact_ticket_customer_data(uuid, uuid) to authenticated;
