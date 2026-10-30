-- Addendum A6 §4.1 (Monvelo Step 1, Task 5) — shop enrolment with the owner's
-- consent, withdrawal (NDPA 2023, ruling 10) and owner nominations.
begin;
create extension if not exists pgtap with schema extensions;

select plan(79);

-- A6 §18.4: every state is switched on, and every tenant opted in, for this file's fixtures
update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
-- A6 §18.4: the tenants created above opt in to every state for this file's fixtures
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

-- 02 ZSA (zone 1) · 04 ASA (area 1) · 05 ASA (area 3) · 06 ZSA (zone 2)
-- · 07 stranger · 14 owner of S1 · 15 owner of S2-S5 · 16 Unilever ZSA
-- · 17 Unilever ZSM · 01 ZSM · 03 TM · 09 MONVELO_OPERATOR
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0'), now()
from unnest(array[1,2,3,4,5,6,7,9,14,15,16,17]) as n;
-- 18: a shop owner whose phone Supabase Auth never confirmed
insert into auth.users (id, phone) values ('20000000-0000-0000-0000-000000000018', '2348000000018');
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000009';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Abuja', 'FC'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', 'Garki'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen'),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'Oba Akran'),
  ('60000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', 'Wuse'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', 'Allen');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000017', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000017',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'ZSA', '30000000-0000-0000-0000-000000000003', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000016',
   'ZSA', '30000000-0000-0000-0000-000000000002', null, '50000000-0000-0000-0000-000000000017', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'ASA', '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'ASA', '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', 'ACTIVE', true);

insert into public.monvelo_tenant_settings (tenant_id, enabled) values
  ('10000000-0000-0000-0000-000000000001', true),
  ('10000000-0000-0000-0000-000000000002', false);

-- owner 14 is a RETAIL_SHOP_OWNER member of Nestle (the nominate owner path checks it live)
insert into public.tenant_users (id, tenant_id, profile_id, role, status, is_primary) values
  ('50000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000014',
   'RETAIL_SHOP_OWNER', 'ACTIVE', true);

-- shops: S1 main flow (owner 14); S2 lock, S3 expiry, S4 throttle, S5 ASA (owner 15)
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text)
select ('70000000-0000-0000-0000-00000000000' || n)::uuid, 'Shop ' || n, '+23480311100' || n,
       case when n = 1 then '20000000-0000-0000-0000-000000000014'::uuid else '20000000-0000-0000-0000-000000000015'::uuid end,
       'SUBURBAN', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street ' || n
from generate_series(1, 5) n;
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('70000000-0000-0000-0000-000000000006', 'Shop 6', '+234803111006', '20000000-0000-0000-0000-000000000018',
   'SUBURBAN', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 6');

-- agents for the nomination close
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status) values
  ('80000000-0000-0000-0000-000000000001', 'Active POS', 'OPAY', 'OP-1', '+2348031110001',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'a',
   '0123456789', '6789', '058', 'Active POS', 'K1', '20000000-0000-0000-0000-000000000002', 'ACTIVE'),
  ('80000000-0000-0000-0000-000000000002', 'Pending POS', 'OPAY', 'OP-2', '+2348031110002',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326)::extensions.geography, 'a',
   '0123456780', '6780', '058', 'Pending POS', 'K2', '20000000-0000-0000-0000-000000000002', 'PENDING');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- ── shape ───────────────────────────────────────────────────────────────
select has_table('public', 'monvelo_consent_challenges', 'challenges table exists');
select has_table('public', 'monvelo_shop_enrolments', 'enrolments table exists');
select has_table('public', 'monvelo_agent_nominations', 'nominations table exists');
select col_not_null('public', 'monvelo_shop_enrolments', 'consent_version', 'consent_version is mandatory');
select col_is_unique('public', 'retail_shops', array['shop_code'], 'shop_code is unique');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'notification_logs_purpose_check') like '%MONVELO_CONSENT%',
  'notification_logs accepts the MONVELO_CONSENT purpose');
select ok(not has_table_privilege('authenticated', 'public.monvelo_consent_challenges', 'SELECT'),
  'the challenges table has no grant');
select ok(not has_table_privilege('authenticated', 'public.monvelo_shop_enrolments', 'INSERT'),
  'enrolments are read-only for the API');
select ok(not has_function_privilege('anon', 'public.start_monvelo_consent(uuid,text,uuid,uuid)', 'EXECUTE'),
  'anon cannot start consent');

