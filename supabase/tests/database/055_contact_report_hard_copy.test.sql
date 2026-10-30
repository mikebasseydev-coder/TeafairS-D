-- Addendum A6 §16.4 (Monvelo Step 1c, Task 2b) — the ZSM review and the signed
-- hard copy of a contact report.
begin;
create extension if not exists pgtap with schema extensions;

select plan(58);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- 1 CSM (A) · 2 ZSM (A) · 3 TENANT_ADMIN (A) · 4 TM (A) · 6 MONVELO_FINANCE
-- · 7 ZSM (B) · 8 CSM (B) · 9 MONVELO_OPERATOR · 10 CSM (C, no ZSM)
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER'),
  ('10000000-0000-0000-0000-000000000003', 'Brand C', 'BRANDC');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 10) n;
update public.profiles set platform_role = 'MONVELO_FINANCE'  where id = '20000000-0000-0000-0000-000000000006';
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000009';

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TENANT_ADMIN', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000010',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true);

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

create function pg_temp.rep(p_sup uuid default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'CALL',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
    'summary', 'Agreed the rebate.', 'supersedes_id', p_sup,
    'decisions', jsonb_build_array(jsonb_build_object('subject', 'BRAND_TERMS', 'text', 'Rebate 2 percent')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222')));
$$;
grant execute on function pg_temp.rep(uuid) to authenticated;

-- named results of filings: R1 approved · R2 rejected · R3 corrects R2 · R4 corrected by R5 · R6 (tenant C)
create temp table res (n text primary key, r jsonb);
grant all on res to authenticated;
create function pg_temp.rid(p_n text) returns uuid language sql as $$ select (r ->> 'report_id')::uuid from res where n = p_n $$;
grant execute on function pg_temp.rid(text) to authenticated;
create function pg_temp.did(p_n text) returns uuid language sql as $$ select (r -> 'decision_ids' ->> 0)::uuid from res where n = p_n $$;
grant execute on function pg_temp.did(text) to authenticated;

select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
insert into res select 'R1', public.file_contact_report(pg_temp.k(1), pg_temp.rep());
insert into res select 'R2', public.file_contact_report(pg_temp.k(2), pg_temp.rep());
insert into res select 'R4', public.file_contact_report(pg_temp.k(3), pg_temp.rep());
select pg_temp.act_as(pg_temp.u(10), '10000000-0000-0000-0000-000000000003');
insert into res select 'R6', public.file_contact_report(pg_temp.k(4), pg_temp.rep());

-- ── no review yet ───────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(10), pg_temp.rid('R1'), 'application/pdf', 204800)$$,
  'P0001', 'a ZSM must approve this contact report before its hard copy is uploaded', 'no slot before a review');
reset role;
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'BRAND_TERMS')$$, pg_temp.did('R1')),
  'P0001', 'a ZSM must approve this contact report before it is cited', 'an unreviewed report cannot be cited');

-- ── who may review ──────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.review_contact_report(pg_temp.k(11), pg_temp.rid('R1'), 'APPROVED')$$, '42501', null, 'the CSM cannot review');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.review_contact_report(pg_temp.k(11), pg_temp.rid('R1'), 'APPROVED')$$, '42501', null, 'a TENANT_ADMIN cannot review');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.review_contact_report(pg_temp.k(11), pg_temp.rid('R1'), 'APPROVED')$$, '42501', null, 'a TM cannot review');
select pg_temp.act_as(pg_temp.u(7), '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.review_contact_report(pg_temp.k(11), pg_temp.rid('R1'), 'APPROVED')$$,
  '42501', 'contact report not found', 'another tenant''s ZSM cannot review');
select pg_temp.act_as(pg_temp.u(9), null);
select throws_ok($$select public.review_contact_report(pg_temp.k(11), pg_temp.rid('R1'), 'APPROVED')$$,
  '42501', 'this tenant has an active ZSM; the ZSM reviews', 'the operator is refused where a ZSM is active');
select pg_temp.act_as(pg_temp.u(6), null);
select throws_ok($$select public.review_contact_report(pg_temp.k(11), pg_temp.rid('R6'), 'APPROVED')$$, '42501', null,
  'MONVELO_FINANCE cannot review');

