-- Addendum A5 §5 — web-order fulfilment: dispatch, the delivery PIN and its
-- lockout, field and courier delivery, delivery photos, and the damage window.
begin;
create extension if not exists pgtap with schema extensions;

select plan(138);

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

-- ── fixtures ────────────────────────────────────────────────────────────
-- TEAFAIR: ZSM (1), Ikeja TM (2), Epe TM (3), Ikeja DSA (4), M (5: an Epe DSM
-- who manages warehouse W), Epe DSA (7), M3 (8: an Epe DSM who manages W2).
-- UNILEVER: M2 (6: a ZSM who manages UNILEVER's warehouse W9).
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0')
  from generate_series(1, 8) n;
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
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSM', null, '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000006',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007',
   'DSA', null, '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008',
   'DSM', null, '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005'),
  ('70000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'REG-EPE', 'REGIONAL',
   '40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008'),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'UNI-LAGOS', 'CENTRAL',
   null, '20000000-0000-0000-0000-000000000006');
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
-- O1..O4 PAID Ikeja web orders fulfilled from W; O5 still PENDING
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id)
select ('90000000-0000-0000-0000-00000000000' || n)::uuid, '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
       '20000000-0000-0000-0000-000000000004', 2500, case when n = 5 then 'PENDING' else 'PAID' end, 'PAYSTACK_WEB',
       'TF-AAAAA' || n, md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001',
       '70000000-0000-0000-0000-000000000001'
  from generate_series(1, 5) n;
insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone)
select ('90000000-0000-0000-0000-00000000000' || n)::uuid, '7eaf0000-0000-4000-8000-000000000001',
       '40000000-0000-0000-0000-000000000001', 'Buyer ' || n, '+23480111111' || lpad(n::text, 2, '0')
  from generate_series(1, 5) n;
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, paystack_reference)
select ('91000000-0000-0000-0000-00000000000' || n)::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('90000000-0000-0000-0000-00000000000' || n)::uuid, '20000000-0000-0000-0000-000000000004', 2500,
       'TFW-00000000-0000-0000-0000-00000000000' || n
  from generate_series(1, 5) n;

