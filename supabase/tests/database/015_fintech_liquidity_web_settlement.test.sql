-- Spec D1 §6 — collection settlement: PENDING → PAID, the commission row
-- copied from the split snapshot, the sweep's age rules, escalations, and
-- claim_unconfirmed_payments.
begin;
create extension if not exists pgtap with schema extensions;

select plan(70);

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
insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000007', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.agent_codes (id, tenant_id, code, agent_id, created_by, max_redemptions) values
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
                             agent_code_id, attributed_agent_id, created_at)
  values (('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000006',
          2500, p_order_status, 'PAYSTACK_WEB', 'TF-AA00' || lpad(p_n::text, 2, '0'),
          md5('ng_lga:LA:Ikeja')::uuid,
          ('40000000-0000-0000-0000-00000000000' || p_territory)::uuid,
          ('70000000-0000-0000-0000-00000000000' || p_territory)::uuid,
          case when p_code then '65000000-0000-0000-0000-000000000001'::uuid end,
          case when p_code then '20000000-0000-0000-0000-000000000006'::uuid end,
          now() - p_age);
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
-- a field order with a split snapshot: D1 settles its payment, not its status
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, created_at) values
  ('90000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001', 'FIELD_DSA',
   '20000000-0000-0000-0000-000000000006', 2500, now() - interval '10 minutes');
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, fintech_partner_id, amount, paystack_reference,
                             split_subaccount_code, split_bps, split_amount, created_at) values
  ('91000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000021',
   '20000000-0000-0000-0000-000000000006', '60000000-0000-0000-0000-000000000001', 2500.00, 'r_field',
   'ACCT_grace01', 150, 37.50, now() - interval '10 minutes');

select throws_ok($$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference,
                                               split_subaccount_code, split_bps, split_amount)
  values ('10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000021',
          '20000000-0000-0000-0000-000000000006', 100, 'r_nopartner', 'ACCT_grace01', 150, 1.50)$$,
  '23514', null, 'a split snapshot needs its partner');
select ok(not has_column_privilege('authenticated', 'public.payments', 'last_swept_at', 'select'),
  'last_swept_at is internal');
select is((select indexdef ~ 'COALESCE\(last_swept_at, created_at\)' from pg_indexes
            where schemaname = 'public' and indexname = 'idx_payments_unconfirmed'),
  true, 'the sweep index follows the sweep order');

-- claiming stamps rows; tests that need a clean sweep order reset the stamps
-- as the owner: last_swept_at = now() for p_refs, null for everything else
create function pg_temp.stamp(p_refs text[]) returns void language sql as $$
  update public.payments
     set last_swept_at = case when paystack_reference = any(p_refs) then now() end;
$$;

create function pg_temp.notes(p_kind text, p_order integer) returns integer language sql as $$
  select count(*)::int from public.notifications
   where kind = p_kind
     and payload ->> 'order_id' = '90000000-0000-0000-0000-0000000000' || lpad(p_order::text, 2, '0');
$$;
grant execute on function pg_temp.notes(text, integer) to service_role;

-- ── privileges ──────────────────────────────────────────────────────────
select hasnt_function('public', 'settle_paystack_payment', array['text','text','text','bigint','text','jsonb'],
  'the 6-argument settle is gone');
