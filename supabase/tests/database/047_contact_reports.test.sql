-- Addendum A6 §16.4 (Monvelo Step 1c, Task 2) — contact reports.
begin;
create extension if not exists pgtap with schema extensions;

select plan(41);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- 1 CSM (A) · 2 ZSM (A) · 3 TENANT_ADMIN (A) · 4 TM (A) · 5 DSA (A)
-- · 6 MONVELO_FINANCE · 7 ZSM (B) · 8 CSM (B)
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 8) n;
update public.profiles set platform_role = 'MONVELO_FINANCE'
 where id = '20000000-0000-0000-0000-000000000006';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TENANT_ADMIN', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSA', '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000004', 'ACTIVE', true);

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

-- a valid report; the first decision's subject and a superseded id are parameters
create function pg_temp.rep(p_sup uuid default null, p_subject text default 'BRAND_TERMS') returns jsonb
language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'MEETING',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR'),
                                   jsonb_build_object('name', 'Chidi', 'side', 'TENANT')),
    'summary', 'Agreed the rebate and the catalogue.',
    'supersedes_id', p_sup,
    'decisions', jsonb_build_array(jsonb_build_object('subject', p_subject, 'text', 'Rebate 2 percent'),
                                   jsonb_build_object('subject', 'CATALOGUE', 'text', 'Add the 100ml')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+234 803 111 2222'),
      jsonb_build_object('name', 'Jane', 'channel', 'EMAIL', 'address', 'Jane@Brand.com')));
$$;
grant execute on function pg_temp.rep(uuid, text) to authenticated;

-- ── filing ──────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.file_contact_report(pg_temp.k(1), pg_temp.rep())$$, 'the CSM files report A');
select is(public.file_contact_report(pg_temp.k(1), pg_temp.rep()), public.file_contact_report(pg_temp.k(1), pg_temp.rep()),
  'the same key replays');

reset role;
create temp table t_a as select r.id, r.reference from public.contact_reports r where r.tenant_id = '7eaf0000-0000-4000-8000-000000000001';
grant select on t_a to authenticated;
select is((select count(*)::int from t_a), 1, 'the replay wrote one report');
select matches((select reference from t_a), '^CR-[A-Z2-7]{8}$', 'the reference is CR- plus 8 base32 characters');
select is((select count(*)::int from public.contact_report_deliveries where report_id = (select id from t_a) and status = 'PENDING'),
  2, 'two PENDING deliveries');
select is((select array_agg(seq order by seq) from public.contact_report_decisions where report_id = (select id from t_a)),
  array[1, 2], 'the decisions are numbered from 1');
select is((select address from public.contact_report_recipients where report_id = (select id from t_a) and channel = 'WHATSAPP'),
  '+2348031112222', 'the phone is normalised to + digits');
select is((select array_agg(address_hint order by channel) from public.contact_report_recipients where report_id = (select id from t_a)),
  array['j***@brand.com', '…2222'], 'the hints');

select is((select (response ->> 'deliveries_pending')::int from public.idempotency_logs where key = pg_temp.k(1)), 2,
  'the stored response counts the deliveries');
select ok(not exists (select 1 from public.idempotency_logs where key = pg_temp.k(1)
                       and coalesce(response::text, '') ~* '(jane@|[0-9]{10})'),
  'the idempotency log holds no address');
select ok(not exists (select 1 from public.audit_logs where operation = 'file_contact_report'
                       and (coalesce(after::text, '') || coalesce(before::text, '')) ~* '(jane@|[0-9]{10})'),
  'the audit row holds no address and no 10-digit run');
select is((select after ->> 'reference' from public.audit_logs where operation = 'file_contact_report' limit 1),
  (select reference from t_a), 'the audit row holds the reference');

-- ── who may file ────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.file_contact_report(pg_temp.k(2), pg_temp.rep())$$, '42501', null, 'a ZSM cannot file');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.file_contact_report(pg_temp.k(2), pg_temp.rep())$$, '42501', null, 'a TENANT_ADMIN cannot file');

-- ── column privileges ───────────────────────────────────────────────────
reset role;
select ok(not has_column_privilege('authenticated', 'public.contact_report_recipients', 'address', 'SELECT'),
  'authenticated cannot select the address');
select ok(has_column_privilege('authenticated', 'public.contact_report_recipients', 'address_hint', 'SELECT'),
  'authenticated can select the hint');

-- ── validation ──────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.file_contact_report(pg_temp.k(3), pg_temp.rep() || '{"recipients": []}'::jsonb)$$,
  'P0001', 'a contact report copies at least one tenant contact', 'zero recipients');
