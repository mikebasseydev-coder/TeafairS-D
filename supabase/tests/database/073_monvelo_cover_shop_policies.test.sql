-- Addendum A8 Task 2: insurers and products (two-person, no overlap), the
-- shop owner's policy consent code, policy submission and review (the
-- §5.2.1 endorsement), withdrawal, and the cover status (§5.2.2): VERIFIED
-- only when a verified policy covers the whole financing and its sum insured
-- covers the shop's open principal across every tenant.
begin;
create extension if not exists pgtap with schema extensions;

select plan(41);

-- ── fixtures (as postgres) ─────────────────────────────────────────────
-- TEAFAIR: zone 1 > terr 1 > area 1; zone 2 > terr 2 > area 2 · NESTLE: zone 9 > terr 9 > area 9
-- 01 ZSM · 04 ASA area 1 · 05 ASA area 2 · 08 TENANT_ADMIN · 11 ZSA zone 1 · 21 NESTLE ZSA · 22 NESTLE ZSM
-- 41, 42 MONVELO_OPERATOR · 50 shop owner (verified phone)
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800073' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 4, 5, 8, 11, 21, 22, 41, 42, 50]) n;

create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.tu(n integer) returns uuid language sql as
  $$ select ('50000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('99000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.t2() returns uuid language sql as $$ select '10000000-0000-0000-0000-000000000073'::uuid $$;
create function pg_temp.id(p text) returns uuid language sql as
  $$ select ('73000000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.tu(integer), pg_temp.k(integer), pg_temp.t1(), pg_temp.t2(),
  pg_temp.id(text) to authenticated;

update public.profiles set platform_role = 'MONVELO_OPERATOR' where id in (pg_temp.u(41), pg_temp.u(42));
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-073', 'gateway_secret'); end $$;

insert into public.tenants (id, name, code) values (pg_temp.t2(), 'Nestle Nigeria', 'NESTLE_073');
insert into public.monvelo_tenant_settings (tenant_id, enabled) values (pg_temp.t1(), true), (pg_temp.t2(), true)
on conflict (tenant_id) do update set enabled = true;
insert into public.zones (id, tenant_id, zone_name, state_code) values
  (pg_temp.id('1'), pg_temp.t1(), 'Lagos', 'LA'), (pg_temp.id('2'), pg_temp.t1(), 'Ogun', 'OG'),
  (pg_temp.id('9'), pg_temp.t2(), 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  (pg_temp.id('11'), pg_temp.t1(), pg_temp.id('1'), 'Ikeja'), (pg_temp.id('12'), pg_temp.t1(), pg_temp.id('2'), 'Kuto'),
  (pg_temp.id('19'), pg_temp.t2(), pg_temp.id('9'), 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  (pg_temp.id('21'), pg_temp.t1(), pg_temp.id('11'), 'Allen'), (pg_temp.id('22'), pg_temp.t1(), pg_temp.id('12'), 'Kuto'),
  (pg_temp.id('29'), pg_temp.t2(), pg_temp.id('19'), 'Allen');

set local session_replication_role = replica;
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  (pg_temp.tu(1), pg_temp.t1(), pg_temp.u(1), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(4), pg_temp.t1(), pg_temp.u(4), 'ASA', null, pg_temp.id('11'), pg_temp.id('21'), pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(5), pg_temp.t1(), pg_temp.u(5), 'ASA', null, pg_temp.id('12'), pg_temp.id('22'), pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(8), pg_temp.t1(), pg_temp.u(8), 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(11), pg_temp.t1(), pg_temp.u(11), 'ZSA', pg_temp.id('1'), null, null, pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(22), pg_temp.t2(), pg_temp.u(22), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(21), pg_temp.t2(), pg_temp.u(21), 'ZSA', pg_temp.id('9'), null, null, pg_temp.tu(22), 'ACTIVE', true);

-- shops: S (owned by 50, enrolled with TEAFAIR area 1 and NESTLE area 9), S3, S4 (TEAFAIR area 1)
insert into public.retail_shops (id, shop_name, contact_phone, density_category, location, owner_id) values
  (pg_temp.id('100'), 'Shop S', '+2348031173001', 'SUBURBAN', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326), pg_temp.u(50)),
  (pg_temp.id('103'), 'Shop S3', '+2348031173003', 'SUBURBAN', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326), null),
  (pg_temp.id('104'), 'Shop S4', '+2348031173004', 'SUBURBAN', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326), null);
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, consumed_at, issued_by)
select pg_temp.id(n::text), case when n = 119 then pg_temp.t2() else pg_temp.t1() end, s, a, 'x',
       now() + interval '5 minutes', now(), pg_temp.u(4)
  from (values (110, pg_temp.id('100'), pg_temp.id('21')), (119, pg_temp.id('100'), pg_temp.id('29')),
               (113, pg_temp.id('103'), pg_temp.id('21')), (114, pg_temp.id('104'), pg_temp.id('21'))) v(n, s, a);
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id)
values (pg_temp.t1(), pg_temp.id('100'), pg_temp.id('21'), pg_temp.u(4), now(), 'MV-SHARE-2026-10', pg_temp.id('110')),
       (pg_temp.t2(), pg_temp.id('100'), pg_temp.id('29'), pg_temp.u(21), now(), 'MV-SHARE-2026-10', pg_temp.id('119')),
       (pg_temp.t1(), pg_temp.id('103'), pg_temp.id('21'), pg_temp.u(4), now(), 'MV-SHARE-2026-10', pg_temp.id('113')),
       (pg_temp.t1(), pg_temp.id('104'), pg_temp.id('21'), pg_temp.u(4), now(), 'MV-SHARE-2026-10', pg_temp.id('114'));