select ok(has_function_privilege('service_role',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute'),
  'process-payment and reconcile-funds (service_role) settle');
select ok(not has_function_privilege('authenticated',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute')
  and not has_function_privilege('anon',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute'),
  'no user or visitor can settle');
select ok(has_function_privilege('service_role', 'public.claim_unconfirmed_payments(integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.claim_unconfirmed_payments(integer)', 'execute')
  and not has_function_privilege('anon', 'public.claim_unconfirmed_payments(integer)', 'execute'),
  'only service_role claims unconfirmed payments');
select ok(not has_function_privilege('service_role', 'public.notify_tenant_zsms(uuid,text,text,text,jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.notify_tenant_zsms(uuid,text,text,text,jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.notify_tenant_zsms(uuid,text,text,text,jsonb)', 'execute'),
  'notify_tenant_zsms is internal');

-- notify_tenant_zsms, as the owner: one row per ACTIVE ZSM
select is(public.notify_tenant_zsms('10000000-0000-0000-0000-000000000001', 'TEST_KIND', 't', 'b', '{"x": 1}'),
  2, 'one notification per ACTIVE ZSM');
select is((select array_agg(user_id::text order by user_id) from public.notifications where kind = 'TEST_KIND'),
  array['20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002'],
  'the DISABLED ZSM is skipped');

-- before anything settles: the code still has its one redemption
select lives_ok($$select public.web_resolve_code('CAPONE01')$$, 'a pending order does not use up the code');

set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

select ok('r_mismatch' in (select paystack_reference from public.claim_unconfirmed_payments(50)),
  'an undecided payment is claimed by the sweep');
reset role;
select pg_temp.stamp(array[]::text[]);
set local role service_role;

-- ── PENDING → PAID ──────────────────────────────────────────────────────
select is(public.settle_paystack_payment('charge.success', 'r_ok', 'success', 250000, 'NGN', '{"id": 9001}',
  '9001', null, null) ->> 'order_status', 'PAID', 'PENDING → PAID');
select is((select payment_status::text from public.payments where paystack_reference = 'r_ok'),
  'SUCCESS', 'the payment is SUCCESS');
select is((select count(*)::int from public.commission_records where payment_id = '91000000-0000-0000-0000-000000000001'),
  0, 'no snapshot, no commission row');
select is(pg_temp.notes('WEB_ORDER_PAID', 1), 2, 'warehouse manager and TM notified');
select is((select array_agg(user_id::text order by user_id) from public.notifications
            where kind = 'WEB_ORDER_PAID' and payload ->> 'order_id' = '90000000-0000-0000-0000-000000000001'),
  array['20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000004'],
  'the recipients are the TM and the warehouse manager');
select ok(exists (select 1 from public.notifications
                   where kind = 'WEB_ORDER_PAID' and user_id = '20000000-0000-0000-0000-000000000004'
                     and tenant_id = '10000000-0000-0000-0000-000000000001'
                     and title = 'Web order paid'
                     and body = 'Order TF-AA0001 is paid and ready to ship.'
                     and payload = '{"order_id": "90000000-0000-0000-0000-000000000001", "public_reference": "TF-AA0001"}'::jsonb),
  'the to-ship notification carries the order and its reference, nothing else');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'settle_paystack_payment' and entity_type = 'orders'
                     and entity_id = '90000000-0000-0000-0000-000000000001'
                     and before ->> 'status' = 'PENDING' and after ->> 'status' = 'PAID'
                     and source = 'WEBHOOK'),
  'the order transition is audited');
select is((select teafair_agent_id from public.audit_logs
            where operation = 'settle_paystack_payment' and entity_type = 'payments'
              and entity_id = '91000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-000000000006'::uuid, 'audit carries the accountable agent');
select is(public.settle_paystack_payment('charge.success', 'r_dedup', 'success', 250000, 'NGN', '{}',
  '9010', null, null) ->> 'outcome', 'updated', 'settled');
select is(pg_temp.notes('WEB_ORDER_PAID', 2), 1, 'recipients deduplicated');

-- ── the commission row ──────────────────────────────────────────────────
select is(public.settle_paystack_payment('charge.success', 'r_split', 'success', 250000, 'NGN', '{}',
  '9002', 'ACCT_grace01', 3750) ->> 'commission_status', 'SPLIT', 'matching split → SPLIT');
select is((select row(amount, bps_applied, paystack_split_reference, paystack_subaccount_code,
                      fintech_partner_id, teafair_agent_id, order_id)::text
             from public.commission_records where payment_id = '91000000-0000-0000-0000-000000000003'),
  row(37.50::numeric(15,2), 150, '9002', 'ACCT_grace01', '60000000-0000-0000-0000-000000000001'::uuid,
      '20000000-0000-0000-0000-000000000006'::uuid, '90000000-0000-0000-0000-000000000003'::uuid)::text,
  'row copies the snapshot');
select is(public.settle_paystack_payment('charge.success', 'r_split_bad', 'success', 250000, 'NGN', '{}',
  '9003', 'ACCT_other', 3750) ->> 'commission_status', 'DISPUTED', 'wrong subaccount → DISPUTED');
select is((select dispute_reason from public.commission_records where payment_id = '91000000-0000-0000-0000-000000000004'),
  'SPLIT_MISMATCH', 'reason SPLIT_MISMATCH');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'SPLIT_MISMATCH' and entity_type = 'commission_records'
                     and before ->> 'split_subaccount' = 'ACCT_grace01' and (before ->> 'split_share_minor')::bigint = 3750
                     and after ->> 'split_subaccount' = 'ACCT_other' and (after ->> 'split_share_minor')::bigint = 3750),
  'the mismatch audit holds both values');
