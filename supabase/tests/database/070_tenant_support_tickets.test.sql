-- Addendum A7 §4 — tenant support tickets: TENANT_ADMIN opens, the tenant's
-- CSM (or the MONVELO_OPERATOR pool) answers; RLS isolation across tenants;
-- the tenant emails land in email_outbox with no message text.
begin;
create extension if not exists pgtap with schema extensions;

select plan(74);

-- ── fixtures (as postgres), tenant TEAFAIR (T1) plus T2 ─────────────────
-- 08 TENANT_ADMIN T1 · 09 TENANT_ADMIN T2 · 12 CSM T1 · 13 CSM T1 (INVITED)
-- · 14 CSM T2 · 15 MONVELO_OPERATOR (platform role, no membership)
-- · 01 ZSM T1 · 16 LOGISTICS_MANAGER T1 · 17 TENANT_ADMIN T1 without email
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 8, 9, 12, 13, 14, 15, 16, 17]) n;

create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.tu(n integer) returns uuid language sql as
  $$ select ('50000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('99000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.t2() returns uuid language sql as $$ select '10000000-0000-0000-0000-000000000070'::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.tu(integer), pg_temp.k(integer),
  pg_temp.t1(), pg_temp.t2() to authenticated, anon;

update public.profiles set email = 'admin' || right(id::text, 2) || '@brand.test'
 where id in (pg_temp.u(8), pg_temp.u(9));
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = pg_temp.u(15);

insert into public.tenants (id, name, code) values (pg_temp.t2(), 'Brand Two', 'BRAND_070');

insert into public.tenant_users (id, tenant_id, profile_id, role, reports_to_id, status) values
  (pg_temp.tu(1),  pg_temp.t1(), pg_temp.u(1),  'ZSM',                    null, 'ACTIVE'),
  (pg_temp.tu(8),  pg_temp.t1(), pg_temp.u(8),  'TENANT_ADMIN',           null, 'ACTIVE'),
  (pg_temp.tu(9),  pg_temp.t2(), pg_temp.u(9),  'TENANT_ADMIN',           null, 'ACTIVE'),
  (pg_temp.tu(12), pg_temp.t1(), pg_temp.u(12), 'CLIENT_SERVICE_MANAGER', null, 'ACTIVE'),
  (pg_temp.tu(13), pg_temp.t1(), pg_temp.u(13), 'CLIENT_SERVICE_MANAGER', null, 'INVITED'),
  (pg_temp.tu(14), pg_temp.t2(), pg_temp.u(14), 'CLIENT_SERVICE_MANAGER', null, 'ACTIVE'),
  (pg_temp.tu(17), pg_temp.t1(), pg_temp.u(17), 'TENANT_ADMIN',           null, 'ACTIVE');
insert into public.tenant_users (id, tenant_id, profile_id, role, reports_to_id, status) values
  (pg_temp.tu(16), pg_temp.t1(), pg_temp.u(16), 'LOGISTICS_MANAGER', pg_temp.tu(12), 'ACTIVE');
-- 12 also serves T2, so the JWT tenant decides which tickets 12 can work
insert into public.tenant_users (id, tenant_id, profile_id, role, reports_to_id, status) values
  (pg_temp.tu(112), pg_temp.t2(), pg_temp.u(12), 'CLIENT_SERVICE_MANAGER', null, 'ACTIVE');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

create temporary table tix (n text primary key, id uuid, ref text);
grant all on tix to authenticated;
create function pg_temp.t(p_n text) returns uuid language sql as $$ select id from tix where n = p_n $$;
grant execute on function pg_temp.t(text) to authenticated;
create function pg_temp.open_as(p_n text, p_user uuid, p_tenant uuid, p_key uuid, p_category text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(p_user, p_tenant);
  v := public.open_tenant_ticket(p_key, p_category, 'Subject ' || p_n, 'Secret-body-' || p_n);
  insert into tix values (p_n, (v ->> 'ticket_id')::uuid, v ->> 'public_reference')
    on conflict (n) do nothing;
  return v;
end; $$;
grant execute on function pg_temp.open_as(text, uuid, uuid, uuid, text) to authenticated;

-- ── schema ──────────────────────────────────────────────────────────────
select has_table('public', 'tenant_support_tickets', 'tenant_support_tickets exists');
select has_table('public', 'tenant_support_ticket_messages', 'tenant_support_ticket_messages exists');
select has_table('public', 'email_outbox', 'email_outbox exists');
select col_not_null('public', 'tenant_support_tickets', 'tenant_id', 'tenant_id is NOT NULL');
select throws_ok(
  $$insert into public.tenant_support_tickets (tenant_id, public_reference, category, subject, opened_by)
    values (pg_temp.t1(), 'TS-ABC123', 'OTHER', 'x x x', pg_temp.u(8))$$,
  '23514', null, 'a non-tenant category is refused');
select throws_ok(
  $$insert into public.tenant_support_tickets (tenant_id, public_reference, category, subject, opened_by)
    values (pg_temp.t1(), 'TK-ABC123', 'TENANT_GENERAL_INQUIRY', 'x x x', pg_temp.u(8))$$,
  '23514', null, 'a non-TS reference is refused');
select ok(not has_function_privilege('authenticated', 'public.enqueue_email(text, text, jsonb, text, uuid)', 'execute'),
  'authenticated cannot enqueue email');
select ok(not has_function_privilege('authenticated', 'public.close_resolved_tenant_tickets()', 'execute'),
  'authenticated cannot run the auto-close');
select ok(not has_table_privilege('authenticated', 'public.tenant_support_tickets', 'insert'),
  'no direct insert on tenant tickets');

-- ── open: auto-assignment ───────────────────────────────────────────────
select pg_temp.open_as('a', pg_temp.u(8), pg_temp.t1(), pg_temp.k(1), 'TENANT_SETTLEMENT_DISCREPANCY');
select is((select assigned_csm_id from tix x join public.tenant_support_tickets s on s.id = x.id where x.n = 'a'),
  pg_temp.u(12), 'the only ACTIVE CSM is assigned');
select matches((select ref from tix where n = 'a'), '^TS-[0-9A-HJKMNP-TV-Z]{6}$', 'TS- reference');
select is((select sender_side from public.tenant_support_ticket_messages where ticket_id = pg_temp.t('a')),
  'TENANT', 'the first message is the tenant''s');
select is((select status from public.tenant_support_tickets where id = pg_temp.t('a')), 'OPEN', 'opens OPEN');
reset role;
select is((select count(*)::int from public.notifications
            where user_id = pg_temp.u(12) and kind = 'TENANT_TICKET_ACTIVITY'
              and payload ->> 'ticket_id' = pg_temp.t('a')::text), 1, 'the assigned CSM is notified');

-- replay
select is((pg_temp.open_as('a', pg_temp.u(8), pg_temp.t1(), pg_temp.k(1), 'TENANT_SETTLEMENT_DISCREPANCY') ->> 'ticket_id')::uuid,
  pg_temp.t('a'), 'a replay returns the same ticket');
reset role;
select is((select count(*)::int from public.tenant_support_tickets where tenant_id = pg_temp.t1()), 1,
  'a replay opens nothing new');
select is((select count(*)::int from public.email_outbox where source_id = pg_temp.t('a')), 1,
  'a replay enqueues nothing new');

-- two ACTIVE CSMs: unassigned, the operators are notified
update public.tenant_users set status = 'ACTIVE' where id = pg_temp.tu(13);
select pg_temp.open_as('b', pg_temp.u(8), pg_temp.t1(), pg_temp.k(2), 'TENANT_STOCK_SHORTAGE');
reset role;
select is((select assigned_csm_id from public.tenant_support_tickets where id = pg_temp.t('b')), null,
  'two CSMs leave the ticket unassigned');
select is((select count(*)::int from public.notifications
            where user_id = pg_temp.u(15) and kind = 'TENANT_TICKET_ACTIVITY'
              and payload ->> 'ticket_id' = pg_temp.t('b')::text), 1, 'the operator pool is notified');

-- no ACTIVE CSM in T2 (12's T2 membership and 14 suspended)
update public.tenant_users set status = 'DISABLED' where id in (pg_temp.tu(14), pg_temp.tu(112));
select pg_temp.open_as('c', pg_temp.u(9), pg_temp.t2(), pg_temp.k(3), 'TENANT_ONBOARDING_ISSUE');
reset role;
select is((select assigned_csm_id from public.tenant_support_tickets where id = pg_temp.t('c')), null,
  'no CSM leaves the ticket unassigned');
update public.tenant_users set status = 'ACTIVE' where id in (pg_temp.tu(14), pg_temp.tu(112));

-- only a TENANT_ADMIN opens
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select throws_ok($$select public.open_tenant_ticket(gen_random_uuid(), 'TENANT_GENERAL_INQUIRY', 'Hello there', 'x')$$,
  '42501', null, 'a CSM cannot open');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select throws_ok($$select public.open_tenant_ticket(gen_random_uuid(), 'TENANT_GENERAL_INQUIRY', 'Hello there', 'x')$$,
  '42501', null, 'a ZSM cannot open');
select pg_temp.act_as(pg_temp.u(16), pg_temp.t1());
select throws_ok($$select public.open_tenant_ticket(gen_random_uuid(), 'TENANT_GENERAL_INQUIRY', 'Hello there', 'x')$$,
  '42501', null, 'a LOGISTICS_MANAGER cannot open');
select pg_temp.act_as(pg_temp.u(15), null);
select throws_ok($$select public.open_tenant_ticket(gen_random_uuid(), 'TENANT_GENERAL_INQUIRY', 'Hello there', 'x')$$,
  '42501', null, 'an operator cannot open');
reset role;

-- ── RLS isolation ───────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(9), pg_temp.t2());
select is((select count(*)::int from public.tenant_support_tickets where tenant_id = pg_temp.t1()), 0,
  'another tenant''s admin reads no T1 tickets');
select is((select count(*)::int from public.tenant_support_ticket_messages where tenant_id = pg_temp.t1()), 0,
  'another tenant''s admin reads no T1 messages');
select is((select count(*)::int from public.tenant_support_tickets), 1, 'T2''s admin reads its own ticket');
select pg_temp.act_as(pg_temp.u(14), pg_temp.t2());
select is((select count(*)::int from public.tenant_support_tickets where tenant_id = pg_temp.t1()), 0,
  'another tenant''s CSM reads no T1 tickets');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is((select count(*)::int from public.tenant_support_tickets), 0, 'a ZSM reads no tenant tickets');
select pg_temp.act_as(pg_temp.u(16), pg_temp.t1());
select is((select count(*)::int from public.tenant_support_tickets), 0, 'a LOGISTICS_MANAGER reads none');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t2());
select is((select count(*)::int from public.tenant_support_tickets where tenant_id = pg_temp.t1()), 0,
  'a CSM reads only the JWT tenant''s tickets');
select pg_temp.act_as(pg_temp.u(13), pg_temp.t1());
select is((select count(*)::int from public.tenant_support_tickets), 2, 'an unassigned CSM of the tenant reads');
select pg_temp.act_as(pg_temp.u(15), null);
select is((select count(*)::int from public.tenant_support_tickets), 3, 'the operator reads every tenant');
select is((select count(*)::int from public.tenant_support_ticket_messages), 3, 'the operator reads the messages');
reset role;
set local role anon;
select throws_ok($$select count(*) from public.tenant_support_tickets$$, '42501', null, 'anon cannot read tenant tickets');
reset role;
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select throws_ok($$select count(*) from public.email_outbox$$, '42501', null, 'authenticated cannot read the outbox');

-- ── cross-tenant RPCs ───────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(9), pg_temp.t2());
select throws_ok(format($$select public.reply_tenant_ticket(gen_random_uuid(), %L, 'hi')$$, pg_temp.t('a')),
  'P0001', 'ticket not found', 'another tenant''s admin cannot reply');
