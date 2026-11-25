-- 20261125120000 — email-first authentication: an email alone makes a
-- profile, contact changes follow into profiles, invitations resolve a
-- confirmed email or phone, and auth_email_context gates the sign-in code.
begin;
create extension if not exists pgtap with schema extensions;

select plan(31);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Email First Test', 'TFEML');

-- ── profiles ────────────────────────────────────────────────────────────
-- 1 no role · 2 PLATFORM_SUPER_ADMIN · 3 MONVELO_OPERATOR · 4 ZSM · 5 agent
-- member · 6 shop owner · 7 ZSM and agent member · 8 DISABLED member only
-- · 9 unconfirmed email · 10 phone only
insert into auth.users (id, email, email_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '  Ada@Example.COM ', now()),
  ('20000000-0000-0000-0000-000000000002', 'admin@example.com', now()),
  ('20000000-0000-0000-0000-000000000003', 'operator@example.com', now()),
  ('20000000-0000-0000-0000-000000000004', 'zsm@example.com', now()),
  ('20000000-0000-0000-0000-000000000005', 'agent@example.com', now()),
  ('20000000-0000-0000-0000-000000000006', 'owner@example.com', now()),
  ('20000000-0000-0000-0000-000000000007', 'both@example.com', now()),
  ('20000000-0000-0000-0000-000000000008', 'gone@example.com', now()),
  ('20000000-0000-0000-0000-000000000009', 'pending@example.com', null);
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000010', '2348100000010', now());

select is((select email from public.profiles where id = '20000000-0000-0000-0000-000000000001'),
  'ada@example.com', 'the profile email is trimmed and lower-cased');
select is((select phone_number from public.profiles where id = '20000000-0000-0000-0000-000000000001'),
  null, 'an email-only account has no phone');
select is((select phone_number from public.profiles where id = '20000000-0000-0000-0000-000000000010'),
  '+2348100000010', 'a phone-only account still gets its E.164 phone');
select throws_ok(
  $$insert into auth.users (id) values ('20000000-0000-0000-0000-0000000000ff')$$,
  'P0001', 'an email address is required to create a Teafair account',
  'an account with neither an email nor a phone is refused');
select throws_ok(
  $$update public.profiles set email = null where id = '20000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a profile keeps an email or a phone (profiles_contact_present)');

-- ── contact changes follow into profiles ────────────────────────────────
update auth.users set email = 'Ada.New@Example.com' where id = '20000000-0000-0000-0000-000000000001';
select is((select email from public.profiles where id = '20000000-0000-0000-0000-000000000001'),
  'ada.new@example.com', 'a confirmed email change follows into the profile');
update auth.users set phone = '2348100000001' where id = '20000000-0000-0000-0000-000000000001';
select is((select phone_number from public.profiles where id = '20000000-0000-0000-0000-000000000001'),
  '+2348100000001', 'a phone added later follows into the profile');
select throws_ok(
  $$update auth.users set email = null, phone = null where id = '20000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'removing the last contact is refused');
update auth.users set email = 'ada@example.com', phone = null where id = '20000000-0000-0000-0000-000000000001';

-- ── memberships and roles ───────────────────────────────────────────────
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN' where id = '20000000-0000-0000-0000-000000000002';
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000003';
insert into public.tenant_users (tenant_id, profile_id, role, status) values
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004', 'ZSM', 'ACTIVE'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007', 'ZSM', 'INVITED'),
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000008', 'ZSM', 'DISABLED');
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status) values
  ('80000000-0000-0000-0000-000000000001', 'Email POS', 'OPAY', 'OP-EML-1', '+2348031110001',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'a',
   '0123456789', '6789', '058', 'Email POS', 'K1', '20000000-0000-0000-0000-000000000004', 'ACTIVE');
insert into public.monvelo_agent_members (agent_id, profile_id) values
  ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005'),
  ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007');
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location) values
  ('90000000-0000-0000-0000-000000000001', 'Email Shop', '+2348000000010', '20000000-0000-0000-0000-000000000006',
   'MARKET_SQUARE', extensions.st_setsrid(extensions.st_makepoint(3.3515, 6.6018), 4326));

