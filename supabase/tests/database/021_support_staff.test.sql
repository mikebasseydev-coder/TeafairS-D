-- Addendum A3 §6–7 — staff RPCs: claim, reply, status, priority, assign,
-- redaction, and the 7-day auto-close.
begin;
create extension if not exists pgtap with schema extensions;

select plan(58);

-- A5: ONLINE orders created from 2026-10-23 must carry refund-policy consent.
-- These fixtures insert ONLINE orders directly and are not about consent, so
-- stamp it for them (027 tests the CHECK itself).
create function pg_temp.a5_stamp_consent() returns trigger language plpgsql as $f$
begin
  if new.channel = 'ONLINE' then
    new.policy_version_tag := coalesce(new.policy_version_tag, 'v2.0-food');
    new.policy_accepted_at := coalesce(new.policy_accepted_at, now());
  end if;
  return new;
end;
$f$;
create trigger a5_stamp_consent before insert on public.orders
  for each row execute function pg_temp.a5_stamp_consent();

-- ── fixtures: TEAFAIR with Ikeja (TM_A) and Epe (TM_B), a ZSM, a DSA, a ──────
-- non-TM default agent DEF, and a second Ikeja TM (TM2)
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe');
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000006',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000002';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
 where id = '30000000-0000-0000-0000-000000000001';
insert into public.tenant_settings (tenant_id, web_default_agent_id)
values ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005')
on conflict (tenant_id) do update set web_default_agent_id = excluded.web_default_agent_id;

insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000002', 2500, 'PENDING', 'PAYSTACK_WEB', 'TF-AAAAAA',
   md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001');

-- order tickets: K1 OPEN, K2 OPEN unassigned, K3 RESOLVED, K4 CLOSED,
-- K5 RESOLVED 8 days ago, K6 RESOLVED yesterday
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, order_id, territory_id,
                                    accountable_id, status, resolved_at) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA1', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'OPEN', null),
  ('60000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA2', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'OPEN', null),
  ('60000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA3', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'RESOLVED', now()),
  ('60000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA4', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'CLOSED', null),
  ('60000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA5', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'RESOLVED', now() - interval '8 days'),
  ('60000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA6', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'RESOLVED', now() - interval '1 day');
-- K7: an ORDER ticket whose accountable is the selling DSA (A2-strict: no access)
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, order_id, territory_id,
                                    accountable_id) values
  ('60000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA7', 'ORDER', 'PAYMENT',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004');
-- pre-purchase: P3 accountable DEF but held by TM_A; P4 held by TM2 (disabled
-- later), nobody accountable; P2 CLOSED
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id,
                                    accountable_id, assigned_to, status) values
  ('60000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAP3', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   '20000000-0000-0000-0000-000000000002', 'IN_PROGRESS'),
  ('60000000-0000-0000-0000-000000000009', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAP4', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000001', null,
   '20000000-0000-0000-0000-000000000006', 'IN_PROGRESS'),
  ('60000000-0000-0000-0000-00000000000a', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAP2', 'PRE_PURCHASE', 'PRODUCT',
   null, null, null, 'CLOSED');

-- P1: a buyer-opened pre-purchase ticket in an uncovered area, so it routes to DEF
do $$
declare v_ref text;
begin
  perform set_config('t.p1', public.open_support_ticket('a1000000-0000-0000-0000-000000000001', 'PRE_PURCHASE',
           'PRODUCT', 'Do you sell in bulk?',
           jsonb_build_object('name', 'Ada', 'phone', '+2348011111111', 'email', 'ada@example.com'),
           null, null, md5('ng_lga:LA:Ikeja')::uuid,
           encode(extensions.digest('s3cret', 'sha256'), 'hex')) ->> 'ticket_id', false);
  select public_reference into v_ref from public.support_tickets where id = current_setting('t.p1')::uuid;
  perform public.add_ticket_message('a1000000-0000-0000-0000-000000000002', v_ref, 's3cret',
                                    'My number is +2348011111111');
end $$;

create procedure pg_temp.as_user(n integer) language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0')),
    'app_metadata', json_build_object('active_tenant_id', '7eaf0000-0000-4000-8000-000000000001'))::text, true);
end $$;

-- ── claim ────────────────────────────────────────────────────────────────
call pg_temp.as_user(2);
select is(public.claim_ticket('b0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001') ->> 'status',
          'IN_PROGRESS', 'TM claims own territory');