select is((select count(*)::int from public.notifications where kind = 'COMMISSION_DISPUTED'),
  2, 'ZSMs told about the dispute');
select ok(exists (select 1 from public.notifications n
                   join public.commission_records c on c.payment_id = '91000000-0000-0000-0000-000000000004'
                  where n.kind = 'COMMISSION_DISPUTED' and n.title = 'Commission disputed'
                    and n.body = 'A partner commission needs review (SPLIT_MISMATCH).'
                    and n.payload = jsonb_build_object('commission_id', c.id, 'order_id', c.order_id,
                                                       'reason', 'SPLIT_MISMATCH')),
  'the dispute notification names the commission and the order');
select is(public.settle_paystack_payment('charge.success', 'r_split_share', 'success', 250000, 'NGN', '{}',
  '9013', 'ACCT_grace01', 3700) ->> 'commission_status', 'DISPUTED', 'right subaccount, wrong share → DISPUTED');
select is((select dispute_reason from public.commission_records where payment_id = '91000000-0000-0000-0000-000000000016'),
  'SPLIT_MISMATCH', 'reason SPLIT_MISMATCH for the share');

-- ── field orders: the payment settles, the order is Spec C's ────────────
select is(public.settle_paystack_payment('charge.success', 'r_field', 'success', 250000, 'NGN', '{}',
  '9014', 'ACCT_grace01', 3750) ->> 'commission_status', 'SPLIT', 'a field payment still gets its commission row');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_field'),
  row('SUCCESS', 'PENDING')::text, 'the FIELD_DSA order stays PENDING');
select ok(not exists (select 1 from public.audit_logs
                       where entity_type = 'orders' and entity_id = '90000000-0000-0000-0000-000000000021'),
  'and is neither transitioned nor escalated');

-- ── age rules ───────────────────────────────────────────────────────────
select is(public.settle_paystack_payment('sweep', 'r_aband_new', 'abandoned', 250000, 'NGN', '{}',
  '9004', null, null) ->> 'outcome', 'not_final', 'abandoned under 2 h is not final');
select ok(not exists (select 1 from public.idempotency_logs where key = md5('paystack:sweep:r_aband_new')::uuid),
  'and takes no key, so the next sweep retries');
select is(public.settle_paystack_payment('sweep', 'r_aband_old', 'abandoned', 250000, 'NGN', '{}',
  '9005', null, null) ->> 'outcome', 'updated', 'abandoned over 2 h fails');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_aband_old'),
  row('FAILED', 'PENDING')::text, 'the payment is FAILED; the order stays PENDING');
select is(public.settle_paystack_payment('sweep', 'r_pend_old', 'ongoing', 250000, 'NGN', '{}',
  '9006', null, null) ->> 'payment_status', 'FAILED', 'non-final over 72 h fails');
