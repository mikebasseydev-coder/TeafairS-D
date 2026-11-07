-- Addendum A8 Task 1: the Monvelo cover schema. Tables, CHECKs, the
-- CLOSED_BY_CLAIM transition, the read rules (a tenant never reads a lender's
-- cover, claim or top-up; a shop's policy is read by Monvelo staff and the
-- field agents covering an area where the shop is enrolled), grants, buckets.
begin;
create extension if not exists pgtap with schema extensions;

select plan(49);

-- ── fixtures (as postgres) ─────────────────────────────────────────────
-- TEAFAIR: zone 1 > territory 1 > area 1 · NESTLE: zone 9 > territory 9 > area 9
-- 01 ZSM · 03 TM · 04 ASA area 1 · 08 TENANT_ADMIN · 11 ZSA zone 1 · 12 CSM
-- 16 LOGISTICS_MANAGER · 21 NESTLE ZSA zone 9 · 31 member of agent A
-- 41 MONVELO_OPERATOR · 42 second MONVELO_OPERATOR
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800072' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 8, 11, 12, 16, 21, 22, 31, 41, 42]) n;

create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.tu(n integer) returns uuid language sql as
  $$ select ('50000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.t2() returns uuid language sql as $$ select '10000000-0000-0000-0000-000000000072'::uuid $$;
create function pg_temp.id(p text) returns uuid language sql as
  $$ select ('72000000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.tu(integer), pg_temp.t1(), pg_temp.t2(), pg_temp.id(text)
  to authenticated;

update public.profiles set platform_role = 'MONVELO_OPERATOR' where id in (pg_temp.u(41), pg_temp.u(42));

insert into public.tenants (id, name, code) values (pg_temp.t2(), 'Nestle Nigeria', 'NESTLE_072');
insert into public.zones (id, tenant_id, zone_name, state_code) values
  (pg_temp.id('1'), pg_temp.t1(), 'Lagos', 'LA'), (pg_temp.id('9'), pg_temp.t2(), 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  (pg_temp.id('11'), pg_temp.t1(), pg_temp.id('1'), 'Ikeja'), (pg_temp.id('19'), pg_temp.t2(), pg_temp.id('9'), 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  (pg_temp.id('21'), pg_temp.t1(), pg_temp.id('11'), 'Allen'), (pg_temp.id('29'), pg_temp.t2(), pg_temp.id('19'), 'Allen');

set local session_replication_role = replica;
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  (pg_temp.tu(1), pg_temp.t1(), pg_temp.u(1), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(3), pg_temp.t1(), pg_temp.u(3), 'TM', pg_temp.id('1'), pg_temp.id('11'), null, pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(4), pg_temp.t1(), pg_temp.u(4), 'ASA', null, pg_temp.id('11'), pg_temp.id('21'), pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(8), pg_temp.t1(), pg_temp.u(8), 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(11), pg_temp.t1(), pg_temp.u(11), 'ZSA', pg_temp.id('1'), null, null, pg_temp.tu(1), 'ACTIVE', true),
  (pg_temp.tu(12), pg_temp.t1(), pg_temp.u(12), 'CLIENT_SERVICE_MANAGER', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(16), pg_temp.t1(), pg_temp.u(16), 'LOGISTICS_MANAGER', null, null, null, pg_temp.tu(12), 'ACTIVE', true),
  (pg_temp.tu(22), pg_temp.t2(), pg_temp.u(22), 'ZSM', null, null, null, null, 'ACTIVE', true),
  (pg_temp.tu(21), pg_temp.t2(), pg_temp.u(21), 'ZSA', pg_temp.id('9'), null, null, pg_temp.tu(22), 'ACTIVE', true);
update public.zones set zsm_id = pg_temp.u(1) where id = pg_temp.id('1');

insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
values (pg_temp.id('81'), 'POS A', 'OPAY', 'OP-072', '+2348031110721',
        extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6), 4326)::extensions.geography, 'a',
        '0123450721', '0721', '058', 'HOLDER A', 'K072', pg_temp.u(11), 'ACTIVE', 5000000, 1000000);
insert into public.monvelo_agent_members (agent_id, profile_id, status) values (pg_temp.id('81'), pg_temp.u(31), 'ACTIVE');

-- one shop enrolled in TEAFAIR area 1, its order and a DELIVERED financing funded by agent A
insert into public.retail_shops (id, shop_name, contact_phone, density_category, location)
values (pg_temp.id('100'), 'Shop 072', '+2348031172001', 'SUBURBAN',
        extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326));
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, consumed_at, issued_by)
values (pg_temp.id('110'), pg_temp.t1(), pg_temp.id('100'), pg_temp.id('21'), 'x', now() + interval '5 minutes', now(), pg_temp.u(4)),
       (pg_temp.id('111'), pg_temp.t1(), pg_temp.id('100'), pg_temp.id('21'), 'x', now() + interval '5 minutes', now(), pg_temp.u(4));
