-- Addendum A5 §4, §5.4 — support photo upload slots, the private buckets and
-- their Storage policy, and attachments on the A3 RPCs.
begin;
create extension if not exists pgtap with schema extensions;

select plan(96);

-- A6 §18.4: every state is switched on, and every tenant opted in, for this file's fixtures
update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

-- A5: ONLINE orders created from 2026-10-23 must carry refund-policy consent.
create function pg_temp.a5_stamp_consent() returns trigger language plpgsql as $f$
begin
  if new.channel = 'ONLINE' then
    new.policy_version_tag := coalesce(new.policy_version_tag, 'v2.0-food-cosmetics');
    new.policy_accepted_at := coalesce(new.policy_accepted_at, now());
  end if;
  return new;
end;
$f$;
create trigger a5_stamp_consent before insert on public.orders
  for each row execute function pg_temp.a5_stamp_consent();

-- ── fixtures: TEAFAIR with Ikeja (TM_A, user 2) and Epe (TM_B, user 3), a ──
-- ZSM (1), the selling DSA (4); Z2 (5) is a ZSM of another tenant
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005');
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000005',
   'ZSM', null, null, null, 'ACTIVE', true);
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001');
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where id = '40000000-0000-0000-0000-000000000002';

-- A6 §17/§18.3: zones.zsm_id is a ZSM's coverage; each tenant's ACTIVE ZSM
-- covers the zones it acts in
update public.zones z
   set zsm_id = (select tu.profile_id from public.tenant_users tu
                  where tu.tenant_id = z.tenant_id and tu.role = 'ZSM' and tu.status = 'ACTIVE'
                  order by tu.created_at, tu.profile_id limit 1)
 where z.zsm_id is null;
