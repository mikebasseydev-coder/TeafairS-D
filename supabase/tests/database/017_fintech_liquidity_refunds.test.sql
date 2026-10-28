-- Spec D1 §9 — refunds and reversals: apply_paystack_refund, full and partial
-- refunds, reversals, conflicts, commission disputes, and plan Decision 2
-- (a refund that arrives before its charge settles takes no key), and a
-- reversal of a charge not yet recorded (straight to REFUNDED, order untouched).
begin;
create extension if not exists pgtap with schema extensions;

select plan(48);

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
-- 01, 02 ACTIVE ZSMs · 03 TM · 04 warehouse manager · 06 DSA, the agent
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Grace Foods', 'GRACE');
insert into public.tenant_settings (tenant_id) values ('10000000-0000-0000-0000-000000000001');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where tenant_id = '10000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004');
insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000007', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());

-- one routed ONLINE order and its 2 500.00 payment, n = 1..99
create function pg_temp.mk(p_n integer, p_ref text, p_order_status text, p_pay_status text,
                           p_split boolean default false)
returns void language plpgsql as $$
begin
  insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                             public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id, created_at)
  values (('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000006',
          2500, p_order_status, 'PAYSTACK_WEB', 'TF-RF00' || lpad(p_n::text, 2, '0'),
          md5('ng_lga:LA:Ikeja')::uuid,
          '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
          now() - interval '1 day');
  insert into public.payments (id, tenant_id, order_id, teafair_agent_id, fintech_partner_id, amount,
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
          now() - interval '1 day');
end $$;

select pg_temp.mk(1, 'r_full',   'PAID',      'SUCCESS', p_split => true);
select pg_temp.mk(2, 'r_part',   'PAID',      'SUCCESS');
select pg_temp.mk(3, 'r_rev',    'DELIVERED', 'SUCCESS');
select pg_temp.mk(4, 'r_init',   'PENDING',   'INITIATED');
select pg_temp.mk(5, 'r_cancel', 'CANCELLED', 'SUCCESS');
select pg_temp.mk(6, 'r_rev_init', 'PENDING', 'INITIATED');
select pg_temp.mk(7, 'r_rev_bad',  'PENDING', 'INITIATED');
-- the settled commission on r_full
insert into public.commission_records (id, tenant_id, order_id, payment_id, fintech_partner_id, teafair_agent_id,
                                       amount, bps_applied, paystack_subaccount_code, paystack_split_reference,
                                       status, settled_at) values
  ('92000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '90000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   37.50, 150, 'ACCT_grace01', '8001', 'SETTLED', now());
-- a field order with a SUCCESS payment: the payment is refunded, the order is Spec C's
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, created_at) values
  ('90000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001', 'FIELD_SALES',
   '20000000-0000-0000-0000-000000000006', 2500, 'DELIVERED', now() - interval '1 day');
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, payment_status, paystack_reference,
                             created_at) values
  ('91000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000021',
   '20000000-0000-0000-0000-000000000006', 2500.00, 'SUCCESS', 'r_field', now() - interval '1 day');

create function pg_temp.audits(p_refund_id text) returns integer language sql as $$
  select count(*)::int from public.audit_logs
   where idempotency_key = md5('paystack-refund:' || p_refund_id)::uuid;
$$;
create function pg_temp.conflict(p_entity text) returns text language sql as $$
  select after ->> 'reason' from public.audit_logs
   where operation = 'REFUND_CONFLICT' and entity_id = p_entity
   order by created_at desc, id desc limit 1;
$$;
grant execute on function pg_temp.audits(text) to service_role;
grant execute on function pg_temp.conflict(text) to service_role;

-- ── privileges ──────────────────────────────────────────────────────────
select ok(has_function_privilege('service_role',
  'public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)', 'execute'),
  'process-payment and reconcile-funds (service_role) apply refunds');
select ok(not has_function_privilege('authenticated',
  'public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)', 'execute')
  and not has_function_privilege('anon',
  'public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)', 'execute'),
  'service_role only');

set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

-- ── input checks ────────────────────────────────────────────────────────
select throws_ok($$select public.apply_paystack_refund('browser', '5999', 'r_part', 100, 'NGN', 'REFUND', '{}')$$,
  'P0001', null, 'an unknown source is refused');
select throws_ok($$select public.apply_paystack_refund('webhook', '5999', 'r_part', 100, 'NGN', 'CHARGEBACK', '{}')$$,
  'P0001', null, 'an unknown reason is refused');
select throws_ok($$select public.apply_paystack_refund('webhook', '5999', 'r_part', 0, 'NGN', 'REFUND', '{}')$$,
  'P0001', null, 'a non-positive amount is refused');

-- ── full refund ─────────────────────────────────────────────────────────
select is(public.apply_paystack_refund('webhook', '5001', 'r_full', 250000, 'NGN', 'REFUND',
  '{"id": 5001, "customer": {"email": "buyer@example.com", "phone": "+2348099999999"}}') ->> 'outcome',
  'refunded', 'full refund');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_full'),
  row('REFUNDED', 'REFUNDED')::text, 'payment and order REFUNDED');