select is((select count(*)::int from public.audit_logs
            where operation = 'SWEEP_EXPIRED' and entity_id = '91000000-0000-0000-0000-000000000007' and source = 'CRON'),
  1, 'audited SWEEP_EXPIRED');
select is(public.settle_paystack_payment('sweep', 'r_ong10', 'ongoing', 250000, 'NGN', '{}',
  '9015', null, null) ->> 'outcome', 'not_final', 'ongoing at 10 h is not final');
select ok(not exists (select 1 from public.idempotency_logs where key = md5('paystack:sweep:r_ong10')::uuid),
  'and takes no key');
select is(public.settle_paystack_payment('sweep', 'r_fail_old', 'failed', 250000, 'NGN', '{}',
  '9016', null, null) ->> 'payment_status', 'FAILED', 'failed at 73 h is FAILED');
select ok(not exists (select 1 from public.audit_logs
                       where operation = 'SWEEP_EXPIRED' and entity_id = '91000000-0000-0000-0000-000000000017'),
  'a verified failure is not an expiry');
select is(public.settle_paystack_payment('sweep', 'r_fail_new', 'failed', 250000, 'NGN', '{}',
  '9019', null, null) ->> 'outcome', 'not_final', 'failed at 1 h is not final: the buyer may retry the same reference');
select ok(not exists (select 1 from public.idempotency_logs where key = md5('paystack:sweep:r_fail_new')::uuid),
  'and takes no key, so a later success on that reference still settles');

-- ── the sweep visits the least recently checked first ───────────────────
reset role;
select pg_temp.stamp(array[]::text[]);
set local role service_role;
select ok((select array_position(l, 'r_q_a') < array_position(l, 'r_q_b')
              and array_position(l, 'r_q_b') < array_position(l, 'r_q_c')
             from (select array_agg(paystack_reference) l from public.claim_unconfirmed_payments(50)) s),
  'unchecked payments are claimed oldest first');
select ok((select bool_and(last_swept_at = now()) from public.payments
            where paystack_reference in ('r_q_a', 'r_q_b', 'r_q_c', 'r_wait_a', 'r_wait_b')),
  'claiming stamps every row it hands out, before the sweep looks at it');
reset role;
select pg_temp.stamp(array[]::text[]);
set local role service_role;
select is(public.settle_paystack_payment('sweep', 'r_q_a', 'pending', 250000, 'NGN', '{}',
  '9017', null, null) ->> 'outcome', 'not_final', 'A is not final yet');
select ok((select last_swept_at = now() from public.payments where paystack_reference = 'r_q_a'),
  'a not-final sweep also stamps last_swept_at');
select is(public.settle_paystack_payment('charge.success', 'r_q_b', 'pending', 250000, 'NGN', '{}',
  '9018', null, null) ->> 'outcome', 'not_final', 'a webhook not-final result');
select ok((select last_swept_at is null from public.payments where paystack_reference = 'r_q_b'),
  'does not count as a sweep');
select ok((select array_position(l, 'r_q_a') > array_position(l, 'r_q_c')
              and array_position(l, 'r_q_b') < array_position(l, 'r_q_c')
             from (select array_agg(paystack_reference) l from public.claim_unconfirmed_payments(50)) s),
  'A, checked last, is claimed behind B and C');

-- ── real money wins ─────────────────────────────────────────────────────
select is(public.settle_paystack_payment('charge.success', 'r_late', 'success', 250000, 'NGN', '{}',
  '9007', null, null) ->> 'order_status', 'PAID', 'a late success still pays the order');
select is((select count(*)::int from public.audit_logs
            where operation = 'LATE_SUCCESS' and entity_id = '91000000-0000-0000-0000-000000000008'),
  1, 'LATE_SUCCESS');
select is(public.settle_paystack_payment('charge.success', 'r_cancel', 'success', 250000, 'NGN', '{}',
  '9008', null, null) ->> 'order_status', 'CANCELLED', 'order left as it is');