-- an ONLINE Ikeja order sold by the DSA (A2-strict: the seller never reads its tickets)
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000004', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-AAAAAA',
   md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001');
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, paystack_reference) values
  ('91000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 2500, 'TFW-00000000-0000-0000-0000-00000000000a');

create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('a5000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated;
create function pg_temp.h(p_secret text) returns text language sql as
  $$ select encode(extensions.digest(p_secret, 'sha256'), 'hex') $$;

-- T1: the buyer's ORDER ticket (Ikeja, accountable = the selling DSA)
do $$ begin
  perform set_config('t.t1', public.open_support_ticket(pg_temp.k(1), 'ORDER', 'DELIVERY', 'It arrived broken',
           jsonb_build_object('name', 'Ada', 'phone', '+2348011111111'),
           'TF-AAAAAA', 'TFW-00000000-0000-0000-0000-00000000000a', null, pg_temp.h('s3cret')) ->> 'ticket_id', false);
  perform set_config('t.r1', (select public_reference from public.support_tickets
                               where id = current_setting('t.t1')::uuid), false);
end $$;
-- T2: a pre-purchase ticket the DSA is accountable for; T3 CLOSED; T4 for the throttle
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, accountable_id, status) values
  ('60000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA2', 'PRE_PURCHASE', 'PRODUCT',
   null, '20000000-0000-0000-0000-000000000004', 'OPEN'),
  ('60000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA3', 'PRE_PURCHASE', 'PRODUCT',
   null, null, 'CLOSED'),
  ('60000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA4', 'PRE_PURCHASE', 'PRODUCT',
   null, null, 'OPEN');
insert into public.support_ticket_secrets (ticket_id, tenant_id, secret_hash)
select id, tenant_id, pg_temp.h('other') from public.support_tickets
 where id in ('60000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000003',
              '60000000-0000-0000-0000-000000000004');
insert into public.support_messages (tenant_id, ticket_id, sender_type, body) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000002', 'CUSTOMER', 'Bulk?');

-- buyer slot request
create function pg_temp.req(p_key integer, p_ref text, p_secret text, p_mime text, p_size bigint)
returns jsonb language sql as
  $$ select public.request_ticket_attachment(pg_temp.k(p_key), p_ref, p_secret, p_mime, p_size) $$;
-- simulate a finished upload of a slot (optionally with a different size or type)
create function pg_temp.upload(p_slot uuid, p_size bigint default null, p_mime text default null)
returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  select s.bucket, s.storage_path,
         jsonb_build_object('size', coalesce(p_size, s.size_bytes), 'mimetype', coalesce(p_mime, s.mime_type))
    from public.upload_slots s where s.id = p_slot
$$;
create function pg_temp.slot(p_key integer) returns uuid language sql as
  $$ select (r.response ->> 'attachment_id')::uuid from public.idempotency_logs r where r.key = pg_temp.k(p_key) $$;
create procedure pg_temp.as_user(n integer, p_tenant uuid default '7eaf0000-0000-4000-8000-000000000001')
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0')), 'role', 'authenticated',
    'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
end $$;

-- ── schema, buckets, grants ─────────────────────────────────────────────
select has_table('public', 'upload_slots', 'upload_slots exists');
select ok((select relrowsecurity from pg_class where oid = 'public.upload_slots'::regclass), 'upload_slots has RLS');
select ok(not has_table_privilege('authenticated', 'public.upload_slots', 'insert')
      and not has_table_privilege('authenticated', 'public.upload_slots', 'update')
      and not has_table_privilege('authenticated', 'public.upload_slots', 'delete')
      and has_table_privilege('authenticated', 'public.upload_slots', 'select'),
  'authenticated may only select upload_slots');
select ok(not has_table_privilege('anon', 'public.upload_slots', 'select'), 'anon cannot read upload_slots');
select is((select row(public, file_size_limit, allowed_mime_types)::text from storage.buckets where id = 'support-attachments'),
  row(false, 5242880::bigint, array['image/jpeg', 'image/png', 'image/webp'])::text, 'support-attachments is private, 5 MB, images');
select is((select row(public, file_size_limit, allowed_mime_types)::text from storage.buckets where id = 'delivery-proofs'),
  row(false, 5242880::bigint, array['image/jpeg', 'image/png', 'image/webp'])::text, 'delivery-proofs is private, 5 MB, images');
select is((select count(*)::int from storage.buckets
            where id in ('support-attachments', 'delivery-proofs') and public = false), 2, 'both buckets are private');
select ok(has_function_privilege('authenticated', 'public.my_support_attachment_paths()', 'execute')
      and not has_function_privilege('anon', 'public.my_support_attachment_paths()', 'execute')
      and not has_function_privilege('service_role', 'public.my_support_attachment_paths()', 'execute'),
  'my_support_attachment_paths is for authenticated');
select ok(exists(select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'support_attachments_select' and cmd = 'SELECT' and roles = '{authenticated}'),
  'staff download policy exists');
select ok(not exists(select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                      and cmd <> 'SELECT' and policyname like '%attachment%'),
  'no client write policies on storage');
select ok(has_function_privilege('service_role', 'public.request_ticket_attachment(uuid,text,text,text,bigint)', 'execute')
      and not has_function_privilege('authenticated', 'public.request_ticket_attachment(uuid,text,text,text,bigint)', 'execute')
      and not has_function_privilege('anon', 'public.request_ticket_attachment(uuid,text,text,text,bigint)', 'execute'),
  'request_ticket_attachment is service_role only');
select ok(has_function_privilege('authenticated', 'public.request_staff_ticket_attachment(uuid,uuid,text,bigint)', 'execute')
      and not has_function_privilege('anon', 'public.request_staff_ticket_attachment(uuid,uuid,text,bigint)', 'execute')
      and not has_function_privilege('service_role', 'public.request_staff_ticket_attachment(uuid,uuid,text,bigint)', 'execute'),
  'request_staff_ticket_attachment is for authenticated staff');
select ok(has_function_privilege('authenticated', 'public.my_support_message_ticket_ids()', 'execute')
      and not has_function_privilege('anon', 'public.my_support_message_ticket_ids()', 'execute')
      and not has_function_privilege('service_role', 'public.my_support_message_ticket_ids()', 'execute'),
  'my_support_message_ticket_ids is for authenticated');
select ok(not has_function_privilege('authenticated', 'public.claim_support_attachments(uuid,uuid,uuid[],text)', 'execute')
      and not has_function_privilege('service_role', 'public.claim_support_attachments(uuid,uuid,uuid[],text)', 'execute')
      and not has_function_privilege('anon', 'public.claim_support_attachments(uuid,uuid,uuid[],text)', 'execute')
      and not has_function_privilege('authenticated', 'public.cleanup_pending_upload_slots()', 'execute')
      and not has_function_privilege('service_role', 'public.cleanup_pending_upload_slots()', 'execute')
      and not has_function_privilege('anon', 'public.cleanup_pending_upload_slots()', 'execute'),
  'the claim and the cleanup are internal');
-- the re-created A3 RPCs keep their grants; open_support_ticket keeps its A3 signature
select ok(has_function_privilege('service_role', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and to_regprocedure('public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text,uuid[])') is null
      and has_function_privilege('service_role', 'public.add_ticket_message(uuid,text,text,text,uuid[])', 'execute')
      and not has_function_privilege('authenticated', 'public.add_ticket_message(uuid,text,text,text,uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.add_ticket_message(uuid,text,text,text,uuid[])', 'execute'),
  'buyer RPCs stay service_role only');
select ok(has_function_privilege('authenticated', 'public.reply_ticket(uuid,uuid,text,uuid[])', 'execute')
      and has_function_privilege('service_role', 'public.reply_ticket(uuid,uuid,text,uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.reply_ticket(uuid,uuid,text,uuid[])', 'execute'),
  'reply_ticket keeps its grants');
select ok(to_regprocedure('public.add_ticket_message(uuid,text,text,text)') is null
      and to_regprocedure('public.reply_ticket(uuid,uuid,text)') is null,
  'the old signatures are gone');

-- ── buyer requests a slot ───────────────────────────────────────────────
select is(pg_temp.req(10, current_setting('t.r1'), 's3cret', 'image/jpeg', 1000) ->> 'storage_path' like 'tickets/%.jpg',
          true, 'slot granted');
select is((select storage_path from public.upload_slots where id = pg_temp.slot(10)),
          'tickets/' || current_setting('t.t1') || '/' || pg_temp.slot(10) || '.jpg', 'path is tickets/<ticket>/<slot>.jpg');
select is((select row(purpose, bucket, ticket_id, uploaded_by_type, uploaded_by, message_id, claimed_at, size_bytes)::text
             from public.upload_slots where id = pg_temp.slot(10)),
          row('SUPPORT_TICKET', 'support-attachments', current_setting('t.t1')::uuid, 'CUSTOMER', null::uuid,
              null::uuid, null::timestamptz, 1000::bigint)::text, 'a pending customer slot');
select is(pg_temp.req(10, current_setting('t.r1'), 's3cret', 'image/jpeg', 1000) ->> 'attachment_id',
          pg_temp.slot(10)::text, 'a replayed key returns the same slot');
select is(pg_temp.req(11, lower(current_setting('t.r1')), 's3cret', 'image/png', 2000) ->> 'storage_path' like '%.png'
      and pg_temp.req(12, current_setting('t.r1'), 's3cret', 'image/webp', 3000) ->> 'storage_path' like '%.webp',
          true, 'png and webp extensions');
select throws_ok($$select pg_temp.req(13, current_setting('t.r1'), 'wrong', 'image/jpeg', 1000)$$,
  'P0001', 'NOT_FOUND', 'secret checked');
select throws_ok($$select pg_temp.req(14, 'TK-ZZZZZZ', 's3cret', 'image/jpeg', 1000)$$,
  'P0001', 'NOT_FOUND', 'unknown ticket');
select throws_ok($$select pg_temp.req(15, current_setting('t.r1'), 's3cret', 'image/gif', 1000)$$,
  'P0001', 'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'type limit');
select throws_ok($$select pg_temp.req(16, current_setting('t.r1'), 's3cret', 'image/jpeg', 5242881)$$,
  'P0001', 'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'size limit');
select throws_ok($$select pg_temp.req(17, current_setting('t.r1'), 's3cret', 'image/jpeg', 0)$$,
  'P0001', 'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'empty file refused');
select lives_ok($$select pg_temp.req(18, current_setting('t.r1'), 's3cret', 'image/jpeg', 5242880)$$,
  'exactly 5 MB is allowed');
select throws_ok($$select pg_temp.req(19, 'TK-AAAAA3', 'other', 'image/jpeg', 1000)$$,
  'P0001', 'This conversation is closed. Open a new ticket if you still need help.', 'closed ticket refused');
insert into public.upload_slots (id, tenant_id, purpose, ticket_id, storage_path, mime_type, size_bytes, uploaded_by_type)
select s.id, '7eaf0000-0000-4000-8000-000000000001', 'SUPPORT_TICKET', '60000000-0000-0000-0000-000000000004',
       'tickets/60000000-0000-0000-0000-000000000004/' || s.id || '.jpg', 'image/jpeg', 100, 'CUSTOMER'
  from (select gen_random_uuid() as id from generate_series(1, 10)) s;
select throws_ok($$select pg_temp.req(20, 'TK-AAAAA4', 'other', 'image/jpeg', 1000)$$,
  'P0001', 'Too many messages. Please wait a few minutes.', 'ten pending slots an hour per ticket');
select is(pg_temp.req(21, 'TK-AAAAA2', 'other', 'image/jpeg', 500) ->> 'storage_path'
            like 'tickets/60000000-0000-0000-0000-000000000002/%', true, 'a slot on another ticket');
select throws_ok($$insert into public.upload_slots (tenant_id, purpose, ticket_id, storage_path, mime_type, size_bytes, uploaded_by_type)
                   values ('7eaf0000-0000-4000-8000-000000000001', 'SUPPORT_TICKET', '60000000-0000-0000-0000-000000000004',
                           'elsewhere/x.jpg', 'image/jpeg', 100, 'CUSTOMER')$$,
  '23514', null, 'a slot path must sit under its ticket');

-- ── claiming on add_ticket_message ──────────────────────────────────────
select throws_ok($$select public.add_ticket_message(pg_temp.k(30), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[pg_temp.slot(10)])$$,
  'P0001', 'That photo hasn''t finished uploading.', 'object must exist');
do $$ begin perform pg_temp.upload(pg_temp.slot(10), 999); end $$;
select throws_ok($$select public.add_ticket_message(pg_temp.k(31), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[pg_temp.slot(10)])$$,
  'P0001', 'That photo hasn''t finished uploading.', 'size must match');
do $$ begin perform pg_temp.upload(pg_temp.slot(11), null, 'image/jpeg'); end $$;
select throws_ok($$select public.add_ticket_message(pg_temp.k(32), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[pg_temp.slot(11)])$$,
  'P0001', 'That photo hasn''t finished uploading.', 'type must match');
select throws_ok($$select public.add_ticket_message(pg_temp.k(33), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[pg_temp.slot(10), pg_temp.slot(11), pg_temp.slot(12), pg_temp.slot(18)])$$,
  'P0001', 'You can attach up to 3 photos.', 'max 3');
select throws_ok($$select public.add_ticket_message(pg_temp.k(34), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[pg_temp.slot(21)])$$,
  'P0001', 'That photo isn''t available.', 'slot bound to ticket');
select throws_ok($$select public.add_ticket_message(pg_temp.k(35), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[gen_random_uuid()])$$,
  'P0001', 'That photo isn''t available.', 'unknown slot');
select throws_ok($$select public.add_ticket_message(pg_temp.k(36), current_setting('t.r1'), 's3cret', 'see photo',
                                                    array[pg_temp.slot(12), pg_temp.slot(12)])$$,
  'P0001', 'That photo isn''t available.', 'the same slot twice');
-- fix the object for slot 10 (an overwrite with the right size)
update storage.objects set metadata = jsonb_set(metadata, '{size}', '1000')
 where name = (select storage_path from public.upload_slots where id = pg_temp.slot(10));
select lives_ok($$select set_config('t.m1', public.add_ticket_message(pg_temp.k(37), current_setting('t.r1'), 's3cret',
                                                    'see photo', array[pg_temp.slot(10)]) ->> 'message_id', false)$$,
  'buyer attaches a photo');
select is((select row(message_id, claimed_at is not null)::text from public.upload_slots where id = pg_temp.slot(10)),
          row(current_setting('t.m1')::uuid, true)::text, 'the slot is claimed by the message');
select throws_ok($$select public.add_ticket_message(pg_temp.k(38), current_setting('t.r1'), 's3cret', 'again',
                                                    array[pg_temp.slot(10)])$$,
  'P0001', 'That photo isn''t available.', 'a claimed slot cannot be reused');
select is((select (after ->> 'attachment_count')::int from public.audit_logs
            where operation = 'add_ticket_message' and idempotency_key = pg_temp.k(37)),
          1, 'the audit carries the attachment count');
select is((public.add_ticket_message(pg_temp.k(39), current_setting('t.r1'), 's3cret', 'no photo') ->> 'message_id') is not null,
          true, 'posting without attachments still works');
select is((select (after ->> 'attachment_count')::int from public.audit_logs
            where operation = 'add_ticket_message' and idempotency_key = pg_temp.k(39)),
          0, 'and audits a zero count');

-- ── buyer reads attachment metadata ─────────────────────────────────────
select is((select jsonb_array_length(m -> 'attachments')
             from jsonb_array_elements(public.read_support_ticket(current_setting('t.r1'), 's3cret') -> 'messages') m
            where m ->> 'body' = 'see photo'),
          1, 'buyer reads attachment metadata');
select is((select (m -> 'attachments' -> 0) - 'storage_path'
             from jsonb_array_elements(public.read_support_ticket(current_setting('t.r1'), 's3cret') -> 'messages') m
            where m ->> 'body' = 'see photo'),
          jsonb_build_object('attachment_id', pg_temp.slot(10), 'mime_type', 'image/jpeg'),
          'attachment id and type');
select is((select count(*)::int
             from jsonb_array_elements(public.read_support_ticket(current_setting('t.r1'), 's3cret') -> 'messages') m
            where jsonb_array_length(m -> 'attachments') = 0),
          2, 'messages without photos carry an empty list');

-- ── who downloads: Storage RLS ──────────────────────────────────────────
create function pg_temp.visible_object(p_slot uuid) returns integer language sql as $$
  select count(*)::int from storage.objects o
   where o.bucket_id = 'support-attachments'
     and o.name = 'tickets/' || current_setting('t.t1') || '/' || p_slot || '.jpg'
$$;
grant execute on function pg_temp.visible_object(uuid) to authenticated;
do $$ begin perform set_config('t.s10', pg_temp.slot(10)::text, false); end $$;
call pg_temp.as_user(2);
select is(pg_temp.visible_object(current_setting('t.s10')::uuid), 1, 'handler TM can download');
select is((select count(*)::int from public.upload_slots where id = current_setting('t.s10')::uuid), 1, 'and sees the slot');
reset role;
call pg_temp.as_user(1);
select is(pg_temp.visible_object(current_setting('t.s10')::uuid), 1, 'the ZSM can download');
reset role;
call pg_temp.as_user(3);
select is(pg_temp.visible_object(current_setting('t.s10')::uuid), 0, 'other-territory TM cannot');
reset role;
call pg_temp.as_user(5, '10000000-0000-0000-0000-000000000002');
select is(pg_temp.visible_object(current_setting('t.s10')::uuid)
          + (select count(*)::int from public.upload_slots), 0, 'another tenant''s ZSM cannot');
reset role;
call pg_temp.as_user(4);
select is(pg_temp.visible_object(current_setting('t.s10')::uuid), 0, 'A2-strict: seller cannot');
select is((select count(*)::int from public.upload_slots where ticket_id = current_setting('t.t1')::uuid),
          0, 'nor see the ORDER ticket''s slots');
select is((select count(*)::int from public.upload_slots where ticket_id = '60000000-0000-0000-0000-000000000002'),
          1, 'but sees slots on the pre-purchase ticket they handle');
reset role;
-- the helper mirrors the support_messages policy exactly, for every caller
-- (tickets that have messages, gathered as postgres, so RLS does not filter them)
do $$ begin perform set_config('t.withmsg', (select array_agg(distinct ticket_id)::text from public.support_messages), false); end $$;
create function pg_temp.mirror_ok() returns boolean language sql as $$
  select not exists (
    (select distinct ticket_id from public.support_messages
     except select f.id from public.my_support_message_ticket_ids() as f (id))
    union all
    (select f.id from public.my_support_message_ticket_ids() as f (id)
      where f.id = any (current_setting('t.withmsg')::uuid[])
     except select distinct ticket_id from public.support_messages))
$$;
grant execute on function pg_temp.mirror_ok() to authenticated;
call pg_temp.as_user(1); do $$ begin perform set_config('t.mir1', pg_temp.mirror_ok()::text, false); end $$; reset role;
call pg_temp.as_user(2); do $$ begin perform set_config('t.mir2', pg_temp.mirror_ok()::text, false); end $$; reset role;
call pg_temp.as_user(3); do $$ begin perform set_config('t.mir3', pg_temp.mirror_ok()::text, false); end $$; reset role;
call pg_temp.as_user(4); do $$ begin perform set_config('t.mir4', pg_temp.mirror_ok()::text, false); end $$; reset role;
call pg_temp.as_user(5, '10000000-0000-0000-0000-000000000002');
do $$ begin perform set_config('t.mir5', pg_temp.mirror_ok()::text, false); end $$; reset role;
select is(array[current_setting('t.mir1'), current_setting('t.mir2'), current_setting('t.mir3'),
                current_setting('t.mir4'), current_setting('t.mir5')],
          array['true', 'true', 'true', 'true', 'true'], 'my_support_message_ticket_ids mirrors the message policy');

-- ── staff attach ────────────────────────────────────────────────────────
call pg_temp.as_user(2);
select is(public.request_staff_ticket_attachment(pg_temp.k(50), current_setting('t.t1')::uuid, 'image/jpeg', 4000)
            ->> 'storage_path' like 'tickets/' || current_setting('t.t1') || '/%.jpg',
          true, 'the territory TM gets a staff slot');
select throws_ok($$select public.request_staff_ticket_attachment(pg_temp.k(51), current_setting('t.t1')::uuid, 'image/gif', 4000)$$,
  'P0001', 'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'staff type limit');
reset role;
call pg_temp.as_user(3);
select throws_ok($$select public.request_staff_ticket_attachment(pg_temp.k(52), current_setting('t.t1')::uuid, 'image/jpeg', 4000)$$,
  '42501', null, 'other-territory TM refused');
reset role;
call pg_temp.as_user(4);
select throws_ok($$select public.request_staff_ticket_attachment(pg_temp.k(53), current_setting('t.t1')::uuid, 'image/jpeg', 4000)$$,
  '42501', null, 'A2-strict: the seller cannot attach to an ORDER ticket');
reset role;
call pg_temp.as_user(1);
select throws_ok($$select public.request_staff_ticket_attachment(pg_temp.k(54), '60000000-0000-0000-0000-000000000003', 'image/jpeg', 4000)$$,
  'P0001', 'This conversation is closed. Open a new ticket if you still need help.', 'staff: closed ticket refused');
reset role;
select is((select row(uploaded_by_type, uploaded_by)::text from public.upload_slots where id = pg_temp.slot(50)),
          row('STAFF', '20000000-0000-0000-0000-000000000002'::uuid)::text, 'a staff slot names its uploader');
do $$ begin perform pg_temp.upload(pg_temp.slot(50)); end $$;
do $$ begin perform pg_temp.upload(pg_temp.slot(12)); end $$;
do $$ begin perform set_config('t.s50', pg_temp.slot(50)::text, false), set_config('t.s12', pg_temp.slot(12)::text, false); end $$;
call pg_temp.as_user(2);
select throws_ok($$select public.reply_ticket(pg_temp.k(55), current_setting('t.t1')::uuid, 'here', array[current_setting('t.s12')::uuid])$$,
  'P0001', 'That photo isn''t available.', 'staff cannot claim a buyer slot');
select lives_ok($$select public.reply_ticket(pg_temp.k(56), current_setting('t.t1')::uuid, 'staff photo', array[current_setting('t.s50')::uuid])$$,
  'staff attaches a photo');
reset role;
select throws_ok($$select public.add_ticket_message(pg_temp.k(57), current_setting('t.r1'), 's3cret', 'mine',
                                                    array[pg_temp.slot(12), pg_temp.slot(50)])$$,
  'P0001', 'That photo isn''t available.', 'a buyer cannot claim a staff slot');
select is((select (after ->> 'attachment_count')::int from public.audit_logs
            where operation = 'reply_ticket' and idempotency_key = pg_temp.k(56)),
          1, 'reply audit carries the count');
select is((select jsonb_array_length(m -> 'attachments')
             from jsonb_array_elements(public.read_support_ticket(current_setting('t.r1'), 's3cret') -> 'messages') m
            where m ->> 'body' = 'staff photo'),
          1, 'the buyer sees the staff photo');
select ok(not exists(select 1 from public.audit_logs
                      where coalesce(before::text, '') like '%tickets/%' or coalesce(after::text, '') like '%tickets/%'),
  'no paths in audit');
select ok(exists(select 1 from public.audit_logs where operation = 'request_ticket_attachment' and source = 'WEB')
      and exists(select 1 from public.audit_logs where operation = 'request_staff_ticket_attachment' and source = 'USER'),
  'slot requests are audited');

-- ── redaction deletes the buyer's photos, not the staff's ───────────────
call pg_temp.as_user(1);
select lives_ok($$select public.redact_ticket_customer_data(pg_temp.k(60), current_setting('t.t1')::uuid)$$, 'ZSM redacts');
reset role;
select is((select count(*)::int from public.upload_slots
            where ticket_id = current_setting('t.t1')::uuid and uploaded_by_type = 'CUSTOMER'),
          0, 'redaction deletes the buyer''s slots');
select is((select array_agg(q.path order by q.path) from public.storage_purge_queue q
            where q.bucket = 'support-attachments' and q.path like 'tickets/' || current_setting('t.t1') || '/%'),
          (select array_agg(p order by p) from unnest(array[pg_temp.slot(10), pg_temp.slot(11), pg_temp.slot(12), pg_temp.slot(18)]) s,
                  lateral (select 'tickets/' || current_setting('t.t1') || '/' || s ||
                                  case when s = pg_temp.slot(11) then '.png' when s = pg_temp.slot(12) then '.webp' else '.jpg' end) as x (p)),
          'and queues exactly their paths for the Storage purge');
select is((select count(*)::int from storage.objects o where o.bucket_id = 'support-attachments'
            and o.name like 'tickets/' || current_setting('t.t1') || '/%'),
          4, 'no storage.objects row is deleted in SQL');
call pg_temp.as_user(2);
select is(pg_temp.visible_object(current_setting('t.s10')::uuid), 0, 'a redacted photo is invisible to the handler TM at once');
select is(pg_temp.visible_object(current_setting('t.s50')::uuid), 1, 'the staff photo stays visible');
reset role;
call pg_temp.as_user(1);
select is(pg_temp.visible_object(current_setting('t.s10')::uuid), 0, 'and to the ZSM');
reset role;
select is((select (after ->> 'attachments_deleted')::int from public.audit_logs
            where operation = 'TICKET_DATA_REDACTED' and idempotency_key = pg_temp.k(60)),
          4, 'the redaction audit counts the deleted photos');

-- ── nightly cleanup of stale pending slots ──────────────────────────────
update public.upload_slots set created_at = now() - interval '25 hours'
 where ticket_id = '60000000-0000-0000-0000-000000000004';
do $$ begin perform pg_temp.upload((select id from public.upload_slots where ticket_id = '60000000-0000-0000-0000-000000000004' limit 1)); end $$;
-- an old object with no slot (uploaded after its slot went) and a fresh one
insert into storage.objects (bucket_id, name, metadata, created_at) values
  ('support-attachments', 'tickets/60000000-0000-0000-0000-000000000004/old-orphan.jpg',
   '{"size": 1, "mimetype": "image/jpeg"}', now() - interval '25 hours'),
  ('support-attachments', 'tickets/60000000-0000-0000-0000-000000000004/fresh-orphan.jpg',
   '{"size": 1, "mimetype": "image/jpeg"}', now());
select is(public.cleanup_pending_upload_slots(), 10, 'stale pending slots cleaned');
select is((select count(*)::int from public.upload_slots where ticket_id = '60000000-0000-0000-0000-000000000004'),
          0, 'their rows are gone');
select is((select count(*)::int from public.storage_purge_queue
            where path like 'tickets/60000000-0000-0000-0000-000000000004/%' and path not like '%orphan%'),
          10, 'their paths are queued');
select is((select array_agg(path) from public.storage_purge_queue where path like '%orphan%'),
          array['tickets/60000000-0000-0000-0000-000000000004/old-orphan.jpg'],
          'an old object with no slot is queued; a fresh one is not');
select is((select count(*)::int from storage.objects where name like 'tickets/60000000-0000-0000-0000-000000000004/%'),
          3, 'the cleanup deletes no storage.objects row');
select is((select count(*)::int from public.upload_slots where id in (pg_temp.slot(21), pg_temp.slot(50))),
          2, 'fresh pending and claimed slots stay');
select is(public.cleanup_pending_upload_slots(), 0, 'a second run finds nothing new');
select is((select count(*)::int from public.storage_purge_queue), 15, 'and queues nothing twice');
select ok(exists(select 1 from cron.job where jobname = 'cleanup-upload-slots' and schedule = '45 0 * * *'),
  'cleanup scheduled');

-- ── the purge queue API (service_role) ──────────────────────────────────
insert into public.storage_purge_queue (bucket, path, queued_at)
values ('delivery-proofs', 'orders/x/oldest.jpg', now() - interval '2 days');
set local role service_role;
select is(public.storage_purge_batch(1) -> 0 ->> 'path', 'orders/x/oldest.jpg', 'batch is oldest first');
select is(jsonb_array_length(public.storage_purge_batch()), 16, 'the default batch takes up to 100');
select is((select array_agg(k order by k) from jsonb_object_keys(public.storage_purge_batch(1) -> 0) k),
          array['bucket', 'id', 'path'], 'each item is {id, bucket, path}');
select is(public.storage_purge_done((select array_agg((e ->> 'id')::uuid)
                                       from jsonb_array_elements(public.storage_purge_batch(5)) e)),
          5, 'done removes the finished rows');
select is(jsonb_array_length(public.storage_purge_batch(1000)), 11, 'the rest stay queued');
reset role;
select ok(not has_function_privilege('anon', 'public.storage_purge_batch(integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.storage_purge_batch(integer)', 'execute')
      and not has_function_privilege('anon', 'public.storage_purge_done(uuid[])', 'execute')
      and not has_function_privilege('authenticated', 'public.storage_purge_done(uuid[])', 'execute')
      and has_function_privilege('service_role', 'public.storage_purge_batch(integer)', 'execute')
      and has_function_privilege('service_role', 'public.storage_purge_done(uuid[])', 'execute'),
  'the purge RPCs are service_role only');
select ok(not has_table_privilege('anon', 'public.storage_purge_queue', 'select')
      and not has_table_privilege('authenticated', 'public.storage_purge_queue', 'select')
      and not has_table_privilege('service_role', 'public.storage_purge_queue', 'select')
      and (select relrowsecurity from pg_class where oid = 'public.storage_purge_queue'::regclass)
      and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'storage_purge_queue'),
  'nobody reads the queue directly');
select ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public'
                         and (p.prosrc ilike '%allow_delete_query%' or p.prosrc ~* 'delete\s+from\s+storage\.')),
  'no public function deletes from storage');

select ok(exists(select 1 from cron.job where jobname = 'storage-purge' and schedule = '*/15 * * * *'),
  'storage-purge cron runs every 15 minutes');

select * from finish();
rollback;