update public.monvelo_consent_challenges set purpose = 'SHOP_POLICY' where id = pg_temp.id('111');
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id)
values (pg_temp.t1(), pg_temp.id('100'), pg_temp.id('21'), pg_temp.u(4), now(), 'MV-SHARE-2026-10', pg_temp.id('110'));
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, retail_shop_id)
values (pg_temp.id('120'), pg_temp.t1(), 'FIELD_SALES', pg_temp.tu(4), 200000, pg_temp.id('100')),
       (pg_temp.id('121'), pg_temp.t1(), 'FIELD_SALES', pg_temp.tu(4), 200000, pg_temp.id('100'));
insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
  principal, supply_date, status, approval_required, funder_agent_id, funded_at, delivered_at, due_at, outstanding)
values (pg_temp.id('130'), pg_temp.t1(), 'MV-COVERAAA', pg_temp.id('100'), pg_temp.id('120'), pg_temp.id('21'),
        pg_temp.id('11'), pg_temp.u(4), 200000, current_date, 'DELIVERED', false, pg_temp.id('81'),
        now() - interval '2 days', now() - interval '1 day', now() + interval '29 days', 200000),
       (pg_temp.id('131'), pg_temp.t1(), 'MV-COVERAAB', pg_temp.id('100'), pg_temp.id('121'), pg_temp.id('21'),
        pg_temp.id('11'), pg_temp.u(4), 200000, current_date, 'REPAID_WITHIN_WINDOW', false, pg_temp.id('81'),
        now() - interval '9 days', now() - interval '8 days', now() + interval '22 days', 0);
insert into public.monvelo_financing_lines (tenant_id, financing_id, brand, brand_key, amount)
values (pg_temp.t1(), pg_temp.id('130'), 'Purerigin', 'purerigin', 200000);
set local session_replication_role = origin;

-- cover rows (as postgres, through the guards)
insert into public.monvelo_insurers (id, code, legal_name, naicom_licence_no, api_provider, created_by)
values (pg_temp.id('200'), 'MOCK', 'Mock Insurance Ltd', 'NAICOM-TEST-1', 'MOCK', pg_temp.u(41));
insert into public.monvelo_insurance_products (id, insurer_id, kind, rate_bps, facilitator_fee_bps, valid_from,
  proposed_by)
values (pg_temp.id('210'), pg_temp.id('200'), 'STORAGE', 100, 1000, current_date, pg_temp.u(41)),
       (pg_temp.id('211'), pg_temp.id('200'), 'GIT', 75, 1000, current_date, pg_temp.u(41));
insert into public.monvelo_shop_policies (id, shop_id, insurer_name, policy_number, covers_fire_perils, covers_burglary,
  sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path, submitted_by, consent_challenge_id)
values (pg_temp.id('220'), pg_temp.id('100'), 'Leadway', 'SME-1', true, true, 1000000, true, current_date - 10,
        current_date + 300, pg_temp.id('100')::text || '/cert.pdf', pg_temp.u(4), pg_temp.id('111'));
-- the cover is written while the financing was being claimed: insert as replica, as Task 3's claim will before funding
set local session_replication_role = replica;
insert into public.monvelo_financing_cover (financing_id, tenant_id, cover_kind, product_id, storage_rate_bps, blocks,
  storage_premium, gross_rebate, net_rebate, locked_at)