select is((select payment_status::text from public.payments where paystack_reference = 'r_cancel'),
  'SUCCESS', 'the money is recorded');
select is(row((select count(*)::int from public.audit_logs
                where operation = 'PAID_AFTER_CANCEL' and entity_id = '90000000-0000-0000-0000-000000000009'),
              (select count(*)::int from public.notifications
                where kind = 'WEB_ORDER_PAID_AFTER_CANCEL' and title = 'Paid order was cancelled'
                  and body = 'Order TF-AA0009 was paid after it was cancelled. Refund or reinstate it.'))::text,
  row(1, 2)::text, 'escalated');

-- ── the sweep after the webhook; mismatches ─────────────────────────────
select is(public.settle_paystack_payment('sweep', 'r_ok', 'success', 250000, 'NGN', '{}',
  '9001', null, null) ->> 'outcome', 'unchanged', 'webhook then sweep: unchanged');
select is(public.settle_paystack_payment('sweep', 'r_mismatch', 'success', 1, 'NGN', '{}',
  '9009', null, null) ->> 'outcome', 'mismatch', 'amount mismatch');
select is((select row(p.payment_status::text, o.status)::text from public.payments p join public.orders o on o.id = p.order_id
            where p.paystack_reference = 'r_mismatch'),
  row('INITIATED', 'PENDING')::text, 'mismatch changes nothing');
select ok(not ('r_mismatch' in (select paystack_reference from public.claim_unconfirmed_payments(50))),
  'a decided payment leaves the sweep');
reset role;
select pg_temp.stamp(array['r_aband_new', 'r_ong10', 'r_q_a', 'r_fail_new']);
set local role service_role;
select is((select array_agg(paystack_reference) from public.claim_unconfirmed_payments(50)),
  array['r_wait_a', 'r_q_b', 'r_q_c', 'r_wait_b', 'r_code', 'r_aband_new', 'r_ong10', 'r_q_a', 'r_fail_new'],
  'least recently checked first, >5 min only');
select throws_ok($$select public.settle_paystack_payment('sweep', 'r_wait_a', 'reversed', 250000, 'NGN', '{}',
  '9011', null, null)$$, 'P0001', 'reversed is applied by apply_paystack_refund', 'reversed is not settled here');
select is(public.settle_paystack_payment('sweep', 'r_nowhere', 'success', 100, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'unknown_reference', 'an unknown reference is reported');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'PAYSTACK_UNKNOWN_REFERENCE' and entity_id = 'r_nowhere' and source = 'CRON'),
  'a sweep row is audited as CRON');

-- ── max_redemptions ─────────────────────────────────────────────────────
select is(public.settle_paystack_payment('charge.success', 'r_code', 'success', 250000, 'NGN', '{}',
  '9012', null, null) ->> 'order_status', 'PAID', 'the code''s order is paid');
reset role;
select throws_ok($$select public.web_resolve_code('CAPONE01')$$, 'P0001', 'This link is no longer valid',
  'PAID orders count toward max_redemptions');

-- ── rows that error do not starve the sweep ─────────────────────────────
-- every row above is now stamped; three older unchecked payments come first
select pg_temp.mk(23, 'r_err_1',      1, '100 days');
select pg_temp.mk(24, 'r_err_2',      1, '99 days');
select pg_temp.mk(25, 'r_err_3',      1, '98 days');
set local role service_role;
select is((select array_agg(paystack_reference) from public.claim_unconfirmed_payments(2)),
  array['r_err_1', 'r_err_2'], 'the two oldest are claimed');
-- both Verify calls fail: settle_paystack_payment is never called for them
select is((select (array_agg(paystack_reference))[1] from public.claim_unconfirmed_payments(50)),
  'r_err_3', 'the next claim starts with the third: claimed rows moved to the back');
reset role;

select * from finish();
rollback;