select throws_ok($$select public.file_contact_report(pg_temp.k(4), pg_temp.rep() ||
  '{"recipients": [{"name": "X", "channel": "WHATSAPP", "address": "12345"}]}'::jsonb)$$,
  'P0001', null, 'a bad phone');

-- ── insert-only (as postgres) ───────────────────────────────────────────
reset role;
select throws_ok($$update public.contact_reports set summary = 'x'$$, 'P0001',
  'contact reports are insert-only; file a correction that supersedes the report', 'update refused');
select throws_ok($$delete from public.contact_reports$$, 'P0001', null, 'delete refused');
select throws_ok($$truncate public.contact_reports cascade$$, 'P0001', null, 'truncate refused');
select throws_ok($$update public.contact_report_decisions set decision_text = 'x'$$, 'P0001', null, 'decisions: update refused');
select throws_ok($$delete from public.contact_report_recipients$$, 'P0001', null, 'recipients: delete refused');
select lives_ok($$update public.contact_report_deliveries set status = 'SENT', attempts = 1, sent_at = now()$$,
  'a delivery status moves');
select throws_ok($$update public.contact_report_deliveries set channel = 'EMAIL'$$, 'P0001', null,
  'a delivery identity does not');
select throws_ok($$delete from public.contact_report_deliveries$$, 'P0001', null, 'a delivery is never deleted');

-- ── corrections: A <- B <- C ────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.file_contact_report(pg_temp.k(5), pg_temp.rep((select id from t_a), 'FEES'))$$,
  'B supersedes A');
select throws_ok($$select public.file_contact_report(pg_temp.k(6), pg_temp.rep((select id from t_a)))$$,
  'P0001', 'only the current version of a report can be corrected', 'a second correction of A');
reset role;
create temp table t_b as select r.id from public.contact_reports r where r.supersedes_id = (select id from t_a);
grant select on t_b to authenticated;
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.file_contact_report(pg_temp.k(7), pg_temp.rep((select id from t_b), 'FEES'))$$,
  'C supersedes B');
reset role;
create temp table t_c as select r.id from public.contact_reports r where r.supersedes_id = (select id from t_b);
-- C is current; make it citable the way Task 2b requires: a ZSM approval and an attached hard copy
insert into public.contact_report_reviews (tenant_id, report_id, outcome, reviewed_by)
select '7eaf0000-0000-4000-8000-000000000001', id, 'APPROVED', pg_temp.u(2) from t_c;
insert into public.contact_report_hard_copies (id, tenant_id, report_id, storage_path, mime_type, size_bytes, uploaded_by, attached_at)
select 'e0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', id,
       'contact-reports/' || id || '/e0000000-0000-0000-0000-000000000001.pdf', 'application/pdf', 1000, pg_temp.u(1), now()
  from t_c;

-- ── assert_citable_decision ─────────────────────────────────────────────
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'BRAND_TERMS')$$,
  (select id from public.contact_report_decisions where report_id = (select id from t_a) and seq = 1)),
  'P0001', 'this contact report has been superseded; cite the decision in its correction', 'A is superseded');
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'FEES')$$,
  (select id from public.contact_report_decisions where report_id = (select id from t_b) and seq = 1)),
  'P0001', 'this contact report has been superseded; cite the decision in its correction', 'B is superseded');
select is((select (public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001',
  (select id from public.contact_report_decisions where report_id = (select id from t_c) and seq = 1), 'FEES')).report_id),
  (select id from t_c), 'C''s decision is returned');
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'STOCK')$$,
  (select id from public.contact_report_decisions where report_id = (select id from t_c) and seq = 1)),
  'P0001', 'cite a decision on STOCK', 'the wrong subject');
select throws_ok(format($$select public.assert_citable_decision('10000000-0000-0000-0000-000000000002', %L, 'FEES')$$,
  (select id from public.contact_report_decisions where report_id = (select id from t_c) and seq = 1)),
  '42501', 'decision not found', 'another tenant''s decision');

-- ── readers ─────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.contact_reports), 3, 'the TENANT_ADMIN reads the tenant''s reports');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.contact_reports), 3, 'the CSM reads them');
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.contact_report_decisions), 6, 'a ZSM reads the decisions');
select pg_temp.act_as(pg_temp.u(6), null);
select is((select count(*)::int from public.contact_reports), 3, 'MONVELO_FINANCE reads the reports');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.contact_reports), 0, 'a TM reads none');
select pg_temp.act_as(pg_temp.u(5), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.contact_reports), 0, 'a DSA reads none');
select pg_temp.act_as(pg_temp.u(7), '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.contact_reports)
        + (select count(*)::int from public.contact_report_deliveries), 0, 'another tenant''s ZSM reads none');

select * from finish();
rollback;
