-- Addendum A7 §5 — buyer ticket emails through the outbox, and the sender's
-- claim / complete / purge state machine. The email carries the reference
-- only: never the secret, never a message body.
begin;
create extension if not exists pgtap with schema extensions;

select plan(43);

-- ── fixtures (as postgres): TEAFAIR, one ZSM ────────────────────────────
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', now());
insert into public.tenant_users (id, tenant_id, profile_id, role, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'ZSM', 'ACTIVE', true);

create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('a7000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated;

create temporary table tk (n text primary key, id uuid, ref text);
grant all on tk to authenticated;
create function pg_temp.t(p_n text) returns uuid language sql as $$ select id from tk where n = p_n $$;
create function pg_temp.r(p_n text) returns text language sql as $$ select ref from tk where n = p_n $$;
grant execute on function pg_temp.t(text), pg_temp.r(text) to authenticated;

-- a buyer opens a pre-purchase ticket (uncovered area: the ZSM queue)
create function pg_temp.open(p_n text, p_key integer, p_email text) returns void language plpgsql as $$
declare v jsonb;
begin
  v := public.open_support_ticket(pg_temp.k(p_key), 'PRE_PURCHASE', 'PRODUCT', 'Buyer-body-' || p_n,
         jsonb_strip_nulls(jsonb_build_object('name', 'Ada', 'phone', '+23480111111' || lpad(p_key::text, 2, '0'),
                                              'email', p_email)),
         null, null, md5('ng_lga:LA:Ikeja')::uuid, encode(extensions.digest('s3cret-' || p_n, 'sha256'), 'hex'));
  insert into tk values (p_n, (v ->> 'ticket_id')::uuid, v ->> 'public_reference');
end; $$;

create function pg_temp.as_zsm() returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', '20000000-0000-0000-0000-000000000001', 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', '7eaf0000-0000-4000-8000-000000000001'))::text, true);
$$;
grant execute on function pg_temp.as_zsm() to authenticated;

create function pg_temp.outbox(p_n text) returns text language sql as $$
  select coalesce(string_agg(template || coalesce(':' || (payload ->> 'status'), ''), ',' order by created_at), '')
    from public.email_outbox where source_table = 'support_tickets' and source_id = pg_temp.t(p_n) $$;

select pg_temp.open('a', 1, 'Ada@Example.com');
select pg_temp.open('n', 2, null);

-- ── opened ──────────────────────────────────────────────────────────────
select is(pg_temp.outbox('a'), 'BUYER_TICKET_OPENED', 'opening with an email enqueues a confirmation');
select is((select to_email from public.email_outbox where source_id = pg_temp.t('a')), 'ada@example.com',
  'to the contact''s address');
select is((select payload from public.email_outbox where source_id = pg_temp.t('a')),
  jsonb_build_object('public_reference', pg_temp.r('a')), 'the payload is the reference only');
select is(pg_temp.outbox('n'), '', 'opening without an email enqueues nothing');

-- ── buyer message, staff reply, replay ──────────────────────────────────
select public.add_ticket_message(pg_temp.k(10), pg_temp.r('a'), 's3cret-a', 'Buyer-follow-up');
select is(pg_temp.outbox('a'), 'BUYER_TICKET_OPENED', 'a buyer message enqueues nothing');

select pg_temp.as_zsm();
select public.claim_ticket(pg_temp.k(11), pg_temp.t('a'));
select public.reply_ticket(pg_temp.k(12), pg_temp.t('a'), 'Staff-reply-body');
select public.reply_ticket(pg_temp.k(12), pg_temp.t('a'), 'Staff-reply-body');
reset role;
select is(pg_temp.outbox('a'), 'BUYER_TICKET_OPENED,BUYER_TICKET_REPLY', 'a staff reply enqueues one email; its replay none');

select pg_temp.as_zsm();
select public.set_ticket_priority(pg_temp.k(13), pg_temp.t('a'), 'HIGH');
reset role;
select is(pg_temp.outbox('a'), 'BUYER_TICKET_OPENED,BUYER_TICKET_REPLY', 'a priority change enqueues nothing');

-- ── status ──────────────────────────────────────────────────────────────
select pg_temp.as_zsm();
select public.update_ticket_status(pg_temp.k(14), pg_temp.t('a'), 'RESOLVED');
reset role;
select is(pg_temp.outbox('a'), 'BUYER_TICKET_OPENED,BUYER_TICKET_REPLY,BUYER_TICKET_STATUS:RESOLVED',
  'RESOLVED enqueues a status email');
update public.support_tickets set resolved_at = now() - interval '8 days' where id = pg_temp.t('a');
select public.close_resolved_support_tickets();
select is(pg_temp.outbox('a'),
  'BUYER_TICKET_OPENED,BUYER_TICKET_REPLY,BUYER_TICKET_STATUS:RESOLVED,BUYER_TICKET_STATUS:CLOSED',
  'the nightly close enqueues a CLOSED email');
