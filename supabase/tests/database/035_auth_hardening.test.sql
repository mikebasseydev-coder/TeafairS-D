-- Auth audit M1 — who may receive a Supabase Auth phone code (send-auth-sms),
-- and the AUTH_OTP delivery log. H1 and H2 are tested in 002, 004 and 008.
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');
-- 1 ACTIVE member · 2 INVITED · 3 DISABLED · 4 no membership · 5 platform admin, no membership
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', now()),
  ('20000000-0000-0000-0000-000000000002', '2348000000002', now()),
  ('20000000-0000-0000-0000-000000000003', '2348000000003', now()),
  ('20000000-0000-0000-0000-000000000004', '2348000000004', now()),
  ('20000000-0000-0000-0000-000000000005', '2348000000005', now());
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN' where id = '20000000-0000-0000-0000-000000000005';
insert into public.tenant_users (tenant_id, profile_id, role, status, is_primary) values
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'RETAIL_SHOP_OWNER', 'ACTIVE', true),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'RETAIL_SHOP_OWNER', 'INVITED', true),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'RETAIL_SHOP_OWNER', 'DISABLED', true);

-- ── grants ───────────────────────────────────────────────────────────────
select ok(has_function_privilege('service_role', 'public.auth_sms_allowed(uuid,text)', 'execute'),
  'the send-auth-sms hook (service role) checks who may get a code');
select ok(not has_function_privilege('authenticated', 'public.auth_sms_allowed(uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.auth_sms_allowed(uuid,text)', 'execute'),
  'no API role can probe who is a member');

-- ── who gets a code ─────────────────────────────────────────────────────
select ok(public.auth_sms_allowed('20000000-0000-0000-0000-000000000001', '2348000000001'),
  'an ACTIVE member gets a code (GoTrue''s number without +)');
select ok(public.auth_sms_allowed('20000000-0000-0000-0000-000000000001', '+2348000000001'),
  'the E.164 form matches too');
select ok(public.auth_sms_allowed('20000000-0000-0000-0000-000000000002', '2348000000002'),
  'an INVITED member gets a code, to sign in and accept');
select ok(not public.auth_sms_allowed('20000000-0000-0000-0000-000000000003', '2348000000003'),
  'a DISABLED member gets none');
select ok(not public.auth_sms_allowed('20000000-0000-0000-0000-000000000004', '2348000000004'),
  'an account with no membership gets none');
select ok(public.auth_sms_allowed('20000000-0000-0000-0000-000000000005', '2348000000005'),
  'a platform administrator gets a code without a membership');
select ok(not public.auth_sms_allowed('20000000-0000-0000-0000-000000000001', '2348000000002'),
  'the phone must be the account''s own profile phone');
select ok(not public.auth_sms_allowed(gen_random_uuid(), '2348000000001'),
  'an unknown account gets none');

-- ── delivery log ────────────────────────────────────────────────────────
select lives_ok($$ select public.log_message_delivery(null, 'AUTH_OTP', 'WHATSAPP', 'SENT', '2348000000001', null, null) $$,
  'AUTH_OTP sends are logged platform-level (no tenant), last four digits only');

select * from finish();
rollback;