-- ── rejection ───────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.review_contact_report(pg_temp.k(12), pg_temp.rid('R2'), 'REJECTED')$$,
  'P0001', 'say what must be corrected', 'a rejection needs a note');
select lives_ok($$select public.review_contact_report(pg_temp.k(13), pg_temp.rid('R2'), 'REJECTED', 'Wrong rebate rate')$$,
  'a rejection with a note is stored');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(14), pg_temp.rid('R2'), 'application/pdf', 1000)$$,
  'P0001', 'this contact report was rejected; file a correction', 'no slot for a rejected report');
insert into res select 'R3', public.file_contact_report(pg_temp.k(15), pg_temp.rep(pg_temp.rid('R2')));
insert into res select 'R5', public.file_contact_report(pg_temp.k(16), pg_temp.rep(pg_temp.rid('R4')));
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.review_contact_report(pg_temp.k(17), pg_temp.rid('R3'), 'APPROVED')$$,
  'the correction of the rejected report is approved');
select throws_ok($$select public.review_contact_report(pg_temp.k(18), pg_temp.rid('R3'), 'APPROVED')$$,
  '23505', 'this contact report has already been reviewed', 'a second review');
select throws_ok($$select public.review_contact_report(pg_temp.k(19), pg_temp.rid('R4'), 'APPROVED')$$,
  'P0001', 'only the current version of a report can be reviewed', 'a superseded report cannot be reviewed');
select throws_ok($$select public.review_contact_report(pg_temp.k(20), pg_temp.rid('R5'), 'MAYBE')$$,
  'P0001', null, 'an unknown outcome');
reset role;
select throws_ok($$update public.contact_report_reviews set note = 'x'$$, 'P0001', null, 'reviews are insert-only');
select throws_ok($$delete from public.contact_report_reviews$$, 'P0001', null, 'reviews are never deleted');

-- ── R1: approved, then the hard copy ────────────────────────────────────
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.review_contact_report(pg_temp.k(21), pg_temp.rid('R1'), 'APPROVED')$$, 'a ZSM approves R1');
select is(public.review_contact_report(pg_temp.k(21), pg_temp.rid('R1'), 'APPROVED'),
          public.review_contact_report(pg_temp.k(21), pg_temp.rid('R1'), 'APPROVED'), 'the review replays');
reset role;
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'BRAND_TERMS')$$, pg_temp.did('R1')),
  'P0001', 'upload the signed hard copy of this contact report before citing it', 'approved but no hard copy');

select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(22), pg_temp.rid('R1'), 'application/pdf', 1000)$$,
  '42501', null, 'a ZSM cannot request a slot');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(22), pg_temp.rid('R1'), 'application/pdf', 1000)$$,
  '42501', null, 'a TENANT_ADMIN cannot request a slot');
select pg_temp.act_as(pg_temp.u(8), '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(22), pg_temp.rid('R1'), 'application/pdf', 1000)$$,
  '42501', 'contact report not found', 'another tenant''s CSM cannot request a slot');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(23), pg_temp.rid('R1'), 'application/pdf', 20971520)$$,
  'P0001', null, 'a 20 MB file is refused');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(24), pg_temp.rid('R1'), 'text/plain', 1000)$$,
  'P0001', null, 'text/plain is refused');
create temp table slot (r jsonb);
grant all on slot to authenticated;
insert into slot select public.request_contact_report_hard_copy(pg_temp.k(25), pg_temp.rid('R1'), 'application/pdf', 204800);
select matches((select r ->> 'storage_path' from slot), '^contact-reports/' || pg_temp.rid('R1')::text || '/[0-9a-f-]{36}\.pdf$',
  'a path under contact-reports/<report_id>/');
select is(public.request_contact_report_hard_copy(pg_temp.k(25), pg_temp.rid('R1'), 'application/pdf', 204800), (select r from slot),
  'the slot request replays');
select throws_ok($$select public.attach_contact_report_hard_copy(pg_temp.k(26), (select (r ->> 'hard_copy_id')::uuid from slot))$$,
  'P0001', 'the hard copy has not been uploaded yet', 'attach before any object exists');

