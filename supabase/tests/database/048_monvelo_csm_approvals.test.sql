-- Addendum A6 §16.3, §16.4, §17.3 (Monvelo Step 1c, Task 3) — brand terms,
-- Monvelo settings and Teafair's fee terms always cite a current contact-report
-- decision; the CSM approves, or two different ZSMs while the tenant has no CSM.
begin;
create extension if not exists pgtap with schema extensions;

select plan(55);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- tenant A = TEAFAIR: 1 CSM · 2 ZSM · 3 second ZSM · 4 TENANT_ADMIN
-- tenant B (Unilever): 5 ZSM · 6 CSM · 9 MONVELO_OPERATOR (no tenant)
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 9) n;
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000009';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TENANT_ADMIN', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000006',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, sale_category, nafdac_number) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TIG-1', 'Tiger Nuts', 'Tiger', 'Snack', 500, 400, 'FOOD', 'A7-0124');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer) to authenticated;

-- a report with one decision of each subject the tests cite
create function pg_temp.rep(p_sup uuid default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'MEETING',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
    'summary', 'Agreed terms, settings, fee and catalogue.', 'supersedes_id', p_sup,
    'decisions', jsonb_build_array(
      jsonb_build_object('subject', 'BRAND_TERMS', 'text', 'Brand terms'),
      jsonb_build_object('subject', 'MONVELO_SETTINGS', 'text', 'Settings'),
      jsonb_build_object('subject', 'FEES', 'text', 'Fee'),
      jsonb_build_object('subject', 'CATALOGUE', 'text', 'Catalogue')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222')));
$$;
grant execute on function pg_temp.rep(uuid) to authenticated;

-- cd: named decisions; cr: named reports
create temp table cr (n text primary key, id uuid);
create temp table cd (n text, subject text, id uuid, primary key (n, subject));
grant select on cr, cd to authenticated;

-- file (CSM), review (ZSM), request + upload stand-in + attach (CSM); keys kb..kb+3
create function pg_temp.cite(p_name text, p_tenant uuid, p_csm uuid, p_zsm uuid, p_kb integer,
                             p_sup uuid default null, p_finish boolean default true) returns void
language plpgsql as $$
declare v_rid uuid; v_slot jsonb;
begin
  perform pg_temp.act_as(p_csm, p_tenant);
  v_rid := (public.file_contact_report(pg_temp.k(p_kb), pg_temp.rep(p_sup)) ->> 'report_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into cr values (p_name, v_rid);
  insert into cd select p_name, d.subject, d.id from public.contact_report_decisions d where d.report_id = v_rid;
  if not p_finish then return; end if;
  perform pg_temp.act_as(p_zsm, p_tenant);
  perform public.review_contact_report(pg_temp.k(p_kb + 1), v_rid, 'APPROVED');
  perform pg_temp.act_as(p_csm, p_tenant);
  v_slot := public.request_contact_report_hard_copy(pg_temp.k(p_kb + 2), v_rid, 'application/pdf', 1000);
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('contact-reports', v_slot ->> 'storage_path', jsonb_build_object('size', '1000', 'mimetype', 'application/pdf'));
  perform pg_temp.act_as(p_csm, p_tenant);
  perform public.attach_contact_report_hard_copy(pg_temp.k(p_kb + 3), (v_slot ->> 'hard_copy_id')::uuid);
  perform set_config('role', 'postgres', true);
end; $$;

create function pg_temp.d(p_n text, p_subject text) returns uuid language sql as
  $$ select id from cd where n = p_n and subject = p_subject $$;
grant execute on function pg_temp.d(text, text) to authenticated;

-- tenant A: a citable report, an old one that is later corrected, tenant B's own
select pg_temp.cite('A', '7eaf0000-0000-4000-8000-000000000001', pg_temp.u(1), pg_temp.u(2), 100);
select pg_temp.cite('OLD', '7eaf0000-0000-4000-8000-000000000001', pg_temp.u(1), pg_temp.u(2), 110);
-- the correction supersedes OLD (filed only; it is not reviewed)
select pg_temp.cite('NEW', '7eaf0000-0000-4000-8000-000000000001', pg_temp.u(1), pg_temp.u(2), 120,
                    (select id from cr where n = 'OLD'), false);
select pg_temp.cite('B', '10000000-0000-0000-0000-000000000002', pg_temp.u(6), pg_temp.u(5), 130);
reset role;

-- ── bridging: the tenant has no active CSM ──────────────────────────────
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000001';
select is(public.monvelo_tenant_has_csm('7eaf0000-0000-4000-8000-000000000001'), false, 'no active CSM: bridging');
select ok(not has_function_privilege('authenticated', 'public.monvelo_tenant_has_csm(uuid)', 'execute'),
  'monvelo_tenant_has_csm is internal');
select hasnt_function('public', 'approve_monvelo_brand_terms', array['uuid', 'uuid'], 'the 2-argument approval is gone');
select hasnt_function('public', 'withdraw_monvelo_brand_terms', array['uuid', 'uuid'], 'the 2-argument withdrawal is gone');
select hasnt_function('public', 'set_monvelo_tenant_settings', array['uuid', 'boolean', 'numeric', 'numeric'], 'the 4-argument settings call is gone');
select hasnt_function('public', 'record_monvelo_fee_terms', array['uuid', 'uuid', 'integer', 'date', 'date'], 'the 5-argument fee call is gone');

select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.propose_monvelo_brand_terms(pg_temp.k(200), 'Purerigin', 500, 30, 1000, date '2026-10-01', null)$$,
  'a ZSM proposes brand terms');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(201),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  '42501', 'terms are approved by a second ZSM', 'the proposer cannot approve');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(202),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  '42501', null, 'a TENANT_ADMIN cannot approve');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(203),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'))$$,
  'P0001', 'cite the contact report decision that agreed these terms', 'bridging: approval without a decision');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(204),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), pg_temp.d('A', 'CATALOGUE'))$$,
  'P0001', 'cite a decision on BRAND_TERMS', 'bridging: a CATALOGUE decision');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(205),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), pg_temp.d('B', 'BRAND_TERMS'))$$,
  '42501', 'decision not found', 'bridging: another tenant''s decision');
