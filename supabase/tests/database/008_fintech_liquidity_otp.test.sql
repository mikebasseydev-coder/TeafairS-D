-- Spec A §6.11 — OTP challenges: hashed, single use, short-lived, attempt
-- lockout, issuance rate-limited per subject.
begin;
create extension if not exists pgtap with schema extensions;

select plan(24);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
-- 1 TM · 2 DSM · 3 DSA (issuer) · 4 second DSA · 5 shop owner · 6 shop owner elsewhere
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
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'DSM', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 'DSA', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'DSA', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'RETAIL_SHOP_OWNER', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000006', 'RETAIL_SHOP_OWNER', null, null, 'ACTIVE', true);

-- challenges for the verify tests, inserted directly under PICKUP_CONFIRM so
-- they do not count against the POS_SETTLEMENT issuance limit
insert into public.otp_challenges (id, tenant_id, subject_id, purpose, code_hash, destination_phone,
                                   issued_by, expires_at, created_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003', now() + interval '5 minutes', now()),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003', now() + interval '5 minutes', now()),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003',
   now() - interval '6 minutes', now() - interval '11 minutes'),
  ('60000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', extensions.crypt('123456', extensions.gen_salt('bf')),
   '+2348000000005', '20000000-0000-0000-0000-000000000003', now() + interval '5 minutes', now());

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

select ok(has_function_privilege('authenticated', 'public.issue_otp(uuid,uuid,public.otp_purpose_enum,text)', 'execute'),
  'issue_otp is callable through the gateway');
select ok(has_function_privilege('authenticated', 'public.verify_otp(uuid,uuid,text)', 'execute'),
  'verify_otp is callable through the gateway');
select ok(not has_function_privilege('anon', 'public.issue_otp(uuid,uuid,public.otp_purpose_enum,text)', 'execute'),
  'anon cannot issue codes');

-- ── issue ────────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.issue_otp('b0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '123456') ->> 'replayed',
  'false', 'a DSA issues a code to a shop owner');

reset role;
select is((select destination_phone from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  '+2348000000005', 'the code goes to the owner''s phone from their profile, never from the request');
select ok((select code_hash <> '123456' and extensions.crypt('123456', code_hash) = code_hash
             from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  'the code is stored as a bcrypt hash');
select ok((select expires_at = created_at + interval '5 minutes' from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  'a code lives five minutes');
select is((select count(*)::int from public.audit_logs
            where operation = 'issue_otp' and not (after ? 'code_hash')),
  1, 'issuance is audited without the hash');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.issue_otp('b0000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '999999') ->> 'replayed',
  'true', 'a replay returns the first challenge, flagged as a replay');
reset role;
select is((select count(*)::int from public.otp_challenges
            where subject_id = '20000000-0000-0000-0000-000000000005' and purpose = 'POS_SETTLEMENT'),
  1, 'a replay issues nothing new');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
do $$ begin
  perform public.issue_otp('b0000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '111111');
  perform public.issue_otp('b0000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000005',
                           'POS_SETTLEMENT', '222222');
end $$;
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000004',
                   '20000000-0000-0000-0000-000000000005', 'POS_SETTLEMENT', '333333') $$,
  'P0001', 'too many codes requested for this shop owner; try again later',
  'a fourth code within ten minutes is refused');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000005',
                   '20000000-0000-0000-0000-000000000002', 'POS_SETTLEMENT', '123456') $$,
  'P0001', 'subject is not an active shop owner in this tenant', 'only shop owners receive codes');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000006',
                   '20000000-0000-0000-0000-000000000006', 'POS_SETTLEMENT', '123456') $$,
  'P0001', 'subject is not an active shop owner in this tenant',
  'a shop owner of another tenant cannot be targeted');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000007',
                   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', '12ab') $$,
  'P0001', 'code must be 6 digits', 'a malformed code is refused');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.issue_otp('b0000000-0000-0000-0000-000000000008',
                   '20000000-0000-0000-0000-000000000005', 'PICKUP_CONFIRM', '123456') $$,
  '42501', 'role TM may not perform this operation', 'a TM cannot issue codes');

-- ── verify ───────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '000000'),
  '{"verified": false, "reason": "INVALID", "attempts_left": 4}'::jsonb,
  'a wrong code fails and reports attempts left');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '123456') ->> 'verified',
  'false', 'a key spent on a wrong attempt replays that failure: each attempt needs a new key');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001', '123456') ->> 'verified',
  'true', 'the right code verifies');
reset role;
select ok((select consumed_at is not null from public.otp_challenges where id = '60000000-0000-0000-0000-000000000001'),
  'verification consumes the challenge');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000001', '123456') ->> 'reason',
  'CONSUMED', 'a code is single use');

do $$ begin
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
  perform public.verify_otp(gen_random_uuid(), '60000000-0000-0000-0000-000000000002', '000000');
end $$;
select is(public.verify_otp('c0000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000002', '123456') ->> 'reason',
  'LOCKED', 'five wrong codes lock the challenge, even against the right code');
select is(public.verify_otp('c0000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000003', '123456') ->> 'reason',
  'EXPIRED', 'an expired code fails');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.verify_otp('c0000000-0000-0000-0000-000000000006',
                   '60000000-0000-0000-0000-000000000004', '123456') $$,
  'P0001', 'challenge not found', 'only the issuer can verify a challenge');

reset role;
select is((select count(*)::int from public.audit_logs where operation = 'OTP_FAILED'),
  6, 'every failed attempt is audited');

select * from finish();
rollback;