-- ── auth_email_context ──────────────────────────────────────────────────
select is(public.auth_email_context('20000000-0000-0000-0000-000000000001'),
  '{"allowed": false, "audience": "TEAM"}'::jsonb, 'no role, no membership: no sign-in code');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000002'),
  '{"allowed": true, "audience": "TEAM"}'::jsonb, 'the platform administrator gets the TEAM copy');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000003'),
  '{"allowed": true, "audience": "MONVELO"}'::jsonb, 'Monvelo staff get the MONVELO copy');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000004'),
  '{"allowed": true, "audience": "TEAM"}'::jsonb, 'an ACTIVE tenant member gets the TEAM copy');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000005'),
  '{"allowed": true, "audience": "MONVELO"}'::jsonb, 'an ACTIVE agent member gets the MONVELO copy');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000006'),
  '{"allowed": true, "audience": "TRADE"}'::jsonb, 'a registered shop owner gets the TRADE copy');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000007'),
  '{"allowed": true, "audience": "TEAM"}'::jsonb, 'an INVITED staff member who is also an agent member: TEAM wins');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000008'),
  '{"allowed": false, "audience": "TEAM"}'::jsonb, 'a DISABLED membership alone gets no code');
update public.monvelo_agent_members set status = 'REVOKED' where profile_id = '20000000-0000-0000-0000-000000000005';
select is(public.auth_email_context('20000000-0000-0000-0000-000000000005') ->> 'allowed',
  'false', 'a revoked agent member gets no code');
select is(public.auth_email_context('20000000-0000-0000-0000-0000000000aa') ->> 'allowed',
  'false', 'an unknown user gets no code');

-- ── grants ──────────────────────────────────────────────────────────────
select ok(has_function_privilege('service_role', 'public.auth_email_context(uuid)', 'execute'),
  'the hook (service_role) may call auth_email_context');
select ok(not has_function_privilege('authenticated', 'public.auth_email_context(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.auth_email_context(uuid)', 'execute'),
  'no API user calls auth_email_context');
select ok(not has_function_privilege('authenticated', 'public.is_monvelo_agent_member(uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.is_monvelo_agent_member(uuid)', 'execute'),
  'is_monvelo_agent_member is internal');
select ok(not has_function_privilege('authenticated', 'public.resolve_verified_account(text)', 'execute'),
  'resolve_verified_account is internal');

-- ── appointing by email ─────────────────────────────────────────────────
select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', json_build_object(
         'sub', '20000000-0000-0000-0000-000000000002', 'role', 'authenticated')::text, true);
select throws_ok(
  $$select public.appoint_zone_manager('aaaaaaaa-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
      'pending@example.com')$$,
  'P0001', 'no Teafair account with a verified email or phone matches that contact',
  'an unconfirmed email is never appointed, and the error does not echo it');
select throws_ok(
  $$select public.appoint_zone_manager('aaaaaaaa-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
      'not-an-email@')$$,
  'P0001', 'enter a valid email address or phone number', 'a malformed email is refused');
select lives_ok(
  $$select public.appoint_zone_manager('aaaaaaaa-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
      '  ADA@example.com ')$$,
  'a confirmed email (any case, padded) is appointed');
select lives_ok(
  $$select public.appoint_zone_manager('aaaaaaaa-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
      'ada@example.com')$$,
  'a replay with the normalised email is the same request');
select lives_ok(
  $$select public.appoint_zone_manager('aaaaaaaa-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
      '+2348100000010')$$,
  'a confirmed phone still resolves');
reset role;

select is((select status::text from public.tenant_users
           where profile_id = '20000000-0000-0000-0000-000000000001'
             and tenant_id = '10000000-0000-0000-0000-000000000001'),
  'INVITED', 'the appointed person is an INVITED ZSM');
select is(public.auth_email_context('20000000-0000-0000-0000-000000000001'),
  '{"allowed": true, "audience": "TEAM"}'::jsonb, 'once invited, the person may sign in by email to accept');
select ok(not exists (select 1 from public.audit_logs
                      where operation = 'appoint_zone_manager'
                        and (coalesce(after::text, '') ~* 'example\.com' or coalesce(before::text, '') ~* 'example\.com')),
  'the audit holds no email address');
select is((select count(*)::int from public.tenant_users
           where profile_id = '20000000-0000-0000-0000-000000000001'),
  1, 'the padded and the normalised email were one request: one membership');

select * from finish();
rollback;
