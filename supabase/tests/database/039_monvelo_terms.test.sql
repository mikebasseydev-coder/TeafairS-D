-- Addendum A6 §4.2 (Monvelo Step 1) — tenant settings, brand terms (two-ZSM
-- approval, dated promotions) and Teafair's fee terms.
begin;
create extension if not exists pgtap with schema extensions;

select plan(56);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER'),
  ('10000000-0000-0000-0000-000000000003', 'Expired Terms Ltd', 'EXPIRED');

-- 1 ZSM · 2 second ZSM · 3 DSM · 8 MONVELO_OPERATOR (no tenant)
-- · 9 Unilever ZSM · 10 MONVELO_FINANCE
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', now()),
  ('20000000-0000-0000-0000-000000000002', '2348000000002', now()),
  ('20000000-0000-0000-0000-000000000003', '2348000000003', now()),
  ('20000000-0000-0000-0000-000000000008', '2348000000008', now()),
  ('20000000-0000-0000-0000-000000000009', '2348000000009', now()),
  ('20000000-0000-0000-0000-000000000010', '2348000000010', now()),
  ('20000000-0000-0000-0000-000000000011', '2348000000011', now());
update public.profiles set platform_role = 'MONVELO_OPERATOR'
 where id = '20000000-0000-0000-0000-000000000008';
update public.profiles set platform_role = 'MONVELO_FINANCE'
 where id = '20000000-0000-0000-0000-000000000010';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000011',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true);

insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, sale_category, nafdac_number) values
  ('10000000-0000-0000-0000-000000000001', 'PUR-200', 'Purerigin 200ml', 'Purerigin', 'Oil', 5000, 4000, 'COSMETICS', 'A7-0123'),
  ('10000000-0000-0000-0000-000000000001', 'TIG-1',   'Tiger Nuts',      'Tiger',     'Snack', 500, 400, 'FOOD', 'A7-0124');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, sale_category, nafdac_number, is_active) values
  ('10000000-0000-0000-0000-000000000001', 'OLD-1',   'Old line',        'Retired',   'Snack', 500, 400, 'FOOD', 'A7-0125', false);

-- rows whose end date has already passed (inserted directly, as postgres)
insert into public.monvelo_tenant_fee_terms (tenant_id, fee_bps, valid_from, valid_to, recorded_by) values
  ('10000000-0000-0000-0000-000000000003', 100, current_date - 100, current_date - 10, '20000000-0000-0000-0000-000000000008');
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, valid_from, valid_to, status, proposed_by, approved_by, approved_at) values
  ('10000000-0000-0000-0000-000000000003', 'Expired', 100, current_date - 100, current_date - 10, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', now());

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;


-- Task 3: every approval, withdrawal, settings change and fee term cites a
-- contact-report decision. Nestle's CSM (11) files one report, a ZSM (1)
-- approves it, the CSM attaches the hard copy; the CSM is then DISABLED so the
-- body below runs under the two-ZSM bridging rule.
create temp table cit (subject text primary key, id uuid);
grant select on cit to authenticated;
create temp table cit_tmp (r jsonb);
grant all on cit_tmp to authenticated;
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
insert into cit_tmp select public.file_contact_report('c0000000-0000-0000-0000-000000000001', jsonb_build_object(
  'met_at', now() - interval '1 hour', 'channel', 'MEETING',
  'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
  'summary', 'Agreed the terms, settings and fee.',
  'decisions', jsonb_build_array(
    jsonb_build_object('subject', 'BRAND_TERMS', 'text', 'Brand terms'),
    jsonb_build_object('subject', 'MONVELO_SETTINGS', 'text', 'Settings'),
    jsonb_build_object('subject', 'FEES', 'text', 'Fee')),
  'recipients', jsonb_build_array(
    jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222'))));
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select public.review_contact_report('c0000000-0000-0000-0000-000000000002', (select (r ->> 'report_id')::uuid from cit_tmp), 'APPROVED');
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select public.request_contact_report_hard_copy('c0000000-0000-0000-0000-000000000003', (select (r ->> 'report_id')::uuid from cit_tmp), 'application/pdf', 1000);
reset role;
insert into storage.objects (bucket_id, name, metadata) select 'contact-reports', h.storage_path,
       jsonb_build_object('size', '1000', 'mimetype', 'application/pdf')
  from public.contact_report_hard_copies h where h.tenant_id = '10000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001');
select public.attach_contact_report_hard_copy('c0000000-0000-0000-0000-000000000004',
  (select id from public.contact_report_hard_copies where tenant_id = '10000000-0000-0000-0000-000000000001'));
reset role;
insert into cit select d.subject, d.id from public.contact_report_decisions d
 where d.report_id = (select (r ->> 'report_id')::uuid from cit_tmp);
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000011';

-- ── tenant settings ─────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.set_monvelo_tenant_settings('cccccccc-0000-0000-0000-000000000001', true, 50000, 20000, null, (select id from cit where subject = 'MONVELO_SETTINGS'))$$,
  'a ZSM sets the tenant''s Monvelo settings');
select lives_ok(
  $$select public.set_monvelo_tenant_settings('cccccccc-0000-0000-0000-000000000001', true, 50000, 20000, null, (select id from cit where subject = 'MONVELO_SETTINGS'))$$,
  'the same key replays');
reset role;
select is(
  (select enabled::text || ':' || opening_limit::text || ':' || approval_cap::text
     from public.monvelo_tenant_settings where tenant_id = '10000000-0000-0000-0000-000000000001'),
  'true:50000.00:20000.00', 'the settings row holds the values');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'set_monvelo_tenant_settings' and idempotency_key = 'cccccccc-0000-0000-0000-000000000001'),
  1, 'the settings write is audited once');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.set_monvelo_tenant_settings('cccccccc-0000-0000-0000-000000000002', false, 60000, 20000, null, (select id from cit where subject = 'MONVELO_SETTINGS'))$$,
  'settings are updated in place');