-- a pending object is unreadable; the stand-in for the upload
reset role;
insert into storage.objects (bucket_id, name) select 'contact-reports', h.storage_path
  from public.contact_report_hard_copies h where h.id = (select (r ->> 'hard_copy_id')::uuid from slot);
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.attach_contact_report_hard_copy(pg_temp.k(35), (select (r ->> 'hard_copy_id')::uuid from slot))$$,
  'P0001', 'the hard copy has not been uploaded yet', 'an object with no size or mimetype metadata is refused');
reset role;
update storage.objects set metadata = jsonb_build_object('size', '204800', 'mimetype', 'application/pdf')
 where bucket_id = 'contact-reports';
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from storage.objects where bucket_id = 'contact-reports'), 0,
  'nobody reads a pending (unattached) object');

select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.attach_contact_report_hard_copy(pg_temp.k(27), (select (r ->> 'hard_copy_id')::uuid from slot))$$,
  '42501', null, 'a ZSM cannot attach');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select public.attach_contact_report_hard_copy(pg_temp.k(28), (select (r ->> 'hard_copy_id')::uuid from slot))$$,
  'the CSM attaches the hard copy');
select is(public.attach_contact_report_hard_copy(pg_temp.k(28), (select (r ->> 'hard_copy_id')::uuid from slot)),
          public.attach_contact_report_hard_copy(pg_temp.k(28), (select (r ->> 'hard_copy_id')::uuid from slot)), 'the attach replays');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(29), pg_temp.rid('R1'), 'application/pdf', 1000)$$,
  'P0001', 'this contact report already has its hard copy', 'a second request');
reset role;
select ok((select attached_at is not null from public.contact_report_hard_copies where id = (select (r ->> 'hard_copy_id')::uuid from slot)),
  'attached_at is set');
select is((select (public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', pg_temp.did('R1'), 'BRAND_TERMS')).report_id),
  pg_temp.rid('R1'), 'after the attach the decision is citable');
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'BRAND_TERMS')$$, pg_temp.did('R5')),
  'P0001', 'a ZSM must approve this contact report before it is cited', 'R5 is unreviewed');
select throws_ok(format($$select public.assert_citable_decision('7eaf0000-0000-4000-8000-000000000001', %L, 'BRAND_TERMS')$$, pg_temp.did('R4')),
  'P0001', 'this contact report has been superseded; cite the decision in its correction', 'R4 is superseded');

-- B: no slot for a superseded report (R4 is corrected by R5)
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.request_contact_report_hard_copy(pg_temp.k(36), pg_temp.rid('R4'), 'application/pdf', 1000)$$,
  'P0001', 'this contact report has been superseded; upload the hard copy of its correction', 'no slot for a superseded report');
reset role;

-- ── a hard copy is never changed ────────────────────────────────────────
select throws_ok($$update public.contact_report_hard_copies set storage_path = storage_path || 'x'$$,
  'P0001', 'a hard copy is never changed; file a correction', 'the path cannot change');
select throws_ok($$update public.contact_report_hard_copies set attached_at = now() + interval '1 day'$$,
  'P0001', null, 'attached_at cannot change again');
select throws_ok($$delete from public.contact_report_hard_copies$$, 'P0001', null, 'a hard copy is never deleted');
select throws_ok($$truncate public.contact_report_hard_copies cascade$$, 'P0001', null, 'nor truncated');

-- ── download ────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from storage.objects where bucket_id = 'contact-reports'), 1,
  'the TENANT_ADMIN reads the attached object');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from storage.objects where bucket_id = 'contact-reports'), 0, 'a TM does not');