-- ── start_monvelo_consent ───────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.s1', public.start_monvelo_consent(
  'e1000000-0000-0000-0000-000000000001', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001')::text, true); end $$;
select ok(current_setting('test.s1')::jsonb ->> 'code' ~ '^[0-9]{6}$', 'start gives a 6-digit code');
select is(current_setting('test.s1')::jsonb ->> 'destination_phone',
  (select phone_number from public.profiles where id = '20000000-0000-0000-0000-000000000014'),
  'the code goes to the owner''s profile phone');
select isnt(current_setting('test.s1')::jsonb ->> 'destination_phone', '+234803111001', 'not to the shop''s contact number');

select is(public.start_monvelo_consent('e1000000-0000-0000-0000-000000000001', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001') ? 'code', false,
  'a replay carries no code');
reset role;
select is((select count(*)::int from public.idempotency_logs
            where key = 'e1000000-0000-0000-0000-000000000001'
              and response::text like '%' || (current_setting('test.s1')::jsonb ->> 'code') || '%'), 0,
  'the code is absent from idempotency_logs');
select is((select count(*)::int from public.audit_logs
            where operation = 'start_monvelo_consent' and (after::text like '%' || (current_setting('test.s1')::jsonb ->> 'code') || '%'
                  or after::text like '%' || (select phone_number from public.profiles where id = '20000000-0000-0000-0000-000000000014') || '%' or after::text like '%code_hash%')), 0,
  'the start audit holds no code, hash or phone');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000002', null,
  '70000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'start without the proof is refused');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000002', 'wrong',
  '70000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'start with a wrong proof is refused');
-- Review Focus 4: area of another tenant
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000003', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002')$$,
  '42501', 'that area does not belong to your tenant', 'a ZSA of tenant A with an area of tenant B is refused');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000003', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000004')$$,
  '42501', 'that area is outside your zone', 'a ZSA cannot use an area in another zone');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000003', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000003')$$,
  '42501', 'that is not your area', 'an ASA cannot use another area, even inside the same territory');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000003', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'a TM cannot start consent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000004', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000006', '60000000-0000-0000-0000-000000000001')$$,
  'P0001', 'the shop owner has no verified phone', 'an owner without a confirmed phone gets no code');
select pg_temp.act_as('20000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000003', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002')$$,
  '42501', 'Monvelo is not enabled for this tenant', 'a tenant that has not enabled Monvelo is refused');

-- ── enrol_monvelo_shop ──────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000001',
  (current_setting('test.s1')::jsonb ->> 'challenge_id')::uuid, '000000'
  ) ->> 'reason',
  case when current_setting('test.s1')::jsonb ->> 'code' = '000000' then null else 'INVALID' end,
  'a wrong code is INVALID');
reset role;
select is((select failed_attempts from public.monvelo_consent_challenges
            where id = (current_setting('test.s1')::jsonb ->> 'challenge_id')::uuid), 1, 'the wrong code was counted');

-- another street agent cannot spend the challenge
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok(format($$select public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000009', %L, %L)$$,
  current_setting('test.s1')::jsonb ->> 'challenge_id', current_setting('test.s1')::jsonb ->> 'code'),
  '42501', null, 'the challenge belongs to the agent who started it');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.e1', public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000002',
  (current_setting('test.s1')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s1')::jsonb ->> 'code')::text, true); end $$;
select is((current_setting('test.e1')::jsonb ->> 'enrolled')::boolean, true, 'the right code enrols');
select ok(current_setting('test.e1')::jsonb ->> 'shop_code' ~ '^SH-[A-Z2-7]{6}$', 'the shop code has the right shape');
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000002',
  (current_setting('test.s1')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s1')::jsonb ->> 'code') ->> 'shop_code',
  current_setting('test.e1')::jsonb ->> 'shop_code', 'enrolling twice (same key) replays the same shop code');
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000003',
  (current_setting('test.s1')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s1')::jsonb ->> 'code') ->> 'shop_code',
  current_setting('test.e1')::jsonb ->> 'shop_code', 'enrolling twice (new key) returns the existing row');
reset role;
select ok((select consent_at is not null and consent_version = 'MV-SHARE-2026-10' and status = 'ACTIVE'
             and recruited_by = '20000000-0000-0000-0000-000000000002'
             and area_id = '60000000-0000-0000-0000-000000000001'
             from public.monvelo_shop_enrolments where shop_id = '70000000-0000-0000-0000-000000000001'),
  'the enrolment records consent_at, the consent version, the area and the recruiter');
select is((select count(*)::int from public.monvelo_shop_enrolments where shop_id = '70000000-0000-0000-0000-000000000001'), 1,
  'no duplicate enrolment');
select set_config('test.consent1', (select consent_at::text from public.monvelo_shop_enrolments
  where shop_id = '70000000-0000-0000-0000-000000000001'), true);
select is((select shop_code from public.retail_shops where id = '70000000-0000-0000-0000-000000000001'),
  current_setting('test.e1')::jsonb ->> 'shop_code', 'the shop code is stored on the shop');
select is((select count(*)::int from public.audit_logs where operation = 'enrol_monvelo_shop'), 1, 'enrolment is audited once');

-- an enrolled shop cannot be started again
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000010', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001')$$,
  'P0001', 'this shop is already enrolled', 'an enrolled shop cannot be started again');