select is((select count(*)::int from public.email_outbox where template = 'BUYER_TICKET_STATUS'
            and source_id = pg_temp.t('a') and payload ? 'status'
            and payload - 'status' = jsonb_build_object('public_reference', pg_temp.r('a'))), 2,
  'status payloads are the reference and the status');

-- ── a SYSTEM ticket emails nobody ───────────────────────────────────────
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, system_key)
values ('60000000-0000-0000-0000-0000000000ff', '7eaf0000-0000-4000-8000-000000000001', 'TK-SYS071', 'SYSTEM',
        'SYSTEM', 'test:071');
insert into tk values ('s', '60000000-0000-0000-0000-0000000000ff', 'TK-SYS071');
update public.support_tickets set status = 'CLOSED' where id = pg_temp.t('s');
select is(pg_temp.outbox('s'), '', 'a SYSTEM ticket enqueues nothing');

-- ── no secret, no body ──────────────────────────────────────────────────
select ok(not exists (select 1 from public.email_outbox
                       where payload::text ~* '(s3cret|Buyer-body|Buyer-follow-up|Staff-reply-body|\+2348)'),
  'no secret, message text or phone in any payload');

-- ── redaction ───────────────────────────────────────────────────────────
select pg_temp.open('b', 3, 'bola@example.com');
update public.email_outbox set status = 'SENT', sent_at = now() where source_id = pg_temp.t('b');
select pg_temp.as_zsm();
select public.claim_ticket(pg_temp.k(20), pg_temp.t('b'));
select public.reply_ticket(pg_temp.k(21), pg_temp.t('b'), 'Staff-reply-body');
select public.redact_ticket_customer_data(pg_temp.k(22), pg_temp.t('b'));
reset role;
select is((select count(*)::int from public.email_outbox where source_id = pg_temp.t('b') and status = 'PENDING'), 0,
  'redaction deletes the PENDING rows');
select is((select count(*)::int from public.email_outbox where source_id = pg_temp.t('b')), 1,
  'the SENT row is kept');
select is((select to_email from public.email_outbox where source_id = pg_temp.t('b')), null,
  'its address is gone');
select pg_temp.as_zsm();
select public.reply_ticket(pg_temp.k(23), pg_temp.t('b'), 'after redaction');
reset role;
select is((select count(*)::int from public.email_outbox where source_id = pg_temp.t('b')), 1,
  'a reply after redaction enqueues nothing');

-- redacted between enqueue and send: nothing is left to claim
select pg_temp.open('c', 4, 'chi@example.com');
select pg_temp.as_zsm();
select public.redact_ticket_customer_data(pg_temp.k(30), pg_temp.t('c'));
reset role;
delete from public.email_outbox where source_id <> pg_temp.t('c');
select is((select count(*)::int from public.claim_email_outbox(10)), 0, 'a redacted buyer''s email is never claimed');

-- ── claim ───────────────────────────────────────────────────────────────
create function pg_temp.row(p_status text, p_attempts integer, p_next interval, p_created interval)
returns uuid language sql as $$
  insert into public.email_outbox (template, to_email, payload, source_table, source_id, status, attempts,
                                   next_attempt_at, sent_at, created_at)
  values ('BUYER_TICKET_REPLY', 'x@example.com', '{"public_reference":"TK-ZZZZZZ"}', 'support_tickets',
          gen_random_uuid(), p_status, p_attempts, now() + p_next,
          case when p_status = 'SENT' then now() end, now() + p_created)
  returning id $$;
create temporary table ids (n text primary key, id uuid);

delete from public.email_outbox;
insert into ids values ('p1', pg_temp.row('PENDING', 0, interval '-2 minutes', interval '0'));
insert into ids values ('p2', pg_temp.row('PENDING', 0, interval '-1 minutes', interval '0'));
insert into ids values ('future', pg_temp.row('PENDING', 0, interval '5 minutes', interval '0'));
insert into ids values ('stale', pg_temp.row('SENDING', 1, interval '-11 minutes', interval '0'));
insert into ids values ('fresh', pg_temp.row('SENDING', 1, interval '-9 minutes', interval '0'));

create temporary table got (id uuid);
insert into got select id from public.claim_email_outbox(2);
select is((select count(*)::int from got), 2, 'a claim takes at most p_limit rows');
select ok((select id from ids where n = 'stale') in (select id from got), 'the oldest due row first: a stale SENDING');
insert into got select id from public.claim_email_outbox(2);
select is((select count(*)::int from got), 3, 'the second claim takes the one row still due');
select is((select count(distinct id)::int from got), 3, 'claims are disjoint');
select ok((select id from ids where n = 'future') not in (select id from got), 'a row not yet due is left');
select ok((select id from ids where n = 'fresh') not in (select id from got), 'a SENDING row under 10 minutes is left');
select is((select status || ':' || attempts from public.email_outbox where id = (select id from ids where n = 'p1')),
  'SENDING:1', 'a claimed row is SENDING with one attempt');