select is((select row(status::text, dispute_reason)::text from public.commission_records
            where id = '92000000-0000-0000-0000-000000000001'),
  row('DISPUTED', 'ORDER_REFUNDED')::text, 'commission disputed on refund');
select is((select count(*)::int from public.notifications
            where kind = 'COMMISSION_DISPUTED' and title = 'Commission disputed'
              and body = 'A partner commission needs review (ORDER_REFUNDED).'
              and payload = '{"commission_id": "92000000-0000-0000-0000-000000000001", "order_id": "90000000-0000-0000-0000-000000000001", "reason": "ORDER_REFUNDED"}'::jsonb),
  2, 'both ZSMs told about the dispute');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'apply_paystack_refund' and entity_type = 'orders'
                     and entity_id = '90000000-0000-0000-0000-000000000001'
                     and before ->> 'status' = 'PAID' and after ->> 'status' = 'REFUNDED'
                     and source = 'WEBHOOK' and teafair_agent_id = '20000000-0000-0000-0000-000000000006'),
  'the order transition is audited with the accountable agent');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'apply_paystack_refund' and entity_type = 'payments'
                     and entity_id = '91000000-0000-0000-0000-000000000001'
                     and before ->> 'payment_status' = 'SUCCESS' and after ->> 'payment_status' = 'REFUNDED'
                     and after ->> 'reason' = 'REFUND' and after ->> 'refund_id' = '5001'
                     and (after ->> 'amount_minor')::bigint = 250000),
  'the payment transition is audited with reason, refund id and amount');
select ok(not exists (select 1 from public.audit_logs
                       where idempotency_key = md5('paystack-refund:5001')::uuid
                         and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(buyer@example|2348099999999)'),
  'no customer contact details reach the audit rows');
select is((select gateway_response_payload from public.payments where paystack_reference = 'r_full'),
  null, 'the charge payload is not overwritten by the refund payload');

-- replays: the same refund id from the webhook again, then from the refund pass
select is(public.apply_paystack_refund('webhook', '5001', 'r_full', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'refunded', 'replay of one refund id returns the first reply');
select is(public.apply_paystack_refund('sweep', '5001', 'r_full', 250000, 'NGN', 'REFUND', '{"other": true}') ->> 'outcome',
  'refunded', 'the refund pass delivering the same refund also gets the first reply');
select is((select count(*)::int from public.audit_logs
            where operation = 'apply_paystack_refund' and entity_type = 'payments' and after ->> 'refund_id' = '5001'),
  1, 'replay writes nothing');
select is((select count(*)::int from public.notifications where kind = 'COMMISSION_DISPUTED'),
  2, 'and notifies nobody again');

-- a second refund id on an already refunded payment is a conflict that takes its key
select is(public.apply_paystack_refund('webhook', '5009', 'r_full', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'conflict', 'refunding a REFUNDED payment conflicts');
select is(row(pg_temp.conflict('91000000-0000-0000-0000-000000000001'),
              (select status::text from public.idempotency_logs where key = md5('paystack-refund:5009')::uuid))::text,
  row('payment_not_success', 'COMPLETED')::text, 'payment_not_success, and the key is taken (REFUNDED is final)');

-- ── partial refund ──────────────────────────────────────────────────────
select is(public.apply_paystack_refund('webhook', '5002', 'r_part', 100000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'partial', 'partial refund');
select is(row((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
                where p.paystack_reference = 'r_part'),
              (select count(*)::int from public.notifications where kind = 'PAYMENT_PARTIALLY_REFUNDED'))::text,
  row(row('SUCCESS', 'PAID')::text, 2)::text, 'no status change, ZSMs told');
select ok(exists (select 1 from public.notifications
                   where kind = 'PAYMENT_PARTIALLY_REFUNDED' and title = 'Partial refund'
                     and body = 'Order TF-RF0002 was partly refunded (1000.00 NGN).'
                     and payload ->> 'order_id' = '90000000-0000-0000-0000-000000000002'
                     and payload ->> 'payment_id' = '91000000-0000-0000-0000-000000000002'),
  'the partial-refund notification names the order, the amount and the currency');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'PARTIAL_REFUND' and entity_type = 'payments'
                     and entity_id = '91000000-0000-0000-0000-000000000002'
                     and (after ->> 'amount_minor')::bigint = 100000 and after ->> 'currency' = 'NGN'),
  'audited PARTIAL_REFUND with the amount');

-- ── reversal ────────────────────────────────────────────────────────────
select is(public.apply_paystack_refund('sweep', 'reversal:r_rev', 'r_rev', 250000, 'NGN', 'REVERSAL', '{}') ->> 'outcome',
  'refunded', 'reversal');
select is((select after ->> 'reason' from public.audit_logs
            where operation = 'apply_paystack_refund' and entity_type = 'payments'
              and entity_id = '91000000-0000-0000-0000-000000000003' and source = 'CRON'),
  'REVERSAL', 'reason REVERSAL, audited as CRON');
select is((select status from public.orders where id = '90000000-0000-0000-0000-000000000003'),
  'REFUNDED', 'a DELIVERED order becomes REFUNDED');

-- ── a reversal before the charge was recorded: one transaction ─────────
select is(public.apply_paystack_refund('sweep', 'reversal:r_rev_init', 'r_rev_init', 250000, 'NGN', 'REVERSAL', '{}') ->> 'outcome',
  'refunded', 'an INITIATED payment is reversed');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_rev_init'),
  row('REFUNDED', 'PENDING')::text, 'the payment is REFUNDED; the order stays PENDING and is never PAID');
select ok(not exists (select 1 from public.notifications
                       where kind = 'WEB_ORDER_PAID' and payload ->> 'order_id' = '90000000-0000-0000-0000-000000000006')
          and not exists (select 1 from public.audit_logs
                           where entity_type = 'orders' and entity_id = '90000000-0000-0000-0000-000000000006'),
  'nobody is told to ship it, and the order has no transition');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'apply_paystack_refund' and entity_type = 'payments'
                     and entity_id = '91000000-0000-0000-0000-000000000006' and source = 'CRON'
                     and before ->> 'payment_status' = 'INITIATED' and after ->> 'payment_status' = 'REFUNDED'
                     and after ->> 'reason' = 'REVERSAL'),
  'audited apply_paystack_refund, reason REVERSAL, with the prior status');