-- lock after 5 wrong codes (S2)
do $$ begin perform set_config('test.s2', public.start_monvelo_consent(
  'e1000000-0000-0000-0000-000000000020', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001')::text, true); end $$;
do $$
declare v_reasons text := '';
  v_wrong text := case when current_setting('test.s2')::jsonb ->> 'code' = '111111' then '222222' else '111111' end;
begin
  for i in 1..5 loop
    v_reasons := v_reasons || (public.enrol_monvelo_shop(('e2000000-0000-0000-0000-0000000001' || lpad(i::text, 2, '0'))::uuid,
      (current_setting('test.s2')::jsonb ->> 'challenge_id')::uuid, v_wrong) ->> 'reason') || ',';
  end loop;
  perform set_config('test.reasons', v_reasons, true);
end $$;
select is(current_setting('test.reasons'), 'INVALID,INVALID,INVALID,INVALID,LOCKED,', 'four wrong codes are INVALID and the fifth locks');
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000199',
  (current_setting('test.s2')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s2')::jsonb ->> 'code') ->> 'reason',
  'LOCKED', 'after the lock even the right code is LOCKED');

-- expiry (S3)
do $$ begin perform set_config('test.s3', public.start_monvelo_consent(
  'e1000000-0000-0000-0000-000000000030', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000001')::text, true); end $$;
reset role;
update public.monvelo_consent_challenges set expires_at = now() - interval '1 minute'
 where id = (current_setting('test.s3')::jsonb ->> 'challenge_id')::uuid;
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000301',
  (current_setting('test.s3')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s3')::jsonb ->> 'code') ->> 'reason',
  'EXPIRED', 'an expired code is EXPIRED');

-- throttle (S4): three per hour, the fourth is refused
select lives_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000041', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001')$$, 'first start for the shop');
select lives_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000042', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001')$$, 'second start');
select lives_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000043', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001')$$, 'third start');
select throws_ok($$select public.start_monvelo_consent('e1000000-0000-0000-0000-000000000044', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001')$$,
  'P0001', null, 'a fourth start within an hour is refused');

-- an ASA enrols into their own area (S5)
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.s5', public.start_monvelo_consent(
  'e1000000-0000-0000-0000-000000000050', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000001')::text, true); end $$;
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000501',
  (current_setting('test.s5')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s5')::jsonb ->> 'code') ->> 'enrolled',
  'true', 'an ASA enrols a shop into their own area');

-- ── nominations ─────────────────────────────────────────────────────────
-- the shop owner nominates; the phone is cut to four digits
select pg_temp.act_as('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.n1', public.nominate_monvelo_agent(
  'e3000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
  ' Baba Tunde ', '+234 803 111 2233', 'OPAY')::text, true); end $$;
select is(current_setting('test.n1')::jsonb ->> 'status', 'OPEN', 'the owner nominates a POS agent');
select throws_ok($$select public.nominate_monvelo_agent('e3000000-0000-0000-0000-000000000002',
  '70000000-0000-0000-0000-000000000001', 'X', '12', 'OPAY')$$, 'P0001', null, 'a short phone is refused');
select throws_ok($$select public.nominate_monvelo_agent('e3000000-0000-0000-0000-000000000003',
  '70000000-0000-0000-0000-000000000002', 'X', '08031112233', 'OPAY')$$, '42501', null,
  'another shop''s nomination is refused to someone who is neither its owner nor a street agent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
do $$ begin perform set_config('test.n2', public.nominate_monvelo_agent(
  'e3000000-0000-0000-0000-000000000004', '70000000-0000-0000-0000-000000000001',
  'Mama Ada', '08031119876', 'MONIEPOINT')::text, true); end $$;
select is(current_setting('test.n2')::jsonb ->> 'status', 'OPEN', 'a ZSA nominates for an enrolled shop');
select throws_ok($$select public.nominate_monvelo_agent('e3000000-0000-0000-0000-000000000005',
  '70000000-0000-0000-0000-000000000004', 'X', '08031112233', 'OPAY')$$, 'P0001', 'this shop is not enrolled',
  'a shop that is not enrolled cannot have a nomination');
reset role;
select is((select nominated_phone_last4 from public.monvelo_agent_nominations where id = (current_setting('test.n1')::jsonb ->> 'nomination_id')::uuid),
  '2233', 'the nomination keeps four digits');
select is((select count(*)::int from public.monvelo_agent_nominations n
            where n::text like '%8031112233%' or n::text like '%234 803%'), 0, 'the full phone is not in the row');
select is((select count(*)::int from public.audit_logs a
            where a.operation = 'nominate_monvelo_agent' and (a.after::text like '%8031112233%' or a.after::text like '%08031119876%')), 0,
  'nor in the audit rows');
select is((select count(*)::int from public.idempotency_logs i
            where i.key in ('e3000000-0000-0000-0000-000000000001') and i.response::text like '%8031112233%'), 0,
  'nor in the idempotency log');

-- close
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(format($$select public.close_monvelo_nomination('e4000000-0000-0000-0000-000000000001', %L, '80000000-0000-0000-0000-000000000002', 'RECRUITED')$$,
  current_setting('test.n1')::jsonb ->> 'nomination_id'), 'P0001', 'the agent is not active yet',
  'a PENDING agent cannot be recruited');
select is(public.close_monvelo_nomination('e4000000-0000-0000-0000-000000000002',
  (current_setting('test.n1')::jsonb ->> 'nomination_id')::uuid, '80000000-0000-0000-0000-000000000001', 'RECRUITED') ->> 'status',
  'RECRUITED', 'an ACTIVE agent closes the nomination as RECRUITED');
select throws_ok(format($$select public.close_monvelo_nomination('e4000000-0000-0000-0000-000000000005', %L, '80000000-0000-0000-0000-000000000001', 'RECRUITED')$$,
  current_setting('test.n2')::jsonb ->> 'nomination_id'), 'P0001', 'the agent is on a different network',
  'the agent must be on the nominated network');
do $$ begin perform set_config('test.n3', public.nominate_monvelo_agent(
  'e3000000-0000-0000-0000-000000000006', '70000000-0000-0000-0000-000000000001', 'Chief Obi', '08031110000', 'OPAY')::text, true); end $$;
select is(public.close_monvelo_nomination('e4000000-0000-0000-0000-000000000003',
  (current_setting('test.n2')::jsonb ->> 'nomination_id')::uuid, null, 'DECLINED') ->> 'status',
  'DECLINED', 'a nomination can be declined');
select throws_ok(format($$select public.close_monvelo_nomination('e4000000-0000-0000-0000-000000000004', %L, null, 'DECLINED')$$,
  current_setting('test.n1')::jsonb ->> 'nomination_id'), 'P0001', 'this nomination is already closed', 'a closed nomination stays closed');
reset role;
select is((select preferred_agent_id::text from public.retail_shops where id = '70000000-0000-0000-0000-000000000001'),
  '80000000-0000-0000-0000-000000000001', 'RECRUITED sets preferred_agent_id');

-- ── read policies ───────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_shop_enrolments), 1, 'the shop owner reads their own enrolment only');
select is((select count(*)::int from public.monvelo_agent_nominations), 3, 'the owner reads the nominations for their shop');
select is((select shop_code from public.retail_shops where id = '70000000-0000-0000-0000-000000000001'),
  current_setting('test.e1')::jsonb ->> 'shop_code', 'the owner reads their shop code');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_shop_enrolments), 2, 'a ZSA reads the tenant''s enrolments');