select pg_temp.act_as(pg_temp.u(14), pg_temp.t2());
select throws_ok(format($$select public.claim_tenant_ticket(gen_random_uuid(), %L)$$, pg_temp.t('b')),
  'P0001', 'ticket not found', 'another tenant''s CSM cannot claim');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t2());
select throws_ok(format($$select public.reply_tenant_ticket(gen_random_uuid(), %L, 'hi')$$, pg_temp.t('a')),
  'P0001', 'ticket not found', 'a CSM acts only in the JWT tenant');

-- ── replies ─────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(13), pg_temp.t1());
select throws_ok(format($$select public.reply_tenant_ticket(gen_random_uuid(), %L, 'hi')$$, pg_temp.t('a')),
  '42501', null, 'a CSM who is not assigned cannot reply');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select is(public.reply_tenant_ticket(pg_temp.k(10), pg_temp.t('a'), 'Teafair-reply-body') ->> 'status', 'IN_PROGRESS',
  'a Teafair reply on OPEN moves to IN_PROGRESS');
reset role;
select is((select sender_side from public.tenant_support_ticket_messages
            where ticket_id = pg_temp.t('a') and sender_id = pg_temp.u(12)), 'TEAFAIR', 'the CSM speaks for Teafair');
select is((select count(*)::int from public.notifications
            where user_id = pg_temp.u(8) and kind = 'TENANT_TICKET_UPDATE'
              and payload ->> 'ticket_id' = pg_temp.t('a')::text), 1, 'the opener is told of the reply');