select throws_ok(
  $$select public.set_monvelo_tenant_settings('cccccccc-0000-0000-0000-000000000003', true, -1, 0)$$,
  'P0001', null, 'a negative limit is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_monvelo_tenant_settings('cccccccc-0000-0000-0000-000000000004', true, 1, 1)$$,
  '42501', null, 'a non-ZSM cannot change the settings');

-- ── propose and approve ─────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000001',
      'Purerigin', 500, 30, 1000, date '2026-10-01', null)$$,
  'a ZSM proposes brand terms');
select is(
  public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000001',
      'Purerigin', 500, 30, 1000, date '2026-10-01', null) ->> 'terms_id',
  (select id::text from public.monvelo_brand_terms where brand = 'Purerigin'),
  'the same key replays and returns the same terms_id');
select is(
  (select status from public.monvelo_brand_terms where brand = 'Purerigin'),
  'PROPOSED', 'new terms are PROPOSED');
select throws_ok(
  $$select public.approve_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000002',
      (select id from public.monvelo_brand_terms where brand = 'Purerigin'), (select id from cit where subject = 'BRAND_TERMS'))$$,
  '42501', 'terms are approved by a second ZSM', 'the proposer cannot approve');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.approve_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000003',
      (select id from public.monvelo_brand_terms where brand = 'Purerigin'), (select id from cit where subject = 'BRAND_TERMS'))$$,
  '42501', null, 'a non-ZSM cannot approve');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.approve_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000004',
      (select id from public.monvelo_brand_terms where brand = 'Purerigin'), (select id from cit where subject = 'BRAND_TERMS'))$$,
  'a second ZSM approves');
reset role;
select is(
  (select status || ':' || (approved_by = '20000000-0000-0000-0000-000000000002')::text
     from public.monvelo_brand_terms where brand = 'Purerigin'),
  'APPROVED:true', 'the terms are APPROVED by the second ZSM');
select is(
  (select brand_key from public.monvelo_brand_terms where brand = 'Purerigin'),
  'purerigin', 'brand_key is the lower-cased trimmed brand');

-- ── brand spelling (Review Focus 1) ─────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000005',
      'PURERIGIN ', 700, 30, 1000, date '2026-11-01', date '2026-11-15')$$,
  'another spelling of the brand can be proposed');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.approve_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000006',
      (select id from public.monvelo_brand_terms where brand = 'PURERIGIN'), (select id from cit where subject = 'BRAND_TERMS'))$$,
  'P0001', 'approved terms for this brand overlap in time', 'PURERIGIN overlapping approved Purerigin is refused');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000007',
      'Retired', 500, 30, 1000, date '2026-10-01', null)$$,
  'P0001', 'no active product of this brand', 'a brand whose products are all inactive is refused');
select throws_ok(
  $$select public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000008',
      'Nonesuch', 500, 30, 1000, date '2026-10-01', null)$$,
  'P0001', 'no active product of this brand', 'a brand with no product is refused');
select throws_ok(
  $$select public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000009',
      'Tiger', 500, 30, 1000, date '2026-11-30', date '2026-11-30')$$,
  'P0001', null, 'an empty period is refused');