select lives_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(206),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  'bridging: a second ZSM approves citing a current decision');
reset role;
select is((select status || ':' || (approved_by = pg_temp.u(3))::text || ':' || (approval_decision_id = pg_temp.d('A', 'BRAND_TERMS'))::text
             from public.monvelo_brand_terms where brand = 'Purerigin'),
  'APPROVED:true:true', 'the terms are APPROVED with the decision stored');

-- settings while bridging
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(210), true, 50000, 20000, 90000)$$,
  'P0001', 'cite the contact report decision that agreed these settings', 'bridging: settings without a decision');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(211), true, 50000, 20000, 90000, pg_temp.d('A', 'BRAND_TERMS'))$$,
  'P0001', 'cite a decision on MONVELO_SETTINGS', 'bridging: the wrong subject');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(212), true, 50000, 20000, 40000, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  '23514', null, 'a maximum limit below the opening limit breaks the CHECK');
select lives_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(213), true, 50000, 20000, 90000, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  'bridging: a ZSM sets the settings citing a decision');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(214), true, 1, 1, null, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  '42501', null, 'a TENANT_ADMIN cannot set the settings (bridging)');

-- immutability, and withdrawal while bridging
reset role;
select throws_ok($$update public.monvelo_brand_terms set approval_decision_id = pg_temp.d('OLD', 'BRAND_TERMS')
                     where brand = 'Purerigin'$$,
  'P0001', 'approved terms are immutable', 'an approved row''s decision cannot change');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.withdraw_monvelo_brand_terms(pg_temp.k(220),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), null)$$,
  'P0001', 'cite the contact report decision that agreed this withdrawal', 'bridging: withdrawal without a decision');
