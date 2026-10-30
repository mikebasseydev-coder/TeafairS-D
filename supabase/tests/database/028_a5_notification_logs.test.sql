-- Addendum A5 §7: notification_logs and log_message_delivery.
begin;
create extension if not exists pgtap with schema extensions;

select plan(10);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),  -- ZSM
  ('20000000-0000-0000-0000-000000000002', '2348000000002');  -- TM
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

select public.log_message_delivery('10000000-0000-0000-0000-000000000001', 'DELIVERY_CODE', 'WHATSAPP', 'SENT',
  '+2348012345678', 'a0000000-0000-0000-0000-000000000001', null);
select public.log_message_delivery('10000000-0000-0000-0000-000000000002', 'OTP', 'SMS', 'SENT',
  '+2348099990000', null, null);
select public.log_message_delivery(null, 'PHONE_VERIFY', 'WHATSAPP', 'FAILED', '+2348055551111', null, '131026');

select is((select phone_last4 from public.notification_logs where purpose = 'DELIVERY_CODE'), '5678', 'stores the last 4 digits');
select is((select count(*) from public.notification_logs l
            where l::text like '%234801234%' or l::text like '%+234%'),
  0::bigint, 'the full number is stored nowhere');
select is((select whatsapp_error from public.notification_logs where purpose = 'PHONE_VERIFY'), '131026', 'provider error code kept');
select throws_ok($$select public.log_message_delivery(null, 'GREETING', 'SMS', 'SENT', '+2348012345678', null, null)$$,
  '23514', null, 'purpose CHECK');
select throws_ok($$select public.log_message_delivery(null, 'OTP', 'PIGEON', 'SENT', '+2348012345678', null, null)$$,
  '23514', null, 'channel CHECK');
select throws_ok($$select public.log_message_delivery(null, 'OTP', 'SMS', 'MAYBE', '+2348012345678', null, null)$$,
  '23514', null, 'status CHECK');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((select count(*) from public.notification_logs), 1::bigint, 'ZSM reads only their tenant rows');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*) from public.notification_logs), 0::bigint, 'TM reads none');
reset role;

select ok(not has_function_privilege('anon', 'public.log_message_delivery(uuid,text,text,text,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.log_message_delivery(uuid,text,text,text,text,uuid,text)', 'execute'),
  'anon and authenticated cannot execute log_message_delivery');
select ok(has_function_privilege('service_role', 'public.log_message_delivery(uuid,text,text,text,text,uuid,text)', 'execute')
      and not has_table_privilege('authenticated', 'public.notification_logs', 'insert')
      and not has_table_privilege('service_role', 'public.notification_logs', 'insert'),
  'service_role executes the RPC; no one inserts directly');

select * from finish();
rollback;
