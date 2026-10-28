-- Addendum A3 §9 — system tickets: the D1 exceptions (PAID_AFTER_CANCEL,
-- LATE_SUCCESS, a commission turning DISPUTED) each raise one SYSTEM ticket,
-- once; plus the A3-wide grant checks.
begin;
create extension if not exists pgtap with schema extensions;

select plan(56);

-- A5: ONLINE orders created from 2026-10-23 must carry refund-policy consent.
-- These fixtures insert ONLINE orders directly and are not about consent, so
-- stamp it for them (027 tests the CHECK itself).
create function pg_temp.a5_stamp_consent() returns trigger language plpgsql as $f$
begin
  if new.channel = 'ONLINE' then
    new.policy_version_tag := coalesce(new.policy_version_tag, 'v2.0-food-cosmetics');
    new.policy_accepted_at := coalesce(new.policy_accepted_at, now());
  end if;
  return new;
end;
$f$;
create trigger a5_stamp_consent before insert on public.orders
  for each row execute function pg_temp.a5_stamp_consent();



-- ── fixtures ────────────────────────────────────────────────────────────
-- 01, 02 ACTIVE ZSMs · 05 DISABLED ZSM · 03 TM (Ikeja and Epe)
-- 04 warehouse manager (Ikeja) · 06 DSA, the accountable agent
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Grace Foods', 'GRACE');
insert into public.tenant_settings (tenant_id) values ('10000000-0000-0000-0000-000000000001');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Epe');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where tenant_id = '10000000-0000-0000-0000-000000000001';
-- Ikeja's warehouse has its own manager; Epe's is managed by the TM himself
insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004'),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'REG-EPE', 'REGIONAL',
   '40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003');
insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   '+2348000000007', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
update public.tenant_settings set web_agent_commission_bps = 150
 where tenant_id = '10000000-0000-0000-0000-000000000001';
insert into public.web_referral_codes (id, tenant_id, code, agent_id, created_by, max_redemptions) values
  ('65000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'CAPONE01',
   '20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001', 1);

-- one routed ONLINE order and its 2 500.00 payment, n = 1..99
create function pg_temp.mk(p_n integer, p_ref text, p_territory integer, p_age interval,
                           p_order_status text default 'PENDING', p_pay_status text default 'INITIATED',
                           p_split boolean default false, p_code boolean default false)