select is((select status::text from public.idempotency_logs where key = md5('paystack-refund:reversal:r_rev_init')::uuid),
  'COMPLETED', 'the reversal takes its key');
select ok(not ('r_rev_init' in (select paystack_reference from public.claim_unconfirmed_payments(500))),
  'the sweep no longer claims it');
select is(public.apply_paystack_refund('sweep', 'reversal:r_rev_bad', 'r_rev_bad', 100000, 'NGN', 'REVERSAL', '{}') ->> 'outcome',
  'conflict', 'a reversal amount other than the payment amount conflicts');
select is(row(pg_temp.conflict('91000000-0000-0000-0000-000000000007'),
              (select payment_status::text from public.payments where paystack_reference = 'r_rev_bad'))::text,
  row('amount_mismatch', 'INITIATED')::text, 'audited amount_mismatch; nothing changes');

-- ── orders outside PAID / IN_TRANSIT / DELIVERED, and field orders ──────
select is(public.apply_paystack_refund('webhook', '5005', 'r_cancel', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'refunded', 'a cancelled order''s payment is refunded');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_cancel'),
  row('REFUNDED', 'CANCELLED')::text, 'the payment is REFUNDED; the CANCELLED order is left as it is');
select is(public.apply_paystack_refund('webhook', '5021', 'r_field', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'refunded', 'a field payment is refunded');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_field'),
  row('REFUNDED', 'DELIVERED')::text, 'the FIELD_SALES order is Spec C''s and stays DELIVERED');

-- ── conflicts ───────────────────────────────────────────────────────────
select is(public.apply_paystack_refund('webhook', '5003', 'r_unknown', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'conflict', 'unknown reference');
select is(row(pg_temp.conflict('r_unknown'), pg_temp.audits('5003'),
              (select status::text from public.idempotency_logs where key = md5('paystack-refund:5003')::uuid))::text,
  row('unknown_reference', 1, 'COMPLETED')::text, 'audited unknown_reference; the key is taken');
select is(public.apply_paystack_refund('webhook', '5006', 'r_part', 100000, 'GHS', 'REFUND', '{}') ->> 'outcome',
  'conflict', 'currency mismatch');
select is(public.apply_paystack_refund('webhook', '5007', 'r_part', 250001, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'conflict', 'more than the payment is an over-refund');
select is(row(pg_temp.audits('5006'), pg_temp.audits('5007'),
              (select string_agg(after ->> 'reason', ',' order by after ->> 'reason') from public.audit_logs
                where operation = 'REFUND_CONFLICT' and entity_id = '91000000-0000-0000-0000-000000000002'),
              (select payment_status::text from public.payments where paystack_reference = 'r_part'))::text,
  row(1, 1, 'currency_mismatch,over_refund', 'SUCCESS')::text, 'each conflict is audited once; nothing changes');

-- ── Decision 2: an early refund, then the late success ──────────────────
select is(public.apply_paystack_refund('webhook', '5004', 'r_init', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'conflict', 'refund before settle conflicts');
select is(row(pg_temp.conflict('91000000-0000-0000-0000-000000000004'),
              (select count(*)::int from public.idempotency_logs where key = md5('paystack-refund:5004')::uuid))::text,
  row('payment_not_success', 0)::text, 'audited payment_not_success; the key is not taken');
select lives_ok($$select public.settle_paystack_payment('charge.success', 'r_init', 'success', 250000, 'NGN', '{}',
  '9004', null, null)$$, 'charge then settles');
select is(public.apply_paystack_refund('sweep', '5004', 'r_init', 250000, 'NGN', 'REFUND', '{}') ->> 'outcome',
  'refunded', 'refund pass re-applies once the charge is SUCCESS');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_init'),
  row('REFUNDED', 'REFUNDED')::text, 'the late refund lands on payment and order');

select * from finish();
rollback;