values (pg_temp.id('130'), pg_temp.t1(), 'AUTO_POLICY', pg_temp.id('210'), 100, 1, 2000, 20000, 18000, now());
insert into public.monvelo_financing_line_cover (financing_id, brand_key, tenant_id, terms_id, rebate_bps,
  interest_free_days, late_charge_bps, gross_rebate, storage_premium, net_rebate)
values (pg_temp.id('130'), 'purerigin', pg_temp.t1(), null, 1000, 30, 1000, 20000, 2000, 18000);
set local session_replication_role = origin;
insert into public.monvelo_order_git_cover (order_id, tenant_id, financing_id, product_id, rate_bps, insured_value, premium)
values (pg_temp.id('120'), pg_temp.t1(), pg_temp.id('130'), pg_temp.id('211'), 75, 200000, 1500);
insert into public.monvelo_premium_payables (id, tenant_id, kind, financing_id, insurer_id, amount, due_at)
values (pg_temp.id('230'), pg_temp.t1(), 'STORAGE', pg_temp.id('130'), pg_temp.id('200'), 2000, now() + interval '1 day');
insert into public.monvelo_rebate_topups (id, tenant_id, financing_id, agent_id, amount, reason, due_at)
values (pg_temp.id('240'), pg_temp.t1(), pg_temp.id('130'), pg_temp.id('81'), 2000, 'DECLARATION_REJECTED',
        now() + interval '1 day');
insert into public.monvelo_insurance_claims (id, reference, tenant_id, kind, financing_id, insurer_id, peril, incident_at,
  description, reported_by, payee_kind, payee_agent_id, claimed_amount)
values (pg_temp.id('250'), 'IC-AAAAAAAA', pg_temp.t1(), 'STORAGE', pg_temp.id('130'), pg_temp.id('200'), 'FIRE',
        now() - interval '1 hour', 'market fire', pg_temp.u(4), 'AGENT', pg_temp.id('81'), 200000),
       (pg_temp.id('251'), 'IC-AAAAAAAB', pg_temp.t1(), 'GIT', pg_temp.id('130'), pg_temp.id('200'), 'THEFT_IN_TRANSIT',
        now() - interval '1 day', 'truck robbed', pg_temp.u(16), 'TENANT', null, 200000);
insert into public.monvelo_insurance_declarations (tenant_id, kind, insurer_id, subject_table, subject_id, payload)
values (pg_temp.t1(), 'STORAGE_DECLARE', pg_temp.id('200'), 'monvelo_financing_cover', pg_temp.id('130'), '{}'::jsonb);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- the rows of the lender-bearing tables a caller can read, as one figure
create function pg_temp.lender_rows() returns bigint language sql as $$
  select (select count(*) from public.monvelo_financing_cover)
       + (select count(*) from public.monvelo_financing_line_cover)
       + (select count(*) from public.monvelo_rebate_topups)
       + (select count(*) from public.monvelo_premium_payables)
       + (select count(*) from public.monvelo_insurance_claims where kind = 'STORAGE');
$$;
grant execute on function pg_temp.lender_rows() to authenticated;

-- ── 1. schema (11 + 8) ───────────────────────────────────────────────────
select has_table('public', t, t || ' exists') from unnest(array[
  'monvelo_insurers', 'monvelo_insurance_products', 'monvelo_shop_policies', 'monvelo_financing_cover',
  'monvelo_financing_line_cover', 'monvelo_order_git_cover', 'monvelo_premium_payables', 'monvelo_rebate_topups',
  'monvelo_insurance_claims', 'monvelo_insurance_declarations', 'monvelo_insurer_events']) t;
