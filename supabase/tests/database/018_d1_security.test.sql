-- Spec D1 §10, §11 — cron jobs and the D1 security suite.
begin;
create extension if not exists pgtap with schema extensions;

select plan(35);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, 'ACTIVE', true);
insert into public.territory_coverage (tenant_id, state_code, territory_id) values
  ('10000000-0000-0000-0000-000000000001', 'LA', '40000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'OG', '40000000-0000-0000-0000-000000000001');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- cron
select has_extension('pg_net');
select is((select count(*)::int from cron.job where jobname in ('reconcile-funds-sweep','reconcile-funds-refunds','fintech-commission-release')), 3, 'three D1 cron jobs');
select is((select schedule from cron.job where jobname = 'reconcile-funds-sweep'), '*/5 * * * *', 'sweep every five minutes');
select is((select schedule from cron.job where jobname = 'reconcile-funds-refunds'), '0 5 * * *', '06:00 Lagos');
select is((select schedule from cron.job where jobname = 'fintech-commission-release'), '0 6 * * *', '07:00 Lagos');
select is(public.invoke_system_function('reconcile-funds', '{}'::jsonb), null, 'no Vault secrets: posts nothing');

-- privileges
select ok(to_regprocedure('public.storefront_catalogue(text)') is not null and not has_function_privilege('anon', 'public.storefront_catalogue(text)', 'execute'),
  'anon cannot execute storefront_catalogue');
select ok(to_regprocedure('public.storefront_catalogue(text)') is not null and not has_function_privilege('authenticated', 'public.storefront_catalogue(text)', 'execute'),
  'authenticated cannot execute storefront_catalogue');
select ok(to_regprocedure('public.quote_web_order(text,jsonb,uuid)') is not null and not has_function_privilege('anon', 'public.quote_web_order(text,jsonb,uuid)', 'execute'),
  'anon cannot execute quote_web_order');
select ok(to_regprocedure('public.quote_web_order(text,jsonb,uuid)') is not null and not has_function_privilege('authenticated', 'public.quote_web_order(text,jsonb,uuid)', 'execute'),
  'authenticated cannot execute quote_web_order');
select ok(to_regprocedure('public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)') is not null and not has_function_privilege('anon', 'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', 'execute'),
  'anon cannot execute place_web_order');
select ok(to_regprocedure('public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)') is not null and not has_function_privilege('authenticated', 'public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', 'execute'),
  'authenticated cannot execute place_web_order');
select ok(to_regprocedure('public.storefront_locations(text)') is not null and not has_function_privilege('anon', 'public.storefront_locations(text)', 'execute'),
  'anon cannot execute storefront_locations');
select ok(to_regprocedure('public.storefront_locations(text)') is not null and not has_function_privilege('authenticated', 'public.storefront_locations(text)', 'execute'),
  'authenticated cannot execute storefront_locations');
select ok(to_regprocedure('public.web_order_status(text,text)') is not null and not has_function_privilege('anon', 'public.web_order_status(text,text)', 'execute'),
  'anon cannot execute web_order_status');
select ok(to_regprocedure('public.web_order_status(text,text)') is not null and not has_function_privilege('authenticated', 'public.web_order_status(text,text)', 'execute'),
  'authenticated cannot execute web_order_status');
select ok(to_regprocedure('public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)') is not null and not has_function_privilege('anon', 'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute'),
  'anon cannot execute settle_paystack_payment');
select ok(to_regprocedure('public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)') is not null and not has_function_privilege('authenticated', 'public.settle_paystack_payment(text,text,text,bigint,text,jsonb,text,text,bigint)', 'execute'),
  'authenticated cannot execute settle_paystack_payment');
select ok(to_regprocedure('public.record_stale_paystack_webhook(text,text,timestamptz)') is not null and not has_function_privilege('anon', 'public.record_stale_paystack_webhook(text,text,timestamptz)', 'execute'),
  'anon cannot execute record_stale_paystack_webhook');
select ok(to_regprocedure('public.record_stale_paystack_webhook(text,text,timestamptz)') is not null and not has_function_privilege('authenticated', 'public.record_stale_paystack_webhook(text,text,timestamptz)', 'execute'),
  'authenticated cannot execute record_stale_paystack_webhook');
select ok(to_regprocedure('public.claim_unconfirmed_payments(integer)') is not null and not has_function_privilege('anon', 'public.claim_unconfirmed_payments(integer)', 'execute'),
  'anon cannot execute claim_unconfirmed_payments');
select ok(to_regprocedure('public.claim_unconfirmed_payments(integer)') is not null and not has_function_privilege('authenticated', 'public.claim_unconfirmed_payments(integer)', 'execute'),
  'authenticated cannot execute claim_unconfirmed_payments');
select ok(to_regprocedure('public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)') is not null and not has_function_privilege('anon', 'public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)', 'execute'),
  'anon cannot execute apply_paystack_refund');
select ok(to_regprocedure('public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)') is not null and not has_function_privilege('authenticated', 'public.apply_paystack_refund(text,text,text,bigint,text,text,jsonb)', 'execute'),
  'authenticated cannot execute apply_paystack_refund');
select ok(to_regprocedure('public.list_unsettled_subaccounts()') is not null and not has_function_privilege('anon', 'public.list_unsettled_subaccounts()', 'execute'),
  'anon cannot execute list_unsettled_subaccounts');
select ok(to_regprocedure('public.list_unsettled_subaccounts()') is not null and not has_function_privilege('authenticated', 'public.list_unsettled_subaccounts()', 'execute'),
  'authenticated cannot execute list_unsettled_subaccounts');
select ok(to_regprocedure('public.release_commission(text,timestamptz,text,bigint)') is not null and not has_function_privilege('anon', 'public.release_commission(text,timestamptz,text,bigint)', 'execute'),
  'anon cannot execute release_commission');
select ok(to_regprocedure('public.release_commission(text,timestamptz,text,bigint)') is not null and not has_function_privilege('authenticated', 'public.release_commission(text,timestamptz,text,bigint)', 'execute'),
  'authenticated cannot execute release_commission');
select ok(to_regprocedure('public.expire_unsettled_commissions()') is not null and not has_function_privilege('anon', 'public.expire_unsettled_commissions()', 'execute'),
  'anon cannot execute expire_unsettled_commissions');
select ok(to_regprocedure('public.expire_unsettled_commissions()') is not null and not has_function_privilege('authenticated', 'public.expire_unsettled_commissions()', 'execute'),
  'authenticated cannot execute expire_unsettled_commissions');
select ok(to_regprocedure('public.invoke_system_function(text,jsonb)') is not null and not has_function_privilege('anon', 'public.invoke_system_function(text,jsonb)', 'execute'),
  'anon cannot execute invoke_system_function');
select ok(to_regprocedure('public.invoke_system_function(text,jsonb)') is not null and not has_function_privilege('authenticated', 'public.invoke_system_function(text,jsonb)', 'execute'),
  'authenticated cannot execute invoke_system_function');
select ok(not has_function_privilege('service_role', 'public.invoke_system_function(text,jsonb)', 'execute'), 'cron helper is not an API');

-- territory_coverage RLS
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.territory_coverage), 2, 'member reads own tenant coverage');
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.territory_coverage), 0, 'other tenant reads nothing');

select * from finish();
rollback;