select throws_ok(
  $$select public.propose_monvelo_brand_terms('dddddddd-0000-0000-0000-000000000010',
      'Tiger', 10001, 30, 1000, date '2026-11-01', null)$$,
  'P0001', null, 'a rebate above 10000 bps is refused');

-- ── back-to-back promotions (Review Focus 2) ────────────────────────────
select public.propose_monvelo_brand_terms('eeeeeeee-0000-0000-0000-000000000001',
  'Tiger', 300, 30, 1000, date '2026-11-01', date '2026-11-30');
select public.propose_monvelo_brand_terms('eeeeeeee-0000-0000-0000-000000000002',
  'Tiger', 200, 30, 1000, date '2026-11-30', null);
select public.propose_monvelo_brand_terms('eeeeeeee-0000-0000-0000-000000000003',
  'tiger', 900, 30, 1000, date '2026-11-29', date '2026-12-05');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.approve_monvelo_brand_terms('eeeeeeee-0000-0000-0000-000000000011',
      (select id from public.monvelo_brand_terms where brand = 'Tiger' and rebate_bps = 300), (select id from cit where subject = 'BRAND_TERMS'))$$,
  'terms ending 2026-11-30 approve');
select lives_ok(
  $$select public.approve_monvelo_brand_terms('eeeeeeee-0000-0000-0000-000000000012',
      (select id from public.monvelo_brand_terms where brand = 'Tiger' and rebate_bps = 200), (select id from cit where subject = 'BRAND_TERMS'))$$,
  'terms starting 2026-11-30 approve too');
select throws_ok(
  $$select public.approve_monvelo_brand_terms('eeeeeeee-0000-0000-0000-000000000013',
      (select id from public.monvelo_brand_terms where brand = 'tiger'), (select id from cit where subject = 'BRAND_TERMS'))$$,
  'P0001', 'approved terms for this brand overlap in time', 'terms starting 2026-11-29 are refused (one-day overlap)');

-- ── monvelo_terms_at ────────────────────────────────────────────────────
reset role;
select is(
  (public.monvelo_terms_at('10000000-0000-0000-0000-000000000001', 'Tiger', date '2026-11-15')).rebate_bps,
  300, 'monvelo_terms_at returns the promotion inside its dates');
select is(
  (public.monvelo_terms_at('10000000-0000-0000-0000-000000000001', ' TIGER', date '2026-11-30')).rebate_bps,
  200, 'valid_to is exclusive: on 2026-11-30 the following row applies (any spelling)');
select is(
  (public.monvelo_terms_at('10000000-0000-0000-0000-000000000001', 'Tiger', date '2026-12-20')).rebate_bps,
  200, 'the open-ended row applies after the promotion');
select ok(
  public.monvelo_terms_at('10000000-0000-0000-0000-000000000001', 'Tiger', date '2026-10-31') is null,
  'before any approved row there are no terms');
select ok(
  public.monvelo_terms_at('10000000-0000-0000-0000-000000000001', 'Nonesuch', date '2026-10-31') is null,
  'an unknown brand has no terms');
select ok(
  not has_function_privilege('authenticated',
    'public.monvelo_terms_at(uuid, text, date)', 'execute'),
  'monvelo_terms_at is internal: no API role can execute it');

-- ── immutability ────────────────────────────────────────────────────────
select throws_ok(
  $$update public.monvelo_brand_terms set rebate_bps = 999 where brand = 'Purerigin'$$,
  'P0001', null, 'an APPROVED row''s rebate cannot change');
select throws_ok(
  $$delete from public.monvelo_brand_terms where brand = 'Purerigin'$$,
  'P0001', null, 'an APPROVED row is never deleted');
select throws_ok(
  $$delete from public.monvelo_brand_terms where brand = 'tiger'$$,
  'P0001', null, 'no brand-terms row is deleted');
select lives_ok(
  $$update public.monvelo_brand_terms set valid_to = current_date + 30 where brand = 'Purerigin' and status = 'APPROVED'$$,
  'an APPROVED row may be set to end on a later date than today');
select throws_ok(
  $$update public.monvelo_brand_terms set valid_to = current_date - 1 where brand = 'Purerigin' and status = 'APPROVED'$$,
  'P0001', null, 'but not ended in the past');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.withdraw_monvelo_brand_terms('ffffffff-0000-0000-0000-000000000001',
      (select id from public.monvelo_brand_terms where brand = 'Tiger' and rebate_bps = 300), (select id from cit where subject = 'BRAND_TERMS'))$$,
  'a ZSM withdraws approved terms');
reset role;
select is(
  (select status from public.monvelo_brand_terms where brand = 'Tiger' and rebate_bps = 300),
  'WITHDRAWN', 'the row is WITHDRAWN');
