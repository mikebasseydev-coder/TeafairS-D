-- Addendum A3 §4–5 — buyer RPCs: open, read, post; the shared order-pair lookup.
begin;
create extension if not exists pgtap with schema extensions;

select plan(41);

-- ── fixtures: TEAFAIR with Ikeja, TM, ZSM, a default agent, one routed order ──
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'FINTECH_AGENT', null, '40000000-0000-0000-0000-000000000001', 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
insert into public.tenant_settings (tenant_id, web_default_agent_id)
values ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003')
on conflict (tenant_id) do update set web_default_agent_id = excluded.web_default_agent_id;
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
values ('7eaf0000-0000-4000-8000-000000000001', 'LA', md5('ng_lga:LA:Ikeja')::uuid,
        '40000000-0000-0000-0000-000000000001');

-- a routed ONLINE order TF-AAAAAA (payment TFW-…0a) and a legacy CANCELLED one
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000002', 2500, 'PENDING', 'PAYSTACK_WEB', 'TF-AAAAAA',
   md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001');
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference) values
  ('90000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000002', 1000, 'CANCELLED', 'PAYSTACK_WEB', 'TF-AAAAAB');
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, paystack_reference) values
  ('91000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 2500, 'TFW-00000000-0000-0000-0000-00000000000a'),
  ('91000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '90000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002', 1000, 'TFW-00000000-0000-0000-0000-00000000000b');

create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('a0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.h(p_secret text) returns text language sql as
  $$ select encode(extensions.digest(p_secret, 'sha256'), 'hex') $$;
-- the public reference a key's reply carried
create function pg_temp.ref_of(n integer) returns text language sql as
  $$ select r.response ->> 'public_reference' from public.idempotency_logs r where r.key = pg_temp.k(n) $$;
-- open wrapper: a PAYMENT ticket from a named phone
create function pg_temp.op(p_key integer, p_kind text, p_phone text, p_ord text, p_pay text, p_lga uuid,
                           p_hash text default null)
returns jsonb language sql as $$
  select public.open_support_ticket(pg_temp.k(p_key), p_kind, 'PAYMENT', 'Hello there',
           jsonb_build_object('name', 'Ada', 'phone', p_phone, 'email', 'Ada@Example.com'),
           p_ord, p_pay, p_lga, coalesce(p_hash, pg_temp.h('s3cret')))
$$;

-- ── open: order tickets ─────────────────────────────────────────────────
select is(pg_temp.op(1, 'ORDER', '+2348011111111', 'TF-AAAAAA', 'TFW-00000000-0000-0000-0000-00000000000a', null) ->> 'status',
          'OPEN', 'order ticket opened');
create temp table t1 on commit drop as
  select * from public.support_tickets where public_reference = pg_temp.ref_of(1);
select is((select row(t.kind, t.tenant_id, t.territory_id, t.accountable_id, t.order_id)::text
             from public.support_tickets t where t.id = (select id from t1)),
          row('ORDER', '7eaf0000-0000-4000-8000-000000000001'::uuid, '40000000-0000-0000-0000-000000000001'::uuid,
              '20000000-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000001'::uuid)::text,
          'routed from the order');
select is((select c.territory_id is not distinct from t.territory_id and c.territory_id is not null
             from public.support_ticket_contacts c join public.support_tickets t on t.id = c.ticket_id
            where t.id = (select id from t1)), true, 'contacts copy the territory');
select throws_ok($$select pg_temp.op(2, 'ORDER', '+2348011111112', 'TF-AAAAAA',
                     'TFW-00000000-0000-0000-0000-00000000000b', null)$$,
  'P0001', 'NOT_FOUND', 'mismatched pair');
select is(pg_temp.op(3, 'ORDER', '+2348011111113', 'tf-aaaaaa', 'TFW-00000000-0000-0000-0000-00000000000A', null) ->> 'status',
          'OPEN', 'pair is case-insensitive on the Paystack reference');
do $$ begin
  perform pg_temp.op(4, 'ORDER', '+2348011111114', 'TF-AAAAAB', 'TFW-00000000-0000-0000-0000-00000000000b', null);
end $$;
select is((select count(*)::int from public.support_tickets t
            where t.public_reference = pg_temp.ref_of(4) and t.territory_id is null
              and t.accountable_id = '20000000-0000-0000-0000-000000000002'),
          1, 'no territory → ZSM queue (Decision 5)');

-- ── open: pre-purchase ──────────────────────────────────────────────────
do $$ begin
  perform pg_temp.op(5, 'PRE_PURCHASE', '+2348022222221', null, null, md5('ng_lga:LA:Ikeja')::uuid);
  perform pg_temp.op(6, 'PRE_PURCHASE', '+2348022222222', null, null, md5('ng_lga:KN:Fagge')::uuid);
end $$;
select is((select row(t.tenant_id, t.territory_id, t.accountable_id)::text from public.support_tickets t
            where t.public_reference = pg_temp.ref_of(5)),
          row('7eaf0000-0000-4000-8000-000000000001'::uuid, '40000000-0000-0000-0000-000000000001'::uuid,
              '20000000-0000-0000-0000-000000000002'::uuid)::text,
          'pre-purchase routed');
select is((select row(t.territory_id, t.accountable_id)::text from public.support_tickets t
            where t.public_reference = pg_temp.ref_of(6)),
          row(null::uuid, '20000000-0000-0000-0000-000000000003'::uuid)::text,
          'unroutable → default agent');
update public.tenant_settings set web_default_agent_id = null
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001';
do $$ begin
  perform pg_temp.op(7, 'PRE_PURCHASE', '+2348022222223', null, null, md5('ng_lga:KN:Fagge')::uuid);
end $$;
select is((select t.accountable_id from public.support_tickets t where t.public_reference = pg_temp.ref_of(7)),
          null, 'else ZSM queue');
select is((select count(*)::int from public.notifications n
            where n.kind = 'SUPPORT_TICKET_ACTIVITY' and n.user_id = '20000000-0000-0000-0000-000000000001'
              and n.payload ->> 'public_reference' = pg_temp.ref_of(7)),
          1, 'unassigned and unaccountable → every ZSM notified');
select throws_ok($$select pg_temp.op(8, 'ORDER', '+2348011111118', 'TF-AAAAAA',
                     'TFW-00000000-0000-0000-0000-00000000000a', md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'exactly one of order or location');
select throws_ok($$select pg_temp.op(9, 'PRE_PURCHASE', '+2348011111119', null, null, null)$$,
  'P0001', null, 'a pre-purchase ticket needs a location');
select throws_ok($$select pg_temp.op(10, 'PRE_PURCHASE', '12345', null, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', null, 'phone must be E.164');

-- ── replay ──────────────────────────────────────────────────────────────
select is(pg_temp.op(1, 'ORDER', '+2348011111111', 'TF-AAAAAA', 'TFW-00000000-0000-0000-0000-00000000000a', null,
                     pg_temp.h('another')) ->> 'ticket_id',
          (select id::text from t1), 'replay ignores a new secret hash');
select is((select s.secret_hash from public.support_ticket_secrets s where s.ticket_id = (select id from t1)),
          pg_temp.h('s3cret'), 'first secret is kept');

-- ── throttles ───────────────────────────────────────────────────────────
do $$ begin
  perform pg_temp.op(20, 'PRE_PURCHASE', '+2348033333333', null, null, md5('ng_lga:LA:Ikeja')::uuid);
  perform pg_temp.op(21, 'PRE_PURCHASE', '+2348033333333', null, null, md5('ng_lga:LA:Ikeja')::uuid);
  perform pg_temp.op(22, 'PRE_PURCHASE', '+2348033333333', null, null, md5('ng_lga:LA:Ikeja')::uuid);
end $$;
select throws_ok($$select pg_temp.op(23, 'PRE_PURCHASE', '+2348033333333', null, null, md5('ng_lga:LA:Ikeja')::uuid)$$,
  'P0001', 'Too many messages. Please wait a few minutes.', 'phone throttle');
-- the order already has two open tickets (keys 1 and 3)
select lives_ok($$select pg_temp.op(24, 'ORDER', '+2348044444441', 'TF-AAAAAA',
                    'TFW-00000000-0000-0000-0000-00000000000a', null)$$, 'third open ticket on the order is allowed');
select throws_ok($$select pg_temp.op(25, 'ORDER', '+2348044444442', 'TF-AAAAAA',
                     'TFW-00000000-0000-0000-0000-00000000000a', null)$$,
  'P0001', 'Too many messages. Please wait a few minutes.', 'order throttle');

-- ── audit and notification privacy ──────────────────────────────────────
select ok((select not (a.after ? 'message') and a.after::text !~ '2348011111111' and a.after::text !~ 'Hello there'
                  and a.after ->> 'phone_last4' = '1111' and (a.after ->> 'has_email')::boolean
                  and a.source = 'WEB'
             from public.audit_logs a where a.idempotency_key = pg_temp.k(1) and a.operation = 'open_support_ticket'),
  'audit carries no text or phone');
select is((select count(*)::int from public.notifications n
            where n.kind = 'SUPPORT_TICKET_ACTIVITY' and n.user_id = '20000000-0000-0000-0000-000000000002'
              and n.payload ->> 'ticket_id' = (select id::text from t1)), 1, 'accountable notified');
select ok((select (select array_agg(k order by k) from jsonb_object_keys(n.payload) k) = array['public_reference', 'ticket_id']
                  and n.title = 'New support message'
                  and n.body = 'Ticket ' || (select public_reference from t1) || ' needs a reply.'
             from public.notifications n
            where n.kind = 'SUPPORT_TICKET_ACTIVITY' and n.payload ->> 'ticket_id' = (select id::text from t1)),
  'notification has no text');

-- ── read ────────────────────────────────────────────────────────────────
select is(jsonb_array_length(public.read_support_ticket((select public_reference from t1), 's3cret') -> 'messages'),
          1, 'buyer reads');
select is(public.read_support_ticket((select public_reference from t1), 'wrong'), null, 'wrong secret is null');
select is(public.read_support_ticket('TK-ZZZZZZ', 's3cret'), null, 'unknown ticket is null');
insert into public.support_messages (tenant_id, ticket_id, sender_type, sender_id, territory_id, body, created_at)
select tenant_id, id, 'STAFF', '20000000-0000-0000-0000-000000000002', territory_id, 'On it', clock_timestamp()
  from public.support_tickets where id = (select id from t1);
select ok(position('20000000-0000-0000-0000-000000000002' in
          public.read_support_ticket((select public_reference from t1), 's3cret')::text) = 0, 'no staff ids exposed');
select is(public.read_support_ticket((select public_reference from t1), 's3cret') -> 'messages' -> 1 ->> 'sender',
          'teafair', 'staff messages read as teafair');
select is(public.read_support_ticket((select public_reference from t1), 's3cret') -> 'messages' -> 0 ->> 'sender',
          'you', 'buyer messages read as you');
select is(public.read_support_ticket((select public_reference from t1), 's3cret') ->> 'order_public_reference',
          'TF-AAAAAA', 'order reference included');

-- ── post ────────────────────────────────────────────────────────────────
select is(public.add_ticket_message(pg_temp.k(30), (select public_reference from t1), 's3cret', 'More info') ->> 'status',
          'OPEN', 'buyer posts');
select throws_ok($$select public.add_ticket_message(pg_temp.k(31), (select public_reference from t1), 'wrong', 'x')$$,
  'P0001', 'NOT_FOUND', 'wrong secret refused');
select ok((select t.last_message_at > t.created_at from public.support_tickets t where t.id = (select id from t1)),
  'queue bumped');
update public.support_tickets set status = 'RESOLVED', resolved_at = now() where id = (select id from t1);
select is(public.add_ticket_message(pg_temp.k(32), (select public_reference from t1), 's3cret', 'Still broken') ->> 'status',
          'OPEN', 'RESOLVED reopens');
select is((select t.status || '/' || coalesce(t.resolved_at::text, 'null') from public.support_tickets t
            where t.id = (select id from t1)), 'OPEN/null', 'and resolved_at is cleared');
update public.support_tickets set status = 'CLOSED' where public_reference = pg_temp.ref_of(3);
select throws_ok($$select public.add_ticket_message(pg_temp.k(33), pg_temp.ref_of(3), 's3cret', 'hi')$$,
  'P0001', 'This conversation is closed. Open a new ticket if you still need help.', 'closed refuses');
select is(public.read_support_ticket(pg_temp.ref_of(3), 's3cret') ->> 'status', 'CLOSED', 'closed stays readable');
-- the ticket of key 5 already has 1 customer message; 29 more makes 30
insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body)
select t.tenant_id, t.id, 'CUSTOMER', t.territory_id, 'm' || g
  from public.support_tickets t, generate_series(1, 29) g
 where t.public_reference = pg_temp.ref_of(5);
select throws_ok($$select public.add_ticket_message(pg_temp.k(34), pg_temp.ref_of(5), 's3cret', 'again')$$,
  'P0001', 'Too many messages. Please wait a few minutes.', 'message throttle');

-- ── shared lookup, grants ───────────────────────────────────────────────
select is(public.web_order_status('TF-AAAAAA', 'tfw-00000000-0000-0000-0000-00000000000A') ->> 'public_reference',
          'TF-AAAAAA', 'web_order_status still answers via the shared lookup');
select is((public.web_find_order_by_pair('tf-aaaaab', 'TFW-00000000-0000-0000-0000-00000000000B')).id,
          '90000000-0000-0000-0000-000000000002'::uuid, 'the lookup finds a cancelled order too');
select is((public.web_find_order_by_pair('TF-AAAAAA', 'TFW-00000000-0000-0000-0000-00000000000B')).id,
          null, 'the lookup misses a mismatched pair');
select ok(has_function_privilege('service_role',
            'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and has_function_privilege('service_role', 'public.read_support_ticket(text,text)', 'execute')
      and has_function_privilege('service_role', 'public.add_ticket_message(uuid,text,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.read_support_ticket(text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.open_support_ticket(uuid,text,text,text,jsonb,text,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.add_ticket_message(uuid,text,text,text)', 'execute'),
  'the buyer RPCs are service_role only');
select ok(not has_function_privilege('service_role', 'public.web_find_order_by_pair(text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.support_notify_activity(public.support_tickets)', 'execute')
      and not has_function_privilege('authenticated', 'public.web_find_order_by_pair(text,text)', 'execute')
      and not has_function_privilege('anon', 'public.support_notify_activity(public.support_tickets)', 'execute'),
  'the internals are not executable by any API role');

select * from finish();
rollback;
