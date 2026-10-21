-- Spec A §3.6 — Paystack webhook: at most once per (event, reference);
-- amounts and status from the Verify API; stale events audited, not applied.
-- D1 §6 signature: transaction id and verified split (none here).
begin;
create extension if not exists pgtap with schema extensions;

select plan(31);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000003', '2348000000003');
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'FIELD_DSA',
   '20000000-0000-0000-0000-000000000003', 10000),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'FIELD_DSA',
   '20000000-0000-0000-0000-000000000003', 10000);
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, payment_status, paystack_reference) values
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 2500.00, 'INITIATED', 'ref_success'),
  ('80000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 1000.00, 'INITIATED', 'ref_mismatch'),
  ('80000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 500.00, 'INITIATED', 'ref_failed'),
  ('80000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 700.00, 'SUCCESS', 'ref_settled'),
  ('80000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 600.00, 'INITIATED', 'ref_pending'),
  ('80000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 100.00, 'INITIATED', 'ref_dup'),
  ('80000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000003', 100.00, 'INITIATED', 'ref_dup');
-- D1 §6.1: failed is final only after 2 h (the buyer may retry the same reference)
update public.payments set created_at = now() - interval '3 hours'
 where id in ('80000000-0000-0000-0000-000000000003', '80000000-0000-0000-0000-000000000004');

select has_index('public', 'payments', 'idx_payments_paystack_reference',
  'the webhook finds a payment by reference without knowing its tenant');
select ok(not has_function_privilege('authenticated',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute'),
  'no user can settle a payment');
select ok(not has_function_privilege('authenticated',
  'public.record_stale_paystack_webhook(text,text,timestamptz)', 'execute'),
  'no user can write webhook audit rows');
select ok(has_function_privilege('service_role',
  'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute'),
  'process-payment (service_role) can settle');
select ok(has_function_privilege('service_role',
  'public.record_stale_paystack_webhook(text,text,timestamptz)', 'execute'),
  'process-payment (service_role) can record a stale event');

set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

-- success
select is(public.settle_paystack_payment('charge.success', 'ref_success', 'success', 250000, 'NGN', '{"id": 1}', '1', null, null) ->> 'outcome',
  'updated', 'a verified success settles the payment');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000001'),
  'SUCCESS', 'the payment is SUCCESS');
select is((select gateway_response_payload from public.payments where id = '80000000-0000-0000-0000-000000000001'),
  '{"id": 1}'::jsonb, 'the Verify API response is kept on the payment');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'settle_paystack_payment' and entity_id = '80000000-0000-0000-0000-000000000001'
                     and source = 'WEBHOOK' and actor_id is null
                     and teafair_agent_id = '20000000-0000-0000-0000-000000000003'),
  'the settlement is audited as a webhook, owned by the accountable agent');
select is(public.settle_paystack_payment('charge.success', 'ref_success', 'success', 250000, 'NGN', '{"id": 1}', '1', null, null) ->> 'outcome',
  'updated', 'a replay returns the first result');
select is((select count(*)::int from public.audit_logs
            where operation = 'settle_paystack_payment' and entity_id = '80000000-0000-0000-0000-000000000001'),
  1, 'a replay writes nothing');

-- amount and currency must agree with the payment
select is(public.settle_paystack_payment('charge.success', 'ref_mismatch', 'success', 50000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'mismatch', 'an amount that disagrees with the payment is not settled');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000002'),
  'INITIATED', 'the mismatched payment is untouched');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'PAYSTACK_MISMATCH' and entity_id = '80000000-0000-0000-0000-000000000002'),
  'the mismatch is audited for review');
select is(public.settle_paystack_payment('charge.success', 'ref_failed', 'success', 50000, 'GHS', '{}', '1', null, null) ->> 'outcome',
  'mismatch', 'a currency that disagrees with the tenant is not settled');

-- failure and conflicts
select is(public.settle_paystack_payment('charge.failed', 'ref_failed', 'failed', 50000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'updated', 'a verified failure over 2 h old is recorded');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000003'),
  'FAILED', 'the payment is FAILED');
select is(public.settle_paystack_payment('charge.success', 'ref_settled', 'failed', 70000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'conflict', 'a settled payment is never downgraded');
select is((select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000004'),
  'SUCCESS', 'it stays SUCCESS');

-- references the database cannot resolve
select is(public.settle_paystack_payment('charge.success', 'ref_unknown', 'success', 100, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'unknown_reference', 'an unknown reference is reported');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'PAYSTACK_UNKNOWN_REFERENCE' and entity_id = 'ref_unknown' and tenant_id is null),
  'and audited');
select ok(not exists (select 1 from public.idempotency_logs
                       where key = md5('paystack:charge.success:ref_unknown')::uuid),
  'an unknown reference is not marked processed, so a later delivery can still settle it');
select is(public.settle_paystack_payment('charge.success', 'ref_dup', 'success', 10000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'ambiguous_reference', 'a reference shared by two tenants is not guessed at');
select is((select count(*)::int from public.payments where paystack_reference = 'ref_dup' and payment_status = 'INITIATED'),
  2, 'neither ambiguous payment is touched');

-- non-final status: leave it to the reconcile-funds sweep
select is(public.settle_paystack_payment('charge.success', 'ref_pending', 'ongoing', 60000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'not_final', 'a non-final status changes nothing');
select ok(not exists (select 1 from public.idempotency_logs
                       where key = md5('paystack:charge.success:ref_pending')::uuid),
  'and is not marked processed');
-- D1 §6.1: a fresh failure may be a declined card the buyer retries on the same reference
select is(public.settle_paystack_payment('charge.failed', 'ref_pending', 'failed', 60000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'not_final', 'failed on a fresh payment is not final');
-- D1 §6.1: a fresh abandoned payment may be a buyer still on the payment page
select is(public.settle_paystack_payment('sweep', 'ref_pending', 'abandoned', 60000, 'NGN', '{}', '1', null, null) ->> 'outcome',
  'not_final', 'abandoned on a fresh payment is not final');
-- D1 §9: reversals belong to apply_paystack_refund
select throws_ok($$select public.settle_paystack_payment('charge.success', 'ref_pending', 'reversed', 60000, 'NGN', '{}', '1', null, null)$$,
  'P0001', 'reversed is applied by apply_paystack_refund', 'a reversal is not settled here');

-- stale
select is(public.record_stale_paystack_webhook('charge.success', 'ref_pending', now() - interval '1 hour') ->> 'outcome',
  'stale', 'a stale event is recorded');
select ok(exists (select 1 from public.audit_logs
                   where operation = 'WEBHOOK_STALE' and entity_id = '80000000-0000-0000-0000-000000000005'
                     and tenant_id = '10000000-0000-0000-0000-000000000001' and source = 'WEBHOOK')
          and (select payment_status::text from public.payments where id = '80000000-0000-0000-0000-000000000005') = 'INITIATED',
  'it is audited against the payment''s tenant and the payment is left for the sweep');

select * from finish();
rollback;