select pg_temp.act_as(pg_temp.u(15), null);
select lives_ok(format($$select public.reply_tenant_ticket(gen_random_uuid(), %L, 'operator here')$$, pg_temp.t('b')),
  'an operator replies on a pool ticket');
reset role;
select is((select sender_side from public.tenant_support_ticket_messages
            where ticket_id = pg_temp.t('b') and sender_id = pg_temp.u(15)), 'TEAFAIR', 'the operator speaks for Teafair');

-- ── status, reopen, close ───────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select throws_ok(format($$select public.update_tenant_ticket_status(gen_random_uuid(), %L, 'RESOLVED')$$, pg_temp.t('a')),
  '42501', null, 'the tenant admin cannot change status');
select pg_temp.act_as(pg_temp.u(15), null);
select throws_ok(format($$select public.update_tenant_ticket_status(gen_random_uuid(), %L, 'RESOLVED')$$, pg_temp.t('c')),
  'P0001', null, 'OPEN cannot jump to RESOLVED');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select is(public.update_tenant_ticket_status(pg_temp.k(11), pg_temp.t('a'), 'RESOLVED') ->> 'status', 'RESOLVED',
  'the assigned CSM resolves');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select is(public.reply_tenant_ticket(pg_temp.k(12), pg_temp.t('a'), 'still broken') ->> 'status', 'OPEN',
  'a tenant reply reopens a RESOLVED ticket');