select col_not_null('public', 'monvelo_insurance_products', 'rate_bps', 'product rate is required');
select col_not_null('public', 'monvelo_shop_policies', 'lender_interest_endorsed', 'endorsement flag is required');
select col_not_null('public', 'monvelo_financing_cover', 'net_rebate', 'net rebate is required');
select col_not_null('public', 'monvelo_premium_payables', 'amount', 'premium amount is required');
select col_not_null('public', 'monvelo_insurance_claims', 'payee_kind', 'claim payee is required');
select col_type_is('public', 'monvelo_insurance_claims', 'claimed_amount', 'numeric(15,2)', 'claim money is numeric(15,2)');
select col_default_is('public', 'monvelo_tenant_settings', 'git_cover_enabled', 'false', 'GIT cover is off by default');
select col_default_is('public', 'monvelo_consent_challenges', 'purpose', 'ENROLMENT', 'consent purpose defaults to ENROLMENT');

-- ── 2. CHECKs (6) ───────────────────────────────────────────────────────
select throws_ok($$ insert into public.monvelo_insurance_products (insurer_id, kind, rate_bps, facilitator_fee_bps,
                    valid_from, proposed_by) values (pg_temp.id('200'), 'STORAGE', 0, 0, current_date, pg_temp.u(41)) $$,
                 '23514', null, 'a product rate of 0 is refused');
select throws_ok($$ insert into public.monvelo_shop_policies (shop_id, insurer_name, policy_number, covers_fire_perils,
                    covers_burglary, sum_insured, lender_interest_endorsed, starts_on, expires_on, document_path,
                    submitted_by, consent_challenge_id)
                    values (pg_temp.id('100'), 'AXA', 'P-2', true, true, 1, true, current_date, current_date,
                            pg_temp.id('100')::text || '/x.pdf', pg_temp.u(4), pg_temp.id('111')) $$,
                 '23514', null, 'a policy must expire after it starts');
select throws_ok($$ insert into public.monvelo_insurance_claims (reference, tenant_id, kind, financing_id, peril,
                    incident_at, reported_by, payee_kind, claimed_amount)
                    values ('IC-AAAAAAAC', pg_temp.t1(), 'STORAGE', pg_temp.id('131'), 'FIRE', now(), pg_temp.u(4),
                            'TENANT', 1) $$,
                 '23514', null, 'a STORAGE claim never pays the tenant');
select throws_ok($$ insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, amount)
                    values (pg_temp.t1(), current_date, 'GIT_PREMIUM', 1) $$,
                 '23514', null, 'a GIT_PREMIUM ledger entry is negative');
select lives_ok($$ insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                   values (pg_temp.t1(), current_date, 'GIT_PREMIUM', pg_temp.id('130'), -1500) $$,
                'GIT_PREMIUM is an entry type');
select throws_ok($$ update public.monvelo_financings set status = 'CLOSED_BY_CLAIM', outstanding = 5, closed_at = now()
                     where id = pg_temp.id('130') $$,
                 '23514', null, 'CLOSED_BY_CLAIM needs outstanding 0');

-- ── 3. transitions and guards (7) ───────────────────────────────────────
select throws_ok($$ update public.monvelo_financings set status = 'CLOSED_BY_CLAIM', outstanding = 0, closed_at = now()
                     where id = pg_temp.id('131') $$,
                 'P0001', null, 'a repaid financing cannot close by claim');
select throws_ok($$ insert into public.monvelo_insurance_claims (reference, tenant_id, kind, financing_id, peril,
                    incident_at, reported_by, payee_kind, payee_agent_id, claimed_amount)
                    values ('IC-AAAAAAAD', pg_temp.t1(), 'STORAGE', pg_temp.id('130'), 'BURGLARY', now(), pg_temp.u(4),
                            'AGENT', pg_temp.id('81'), 1) $$,
                 '23505', null, 'one open claim of a kind per financing');
select throws_ok($$ update public.monvelo_insurance_claims set status = 'SETTLED', settled_amount = 1, settled_at = now()
                     where id = pg_temp.id('250') $$,
                 'P0001', null, 'a REPORTED claim cannot settle before it is filed');
select throws_ok($$ update public.monvelo_premium_payables set amount = 1 where id = pg_temp.id('230') $$,
                 'P0001', null, 'a premium payable''s amount never changes');
select throws_ok($$ delete from public.monvelo_shop_policies where id = pg_temp.id('220') $$,
                 'P0001', null, 'a policy is never deleted');