-- S has open principal 400,000: 300,000 DELIVERED with TEAFAIR and 100,000 FUNDED with NESTLE
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, retail_shop_id) values
  (pg_temp.id('120'), pg_temp.t1(), 'FIELD_SALES', pg_temp.tu(4), 300000, pg_temp.id('100')),
  (pg_temp.id('129'), pg_temp.t2(), 'FIELD_SALES', pg_temp.tu(21), 100000, pg_temp.id('100'));
insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
  principal, supply_date, status, approval_required, delivered_at, due_at, outstanding)
values (pg_temp.id('130'), pg_temp.t1(), 'MV-POLICYAA', pg_temp.id('100'), pg_temp.id('120'), pg_temp.id('21'),
        pg_temp.id('11'), pg_temp.u(4), 300000, current_date, 'DELIVERED', false, now(), now() + interval '30 days', 300000),
       (pg_temp.id('139'), pg_temp.t2(), 'MV-POLICYAB', pg_temp.id('100'), pg_temp.id('129'), pg_temp.id('29'),
        pg_temp.id('19'), pg_temp.u(21), 100000, current_date, 'FUNDED', false, null, null, null);
-- S4 has only a REJECTED policy; S3 gets a PENDING one below
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id,
  status, reviewed_by, reviewed_at)
values (pg_temp.id('204'), pg_temp.id('104'), 'AXA', 'R-4', true, true, 900000, true, current_date - 1,
        current_date + 300, pg_temp.id('104')::text || '/r.pdf', pg_temp.u(4), pg_temp.id('114'), 'REJECTED',
        pg_temp.u(41), now()),
       (pg_temp.id('203'), pg_temp.id('103'), 'AXA', 'P-3', true, true, 900000, true, current_date - 1,
        current_date + 300, pg_temp.id('103')::text || '/p.pdf', pg_temp.u(4), pg_temp.id('113'), 'PENDING', null, null);
set local session_replication_role = origin;

-- the certificate objects the upload gateway (Task 9) would have stored
insert into storage.objects (bucket_id, name) values
  ('monvelo-shop-policies', pg_temp.id('100')::text || '/cert-1.pdf'),
  ('monvelo-shop-policies', pg_temp.id('100')::text || '/cert-2.pdf'),
  ('monvelo-shop-policies', pg_temp.id('100')::text || '/cert-3.pdf');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create temp table r (n text primary key, v jsonb);
grant all on r to authenticated;