reset role;
select is((select resolved_at from public.tenant_support_tickets where id = pg_temp.t('a')), null,
  'reopening clears resolved_at');
select pg_temp.act_as(pg_temp.u(15), null);
select lives_ok(format($$select public.update_tenant_ticket_status(gen_random_uuid(), %L, 'CLOSED')$$, pg_temp.t('c')),
  'an operator closes');
select throws_ok(format($$select public.reply_tenant_ticket(gen_random_uuid(), %L, 'more')$$, pg_temp.t('c')),
  'P0001', null, 'CLOSED refuses a reply');

-- ── claim, release, assign ──────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(13), pg_temp.t1());
select throws_ok(format($$select public.claim_tenant_ticket(gen_random_uuid(), %L)$$, pg_temp.t('a')),
  'P0001', null, 'an assigned ticket cannot be claimed');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select is(public.release_tenant_ticket(pg_temp.k(13), pg_temp.t('a')) ->> 'assigned_csm_id', null,
  'the assigned CSM releases to the pool');
select pg_temp.act_as(pg_temp.u(13), pg_temp.t1());
select is((public.claim_tenant_ticket(pg_temp.k(14), pg_temp.t('a')) ->> 'assigned_csm_id')::uuid, pg_temp.u(13),
  'another CSM claims the released ticket');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select throws_ok(format($$select public.claim_tenant_ticket(gen_random_uuid(), %L)$$, pg_temp.t('a')),
  'P0001', null, 'a second claim is refused');
select throws_ok(format($$select public.release_tenant_ticket(gen_random_uuid(), %L)$$, pg_temp.t('a')),
  '42501', null, 'only the assignee releases');
select pg_temp.act_as(pg_temp.u(15), null);
select throws_ok(format($$select public.assign_tenant_ticket(gen_random_uuid(), %L, %L)$$, pg_temp.t('a'), pg_temp.u(14)),
  'P0001', null, 'assigning another tenant''s CSM is refused');