select throws_ok($$ update public.monvelo_financing_cover set storage_premium = 0, net_rebate = 20000
                     where financing_id = pg_temp.id('130') $$,
                 'P0001', null, 'a delivered financing''s cover is fixed');
select lives_ok($$ update public.monvelo_financings set status = 'CLOSED_BY_CLAIM', outstanding = 0, closed_at = now()
                    where id = pg_temp.id('130') $$,
                'DELIVERED -> CLOSED_BY_CLAIM with outstanding 0');

-- ── 4. read rules (11) ──────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select is(pg_temp.lender_rows(), 0::bigint, 'a TENANT_ADMIN reads no lender cover, top-up, payable or STORAGE claim');
select is((select count(*) from public.monvelo_insurance_claims where kind = 'GIT'), 1::bigint,
          'a TENANT_ADMIN reads its GIT claim');
select is((select count(*) from public.monvelo_shop_policies), 0::bigint, 'a TENANT_ADMIN reads no shop policy');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select is(pg_temp.lender_rows() + (select count(*) from public.monvelo_shop_policies), 0::bigint,
          'a CSM reads no lender row or policy');
select is((select count(*) from public.monvelo_order_git_cover), 1::bigint, 'a CSM reads the GIT cover');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is(pg_temp.lender_rows(), 0::bigint, 'a ZSM reads no lender row');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is(pg_temp.lender_rows(), 0::bigint, 'a TM reads no lender row');
select pg_temp.act_as(pg_temp.u(21), pg_temp.t2());
select is((select count(*) from public.monvelo_shop_policies), 0::bigint,
          'a ZSA of a tenant without the shop''s enrolment reads no policy');
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select is((select count(*) from public.monvelo_shop_policies), 1::bigint, 'the zone''s ZSA reads the policy');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*) from public.monvelo_shop_policies), 1::bigint, 'the area''s ASA reads the policy');
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
select is(pg_temp.lender_rows() + (select count(*) from public.monvelo_shop_policies)
          + (select count(*) from public.monvelo_insurance_products), 8::bigint,
          'an operator reads every cover row, policy and product');

-- ── 5. the agent reads its own top-up (1) ────────────────────────────────
select pg_temp.act_as(pg_temp.u(31), pg_temp.t1());
select is((select count(*) from public.monvelo_rebate_topups), 1::bigint, 'the agent''s member reads its top-up');
reset role;

-- ── 6. grants (3) ───────────────────────────────────────────────────────
select is((select count(*) from unnest(array[
  'monvelo_insurers', 'monvelo_insurance_products', 'monvelo_shop_policies', 'monvelo_financing_cover',
  'monvelo_financing_line_cover', 'monvelo_order_git_cover', 'monvelo_premium_payables', 'monvelo_rebate_topups',
  'monvelo_insurance_claims', 'monvelo_insurance_declarations', 'monvelo_insurer_events']) t
  where has_table_privilege('authenticated', 'public.' || t, 'INSERT')
     or has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
     or has_table_privilege('authenticated', 'public.' || t, 'DELETE')), 0::bigint,
  'authenticated cannot write any cover table');
select pg_temp.act_as(pg_temp.u(41), pg_temp.t1());
select throws_ok($$ select count(*) from public.monvelo_insurance_declarations $$, '42501', null,
                 'not even an operator reads the declarations outbox directly');
select throws_ok($$ select count(*) from public.monvelo_insurer_events $$, '42501', null,
                 'nobody reads insurer events directly');
reset role;

-- ── 7. buckets (2) ──────────────────────────────────────────────────────
select is((select count(*) from storage.buckets
            where id in ('monvelo-shop-policies', 'monvelo-claim-evidence') and not public
              and file_size_limit = 10485760), 2::bigint, 'both cover buckets exist, private, 10 MB');
select is((select allowed_mime_types from storage.buckets where id = 'monvelo-shop-policies'),
          array['application/pdf', 'image/jpeg', 'image/png'], 'policy bucket takes PDF, JPEG, PNG');

select * from finish();
rollback;