select is((select status || ':' || attempts from public.email_outbox where id = (select id from ids where n = 'stale')),
  'SENDING:2', 'a reclaimed row counts its attempt');

-- ── complete ────────────────────────────────────────────────────────────
select public.complete_email_outbox((select id from ids where n = 'p1'), 'SENT');
select ok((select status = 'SENT' and sent_at is not null from public.email_outbox
            where id = (select id from ids where n = 'p1')), 'SENT stamps sent_at');
select public.complete_email_outbox((select id from ids where n = 'p2'), 'RETRY');
select ok((select status = 'PENDING' and next_attempt_at between now() + interval '59 seconds' and now() + interval '61 seconds'
             from public.email_outbox where id = (select id from ids where n = 'p2')),
  'RETRY after attempt 1 waits a minute');
update public.email_outbox set status = 'SENDING', attempts = 3 where id = (select id from ids where n = 'p2');
select public.complete_email_outbox((select id from ids where n = 'p2'), 'RETRY');
select ok((select status = 'PENDING' and next_attempt_at between now() + interval '899 seconds' and now() + interval '901 seconds'
             from public.email_outbox where id = (select id from ids where n = 'p2')),
  'RETRY after attempt 3 waits 15 minutes');
update public.email_outbox set status = 'SENDING', attempts = 5 where id = (select id from ids where n = 'p2');
select public.complete_email_outbox((select id from ids where n = 'p2'), 'RETRY');
select is((select status from public.email_outbox where id = (select id from ids where n = 'p2')), 'FAILED',
  'RETRY after attempt 5 is FAILED');
select public.complete_email_outbox((select id from ids where n = 'stale'), 'PERMANENT');
select is((select status from public.email_outbox where id = (select id from ids where n = 'stale')), 'FAILED',
  'PERMANENT is FAILED at once');
update public.email_outbox set status = 'SENDING', attempts = 2 where id = (select id from ids where n = 'p1');
select public.complete_email_outbox((select id from ids where n = 'p1'), 'DEFER');
select ok((select status = 'PENDING' and attempts = 1
                  and next_attempt_at between now() + interval '299 seconds' and now() + interval '301 seconds'
             from public.email_outbox where id = (select id from ids where n = 'p1')),
  'DEFER waits 5 minutes and gives the attempt back');
select public.complete_email_outbox((select id from ids where n = 'future'), 'SENT');
select is((select status from public.email_outbox where id = (select id from ids where n = 'future')), 'PENDING',
  'completing a row that is not SENDING does nothing');
select throws_ok($$select public.complete_email_outbox(gen_random_uuid(), 'MAYBE')$$, '22023', null,
  'an unknown result is refused');

-- ── purge ───────────────────────────────────────────────────────────────
delete from public.email_outbox;
insert into ids values ('old_sent', pg_temp.row('SENT', 1, interval '0', interval '-31 days'));
insert into ids values ('old_failed', pg_temp.row('FAILED', 5, interval '0', interval '-31 days'));
insert into ids values ('new_sent', pg_temp.row('SENT', 1, interval '0', interval '-29 days'));
insert into ids values ('old_pending', pg_temp.row('PENDING', 0, interval '0', interval '-31 days'));
select is(public.purge_email_outbox(), 2, 'purge deletes the two old SENT and FAILED rows');
select is((select count(*)::int from public.email_outbox), 2, 'a 29-day row and a PENDING row are kept');

-- ── grants and cron ─────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.claim_email_outbox(integer)', 'execute'),
  'authenticated cannot claim');
select ok(not has_function_privilege('authenticated', 'public.complete_email_outbox(uuid, text)', 'execute'),
  'authenticated cannot complete');
select ok(not has_function_privilege('service_role', 'public.purge_email_outbox()', 'execute'),
  'nobody but cron purges');
select ok(has_function_privilege('service_role', 'public.claim_email_outbox(integer)', 'execute'),
  'service_role claims');
select ok(has_function_privilege('service_role', 'public.complete_email_outbox(uuid, text)', 'execute'),
  'service_role completes');
select ok(not has_function_privilege('authenticated', 'public.support_email_on_status()', 'execute'),
  'the trigger functions are not callable');
select is((select count(*)::int from cron.job
            where jobname in ('email-outbox-send', 'purge-email-outbox', 'close-resolved-tenant-tickets')), 3,
  'the three cron jobs exist');
select is((select command from cron.job where jobname = 'email-outbox-send'),
  $$select public.invoke_system_function('email-outbox-send', '{}'::jsonb)$$, 'the sender runs through pg_net');

select * from finish();
rollback;