-- ── 1. insurers and products (10) ───────────────────────────────────────
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select throws_ok($$ select public.register_monvelo_insurer(pg_temp.k(1), 'MOCK', 'Mock Ltd', 'NAICOM-1', 'MOCK') $$,
                 '42501', null, 'a ZSA cannot register an insurer');
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
insert into r select 'ins', public.register_monvelo_insurer(pg_temp.k(2), 'MOCK', 'Mock Ltd', 'NAICOM-1', 'MOCK');
select ok((select v ? 'insurer_id' from r where n = 'ins'), 'an operator registers an insurer');
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select throws_ok($$ select public.propose_monvelo_insurance_product(pg_temp.k(3), (select (v->>'insurer_id')::uuid from r where n = 'ins'),
                      'STORAGE', 100, 1000, current_date, null) $$, '42501', null, 'a ZSA cannot propose a product');
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
select throws_ok($$ select public.propose_monvelo_insurance_product(pg_temp.k(4), (select (v->>'insurer_id')::uuid from r where n = 'ins'),
                      'STORAGE', 0, 1000, current_date, null) $$, 'P0001', null, 'a rate outside 1-1000 bps is refused');
insert into r select 'p1', public.propose_monvelo_insurance_product(pg_temp.k(5),
  (select (v->>'insurer_id')::uuid from r where n = 'ins'), 'STORAGE', 100, 1000, current_date, null);
select is((select v->>'status' from r where n = 'p1'), 'PROPOSED', 'an operator proposes a STORAGE product');
select throws_ok($$ select public.approve_monvelo_insurance_product(pg_temp.k(6), (select (v->>'product_id')::uuid from r where n = 'p1')) $$,
                 '42501', null, 'the proposer cannot approve');
select pg_temp.act_as(pg_temp.u(42), pg_temp.t1());
select is(public.approve_monvelo_insurance_product(pg_temp.k(7), (select (v->>'product_id')::uuid from r where n = 'p1')) ->> 'status',
          'APPROVED', 'a second operator approves');
insert into r select 'p2', public.propose_monvelo_insurance_product(pg_temp.k(8),
  (select (v->>'insurer_id')::uuid from r where n = 'ins'), 'STORAGE', 120, 1000, current_date + 30, null);
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
select throws_ok($$ select public.approve_monvelo_insurance_product(pg_temp.k(9), (select (v->>'product_id')::uuid from r where n = 'p2')) $$,
                 'P0001', null, 'an overlapping approved product of the same kind is refused');
select is(public.withdraw_monvelo_insurance_product(pg_temp.k(10), (select (v->>'product_id')::uuid from r where n = 'p1'),
            'replaced by the 120 bps quote') ->> 'status', 'WITHDRAWN', 'an operator withdraws a product');
select is(public.approve_monvelo_insurance_product(pg_temp.k(11), (select (v->>'product_id')::uuid from r where n = 'p2')) ->> 'status',
          'APPROVED', 'the overlap is gone once the first is withdrawn');

-- ── 2. a suspended insurer (2) ───────────────────────────────────────────
select is(public.set_monvelo_insurer_status(pg_temp.k(12), (select (v->>'insurer_id')::uuid from r where n = 'ins'), 'SUSPENDED')
            ->> 'status', 'SUSPENDED', 'an operator suspends an insurer');
insert into r select 'p3', public.propose_monvelo_insurance_product(pg_temp.k(13),
  (select (v->>'insurer_id')::uuid from r where n = 'ins'), 'GIT', 75, 1000, current_date, null);
select pg_temp.act_as(pg_temp.u(42), pg_temp.t1());
select throws_ok($$ select public.approve_monvelo_insurance_product(pg_temp.k(14), (select (v->>'product_id')::uuid from r where n = 'p3')) $$,
                 'P0001', null, 'a suspended insurer''s product is not approved');

-- ── 3. the owner's consent code (5) ──────────────────────────────────────
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$ select public.start_monvelo_policy_consent(pg_temp.k(20), 'wrong', pg_temp.id('100'), pg_temp.id('21')) $$,
                 '42501', null, 'start without the gateway proof is refused');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select throws_ok($$ select public.start_monvelo_policy_consent(pg_temp.k(21), 'test-gw-073', pg_temp.id('100'), pg_temp.id('21')) $$,
                 '42501', null, 'an ASA of another area cannot start');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$ select public.start_monvelo_policy_consent(pg_temp.k(22), 'test-gw-073', pg_temp.id('100'), pg_temp.id('22')) $$,
                 '42501', null, 'the shop must be enrolled in the named area');