select is((public.assign_tenant_ticket(pg_temp.k(15), pg_temp.t('a'), pg_temp.u(12)) ->> 'assigned_csm_id')::uuid,
  pg_temp.u(12), 'the operator assigns a CSM of the tenant');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select throws_ok(format($$select public.assign_tenant_ticket(gen_random_uuid(), %L, null)$$, pg_temp.t('a')),
  '42501', null, 'the tenant admin cannot assign');

-- ── an assignee who is no longer ACTIVE ─────────────────────────────────
reset role;
update public.tenant_users set status = 'DISABLED' where id = pg_temp.tu(12);
select pg_temp.act_as(pg_temp.u(13), pg_temp.t1());
select is((public.claim_tenant_ticket(pg_temp.k(16), pg_temp.t('a')) ->> 'assigned_csm_id')::uuid, pg_temp.u(13),
  'a suspended assignee counts as unassigned');
reset role;
update public.tenant_users set status = 'DISABLED' where id = pg_temp.tu(13);
delete from public.notifications;
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select lives_ok(format($$select public.reply_tenant_ticket(gen_random_uuid(), %L, 'anyone?')$$, pg_temp.t('a')),
  'the tenant replies with no live assignee');
reset role;
select is((select count(*)::int from public.notifications where user_id = pg_temp.u(15)), 1,
  'with no live assignee the operators are notified');
update public.tenant_users set status = 'ACTIVE' where id in (pg_temp.tu(12), pg_temp.tu(13));

-- ── auto-close ──────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(15), null);
select public.reply_tenant_ticket(pg_temp.k(17), pg_temp.t('b'), 'looking') ;
select public.update_tenant_ticket_status(pg_temp.k(18), pg_temp.t('b'), 'RESOLVED');
reset role;
update public.tenant_support_tickets set resolved_at = now() - interval '8 days' where id = pg_temp.t('b');
select is(public.close_resolved_tenant_tickets(), 1, 'one resolved ticket auto-closes');
select is((select status from public.tenant_support_tickets where id = pg_temp.t('b')), 'CLOSED', 'it is CLOSED');

-- ── the outbox ──────────────────────────────────────────────────────────
select is((select string_agg(template, ',' order by created_at, template) from public.email_outbox
            where source_id = pg_temp.t('a')),
  'TENANT_TICKET_OPENED,TENANT_TICKET_REPLY,TENANT_TICKET_STATUS', 'ticket a: opened, reply, resolved');
select is((select string_agg(template || ':' || coalesce(payload ->> 'status', ''), ',' order by created_at, template)
             from public.email_outbox where source_id = pg_temp.t('b')),
  'TENANT_TICKET_OPENED:,TENANT_TICKET_REPLY:,TENANT_TICKET_REPLY:,TENANT_TICKET_STATUS:RESOLVED,TENANT_TICKET_STATUS:CLOSED',
  'ticket b: opened, two replies, resolved, auto-closed');
select is((select count(distinct to_email)::int from public.email_outbox where source_id = pg_temp.t('a')), 1,
  'every tenant email goes to one address');
select is((select min(to_email) from public.email_outbox where source_id = pg_temp.t('a')), 'admin08@brand.test',
  'it is the opener''s profile email');
select ok(not exists (select 1 from public.email_outbox
                       where payload::text ~ '(Secret-body|Teafair-reply-body|still broken|anyone)'
                          or payload ? 'body'), 'no message text in any outbox payload');
select pg_temp.open_as('d', pg_temp.u(17), pg_temp.t1(), pg_temp.k(19), 'TENANT_GENERAL_INQUIRY');
reset role;
select is((select count(*)::int from public.email_outbox where source_id = pg_temp.t('d')), 0,
  'an opener with no email enqueues nothing');

-- ── audit rows stay out of the tenant's audit_logs (spec §4.2) ─────────
select ok((select count(*) from public.audit_logs where entity_type = 'tenant_support_tickets') > 0,
  'tenant ticket writes are audited');
select is((select count(*)::int from public.audit_logs
            where entity_type = 'tenant_support_tickets' and tenant_id is not null), 0,
  'tenant ticket audit rows are tenant-null');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is((select count(*)::int from public.audit_logs where entity_type = 'tenant_support_tickets'), 0,
  'a ZSM reads no tenant ticket audit rows');
reset role;

select * from finish();
rollback;