create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('a7000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.o(n integer) returns uuid language sql as
  $$ select ('90000000-0000-0000-0000-00000000000' || n)::uuid $$;
create function pg_temp.dispatch(p_key integer, p_order integer, p_pin text, p_tracking text default null)
returns jsonb language sql as
  $$ select public.mark_order_dispatched(pg_temp.k(p_key), pg_temp.o(p_order), p_tracking, p_pin, 'test-gw-secret') $$;
create function pg_temp.sent(p_key integer, p_order integer, p_channel text default 'WHATSAPP')
returns jsonb language sql as
  $$ select public.mark_delivery_pin_sent(pg_temp.k(p_key), pg_temp.o(p_order), p_channel, 'test-gw-secret') $$;
create function pg_temp.resend(p_key integer, p_order integer, p_pin text)
returns jsonb language sql as
  $$ select public.resend_delivery_pin(pg_temp.k(p_key), pg_temp.o(p_order), p_pin, 'test-gw-secret') $$;
create function pg_temp.deliver(p_key integer, p_order integer, p_pin text, p_photo uuid default null)
returns jsonb language sql as
  $$ select public.mark_order_delivered(pg_temp.k(p_key), pg_temp.o(p_order), p_pin, p_photo) $$;
create function pg_temp.photo(p_key integer, p_order integer, p_mime text default 'image/jpeg', p_size bigint default 900)
returns jsonb language sql as
  $$ select public.request_delivery_photo(pg_temp.k(p_key), pg_temp.o(p_order), p_mime, p_size) $$;
create function pg_temp.visible_photo(p_order integer) returns integer language sql as $$
  select count(*)::int from storage.objects o
   where o.bucket_id = 'delivery-proofs' and o.name like 'orders/' || pg_temp.o(p_order) || '/%'
$$;
grant execute on function pg_temp.k(integer), pg_temp.o(integer),
  pg_temp.dispatch(integer, integer, text, text), pg_temp.sent(integer, integer, text),
  pg_temp.resend(integer, integer, text), pg_temp.deliver(integer, integer, text, uuid),
  pg_temp.photo(integer, integer, text, bigint), pg_temp.visible_photo(integer) to authenticated;
-- the fulfilment row, read as postgres
create function pg_temp.f(p_order integer) returns public.order_fulfilments language sql as
  $$ select * from public.order_fulfilments where order_id = pg_temp.o(p_order) $$;
create function pg_temp.h(p_secret text) returns text language sql as
  $$ select encode(extensions.digest(p_secret, 'sha256'), 'hex') $$;
-- simulate a finished upload of a slot
create function pg_temp.upload(p_slot uuid) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  select s.bucket, s.storage_path, jsonb_build_object('size', s.size_bytes, 'mimetype', s.mime_type)
    from public.upload_slots s where s.id = p_slot
$$;
create procedure pg_temp.as_user(n integer, p_tenant uuid default '7eaf0000-0000-4000-8000-000000000001')
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0')), 'role', 'authenticated',
    'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
end $$;

-- ── schema and grants ───────────────────────────────────────────────────
select has_table('public', 'order_fulfilments', 'order_fulfilments exists');
select ok((select relrowsecurity from pg_class where oid = 'public.order_fulfilments'::regclass), 'order_fulfilments has RLS');
select ok(not has_column_privilege('authenticated', 'public.order_fulfilments', 'delivery_pin_hash', 'select'),
  'PIN hash unreadable');
select ok(has_column_privilege('authenticated', 'public.order_fulfilments', 'pin_failed_attempts', 'select')
      and has_column_privilege('authenticated', 'public.order_fulfilments', 'damage_claim_deadline', 'select')
      and has_column_privilege('authenticated', 'public.order_fulfilments', 'delivered_via', 'select'),
  'the other columns are readable');
select ok(not has_table_privilege('authenticated', 'public.order_fulfilments', 'insert')
      and not has_table_privilege('authenticated', 'public.order_fulfilments', 'update')
      and not has_table_privilege('authenticated', 'public.order_fulfilments', 'delete')
      and not has_table_privilege('anon', 'public.order_fulfilments', 'select')
      and not has_any_column_privilege('anon', 'public.order_fulfilments', 'select'),
  'no writes; anon reads nothing');
select is((select array_agg(policyname::text) from pg_policies where schemaname = 'public' and tablename = 'order_fulfilments'),
  array['order_fulfilments_select'], 'one policy');
select is((select cmd::text from pg_policies where schemaname = 'public' and tablename = 'order_fulfilments'),
  'SELECT', 'and it is SELECT');
select ok(has_function_privilege('authenticated', 'public.mark_order_dispatched(uuid,uuid,text,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.mark_delivery_pin_sent(uuid,uuid,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.resend_delivery_pin(uuid,uuid,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.mark_order_delivered(uuid,uuid,text,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.request_delivery_photo(uuid,uuid,text,bigint)', 'execute')
      and has_function_privilege('authenticated', 'public.my_fulfilment_order_ids()', 'execute')
      and has_function_privilege('authenticated', 'public.my_delivery_proof_paths()', 'execute'),
  'staff RPCs and helpers are granted to authenticated');
select ok(not has_function_privilege('anon', 'public.mark_order_dispatched(uuid,uuid,text,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.mark_order_dispatched(uuid,uuid,text,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.mark_order_delivered(uuid,uuid,text,uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.mark_order_delivered(uuid,uuid,text,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.resend_delivery_pin(uuid,uuid,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.mark_delivery_pin_sent(uuid,uuid,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.request_delivery_photo(uuid,uuid,text,bigint)', 'execute'),
  'not for anon or service_role');
select ok(not has_function_privilege('authenticated', 'public.fulfilment_can_dispatch(public.tenant_users,public.orders)', 'execute')
      and not has_function_privilege('service_role', 'public.fulfilment_can_dispatch(public.tenant_users,public.orders)', 'execute')
      and not has_function_privilege('anon', 'public.fulfilment_can_dispatch(public.tenant_users,public.orders)', 'execute')
      and not has_function_privilege('authenticated', 'public.fulfilment_delivery_path(public.tenant_users,public.orders)', 'execute')
      and not has_function_privilege('service_role', 'public.fulfilment_delivery_path(public.tenant_users,public.orders)', 'execute')
      and not has_function_privilege('anon', 'public.fulfilment_delivery_path(public.tenant_users,public.orders)', 'execute'),
  'the permission helpers are internal');
select ok(exists(select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'delivery_proofs_select' and cmd = 'SELECT' and roles = '{authenticated}'),
  'delivery-proof download policy exists');
select ok(not exists(select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                      and cmd <> 'SELECT'),
  'no client write policies on storage');
select ok((select qual from pg_policies where schemaname = 'storage' and policyname = 'delivery_proofs_select')
            like '%my_delivery_proof_paths%'
      and (select qual from pg_policies where schemaname = 'storage' and policyname = 'delivery_proofs_select')
            not like '%::uuid%',
  'the download policy requires a live slot and casts nothing');
select ok(to_regprocedure('public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)') is not null
      and has_function_privilege('service_role', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute'),
  'open_support_ticket keeps its A3 signature and grants');
select has_column('public', 'support_tickets', 'within_damage_window', 'tickets carry within_damage_window');

-- ── the gateway proof (ruling R16) ──────────────────────────────────────
select ok(not has_function_privilege('anon', 'public.assert_gateway_proof(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.assert_gateway_proof(text)', 'execute')
      and not has_function_privilege('service_role', 'public.assert_gateway_proof(text)', 'execute'),
  'assert_gateway_proof is internal');
select ok((select prosecdef and proconfig @> array['search_path=public, pg_temp'] from pg_proc
            where oid = 'public.assert_gateway_proof(text)'::regprocedure), 'and SECURITY DEFINER with a pinned search_path');
delete from vault.secrets where name = 'gateway_secret';
call pg_temp.as_user(5);
select throws_ok($$select pg_temp.dispatch(100, 1, '1234')$$, '42501', null, 'dispatch fails closed with no vault secret');
select throws_ok($$select pg_temp.resend(101, 1, '1234')$$, '42501', null, 'resend fails closed with no vault secret');
select throws_ok($$select pg_temp.sent(102, 1, 'SMS')$$, '42501', null, 'mark-sent fails closed with no vault secret');
reset role;
do $$ begin perform vault.create_secret('', 'gateway_secret'); end $$;
call pg_temp.as_user(5);
select throws_ok($$select public.mark_order_dispatched(pg_temp.k(103), pg_temp.o(1), null, '1234', '')$$, '42501', null,
  'an empty secret matches nothing');
reset role;
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;
call pg_temp.as_user(5);
select throws_ok($$select public.mark_order_dispatched(pg_temp.k(104), pg_temp.o(1), null, '1234', 'wrong-secret')$$,
  '42501', null, 'dispatch with a wrong proof');
select throws_ok($$select public.mark_order_dispatched(pg_temp.k(105), pg_temp.o(1), null, '1234', null)$$,
  '42501', null, 'dispatch with no proof');
reset role;

-- ── dispatch ────────────────────────────────────────────────────────────
call pg_temp.as_user(4);
select throws_ok($$select pg_temp.dispatch(1, 1, '1234')$$, '42501', null, 'DSA cannot dispatch');
reset role;
call pg_temp.as_user(2);
select throws_ok($$select pg_temp.dispatch(2, 1, '1234')$$, '42501', null, 'the TM cannot dispatch');
reset role;
call pg_temp.as_user(6, '10000000-0000-0000-0000-000000000002');
select throws_ok($$select pg_temp.dispatch(3, 1, '1234')$$, '42501', null, 'other tenant manager refused');
reset role;
call pg_temp.as_user(6);
select throws_ok($$select pg_temp.dispatch(4, 1, '1234')$$, '42501', null, 'other tenant manager refused in our tenant');
reset role;
call pg_temp.as_user(8);
select throws_ok($$select pg_temp.dispatch(5, 1, '1234')$$, '42501', null, 'another warehouse''s manager refused');
reset role;
call pg_temp.as_user(5);
select throws_ok($$select pg_temp.dispatch(6, 5, '1234')$$, 'P0001', 'only paid web orders can be dispatched', 'must be paid');
select throws_ok($$select pg_temp.dispatch(7, 1, '12a4')$$, 'P0001', null, 'PIN must be 4 digits');
select throws_ok($$select pg_temp.dispatch(8, 1, '12345')$$, 'P0001', null, 'not 5 digits');
select lives_ok($$select set_config('t.d1', pg_temp.dispatch(10, 1, '1234', 'GIG-778')::text, false)$$, 'manager dispatches O1');
select is(current_setting('t.d1')::jsonb ->> 'status', 'IN_TRANSIT', 'warehouse manager dispatches');
select is(current_setting('t.d1')::jsonb ->> 'public_reference', 'TF-AAAAA1', 'reply carries the public reference');
select is(pg_temp.dispatch(10, 1, '1234', 'GIG-778') ? 'buyer_phone', false, 'a replay returns no phone (the gateway sends nothing)');
select throws_ok($$select pg_temp.dispatch(11, 1, '1234')$$, 'P0001', 'only paid web orders can be dispatched',
  'an order in transit cannot be dispatched again');
reset role;
select ok(current_setting('t.d1')::jsonb ->> 'buyer_phone' = (select customer_phone from public.order_contacts where order_id = pg_temp.o(1)),
  'gateway gets the buyer phone');
select is((select status from public.orders where id = pg_temp.o(1)), 'IN_TRANSIT', 'the order is in transit');
select is((select row(f.dispatched_by, f.tracking_reference, f.pin_sent_at, f.pin_failed_attempts, f.delivered_at)::text
             from pg_temp.f(1) f),
  row('20000000-0000-0000-0000-000000000005'::uuid, 'GIG-778', null::timestamptz, 0, null::timestamptz)::text,
  'the fulfilment row is written, not yet sent');
select ok((select f.delivery_pin_hash ~ '^\$2[aby]\$' and f.delivery_pin_hash = extensions.crypt('1234', f.delivery_pin_hash)
             from pg_temp.f(1) f), 'the PIN is stored as a bcrypt hash');
select is((select after from public.audit_logs where operation = 'mark_order_dispatched' and idempotency_key = pg_temp.k(10)),
  jsonb_build_object('order_id', pg_temp.o(1), 'status', 'IN_TRANSIT', 'has_tracking', true), 'dispatch audit');
select ok((select response from public.idempotency_logs where key = pg_temp.k(10)) ? 'buyer_phone' = false,
  'the stored reply holds no phone');
call pg_temp.as_user(5);
select throws_ok($$select public.resend_delivery_pin(pg_temp.k(106), pg_temp.o(1), '1111', 'wrong-secret')$$,
  '42501', null, 'resend with a wrong proof');
select throws_ok($$select public.mark_delivery_pin_sent(pg_temp.k(107), pg_temp.o(1), 'SMS', 'test-gw-secreT')$$,
  '42501', null, 'mark-sent with a wrong proof');
select is(pg_temp.sent(12, 1, 'WHATSAPP') ->> 'order_id', pg_temp.o(1)::text, 'the gateway marks the code sent');
select throws_ok($$select pg_temp.sent(13, 1, 'EMAIL')$$, 'P0001', null, 'channel must be WHATSAPP or SMS');
reset role;
select ok((select f.pin_sent_at is not null and f.pin_resends_today = 0 from pg_temp.f(1) f),
  'the first send is not a resend');
call pg_temp.as_user(7);
select throws_ok($$select pg_temp.sent(14, 1, 'SMS')$$, '42501', null, 'another territory''s DSA cannot mark sent');
reset role;

-- ── who reads the fulfilment row ────────────────────────────────────────
call pg_temp.as_user(2);
select is((select count(*)::int from public.order_fulfilments), 1, 'the order''s TM reads it');
select throws_ok($$select delivery_pin_hash from public.order_fulfilments$$, '42501', null, 'but never the PIN hash');
reset role;
call pg_temp.as_user(5);
select is((select count(*)::int from public.order_fulfilments), 1, 'the warehouse manager reads it');
reset role;
call pg_temp.as_user(1);
select is((select count(*)::int from public.order_fulfilments), 1, 'the ZSM reads it');
reset role;
call pg_temp.as_user(3);
select is((select count(*)::int from public.order_fulfilments), 0, 'another territory''s TM does not');
reset role;
call pg_temp.as_user(8);
select is((select count(*)::int from public.order_fulfilments), 0, 'another warehouse''s manager does not');
reset role;
call pg_temp.as_user(6, '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.order_fulfilments), 0, 'another tenant does not');
reset role;

-- ── delivery: wrong codes and the lockout ───────────────────────────────
call pg_temp.as_user(7);
select throws_ok($$select pg_temp.deliver(19, 1, '1234')$$, '42501', null, 'other territory refused');
reset role;
call pg_temp.as_user(8);
select throws_ok($$select pg_temp.deliver(18, 1, '1234')$$, '42501', null, 'another warehouse''s manager cannot deliver');
reset role;
call pg_temp.as_user(6, '10000000-0000-0000-0000-000000000002');
select throws_ok($$select pg_temp.deliver(17, 1, '1234')$$, '42501', null, 'another tenant''s manager cannot deliver');
reset role;
call pg_temp.as_user(4);
select throws_ok($$select pg_temp.deliver(16, 1, '12x4')$$, 'P0001', null, 'a malformed code is refused');
select is(pg_temp.deliver(20, 1, '0000'), jsonb_build_object('order_id', pg_temp.o(1), 'status', 'IN_TRANSIT', 'error', 'WRONG_PIN'),
  'wrong pin reported');
reset role;
select is((select pin_failed_attempts from pg_temp.f(1)), 1, 'failure recorded');
call pg_temp.as_user(4);
select is(pg_temp.deliver(20, 1, '0000') ->> 'error', 'WRONG_PIN', 'a replay returns the same reply');
reset role;
select is((select row(pin_failed_attempts, pin_lifetime_failures)::text from pg_temp.f(1)), row(1, 1)::text,
  'and counts nothing more');
call pg_temp.as_user(4);
select is(pg_temp.deliver(20, 1, '1234') ->> 'error', 'WRONG_PIN',
  'replaying a WRONG_PIN key with the right code returns the stored reply');
reset role;
select is((select status from public.orders where id = pg_temp.o(1)) || '/' || (select pin_lifetime_failures from pg_temp.f(1)),
  'IN_TRANSIT/1', 'and neither delivers nor counts');
call pg_temp.as_user(4);
do $$ begin for i in 21..23 loop perform pg_temp.deliver(i, 1, '0000'); end loop; end $$;
select is(pg_temp.deliver(24, 1, '0000') ->> 'error', 'LOCKED', 'locks after 5');
select is(pg_temp.deliver(25, 1, '1234') ->> 'error', 'LOCKED', 'locked refuses right pin');
reset role;
select ok((select f.pin_locked_until > now() + interval '29 minutes' and f.pin_locked_until <= now() + interval '30 minutes'
                  and f.pin_failed_attempts = 0 and f.pin_lifetime_failures = 5 and not f.pin_zsm_lock
             from pg_temp.f(1) f), 'a 30-minute lock; the window count restarts; the lifetime count stays');
select is((select status from public.orders where id = pg_temp.o(1)), 'IN_TRANSIT', 'still in transit');
update public.order_fulfilments set pin_locked_until = now() - interval '1 minute' where order_id = pg_temp.o(1);
call pg_temp.as_user(4);
do $$ begin for i in 26..29 loop perform pg_temp.deliver(i, 1, '0000'); end loop; end $$;
select is(pg_temp.deliver(30, 1, '0000') ->> 'error', 'LOCKED', 'lifetime lock');
reset role;
select ok((select f.pin_zsm_lock and f.pin_lifetime_failures = 10 from pg_temp.f(1) f), 'ten lifetime failures set the ZSM lock');
update public.order_fulfilments set pin_locked_until = null where order_id = pg_temp.o(1);
call pg_temp.as_user(4);
select is(pg_temp.deliver(31, 1, '1234') ->> 'error', 'LOCKED', 'the ZSM lock holds without the 30-minute lock');
reset role;
select is((select pin_lifetime_failures from pg_temp.f(1)), 10, 'a locked attempt is not counted');
-- a TM resend changes the code but not the locks
call pg_temp.as_user(2);
select is(pg_temp.resend(32, 1, '4321') ->> 'public_reference', 'TF-AAAAA1', 'the TM resends');
select is(pg_temp.sent(33, 1, 'SMS') ->> 'order_id', pg_temp.o(1)::text, 'and the resend is marked sent');
reset role;
call pg_temp.as_user(4);
select is(pg_temp.deliver(34, 1, '4321') ->> 'error', 'LOCKED', 'non-ZSM resend does not clear the lifetime lock');
reset role;
select ok((select f.pin_zsm_lock and f.pin_lifetime_failures = 10 and f.pin_resends_today = 1
                  and f.delivery_pin_hash = extensions.crypt('4321', f.delivery_pin_hash) from pg_temp.f(1) f),
  'the TM resend set a new hash, counted once, left the locks');
-- the ZSM resend clears every lock
call pg_temp.as_user(1);
select ok(pg_temp.resend(35, 1, '5678') ? 'buyer_phone', 'the ZSM resends; the gateway gets the phone');
select lives_ok($$select pg_temp.sent(36, 1, 'WHATSAPP')$$, 'marked sent');
reset role;
select is((select row(pin_failed_attempts, pin_locked_until, pin_lifetime_failures, pin_zsm_lock)::text from pg_temp.f(1)),
  row(0, null::timestamptz, 0, false)::text, 'the ZSM resend resets every counter and lock');
call pg_temp.as_user(4);
select lives_ok($$select set_config('t.dv1', pg_temp.deliver(37, 1, '5678')::text, false)$$, 'the DSA enters the code');
select is(current_setting('t.dv1')::jsonb ->> 'status', 'DELIVERED', 'ZSM resend unlocks; delivery succeeds');
select throws_ok($$select pg_temp.deliver(38, 1, '5678')$$, 'P0001', null, 'a delivered order cannot be delivered again');
select throws_ok($$select pg_temp.resend(39, 1, '1111')$$, 'P0001', null, 'nor get a new code');
reset role;
select ok((select f.damage_claim_deadline = f.delivered_at + interval '24 hours' and f.delivered_via = 'FIELD_STAFF'
                  and f.delivered_by = '20000000-0000-0000-0000-000000000004'
             from pg_temp.f(1) f), 'window started');
select is((select status from public.orders where id = pg_temp.o(1)), 'DELIVERED', 'the order is delivered');
select is((select array_agg(k order by k) from jsonb_object_keys(current_setting('t.dv1')::jsonb) k),
  array['damage_claim_deadline', 'delivered_at', 'delivered_via', 'order_id', 'status'], 'the delivery reply');
select is((select after from public.audit_logs where operation = 'mark_order_delivered' and idempotency_key = pg_temp.k(37)),
  jsonb_build_object('order_id', pg_temp.o(1), 'status', 'DELIVERED', 'pin_verified', true, 'has_photo', false,
                     'delivered_via', 'FIELD_STAFF'), 'delivery audit');
select ok(exists(select 1 from public.audit_logs where operation = 'DELIVERY_PIN_FAILED' and idempotency_key = pg_temp.k(20)),
  'a wrong code is audited');

-- ── courier path: O2 dispatched and delivered by the warehouse manager ──
call pg_temp.as_user(5);
select lives_ok($$select pg_temp.dispatch(40, 2, '2468')$$, 'M dispatches O2');
select is(pg_temp.deliver(41, 2, '2468') ->> 'delivered_via', 'COURIER', 'courier delivery by warehouse manager');
reset role;
select is((select delivered_via from pg_temp.f(2)), 'COURIER', 'recorded as courier');
-- the ZSM may dispatch too; O4 is for the resend limit
call pg_temp.as_user(1);
select lives_ok($$select pg_temp.dispatch(42, 4, '1357')$$, 'a ZSM dispatches');
reset role;

-- ── delivery photos (O3) ────────────────────────────────────────────────
call pg_temp.as_user(4);
select throws_ok($$select pg_temp.photo(50, 3)$$, 'P0001', null, 'no photo before dispatch');
reset role;
call pg_temp.as_user(5);
select lives_ok($$select pg_temp.dispatch(51, 3, '9753')$$, 'M dispatches O3');
reset role;
call pg_temp.as_user(4);
select lives_ok($$select set_config('t.p1', pg_temp.photo(52, 3)::text, false)$$, 'the DSA requests a photo slot');
select is(current_setting('t.p1')::jsonb ->> 'storage_path',
  'orders/' || pg_temp.o(3) || '/' || (current_setting('t.p1')::jsonb ->> 'attachment_id') || '.jpg',
  'path is orders/<order>/<slot>.jpg');
select throws_ok($$select pg_temp.photo(53, 3, 'image/gif')$$, 'P0001',
  'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'type limit');
select throws_ok($$select pg_temp.photo(54, 3, 'image/png', 5242881)$$, 'P0001',
  'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'size limit');
reset role;
call pg_temp.as_user(7);
select throws_ok($$select pg_temp.photo(55, 3)$$, '42501', null, 'another territory''s DSA cannot request a photo');
reset role;
call pg_temp.as_user(5);
select lives_ok($$select set_config('t.p2', pg_temp.photo(56, 3)::text, false)$$, 'M requests a photo slot');
reset role;
select is((select row(purpose, bucket, order_id, uploaded_by_type, uploaded_by, claimed_at)::text
             from public.upload_slots where id = (current_setting('t.p1')::jsonb ->> 'attachment_id')::uuid),
  row('DELIVERY_PROOF', 'delivery-proofs', pg_temp.o(3), 'STAFF', '20000000-0000-0000-0000-000000000004'::uuid,
      null::timestamptz)::text, 'a pending delivery-proof slot');
call pg_temp.as_user(4);
select throws_ok(format($$select pg_temp.deliver(57, 3, '9753', %L)$$, current_setting('t.p1')::jsonb ->> 'attachment_id'),
  'P0001', 'That photo hasn''t finished uploading.', 'the object must exist');
select throws_ok(format($$select pg_temp.deliver(58, 3, '9753', %L)$$, current_setting('t.p2')::jsonb ->> 'attachment_id'),
  'P0001', 'That photo isn''t available.', 'only the uploader''s own slot');
reset role;
do $$ begin perform pg_temp.upload((current_setting('t.p1')::jsonb ->> 'attachment_id')::uuid); end $$;
call pg_temp.as_user(4);
select is(pg_temp.deliver(59, 3, '0000', (current_setting('t.p1')::jsonb ->> 'attachment_id')::uuid) ->> 'error',
  'WRONG_PIN', 'a wrong code with a photo');
reset role;
select is((select claimed_at from public.upload_slots where id = (current_setting('t.p1')::jsonb ->> 'attachment_id')::uuid),
  null, 'leaves the slot pending');
call pg_temp.as_user(4);
select lives_ok(format($$select pg_temp.deliver(60, 3, '9753', %L)$$, current_setting('t.p1')::jsonb ->> 'attachment_id'),
  'photo claimed on delivery');
reset role;
select ok((select s.claimed_at is not null from public.upload_slots s
            where s.id = (current_setting('t.p1')::jsonb ->> 'attachment_id')::uuid)
      and (select delivery_photo_path from pg_temp.f(3)) = current_setting('t.p1')::jsonb ->> 'storage_path',
  'the slot is claimed and its path recorded');
select is((select (after ->> 'has_photo')::boolean from public.audit_logs
            where operation = 'mark_order_delivered' and idempotency_key = pg_temp.k(60)), true, 'audited with a photo');
call pg_temp.as_user(2); do $$ begin perform set_config('t.v2', pg_temp.visible_photo(3)::text, false); end $$; reset role;
call pg_temp.as_user(5); do $$ begin perform set_config('t.v5', pg_temp.visible_photo(3)::text, false); end $$; reset role;
call pg_temp.as_user(4); do $$ begin perform set_config('t.v4', pg_temp.visible_photo(3)::text, false); end $$; reset role;
call pg_temp.as_user(1); do $$ begin perform set_config('t.v1', pg_temp.visible_photo(3)::text, false); end $$; reset role;
select is(array[current_setting('t.v2'), current_setting('t.v5'), current_setting('t.v4'), current_setting('t.v1')]::int[],
  array[1, 1, 1, 1], 'photo readers');
call pg_temp.as_user(3);
select is(pg_temp.visible_photo(3), 0, 'others cannot see the photo');
reset role;
call pg_temp.as_user(7);
select is(pg_temp.visible_photo(3) + (select count(*)::int from public.upload_slots), 0,
  'nor its slot (another territory''s DSA)');
reset role;
call pg_temp.as_user(2);
select is((select count(*)::int from public.upload_slots where purpose = 'DELIVERY_PROOF'), 2, 'the TM sees the order''s slots');
reset role;
call pg_temp.as_user(4);
select is((select count(*)::int from public.upload_slots where purpose = 'DELIVERY_PROOF'), 1, 'the uploader sees their own slot');
reset role;
-- a photo whose slot is gone is unreadable at once
delete from public.upload_slots where id = (current_setting('t.p1')::jsonb ->> 'attachment_id')::uuid;
call pg_temp.as_user(2);
select is(pg_temp.visible_photo(3), 0, 'no live slot, no download');
reset role;

-- ── fail closed: no fulfilment row, or not a web order (set up as postgres) ─
-- O6: ONLINE and IN_TRANSIT with no fulfilment row; O7: a FIELD_SALES order in
-- transit with a fulfilment row and a known code
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  (pg_temp.o(6), '7eaf0000-0000-4000-8000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000004', 2500,
   'IN_TRANSIT', 'PAYSTACK_WEB', 'TF-AAAAA6', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001',
   '70000000-0000-0000-0000-000000000001'),
  (pg_temp.o(7), '7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES', '20000000-0000-0000-0000-000000000004', 2500,
   'IN_TRANSIT', null, null, null, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001');
insert into public.order_fulfilments (order_id, tenant_id, dispatched_by, delivery_pin_hash)
values (pg_temp.o(7), '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
        extensions.crypt('2222', extensions.gen_salt('bf')));
call pg_temp.as_user(4);
select throws_ok($$select pg_temp.deliver(61, 6, '1234')$$, 'P0001', 'this order has no delivery record',
  'an in-transit web order with no fulfilment row is refused');
select throws_ok($$select pg_temp.resend(62, 6, '1234')$$, 'P0001', 'this order has no delivery record',
  'and gets no new code');
select throws_ok($$select pg_temp.photo(63, 6)$$, 'P0001', 'this order has no delivery record', 'nor a photo slot');
select throws_ok($$select pg_temp.deliver(64, 7, '2222')$$, 'P0001', 'only orders in transit can be delivered',
  'a non-web order is refused by deliver');
select throws_ok($$select pg_temp.resend(65, 7, '3333')$$, 'P0001', 'only orders in transit can get a new delivery code',
  'and by resend');
reset role;
select is((select array_agg(status order by id) from public.orders where id in (pg_temp.o(6), pg_temp.o(7))),
  array['IN_TRANSIT', 'IN_TRANSIT'], 'both stay in transit');

-- ── the damage window on ORDER tickets ──────────────────────────────────
do $$ begin
  perform set_config('t.tk1', public.open_support_ticket(pg_temp.k(70), 'ORDER', 'DELIVERY', 'It arrived broken',
           jsonb_build_object('name', 'Ada', 'phone', '+2348022222201'),
           'TF-AAAAA1', 'TFW-00000000-0000-0000-0000-000000000001', null, pg_temp.h('s1')) ->> 'ticket_id', false);
  perform set_config('t.tk2', public.open_support_ticket(pg_temp.k(71), 'ORDER', 'PAYMENT', 'Charged twice',
           jsonb_build_object('name', 'Ada', 'phone', '+2348022222202'),
           'TF-AAAAA1', 'TFW-00000000-0000-0000-0000-000000000001', null, pg_temp.h('s2')) ->> 'ticket_id', false);
  perform set_config('t.tk3', public.open_support_ticket(pg_temp.k(72), 'ORDER', 'PRODUCT', 'Not here yet',
           jsonb_build_object('name', 'Bola', 'phone', '+2348022222203'),
           'TF-AAAAA4', 'TFW-00000000-0000-0000-0000-000000000004', null, pg_temp.h('s3')) ->> 'ticket_id', false);
end $$;
select is((select within_damage_window from public.support_tickets where id = current_setting('t.tk1')::uuid), true, 'inside window');
select is((select within_damage_window from public.support_tickets where id = current_setting('t.tk2')::uuid), null,
  'not applicable to a payment ticket');
select is((select within_damage_window from public.support_tickets where id = current_setting('t.tk3')::uuid), null,
  'not applicable before delivery');
update public.order_fulfilments set delivered_at = now() - interval '25 hours', damage_claim_deadline = now() - interval '1 hour'
 where order_id = pg_temp.o(1);
do $$ begin
  perform set_config('t.tk4', public.open_support_ticket(pg_temp.k(73), 'ORDER', 'PRODUCT', 'Spoiled',
           jsonb_build_object('name', 'Ada', 'phone', '+2348022222204'),
           'TF-AAAAA1', 'TFW-00000000-0000-0000-0000-000000000001', null, pg_temp.h('s4')) ->> 'ticket_id', false);
end $$;
select is((select within_damage_window from public.support_tickets where id = current_setting('t.tk4')::uuid), false, 'outside window');

-- ── the resend limit (O4) ───────────────────────────────────────────────
call pg_temp.as_user(4);
select lives_ok($$do $x$ begin perform pg_temp.resend(80, 4, '1111'); perform pg_temp.sent(81, 4, 'SMS'); end $x$ $$,
  'the DSA resends (1)');
reset role;
call pg_temp.as_user(5);
select lives_ok($$do $x$ begin perform pg_temp.resend(82, 4, '2222'); perform pg_temp.sent(83, 4, 'SMS'); end $x$ $$,
  'the manager resends (2)');
reset role;
call pg_temp.as_user(2);
select lives_ok($$select pg_temp.resend(84, 4, '3333')$$, 'a resend whose message failed (not counted)');
select lives_ok($$do $x$ begin perform pg_temp.resend(85, 4, '3334'); perform pg_temp.sent(86, 4, 'SMS'); end $x$ $$,
  'the TM resends (3)');
select throws_ok($$select pg_temp.resend(87, 4, '4444')$$, 'P0001', 'Too many codes sent today. Ask a ZSM.', 'resend limit');
reset role;
select is((select pin_resends_today from pg_temp.f(4)), 3, 'three resends counted');
call pg_temp.as_user(1);
select lives_ok($$select pg_temp.resend(88, 4, '5555')$$, 'a ZSM is not limited');
reset role;
call pg_temp.as_user(7);
select throws_ok($$select pg_temp.resend(89, 4, '6666')$$, '42501', null, 'another territory''s DSA cannot resend');
reset role;
update public.order_fulfilments set pin_resend_day = pin_resend_day - 1 where order_id = pg_temp.o(4);
call pg_temp.as_user(2);
select lives_ok($$select pg_temp.resend(90, 4, '7777')$$, 'the limit is per day');
reset role;

-- ── privacy ─────────────────────────────────────────────────────────────
select ok(not exists(select 1 from public.audit_logs
                      where operation in ('mark_order_dispatched', 'mark_delivery_pin_sent', 'resend_delivery_pin',
                                          'mark_order_delivered', 'DELIVERY_PIN_FAILED', 'request_delivery_photo')
                        and (coalesce(before::text, '') ~ '1234|5678|4321|9753|2468|1357|\$2[aby]\$'
                          or coalesce(after::text, '') ~ '1234|5678|4321|9753|2468|1357|\$2[aby]\$')),
  'no PIN in audit');
select ok(not exists(select 1 from public.audit_logs
                      where coalesce(before::text, '') || coalesce(after::text, '') ~ '\+23480111111|orders/'),
  'no buyer phone or storage path in audit');
select ok(not exists(select 1 from public.audit_logs
                      where coalesce(before::text, '') || coalesce(after::text, '') like '%test-gw-secret%')
      and not exists(select 1 from public.idempotency_logs where response::text like '%test-gw-secret%'),
  'the gateway proof never appears in audit rows or stored replies');
select ok(not exists(select 1 from public.idempotency_logs
                      where operation in ('mark_order_dispatched', 'resend_delivery_pin')
                        and response::text like '%+23480111111%'),
  'no buyer phone in stored replies');

select * from finish();
rollback;