insert into r select 'c1', public.start_monvelo_policy_consent(pg_temp.k(23), 'test-gw-073', pg_temp.id('100'), pg_temp.id('21'));
select ok((select v->>'code' ~ '^[0-9]{6}$' from r where n = 'c1'), 'the area''s ASA gets a 6-digit code for the gateway');
reset role;
select is((select purpose from public.monvelo_consent_challenges where id = (select (v->>'challenge_id')::uuid from r where n = 'c1')),
          'SHOP_POLICY', 'the challenge is a SHOP_POLICY one');

-- ── 4. submission (8) ───────────────────────────────────────────────────
create function pg_temp.submit(p_key integer, p_challenge text, p_code text, p_number text, p_endorsed boolean,
                               p_doc text, p_sum numeric default 500000) returns jsonb language sql as $$
  select public.submit_monvelo_shop_policy(pg_temp.k(p_key), (select (v->>'challenge_id')::uuid from r where n = p_challenge),
    p_code, 'Leadway Assurance', p_number, true, true, p_sum, p_endorsed, current_date - 5, current_date + 60,
    pg_temp.id('100')::text || '/' || p_doc)
$$;
grant execute on function pg_temp.submit(integer, text, text, text, boolean, text, numeric) to authenticated;

select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is(pg_temp.submit(30, 'c1', '000000', 'SME-1', true, 'cert-1.pdf') ->> 'reason',
          case when (select v->>'code' from r where n = 'c1') = '000000' then null else 'INVALID' end,
          'a wrong code is refused as data, so the counter commits');
select throws_ok($$ select pg_temp.submit(31, 'c1', (select v->>'code' from r where n = 'c1'), 'SME-1', true, 'missing.pdf') $$,
                 'P0001', null, 'the certificate must be in the policies bucket');
select pg_temp.act_as(pg_temp.u(21), pg_temp.t2());
select throws_ok($$ select pg_temp.submit(32, 'c1', (select v->>'code' from r where n = 'c1'), 'SME-1', true, 'cert-1.pdf') $$,
                 '42501', null, 'only the field agent who asked for the code submits with it');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
insert into r select 's1', pg_temp.submit(33, 'c1', (select v->>'code' from r where n = 'c1'), 'SME-1', true, 'cert-1.pdf');
select is((select v->>'status' from r where n = 's1'), 'PENDING', 'the right code files a PENDING policy');
select is(pg_temp.submit(33, 'c1', (select v->>'code' from r where n = 'c1'), 'SME-1', true, 'cert-1.pdf') ->> 'policy_id',
          (select v->>'policy_id' from r where n = 's1'), 'a replay returns the same policy');
select is(pg_temp.submit(34, 'c1', (select v->>'code' from r where n = 'c1'), 'SME-1B', true, 'cert-1.pdf') ->> 'reason',
          'INVALID', 'a consumed code cannot file a second policy');
insert into r select 'c2', public.start_monvelo_policy_consent(pg_temp.k(35), 'test-gw-073', pg_temp.id('100'), pg_temp.id('21'));
select throws_ok($$ select pg_temp.submit(36, 'c2', (select v->>'code' from r where n = 'c2'), 'SME-1', true, 'cert-2.pdf') $$,
                 'P0001', null, 'a live policy number is not filed twice');
insert into r select 's2', pg_temp.submit(37, 'c2', (select v->>'code' from r where n = 'c2'), 'SME-2', false, 'cert-2.pdf');
select throws_ok($$ select public.enrol_monvelo_shop(pg_temp.k(38), (select (v->>'challenge_id')::uuid from r where n = 'c2'), '123456') $$,
                 '42501', null, 'a policy consent code never enrols a shop');