select pg_temp.act_as(pg_temp.u(7), '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from storage.objects where bucket_id = 'contact-reports'), 0, 'another tenant''s ZSM does not');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.contact_report_hard_copies), 1, 'the TENANT_ADMIN reads the hard copy row');
reset role;
select ok(not has_column_privilege('authenticated', 'public.contact_report_hard_copies', 'storage_path', 'SELECT'),
  'the storage path is not selectable through the API');

-- ── the operator fallback (tenant C has no ACTIVE ZSM) ──────────────────
select pg_temp.act_as(pg_temp.u(9), null);
select lives_ok($$select public.review_contact_report(pg_temp.k(30), pg_temp.rid('R6'), 'APPROVED')$$,
  'the operator approves for a tenant without a ZSM');
reset role;
select is((select reviewed_by::text || ':' || reviewer_kind from public.contact_report_reviews where report_id = pg_temp.rid('R6')),
  pg_temp.u(9)::text || ':OPERATOR_FALLBACK', 'reviewed_by is the operator');
select is((select after ->> 'reviewer_kind' from public.audit_logs where operation = 'review_contact_report'
            and entity_id = (select id::text from public.contact_report_reviews where report_id = pg_temp.rid('R6'))),
  'OPERATOR_FALLBACK', 'the audit row records the fallback');
select pg_temp.act_as(pg_temp.u(10), '10000000-0000-0000-0000-000000000003');
create temp table slot2 (r jsonb);
grant all on slot2 to authenticated;
insert into slot2 select public.request_contact_report_hard_copy(pg_temp.k(31), pg_temp.rid('R6'), 'image/png', 5000);
reset role;
insert into storage.objects (bucket_id, name, metadata) select 'contact-reports', h.storage_path,
         jsonb_build_object('size', '5000', 'mimetype', 'image/png')
  from public.contact_report_hard_copies h where h.id = (select (r ->> 'hard_copy_id')::uuid from slot2);
select pg_temp.act_as(pg_temp.u(10), '10000000-0000-0000-0000-000000000003');
select lives_ok($$select public.attach_contact_report_hard_copy(pg_temp.k(32), (select (r ->> 'hard_copy_id')::uuid from slot2))$$, 'the operator-approved report gets its hard copy');
reset role;
select is((select (public.assert_citable_decision('10000000-0000-0000-0000-000000000003', pg_temp.did('R6'), 'BRAND_TERMS')).report_id),
  pg_temp.rid('R6'), 'the operator-approved report is citable once its copy is attached');
select ok(not exists (select 1 from public.audit_logs where (coalesce(after::text, '') || coalesce(before::text, '')) like '%contact-reports/%'),
  'no audit row holds a storage path');

-- ── cleanup: a stale pending copy is queued for the purge, its row stays ─
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
create temp table slot3 (r jsonb);
grant all on slot3 to authenticated;
-- R3 is approved but has no copy yet
insert into slot3 select public.request_contact_report_hard_copy(pg_temp.k(33), pg_temp.rid('R3'), 'image/jpeg', 9000);
reset role;
insert into storage.objects (bucket_id, name, metadata) select 'contact-reports', h.storage_path,
         jsonb_build_object('size', '9000', 'mimetype', 'image/jpeg')
  from public.contact_report_hard_copies h where h.id = (select (r ->> 'hard_copy_id')::uuid from slot3);
alter table public.contact_report_hard_copies disable trigger contact_report_hard_copies_guard_row;
update public.contact_report_hard_copies set created_at = now() - interval '25 hours'
 where id = (select (r ->> 'hard_copy_id')::uuid from slot3);
alter table public.contact_report_hard_copies enable trigger contact_report_hard_copies_guard_row;
select lives_ok($$select public.cleanup_pending_upload_slots()$$, 'the nightly cleanup runs');
select is((select count(*)::int from public.storage_purge_queue where bucket = 'contact-reports'
            and path = (select storage_path from public.contact_report_hard_copies where id = (select (r ->> 'hard_copy_id')::uuid from slot3))),
  1, 'the stale object is queued for the purge');
select is((select count(*)::int from public.contact_report_hard_copies where id = (select (r ->> 'hard_copy_id')::uuid from slot3)),
  1, 'the row stays');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.attach_contact_report_hard_copy(pg_temp.k(34), (select (r ->> 'hard_copy_id')::uuid from slot3))$$,
  'P0001', 'this upload has expired; request a new one', 'an expired slot cannot be attached');

select * from finish();
rollback;