returns void language plpgsql as $$
begin
  insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                             public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id,
                             referral_code_id, attributed_agent_id, created_at)
  values (('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000006',
          2500, p_order_status, 'PAYSTACK_WEB', 'TF-AA00' || lpad(p_n::text, 2, '0'),
          md5('ng_lga:LA:Ikeja')::uuid,
          ('40000000-0000-0000-0000-00000000000' || p_territory)::uuid,
          ('70000000-0000-0000-0000-00000000000' || p_territory)::uuid,
          case when p_code then '65000000-0000-0000-0000-000000000001'::uuid end,
          case when p_code then '20000000-0000-0000-0000-000000000006'::uuid end,
          now() - p_age);
  insert into public.payments (id, tenant_id, order_id, teafair_agent_id, web_pos_partner_id, amount,
                               payment_status, paystack_reference,
                               split_subaccount_code, split_bps, split_amount, created_at)
  values (('91000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001',
          ('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '20000000-0000-0000-0000-000000000006',
          case when p_split then '60000000-0000-0000-0000-000000000001'::uuid end,
          2500.00, p_pay_status::public.payment_status_enum, p_ref,
          case when p_split then 'ACCT_grace01' end,
          case when p_split then 150 end,
          case when p_split then 37.50 end,
          now() - p_age);
end $$;

select pg_temp.mk( 1, 'r_ok',         1, '10 minutes');
select pg_temp.mk( 2, 'r_dedup',      2, '10 minutes');
select pg_temp.mk( 3, 'r_split',      1, '10 minutes', p_split => true);
select pg_temp.mk( 4, 'r_split_bad',  1, '10 minutes', p_split => true);
select pg_temp.mk( 5, 'r_aband_new',  1, '1 hour');
select pg_temp.mk( 6, 'r_aband_old',  1, '3 hours');
select pg_temp.mk( 7, 'r_pend_old',   1, '73 hours');
select pg_temp.mk( 8, 'r_late',       1, '10 minutes', p_pay_status => 'FAILED');
select pg_temp.mk( 9, 'r_cancel',     1, '10 minutes', p_order_status => 'CANCELLED');
select pg_temp.mk(10, 'r_mismatch',   1, '30 minutes');
select pg_temp.mk(11, 'r_fresh',      1, '1 minute');
select pg_temp.mk(12, 'r_code',       1, '10 minutes', p_code => true);
select pg_temp.mk(13, 'r_wait_a',     1, '50 minutes');
select pg_temp.mk(14, 'r_wait_b',     1, '20 minutes', p_pay_status => 'PROCESSING');
select pg_temp.mk(15, 'r_ong10',      1, '10 hours');
select pg_temp.mk(16, 'r_split_share', 1, '10 minutes', p_split => true);
select pg_temp.mk(17, 'r_fail_old',   1, '73 hours');
select pg_temp.mk(18, 'r_q_a',        1, '40 minutes');
select pg_temp.mk(19, 'r_q_b',        1, '35 minutes');
select pg_temp.mk(20, 'r_q_c',        1, '32 minutes');
select pg_temp.mk(22, 'r_fail_new',   1, '1 hour');

create function pg_temp.sys_count(p_key text) returns integer language sql as $$
  select count(*)::int from public.support_tickets where system_key = p_key;
$$;
create function pg_temp.pid(p_n integer) returns text language sql as $$
  select ('91000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'));
$$;
create function pg_temp.cid(p_n integer) returns text language sql as $$
  select id::text from public.web_commissions where payment_id = pg_temp.pid(p_n)::uuid;
$$;

set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

-- ── PAID_AFTER_CANCEL (audited on the order, payment id in the after-image)
select lives_ok($$select public.settle_paystack_payment('charge.success', 'r_cancel', 'success', 250000, 'NGN', '{}',
  '9008', null, null)$$, 'PAID_AFTER_CANCEL path');
reset role;
select is(pg_temp.sys_count('PAID_AFTER_CANCEL:' || pg_temp.pid(9)), 1, 'one urgent ticket');
select is((select row(priority, territory_id, order_id, accountable_id, kind, category, status)::text
             from public.support_tickets where system_key = 'PAID_AFTER_CANCEL:' || pg_temp.pid(9)),
  row('URGENT', '40000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000009'::uuid,
      null::uuid, 'SYSTEM', 'SYSTEM', 'OPEN')::text,
  'routed to the ZSM queue with the order');
select is((select m.body from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'PAID_AFTER_CANCEL:' || pg_temp.pid(9)),
  'PAID_AFTER_CANCEL on payment ' || pg_temp.pid(9) || ' for order TF-AA0009.', 'the body names ids and the reference');

-- ── LATE_SUCCESS (audited on the payment) ───────────────────────────────
set local role service_role;
select is(public.settle_paystack_payment('charge.success', 'r_late', 'success', 250000, 'NGN', '{}',
  '9007', null, null) ->> 'order_status', 'PAID', 'a late success pays the order');
reset role;
select is(pg_temp.sys_count('LATE_SUCCESS:' || pg_temp.pid(8)), 1, 'late success ticket');
select is((select row(priority, territory_id, order_id)::text from public.support_tickets
            where system_key = 'LATE_SUCCESS:' || pg_temp.pid(8)),
  row('HIGH', '40000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000008'::uuid)::text,
  'HIGH, with the order');

-- ── a healthy split raises nothing; a mismatch raises one ───────────────
set local role service_role;
select is(public.settle_paystack_payment('charge.success', 'r_split', 'success', 250000, 'NGN', '{}',
  '9002', 'ACCT_grace01', 3750) ->> 'commission_status', 'SPLIT', 'a matching split');
reset role;
select is(pg_temp.sys_count('COMMISSION_DISPUTED:' || pg_temp.cid(3)), 0, 'a SPLIT commission raises no ticket');
set local role service_role;
select is(public.settle_paystack_payment('charge.success', 'r_split_bad', 'success', 250000, 'NGN', '{}',
  '9003', 'ACCT_other', 3750) ->> 'commission_status', 'DISPUTED', 'a mismatched split');
reset role;
select is(pg_temp.sys_count('COMMISSION_DISPUTED:' || pg_temp.cid(4)), 1, 'split mismatch ticket');
select is((select row(t.priority, t.territory_id, t.order_id, t.accountable_id)::text
             from public.support_tickets t where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(4)),
  row('HIGH', '40000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000004'::uuid,
      null::uuid)::text, 'HIGH, in the ZSM queue');
select is((select m.body from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(4)),
  'Commission ' || pg_temp.cid(4) || ' disputed (SPLIT_MISMATCH): 37.50 on payment ' || pg_temp.pid(4) || '.',
  'the body names the commission, reason, amount and payment');

-- ── replay raises none ──────────────────────────────────────────────────
select is((select count(*)::int from public.support_tickets where kind = 'SYSTEM'), 3, 'three SYSTEM tickets so far');
set local role service_role;
select public.settle_paystack_payment('charge.success', 'r_cancel', 'success', 250000, 'NGN', '{}', '9008', null, null);
select public.settle_paystack_payment('charge.success', 'r_split_bad', 'success', 250000, 'NGN', '{}',
  '9003', 'ACCT_other', 3750);
reset role;
select is((select count(*)::int from public.support_tickets where kind = 'SYSTEM'), 3, 'replay raises none');
select is((select count(*)::int from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.kind = 'SYSTEM'), 3, 'and adds no message');

-- ── a refund of a SETTLED commission ────────────────────────────────────
set local role service_role;
select is(public.release_commission('S1', now(), 'r_split', 3750) ->> 'outcome', 'settled', 'the commission settles');
select is(public.apply_paystack_refund('webhook', '5001', 'r_split', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'refunded', 'a full refund');
reset role;
select is(pg_temp.sys_count('COMMISSION_DISPUTED:' || pg_temp.cid(3)), 1, 'ORDER_REFUNDED dispute ticket');
select is((select m.body from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(3)),
  'Commission ' || pg_temp.cid(3) || ' disputed (ORDER_REFUNDED): 37.50 on payment ' || pg_temp.pid(3) || '.',
  'its body carries the reason');

-- ── a second dispute on one commission adds a message, not a ticket ─────
set local role service_role;
select is(public.settle_paystack_payment('charge.success', 'r_split_share', 'success', 250000, 'NGN', '{}',
  '9013', 'ACCT_grace01', 3700) ->> 'commission_status', 'DISPUTED', 'a wrong share');
reset role;
update public.web_commissions set status = 'SPLIT', dispute_reason = null, created_at = now() - interval '8 days'
 where payment_id = pg_temp.pid(16)::uuid;
set local role service_role;
select is(public.expire_unsettled_commissions(), 1, 'the aged SPLIT row expires');
reset role;
select is((select row(count(distinct t.id), count(m.id))::text
             from public.support_tickets t join public.support_messages m on m.ticket_id = t.id
            where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(16)),
  row(1::bigint, 2::bigint)::text, 'one ticket, two SYSTEM messages');
select is((select m.body from public.support_messages m join public.support_tickets t on t.id = m.ticket_id
            where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(16) order by m.created_at desc, m.id limit 1),
  'Commission ' || pg_temp.cid(16) || ' disputed (NOT_SETTLED): 37.50 on payment ' || pg_temp.pid(16) || '.',
  'the later reason is in the second message');

-- ── a repeat reopens a RESOLVED ticket; a CLOSED one is replaced ───────
-- the split-mismatch dispute on commission 4 recurs (status flips back)
create function pg_temp.redispute(p_n integer) returns void language sql as $$
  update public.web_commissions set status = 'SPLIT', dispute_reason = null where payment_id = pg_temp.pid(p_n)::uuid;
  update public.web_commissions set status = 'DISPUTED', dispute_reason = 'SPLIT_MISMATCH'
   where payment_id = pg_temp.pid(p_n)::uuid;
$$;
update public.support_tickets set status = 'RESOLVED', resolved_at = now()
 where system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(4);
select pg_temp.redispute(4);
select is((select row(t.status, t.resolved_at, pg_temp.sys_count(t.system_key))::text from public.support_tickets t
            where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(4)),
  row('OPEN', null::timestamptz, 1)::text, 'resolved ticket reopens');
create temp table closed_t on commit drop as
  select t.id, (select count(*)::int from public.support_messages m
                 where m.ticket_id = t.id and m.sender_type = 'SYSTEM') as n_sys
    from public.support_tickets t where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(4);
update public.support_tickets set status = 'CLOSED' where id = (select id from closed_t);
select pg_temp.redispute(4);
select is(pg_temp.sys_count('COMMISSION_DISPUTED:' || pg_temp.cid(4)), 2, 'closed ticket -> a new ticket');
select is((select t.previous_ticket_id from public.support_tickets t
            where t.system_key = 'COMMISSION_DISPUTED:' || pg_temp.cid(4) and t.status <> 'CLOSED'),
  (select id from closed_t), 'new ticket links to the closed one');
select is((select count(*)::int from public.support_messages m
            where m.ticket_id = (select id from closed_t) and m.sender_type = 'SYSTEM'),
  (select n_sys from closed_t), 'closed history is not appended to');

-- ── no contact data, no secret ──────────────────────────────────────────
select ok(not exists (select 1 from public.support_messages
                       where sender_type = 'SYSTEM' and (body like '%@%' or body like '%+234%')),
  'no contact data in system bodies');
select ok((select bool_and(sender_type = 'SYSTEM' and sender_id is null) from public.support_messages),
  'every message on a SYSTEM ticket is a SYSTEM message');
select is((select count(*)::int from public.support_ticket_contacts c
            join public.support_tickets t on t.id = c.ticket_id where t.kind = 'SYSTEM'),
  0, 'SYSTEM tickets have no contact row');
select is((select count(*)::int from public.support_ticket_secrets s
            join public.support_tickets t on t.id = s.ticket_id where t.kind = 'SYSTEM'),
  0, 'and no secret');

-- ── grants across A3 ────────────────────────────────────────────────────
select ok(to_regprocedure('public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)') is not null and not has_function_privilege('anon', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute'),
  'anon cannot execute open_support_ticket');
select ok(to_regprocedure('public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)') is not null and not has_function_privilege('authenticated', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute'),
  'authenticated cannot execute open_support_ticket');
select ok(to_regprocedure('public.read_support_ticket(text,text)') is not null and not has_function_privilege('anon', 'public.read_support_ticket(text,text)', 'execute'),
  'anon cannot execute read_support_ticket');
select ok(to_regprocedure('public.read_support_ticket(text,text)') is not null and not has_function_privilege('authenticated', 'public.read_support_ticket(text,text)', 'execute'),
  'authenticated cannot execute read_support_ticket');
select ok(to_regprocedure('public.add_ticket_message(uuid,text,text,text,uuid[])') is not null and not has_function_privilege('anon', 'public.add_ticket_message(uuid,text,text,text,uuid[])', 'execute'),
  'anon cannot execute add_ticket_message');
select ok(to_regprocedure('public.add_ticket_message(uuid,text,text,text,uuid[])') is not null and not has_function_privilege('authenticated', 'public.add_ticket_message(uuid,text,text,text,uuid[])', 'execute'),
  'authenticated cannot execute add_ticket_message');
select ok(to_regprocedure('public.raise_system_ticket(text,uuid,text,text)') is not null and not has_function_privilege('anon', 'public.raise_system_ticket(text,uuid,text,text)', 'execute'),
  'anon cannot execute raise_system_ticket');
select ok(to_regprocedure('public.raise_system_ticket(text,uuid,text,text)') is not null and not has_function_privilege('authenticated', 'public.raise_system_ticket(text,uuid,text,text)', 'execute'),
  'authenticated cannot execute raise_system_ticket');
select ok(to_regprocedure('public.web_find_order_by_pair(text,text)') is not null and not has_function_privilege('anon', 'public.web_find_order_by_pair(text,text)', 'execute'),
  'anon cannot execute web_find_order_by_pair');
select ok(to_regprocedure('public.web_find_order_by_pair(text,text)') is not null and not has_function_privilege('authenticated', 'public.web_find_order_by_pair(text,text)', 'execute'),
  'authenticated cannot execute web_find_order_by_pair');
select ok(to_regprocedure('public.support_notify_activity(public.support_tickets)') is not null and not has_function_privilege('anon', 'public.support_notify_activity(public.support_tickets)', 'execute'),
  'anon cannot execute support_notify_activity');
select ok(to_regprocedure('public.support_notify_activity(public.support_tickets)') is not null and not has_function_privilege('authenticated', 'public.support_notify_activity(public.support_tickets)', 'execute'),
  'authenticated cannot execute support_notify_activity');
select ok(to_regprocedure('public.close_resolved_support_tickets()') is not null and not has_function_privilege('anon', 'public.close_resolved_support_tickets()', 'execute'),
  'anon cannot execute close_resolved_support_tickets');
select ok(to_regprocedure('public.close_resolved_support_tickets()') is not null and not has_function_privilege('authenticated', 'public.close_resolved_support_tickets()', 'execute'),
  'authenticated cannot execute close_resolved_support_tickets');
select ok(to_regprocedure('public.new_crockford_reference(text)') is not null and not has_function_privilege('anon', 'public.new_crockford_reference(text)', 'execute'),
  'anon cannot execute new_crockford_reference');
select ok(to_regprocedure('public.new_crockford_reference(text)') is not null and not has_function_privilege('authenticated', 'public.new_crockford_reference(text)', 'execute'),
  'authenticated cannot execute new_crockford_reference');
select ok(to_regprocedure('public.raise_system_ticket(text,uuid,text,text)') is not null and not has_function_privilege('service_role', 'public.raise_system_ticket(text,uuid,text,text)', 'execute'),
  'service_role cannot execute raise_system_ticket');
select ok(to_regprocedure('public.support_ticket_on_commission_disputed()') is not null and not has_function_privilege('anon', 'public.support_ticket_on_commission_disputed()', 'execute'),
  'anon cannot execute support_ticket_on_commission_disputed');
select ok(to_regprocedure('public.support_ticket_on_commission_disputed()') is not null and not has_function_privilege('authenticated', 'public.support_ticket_on_commission_disputed()', 'execute'),
  'authenticated cannot execute support_ticket_on_commission_disputed');
select ok(to_regprocedure('public.support_ticket_on_commission_disputed()') is not null and not has_function_privilege('service_role', 'public.support_ticket_on_commission_disputed()', 'execute'),
  'service_role cannot execute support_ticket_on_commission_disputed');
select ok(to_regprocedure('public.support_ticket_on_payment_exception()') is not null and not has_function_privilege('anon', 'public.support_ticket_on_payment_exception()', 'execute'),
  'anon cannot execute support_ticket_on_payment_exception');
select ok(to_regprocedure('public.support_ticket_on_payment_exception()') is not null and not has_function_privilege('authenticated', 'public.support_ticket_on_payment_exception()', 'execute'),
  'authenticated cannot execute support_ticket_on_payment_exception');
select ok(to_regprocedure('public.support_ticket_on_payment_exception()') is not null and not has_function_privilege('service_role', 'public.support_ticket_on_payment_exception()', 'execute'),
  'service_role cannot execute support_ticket_on_payment_exception');
select ok(to_regprocedure('public.claim_ticket(uuid,uuid)') is not null and not has_function_privilege('anon', 'public.claim_ticket(uuid,uuid)', 'execute'),
  'staff RPCs not for anon');

select * from finish();
rollback;