select lives_ok($$select public.withdraw_monvelo_brand_terms(pg_temp.k(221),
    (select id from public.monvelo_brand_terms where brand = 'Purerigin'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  'bridging: a ZSM withdraws citing a decision');

-- ── the CSM is active ───────────────────────────────────────────────────
reset role;
update public.tenant_users set status = 'ACTIVE' where id = '50000000-0000-0000-0000-000000000001';
select is(public.monvelo_tenant_has_csm('7eaf0000-0000-4000-8000-000000000001'), true, 'an active CSM exists');

select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.propose_monvelo_brand_terms(pg_temp.k(230), 'Tiger', 300, 30, 1000, date '2026-11-01', null)$$,
  'a ZSM proposes Tiger terms');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(231),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  '42501', 'brand terms are approved by the client service manager', 'a second ZSM cannot approve once a CSM exists');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(232),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  '42501', null, 'a TENANT_ADMIN cannot approve');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(233),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'))$$,
  'P0001', 'cite the contact report decision that agreed these terms', 'the CSM without a decision');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(234),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('A', 'CATALOGUE'))$$,
  'P0001', 'cite a decision on BRAND_TERMS', 'the CSM with a CATALOGUE decision');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(235),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('OLD', 'BRAND_TERMS'))$$,
  'P0001', 'this contact report has been superseded; cite the decision in its correction',
  'the CSM with a superseded report''s decision');
select throws_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(236),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('NEW', 'BRAND_TERMS'))$$,
  'P0001', 'a ZSM must approve this contact report before it is cited', 'the correction is not citable until reviewed');
select lives_ok($$select public.approve_monvelo_brand_terms(pg_temp.k(237),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  'the CSM approves citing a current BRAND_TERMS decision');
reset role;
select is((select status || ':' || (approved_by = pg_temp.u(1))::text || ':' || (approval_decision_id = pg_temp.d('A', 'BRAND_TERMS'))::text
             from public.monvelo_brand_terms where brand = 'Tiger'),
  'APPROVED:true:true', 'Tiger is APPROVED with approval_decision_id set');
select is((select (after ->> 'approval_decision_id')::uuid from public.audit_logs
            where operation = 'approve_monvelo_brand_terms' and idempotency_key = pg_temp.k(237)),
  pg_temp.d('A', 'BRAND_TERMS'), 'the audit row holds the decision');

-- settings with the CSM
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(240), true, 1, 1, null, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  '42501', 'Monvelo settings are set by the client service manager', 'a ZSM cannot set the settings once a CSM exists');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(241), true, 1, 1, null, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  '42501', null, 'a TENANT_ADMIN cannot set the settings');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(242), true, 70000, 30000)$$,
  'P0001', 'cite the contact report decision that agreed these settings', 'the CSM without a decision');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(243), true, 70000, 30000, null, pg_temp.d('OLD', 'MONVELO_SETTINGS'))$$,
  'P0001', 'this contact report has been superseded; cite the decision in its correction', 'a superseded settings decision');
select lives_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(244), true, 70000, 30000, 120000, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  'the CSM sets the settings citing a decision');
reset role;
select is((select enabled::text || ':' || opening_limit || ':' || approval_cap || ':' || max_limit || ':'
                  || (decision_id = pg_temp.d('A', 'MONVELO_SETTINGS'))::text
             from public.monvelo_tenant_settings where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  'true:70000.00:30000.00:120000.00:true', 'the settings and their decision are stored');

-- the tenant's credit and recovery rules (A6 §7.2, §18.2; Task 7): null keeps the current value
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(245), true, 70000, 30000, 120000,
    pg_temp.d('A', 'MONVELO_SETTINGS'), p_limit_growth_bps => 2500, p_default_cure_days => 7, p_post_default_limit_bps => 5000)$$,
  'the CSM sets limit growth, cure days and the post-default limit citing a decision');