select pg_temp.act_as('20000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.monvelo_shop_enrolments), 0, 'another tenant''s ZSA reads none');
select is((select count(*)::int from public.monvelo_agent_nominations), 0, 'nor any nominations');
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.monvelo_shop_enrolments), 0, 'a stranger reads none');
select throws_ok($$select count(*) from public.monvelo_consent_challenges$$, '42501', null, 'nobody reads the challenges');

-- ── withdrawal (ruling 10) ──────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.withdraw_monvelo_shop_consent('e5000000-0000-0000-0000-000000000001',
  '70000000-0000-0000-0000-000000000001')$$, '42501', null, 'a street agent cannot withdraw the owner''s consent');
select pg_temp.act_as('20000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.withdraw_monvelo_shop_consent('e5000000-0000-0000-0000-000000000002',
  '70000000-0000-0000-0000-000000000001')$$, '42501', null, 'another shop''s owner cannot withdraw it');
-- a second tenant enrols the same shop independently and keeps the same shop code
reset role;
update public.monvelo_tenant_settings set enabled = true where tenant_id = '10000000-0000-0000-0000-000000000002';
select pg_temp.act_as('20000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002');
do $$ begin perform set_config('test.s1u', public.start_monvelo_consent(
  'e1000000-0000-0000-0000-000000000070', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002')::text, true); end $$;
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000701',
  (current_setting('test.s1u')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s1u')::jsonb ->> 'code') ->> 'shop_code',
  current_setting('test.e1')::jsonb ->> 'shop_code', 'a second tenant enrols the same shop and keeps the same shop code');
reset role;
select is((select count(*)::int from public.monvelo_shop_enrolments where shop_id = '70000000-0000-0000-0000-000000000001' and status = 'ACTIVE'), 2,
  'the shop is enrolled in two tenants');

select pg_temp.act_as('20000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001');
select is(public.withdraw_monvelo_shop_consent('e5000000-0000-0000-0000-000000000003',
  '70000000-0000-0000-0000-000000000001') ->> 'withdrawn', '2', 'the owner withdraws consent in both tenants');
select is(public.withdraw_monvelo_shop_consent('e5000000-0000-0000-0000-000000000003',
  '70000000-0000-0000-0000-000000000001') ->> 'withdrawn', '2', 'a replay returns the same answer');
reset role;
select is((select count(*)::int from public.monvelo_shop_enrolments
            where shop_id = '70000000-0000-0000-0000-000000000001' and status = 'WITHDRAWN' and withdrawn_at is not null), 2,
  'both enrolments are WITHDRAWN');
select is((select count(*)::int from public.audit_logs where operation = 'withdraw_monvelo_shop_consent'), 2, 'each withdrawal is audited');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(format($$select public.close_monvelo_nomination('e4000000-0000-0000-0000-000000000006', %L, '80000000-0000-0000-0000-000000000001', 'RECRUITED')$$,
  current_setting('test.n3')::jsonb ->> 'nomination_id'), 'P0001', 'this shop is not enrolled',
  'a withdrawn shop''s nomination cannot be recruited');
reset role;

-- the old, spent code does not bring it back
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000401',
  (current_setting('test.s1')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s1')::jsonb ->> 'code') ->> 'enrolled',
  'false', 'the old consent code cannot re-enrol a withdrawn shop');
do $$ begin perform set_config('test.s1b', public.start_monvelo_consent(
  'e1000000-0000-0000-0000-000000000060', 'test-gw-secret',
  '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001')::text, true); end $$;
select is(public.enrol_monvelo_shop('e2000000-0000-0000-0000-000000000402',
  (current_setting('test.s1b')::jsonb ->> 'challenge_id')::uuid, current_setting('test.s1b')::jsonb ->> 'code') ->> 'shop_code',
  current_setting('test.e1')::jsonb ->> 'shop_code', 're-enrolment with a fresh code keeps the shop code');
reset role;
select ok((select status = 'ACTIVE' and withdrawn_at is null
              and consent_challenge_id = (current_setting('test.s1b')::jsonb ->> 'challenge_id')::uuid
              and consent_at > current_setting('test.consent1')::timestamptz
             from public.monvelo_shop_enrolments where shop_id = '70000000-0000-0000-0000-000000000001'
              and tenant_id = '10000000-0000-0000-0000-000000000001'),
  're-enrolment after withdrawal is ACTIVE again with the new challenge and consent time');
select is((select count(*)::int from public.monvelo_shop_enrolments
            where shop_id = '70000000-0000-0000-0000-000000000001' and tenant_id = '10000000-0000-0000-0000-000000000001'), 1,
  'still one enrolment row for the tenant');

select * from finish();
rollback;