-- ── 5. review (6) ───────────────────────────────────────────────────────
select throws_ok($$ select public.review_monvelo_shop_policy(pg_temp.k(40), (select (v->>'policy_id')::uuid from r where n = 's1'), true, 'ok') $$,
                 '42501', null, 'a field agent cannot review');
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
select throws_ok($$ select public.review_monvelo_shop_policy(pg_temp.k(41), (select (v->>'policy_id')::uuid from r where n = 's2'), true, 'ok') $$,
                 'P0001', null, 'a policy without the lender endorsement is never verified');
select is(public.review_monvelo_shop_policy(pg_temp.k(42), (select (v->>'policy_id')::uuid from r where n = 's2'), false,
            'no lender endorsement') ->> 'status', 'REJECTED', 'an operator rejects it');
select is(public.review_monvelo_shop_policy(pg_temp.k(43), (select (v->>'policy_id')::uuid from r where n = 's1'), true,
            'certificate checked') ->> 'status', 'VERIFIED', 'an operator verifies a complete policy');
select throws_ok($$ select public.review_monvelo_shop_policy(pg_temp.k(44), (select (v->>'policy_id')::uuid from r where n = 's1'), false, 'x') $$,
                 'P0001', null, 'a reviewed policy is not reviewed again');
reset role;
select is((select count(*) from public.audit_logs
            where operation in ('submit_monvelo_shop_policy', 'review_monvelo_shop_policy') and tenant_id is not null),
          0::bigint, 'policy audit rows are tenant-null');

-- ── 6. cover status (8) ─────────────────────────────────────────────────
select is((select status from public.monvelo_shop_cover_status(pg_temp.id('100'), now() + interval '31 days', 100000)),
          'VERIFIED', 'sum 500,000 covers 400,000 open across tenants plus 100,000');
select is((select status from public.monvelo_shop_cover_status(pg_temp.id('100'), now() + interval '31 days', 100001)),
          'INSUFFICIENT', 'cover status sums all tenants');
select is((select status from public.monvelo_shop_cover_status(pg_temp.id('100'), now() + interval '90 days', 1)),
          'INSUFFICIENT', 'a policy expiring before the financing ends does not exempt');
select is((select status from public.monvelo_shop_cover_status(pg_temp.id('103'), now(), 1)), 'PENDING', 'PENDING only');
select is((select status from public.monvelo_shop_cover_status(pg_temp.id('104'), now(), 1)), 'REJECTED', 'REJECTED only');
select is((select status from public.monvelo_shop_cover_status(gen_random_uuid(), now(), 1)), 'UNVERIFIED', 'no policy');
select ok(public.monvelo_is_shop_covered(pg_temp.id('100'), now() + interval '31 days', 100000)
          and not public.monvelo_is_shop_covered(pg_temp.id('103'), now(), 1), 'monvelo_is_shop_covered agrees');
select ok(not has_function_privilege('authenticated', 'public.monvelo_shop_cover_status(uuid, timestamptz, numeric)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.monvelo_is_shop_covered(uuid, timestamptz, numeric)', 'EXECUTE'),
          'the cover helpers are internal');

-- ── 7. withdrawal (2) ───────────────────────────────────────────────────
-- the TEAFAIR financing is locked to S's policy (as Task 3's claim will lock it)
set local session_replication_role = replica;
insert into public.monvelo_financing_cover (financing_id, tenant_id, cover_kind, shop_policy_id, blocks, storage_premium,
  gross_rebate, net_rebate, locked_at)
values (pg_temp.id('130'), pg_temp.t1(), 'SHOP_POLICY', (select (v->>'policy_id')::uuid from r where n = 's1'), 1, 0,
        30000, 30000, now());
set local session_replication_role = origin;
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select throws_ok($$ select public.withdraw_monvelo_shop_policy(pg_temp.k(50), (select (v->>'policy_id')::uuid from r where n = 's1'), 'fraud') $$,
                 '42501', null, 'a field agent cannot withdraw a policy');
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
select is(public.withdraw_monvelo_shop_policy(pg_temp.k(51), (select (v->>'policy_id')::uuid from r where n = 's1'),
            'insurer says the policy was cancelled') - 'policy_id',
          '{"status": "WITHDRAWN", "flagged": 1}'::jsonb, 'withdrawal flags the open financing locked to it');
reset role;

select * from finish();
rollback;