select lives_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(246), true, 80000, 30000, 120000, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  'a later call that leaves them out');
select throws_ok($$select public.set_monvelo_tenant_settings(pg_temp.k(247), true, 80000, 30000, 120000,
    pg_temp.d('A', 'MONVELO_SETTINGS'), p_default_cure_days => 366)$$,
  '23514', null, 'cure days above 365 are refused');
reset role;
select is((select limit_growth_bps || ':' || default_cure_days || ':' || post_default_limit_bps || ':' || opening_limit
             from public.monvelo_tenant_settings where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  '2500:7:5000:80000.00', 'left out, they keep their values while the opening limit changes');
select is((select (after ->> 'default_cure_days')::int from public.audit_logs
            where operation = 'set_monvelo_tenant_settings' and idempotency_key = pg_temp.k(245)),
  7, 'the audit row holds the recovery rules');

-- withdrawal with the CSM
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.withdraw_monvelo_brand_terms(pg_temp.k(250),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  '42501', 'brand terms are withdrawn by the client service manager', 'a ZSM cannot withdraw once a CSM exists');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.withdraw_monvelo_brand_terms(pg_temp.k(251),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), null)$$,
  'P0001', 'cite the contact report decision that agreed this withdrawal', 'the CSM withdraws without a decision');
select lives_ok($$select public.withdraw_monvelo_brand_terms(pg_temp.k(252),
    (select id from public.monvelo_brand_terms where brand = 'Tiger'), pg_temp.d('A', 'BRAND_TERMS'))$$,
  'the CSM withdraws citing a decision');
reset role;
select is((select status from public.monvelo_brand_terms where brand = 'Tiger'), 'WITHDRAWN', 'the terms are WITHDRAWN');
select is((select (after ->> 'withdrawal_decision_id')::uuid from public.audit_logs
            where operation = 'withdraw_monvelo_brand_terms' and idempotency_key = pg_temp.k(252)),
  pg_temp.d('A', 'BRAND_TERMS'), 'the withdrawal audit row records the decision');

-- ── Teafair's fee terms ─────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(9), null);
select throws_ok($$select public.record_monvelo_fee_terms(pg_temp.k(260),
    '7eaf0000-0000-4000-8000-000000000001', 150, date '2026-11-01', null, null)$$,
  'P0001', 'cite the contact report decision that agreed these fee terms', 'fee terms without a decision');
select throws_ok($$select public.record_monvelo_fee_terms(pg_temp.k(261),
    '7eaf0000-0000-4000-8000-000000000001', 150, date '2026-11-01', null, pg_temp.d('B', 'FEES'))$$,
  '42501', 'decision not found', 'fee terms citing another tenant''s FEES decision');
select throws_ok($$select public.record_monvelo_fee_terms(pg_temp.k(262),
    '7eaf0000-0000-4000-8000-000000000001', 150, date '2026-11-01', null, pg_temp.d('A', 'MONVELO_SETTINGS'))$$,
  'P0001', 'cite a decision on FEES', 'fee terms citing the wrong subject');
select throws_ok($$select public.record_monvelo_fee_terms(pg_temp.k(263),
    '7eaf0000-0000-4000-8000-000000000001', 150, date '2026-11-01', null, pg_temp.d('OLD', 'FEES'))$$,
  'P0001', 'this contact report has been superseded; cite the decision in its correction', 'fee terms citing a superseded decision');
select lives_ok($$select public.record_monvelo_fee_terms(pg_temp.k(264),
    '7eaf0000-0000-4000-8000-000000000001', 150, date '2026-11-01', null, pg_temp.d('A', 'FEES'))$$,
  'the operator records fee terms citing a current FEES decision');
reset role;
select is((select decision_id from public.monvelo_tenant_fee_terms where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  pg_temp.d('A', 'FEES'), 'the fee terms hold the decision');

select * from finish();
rollback;