reset role;
call pg_temp.as_user(3);
select throws_ok($$select public.claim_ticket('b0000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'other territory refused');
reset role;
call pg_temp.as_user(6);
select throws_ok($$select public.claim_ticket('b0000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'TM cannot take a held ticket');
reset role;
-- claimed tickets are locked to the assignee and ZSMs (Amendment 1): TM_A holds K1
call pg_temp.as_user(6);
select throws_ok($$select public.reply_ticket('b1000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'x')$$,
  '42501', null, 'second TM cannot reply to a claimed ticket');
select throws_ok($$select public.update_ticket_status('b1000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001', 'RESOLVED')$$,
  '42501', null, 'second TM cannot resolve a claimed ticket');
select throws_ok($$select public.set_ticket_priority('b1000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000001', 'HIGH')$$,
  '42501', null, 'second TM cannot reprioritise a claimed ticket');
select is((select count(*)::int from public.support_tickets where id = '60000000-0000-0000-0000-000000000001'),
          1, 'second TM still sees it in the queue');
reset role;
call pg_temp.as_user(2);
select is(public.reply_ticket('b1000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001',
            'Assignee reply') ->> 'status',
          'IN_PROGRESS', 'assignee can still reply');
reset role;
call pg_temp.as_user(1);
select lives_ok($$select public.reply_ticket('b1000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000001', 'ZSM reply')$$,
  'ZSM can still write to a claimed ticket');
reset role;
call pg_temp.as_user(1);
select is(public.claim_ticket('b0000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001') ->> 'assigned_to',
          '20000000-0000-0000-0000-000000000001', 'ZSM takeover');
select is(public.claim_ticket('b0000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001') ->> 'assigned_to',
          '20000000-0000-0000-0000-000000000001', 'a replayed key returns the stored reply');
select throws_ok($$select public.claim_ticket('b0000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-0000000000ff')$$,
  'P0001', 'ticket not found', 'unknown ticket');
reset role;
select ok(exists(select 1 from public.audit_logs
                  where operation = 'claim_ticket' and entity_id = '60000000-0000-0000-0000-000000000001'
                    and before ->> 'assigned_to' = '20000000-0000-0000-0000-000000000002'),
          'takeover audited');

-- ── reply ────────────────────────────────────────────────────────────────
call pg_temp.as_user(5);
select is(public.reply_ticket('b0000000-0000-0000-0000-000000000006', current_setting('t.p1')::uuid,
            'Secret reply body one') ->> 'status',
          'IN_PROGRESS', 'non-TM default agent replies to the ticket routed to them');
select throws_ok($$select public.reply_ticket('b0000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000001', 'x')$$,
  '42501', null, 'but not to others');
reset role;
call pg_temp.as_user(4);
select throws_ok($$select public.reply_ticket('b0000000-0000-0000-0000-000000000008', '60000000-0000-0000-0000-000000000001', 'x')$$,
  '42501', null, 'DSA refused');
select throws_ok($$select public.claim_ticket('b2000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000007')$$,
  '42501', null, 'the accountable DSA cannot claim on an ORDER ticket');
select throws_ok($$select public.reply_ticket('b2000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000007', 'x')$$,
  '42501', null, 'the accountable DSA cannot reply on an ORDER ticket');
select throws_ok($$select public.update_ticket_status('b2000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000007', 'CLOSED')$$,
  '42501', null, 'the accountable DSA cannot change status on an ORDER ticket');
select throws_ok($$select public.set_ticket_priority('b2000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000007', 'HIGH')$$,
  '42501', null, 'the accountable DSA cannot change priority on an ORDER ticket');
reset role;
call pg_temp.as_user(5);
select throws_ok($$select public.reply_ticket('b2000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000008', 'x')$$,
  '42501', null, 'the accountable default agent is locked out of a PRE_PURCHASE ticket someone else holds');
reset role;
call pg_temp.as_user(2);
select is(public.reply_ticket('b0000000-0000-0000-0000-000000000009', '60000000-0000-0000-0000-000000000002',
            'Secret reply body two') ->> 'assigned_to',
          '20000000-0000-0000-0000-000000000002', 'reply auto-claims');
reset role;
call pg_temp.as_user(1);
do $$ begin
  perform public.reply_ticket('b0000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-000000000003',
                              'Secret reply body three');
end $$;
reset role;
select is((select row(t.status, t.resolved_at)::text from public.support_tickets t
            where t.id = '60000000-0000-0000-0000-000000000003'),
          row('IN_PROGRESS'::text, null::timestamptz)::text, 'reply reopens');

-- ── status ───────────────────────────────────────────────────────────────
call pg_temp.as_user(1);
do $$ begin
  perform public.update_ticket_status('b0000000-0000-0000-0000-00000000000b', '60000000-0000-0000-0000-000000000002',
                                      'RESOLVED');
end $$;
reset role;
select is((select resolved_at is not null from public.support_tickets where id = '60000000-0000-0000-0000-000000000002'),
          true, 'resolve stamps time');
call pg_temp.as_user(1);
select throws_ok($$select public.update_ticket_status('b0000000-0000-0000-0000-00000000000c', '60000000-0000-0000-0000-000000000004', 'OPEN')$$,
  'P0001', 'that status change is not allowed', 'CLOSED is final');
select throws_ok($$select public.update_ticket_status('b0000000-0000-0000-0000-00000000000d', '60000000-0000-0000-0000-000000000006', 'IN_PROGRESS')$$,
  'P0001', 'that status change is not allowed', 'RESOLVED cannot go back by status change');
select is(public.update_ticket_status('b0000000-0000-0000-0000-00000000000e', '60000000-0000-0000-0000-000000000002', 'CLOSED') ->> 'status',
          'CLOSED', 'RESOLVED to CLOSED');
select throws_ok($$select public.reply_ticket('b0000000-0000-0000-0000-00000000000f', '60000000-0000-0000-0000-000000000004', 'x')$$,
  'P0001', 'This conversation is closed. Open a new ticket if you still need help.', 'no replies on closed');
select is(public.set_ticket_priority('b0000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000001',
            'URGENT') ->> 'priority',
          'URGENT', 'priority');
reset role;

-- ── assign (PRE_PURCHASE only, ZSM only) ─────────────────────────────────
call pg_temp.as_user(2);
select throws_ok($$select public.assign_ticket('b0000000-0000-0000-0000-000000000011', current_setting('t.p1')::uuid,
                     '40000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'assign is ZSM only');
reset role;
call pg_temp.as_user(1);
select throws_ok($$select public.assign_ticket('b0000000-0000-0000-0000-000000000012', '60000000-0000-0000-0000-000000000001',
                     '40000000-0000-0000-0000-000000000001')$$,
  'P0001', 'only pre-purchase tickets can be re-routed', 'order tickets follow the order');
do $$ begin
  perform public.assign_ticket('b0000000-0000-0000-0000-000000000013', current_setting('t.p1')::uuid,
                               '40000000-0000-0000-0000-000000000001');
end $$;
reset role;
select is((select row(t.territory_id, t.accountable_id, t.assigned_to)::text
             from public.support_tickets t where t.id = current_setting('t.p1')::uuid),
          row('40000000-0000-0000-0000-000000000001'::uuid, '20000000-0000-0000-0000-000000000002'::uuid, null::uuid)::text,
          'assign re-routes');
select is((select t.status from public.support_tickets t where t.id = current_setting('t.p1')::uuid),
          'OPEN', 're-routing an IN_PROGRESS ticket sets it back to OPEN');
call pg_temp.as_user(1);
select throws_ok($$select public.assign_ticket('b2000000-0000-0000-0000-000000000006', '60000000-0000-0000-0000-00000000000a',
                     '40000000-0000-0000-0000-000000000001')$$,
  'P0001', 'that ticket is closed', 'a CLOSED ticket cannot be re-routed');
reset role;
call pg_temp.as_user(2);
select is((select count(*)::int from public.support_messages where ticket_id = current_setting('t.p1')::uuid),
          3, 'Ikeja TM gains access');
reset role;
call pg_temp.as_user(1);
select lives_ok($$select public.assign_ticket('b0000000-0000-0000-0000-000000000014', current_setting('t.p1')::uuid,
                    '40000000-0000-0000-0000-000000000002')$$, 're-route again');
reset role;
select is((select (select count(*) from public.support_messages m
                    where m.ticket_id = t.id and m.territory_id is distinct from t.territory_id)
                + (select count(*) from public.support_ticket_contacts c
                    where c.ticket_id = t.id and c.territory_id is distinct from t.territory_id)
             from public.support_tickets t where t.id = current_setting('t.p1')::uuid)::int,
          0, 'copies moved');
call pg_temp.as_user(3);
select is((select count(*)::int from public.support_messages where ticket_id = current_setting('t.p1')::uuid),
          3, 'new TM gains access');
reset role;
call pg_temp.as_user(2);
select is((select count(*)::int from public.support_messages where ticket_id = current_setting('t.p1')::uuid),
          0, 'old territory loses access');
select throws_ok($$select public.redact_ticket_customer_data('b0000000-0000-0000-0000-000000000015', current_setting('t.p1')::uuid)$$,
  '42501', null, 'redact is ZSM only');
reset role;

-- ── redaction ────────────────────────────────────────────────────────────
call pg_temp.as_user(1);
select lives_ok($$select public.redact_ticket_customer_data('b0000000-0000-0000-0000-000000000016', current_setting('t.p1')::uuid)$$,
  'redact');
reset role;
select is((select c.customer_name is null and c.customer_phone is null and c.customer_email is null
                  and c.redacted_at is not null
             from public.support_ticket_contacts c where c.ticket_id = current_setting('t.p1')::uuid),
          true, 'contacts blanked');
select is((select bool_and(m.body = '[redacted]' and m.redacted_at is not null) from public.support_messages m
            where m.ticket_id = current_setting('t.p1')::uuid and m.sender_type = 'CUSTOMER'),
          true, 'buyer bodies redacted');
select is((select m.body from public.support_messages m
            where m.ticket_id = current_setting('t.p1')::uuid and m.sender_type = 'STAFF'),
          'Secret reply body one', 'staff reply untouched');
select is((select a.after from public.audit_logs a
            where a.operation = 'TICKET_DATA_REDACTED' and a.entity_id = current_setting('t.p1')),
          jsonb_build_object('ticket_id', current_setting('t.p1'), 'had_email', true, 'messages_redacted', 2),
          'audit summary only');
call pg_temp.as_user(1);
select is(public.redact_ticket_customer_data('b2000000-0000-0000-0000-000000000007', current_setting('t.p1')::uuid) ->> 'ticket_id',
          current_setting('t.p1'), 'a second redaction still replies');
reset role;
select is((select count(*)::int from public.audit_logs a
            where a.operation = 'TICKET_DATA_REDACTED' and a.entity_id = current_setting('t.p1')),
          1, 'a second redaction with a new key writes no second audit row');
select is((select count(*)::int from jsonb_array_elements(public.read_support_ticket(
             (select public_reference from public.support_tickets where id = current_setting('t.p1')::uuid), 's3cret') -> 'messages') e
            where e ->> 'sender' = 'you' and e ->> 'body' <> '[redacted]'),
          0, 'buyer sees redacted history');
select is(public.add_ticket_message('a1000000-0000-0000-0000-000000000003',
            (select public_reference from public.support_tickets where id = current_setting('t.p1')::uuid),
            's3cret', 'A fresh question') ->> 'status',
          (select status from public.support_tickets where id = current_setting('t.p1')::uuid), 'buyer can still post');
select is((select count(*)::int from public.support_messages m
            where m.ticket_id = current_setting('t.p1')::uuid and m.body = 'A fresh question' and m.redacted_at is null),
          1, 'new messages are not redacted');
select is((select count(*)::int from public.audit_logs a
            where (coalesce(a.before::text, '') || coalesce(a.after::text, '')) ~ 'Secret reply body|A fresh question|Do you sell|My number is'),
          0, 'no bodies in audit');

-- ── inactive targets ─────────────────────────────────────────────────────
-- P4 is held by TM2; TM2 is disabled
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000006';
do $$ begin
  perform public.support_notify_activity(t) from public.support_tickets t
   where t.id = '60000000-0000-0000-0000-000000000009';
end $$;
select is((select count(*)::int from public.notifications n
            where n.payload ->> 'ticket_id' = '60000000-0000-0000-0000-000000000009'
              and n.user_id = '20000000-0000-0000-0000-000000000001')
        - (select count(*)::int from public.notifications n
            where n.payload ->> 'ticket_id' = '60000000-0000-0000-0000-000000000009'
              and n.user_id = '20000000-0000-0000-0000-000000000006'),
          1, 'a notification for a disabled assignee falls back to the ZSMs');
call pg_temp.as_user(2);
select is(public.claim_ticket('b2000000-0000-0000-0000-000000000008', '60000000-0000-0000-0000-000000000009') ->> 'assigned_to',
          '20000000-0000-0000-0000-000000000002', 'a ticket held by a disabled TM can be claimed by the territory TM');
reset role;
select ok(exists(select 1 from public.audit_logs
                  where operation = 'claim_ticket' and entity_id = '60000000-0000-0000-0000-000000000009'
                    and before ->> 'assigned_to' = '20000000-0000-0000-0000-000000000006'),
          'that claim is audited with the old assignee');

-- ── auto-close ───────────────────────────────────────────────────────────
select is(public.close_resolved_support_tickets(), 1, 'one RESOLVED ticket older than 7 days closes');
select is((select count(*)::int from public.audit_logs a
            where a.operation = 'close_resolved_support_tickets' and a.source = 'CRON'
              and a.entity_id = '60000000-0000-0000-0000-000000000005'),
          1, 'auto-close audited as CRON');
select ok(exists(select 1 from cron.job where jobname = 'close-resolved-support-tickets'
                    and schedule = '30 0 * * *'), 'auto-close scheduled');
call pg_temp.as_user(1);
select throws_ok($$select public.close_resolved_support_tickets()$$, '42501', null, 'auto-close is not an API call');
reset role;

select * from finish();
rollback;