select ok(
  public.monvelo_terms_at('10000000-0000-0000-0000-000000000001', 'Tiger', date '2026-11-15') is null,
  'withdrawn terms no longer apply');

-- ── Teafair fee terms ───────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', null);
select lives_ok(
  $$select public.record_monvelo_fee_terms('99999999-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001', 150, current_date - 60, current_date + 60, (select id from cit where subject = 'FEES'))$$,
  'the operator records fee terms for a tenant');
select throws_ok(
  $$select public.record_monvelo_fee_terms('99999999-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000001', 200, current_date + 59, null, (select id from cit where subject = 'FEES'))$$,
  'P0001', 'fee terms for this tenant overlap in time', 'overlapping fee terms are refused');
select lives_ok(
  $$select public.record_monvelo_fee_terms('99999999-0000-0000-0000-000000000003',
      '10000000-0000-0000-0000-000000000001', 200, current_date + 60, null, (select id from cit where subject = 'FEES'))$$,
  'back-to-back fee terms are allowed');
select throws_ok(
  $$select public.record_monvelo_fee_terms('99999999-0000-0000-0000-000000000004',
      '00000000-0000-0000-0000-00000000dead', 200, date '2027-01-01', null, (select id from cit where subject = 'FEES'))$$,
  'P0001', null, 'an unknown tenant is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.record_monvelo_fee_terms('99999999-0000-0000-0000-000000000005',
      '10000000-0000-0000-0000-000000000001', 100, date '2030-01-01', null, (select id from cit where subject = 'FEES'))$$,
  '42501', null, 'a tenant ZSM cannot record fee terms');
select pg_temp.act_as('20000000-0000-0000-0000-000000000010', null);
select throws_ok(
  $$select public.record_monvelo_fee_terms('99999999-0000-0000-0000-000000000006',
      '10000000-0000-0000-0000-000000000001', 100, date '2030-01-01', null, (select id from cit where subject = 'FEES'))$$,
  '42501', null, 'MONVELO_FINANCE cannot record fee terms');
reset role;
select throws_ok(
  $$update public.monvelo_tenant_fee_terms set fee_bps = 1 where valid_to is null$$,
  'P0001', null, 'a fee row''s rate cannot change');
select throws_ok(
  $$delete from public.monvelo_tenant_fee_terms$$,
  'P0001', null, 'fee terms are never deleted');
select throws_ok(
  $$update public.monvelo_tenant_fee_terms set valid_to = current_date - 1 where fee_bps = 150$$,
  'P0001', null, 'a fee row cannot be ended in the past');
select lives_ok(
  $$update public.monvelo_tenant_fee_terms set valid_to = current_date + 30 where fee_bps = 150$$,
  'a fee row can be ended on a later date than today');

select throws_ok(
  $$update public.monvelo_tenant_fee_terms set valid_to = current_date + 5
     where tenant_id = '10000000-0000-0000-0000-000000000003'$$,
  'P0001', null, 'an expired fee row cannot be re-opened by a new end date');
select throws_ok(
  $$update public.monvelo_brand_terms set valid_to = current_date + 5
     where tenant_id = '10000000-0000-0000-0000-000000000003'$$,
  'P0001', null, 'expired approved brand terms cannot be re-opened by a new end date');

-- ── RLS ─────────────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is(
  (select count(*)::int from public.monvelo_brand_terms)
  + (select count(*)::int from public.monvelo_tenant_settings)
  + (select count(*)::int from public.monvelo_tenant_fee_terms),
  0, 'another tenant''s ZSM reads no terms, settings or fee terms');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select ok(
  (select count(*) from public.monvelo_brand_terms) > 0
  and (select count(*) from public.monvelo_tenant_settings) = 1
  and (select count(*) from public.monvelo_tenant_fee_terms) = 2,
  'tenant members read the terms, settings and fee terms');
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', null);
select ok(
  (select count(*) from public.monvelo_brand_terms) > 0
  and (select count(*) from public.monvelo_tenant_fee_terms) = 3,
  'a MONVELO_OPERATOR with no tenant reads them');
select pg_temp.act_as('20000000-0000-0000-0000-000000000010', null);
select is((select count(*)::int from public.monvelo_tenant_settings), 1,
  'MONVELO_FINANCE reads them too');
reset role;
select ok(
  has_function_privilege('authenticated', 'public.is_monvelo_staff()', 'execute'),
  'is_monvelo_staff is granted for policies');
select ok(
  not has_function_privilege('anon', 'public.is_monvelo_staff()', 'execute'),
  'but not to anon');

select * from finish();
rollback;
