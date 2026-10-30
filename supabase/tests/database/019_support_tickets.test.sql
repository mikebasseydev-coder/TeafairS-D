-- Addendum A3 §3 — support tickets: schema constraints, handler RLS, Realtime.
begin;
create extension if not exists pgtap with schema extensions;

select plan(44);

-- A5: ONLINE orders created from 2026-10-23 must carry refund-policy consent.
-- These fixtures insert ONLINE orders directly and are not about consent, so
-- stamp it for them (027 tests the CHECK itself).
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

-- users: ZSM1, TM_A, TM_B, DSA, DEF (DSM default agent), GONE (disabled DSM), ZSM2
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000005', '2348000000005'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000009', '2348000000009');
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Epe'),
  ('40000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'ZSM', null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'DISABLED', true);

-- A6 §17/§18.3: zones.zsm_id is a ZSM's coverage; each tenant's ACTIVE ZSM
-- covers the zones it acts in
update public.zones z
   set zsm_id = (select tu.profile_id from public.tenant_users tu
                  where tu.tenant_id = z.tenant_id and tu.role = 'ZSM' and tu.status = 'ACTIVE'
                  order by tu.created_at, tu.profile_id limit 1)
 where z.zsm_id is null;
-- tickets, inserted directly as postgres
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, accountable_id) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'TK-AAAAA1', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'TK-AAAAA2', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003'),
  ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'TK-AAAAA3', 'PRE_PURCHASE', 'OTHER',
   null, '20000000-0000-0000-0000-000000000005'),
  ('60000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'TK-AAAAA4', 'PRE_PURCHASE', 'OTHER',
   null, '20000000-0000-0000-0000-000000000006');
insert into public.support_ticket_contacts (ticket_id, tenant_id, territory_id, customer_name, customer_phone) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'Ada', '+2348012345678'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000002', 'Bola', '+2348012345679');
insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body) values
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'CUSTOMER', '40000000-0000-0000-0000-000000000001', 'hello'),
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'CUSTOMER', '40000000-0000-0000-0000-000000000001', 'my phone is 0801'),
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002', 'CUSTOMER', '40000000-0000-0000-0000-000000000002', 'epe question'),
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000003', 'CUSTOMER', null, 'unrouted question'),
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000004', 'CUSTOMER', null, 'orphan question');

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- constraints
select throws_ok($$insert into public.support_tickets (tenant_id, public_reference, kind, category)
  values ('10000000-0000-0000-0000-000000000001', 'TK-BBBBB1', 'ORDER', 'PAYMENT')$$, '23514', null, 'ORDER needs an order');
select throws_ok($$insert into public.support_tickets (tenant_id, public_reference, kind, category)
  values ('10000000-0000-0000-0000-000000000001', 'TK-BBBBB2', 'SYSTEM', 'SYSTEM')$$, '23514', null, 'SYSTEM needs a system_key');
select throws_ok($$insert into public.support_tickets (tenant_id, public_reference, kind, category, status)
  values ('10000000-0000-0000-0000-000000000001', 'TK-BBBBB3', 'PRE_PURCHASE', 'OTHER', 'RESOLVED')$$, '23514', null, 'RESOLVED needs resolved_at');
select throws_ok($$insert into public.support_tickets (tenant_id, public_reference, kind, category)
  values ('10000000-0000-0000-0000-000000000001', 'TK-12', 'PRE_PURCHASE', 'OTHER')$$, '23514', null, 'reference format');
select throws_ok($$insert into public.support_messages (tenant_id, ticket_id, sender_type, body)
  values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'CUSTOMER', '   ')$$, '23514', null, 'empty body refused');
select throws_ok($$insert into public.support_messages (tenant_id, ticket_id, sender_type, body)
  values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'CUSTOMER', repeat('x', 2001))$$, '23514', null, 'over 2000 refused');
select throws_ok($$insert into public.support_messages (tenant_id, ticket_id, sender_type, body)
  values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'STAFF', 'hi')$$, '23514', null, 'STAFF needs sender');
select throws_ok($$insert into public.support_ticket_contacts (ticket_id, tenant_id)
  values ('60000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002')$$, '23503', null, 'composite FK keeps tenants apart');
select ok(public.new_crockford_reference('TK') ~ '^TK-[0-9A-HJKMNP-TV-Z]{6}$', 'reference generator');

-- privileges
select ok(not has_table_privilege('authenticated', 'public.support_ticket_secrets', 'select'), 'secrets unreadable');
select ok(not has_table_privilege('anon', 'public.support_messages', 'select'), 'anon reads no messages');
select ok(not has_table_privilege('authenticated', 'public.support_tickets', 'insert'), 'no client writes');
select ok(not has_function_privilege('anon', 'public.my_support_ticket_ids()', 'execute'), 'anon cannot list handler tickets');
select ok(not has_function_privilege('service_role', 'public.my_support_ticket_ids()', 'execute'), 'service_role cannot list handler tickets');
select ok(to_regprocedure('public.my_support_history_ticket_ids()') is not null
          and not has_function_privilege('anon', 'public.my_support_history_ticket_ids()', 'execute'), 'anon cannot list handler history');
select ok(to_regprocedure('public.my_support_history_ticket_ids()') is not null
          and not has_function_privilege('service_role', 'public.my_support_history_ticket_ids()', 'execute'), 'service_role cannot list handler history');
select ok(not has_function_privilege('authenticated', 'public.new_crockford_reference(text)', 'execute'), 'generator is internal');
select ok(not has_function_privilege('service_role', 'public.new_crockford_reference(text)', 'execute'), 'generator is not callable by service_role');
select ok(not has_table_privilege('service_role', 'public.support_ticket_secrets', 'select'), 'service_role cannot read secrets');
select ok(not has_table_privilege('anon', 'public.support_ticket_secrets', 'select'), 'anon cannot read secrets');

-- RLS
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_tickets), 4, 'every tenant member sees headers');
select is((select count(*)::int from public.support_messages), 0, 'DSA reads no messages');
select is((select count(*)::int from public.support_ticket_contacts), 0, 'DSA reads no contacts');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000001'), 2, 'territory TM reads messages');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000002'), 0, 'not another territory');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_ticket_contacts), 2, 'ZSM reads all');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000003'), 1, 'non-TM default agent reads the ticket routed to them');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000001'), 0, 'and nothing else');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000004'), 0, 'disabled handler loses access');
reset role;

select pg_temp.act_as('20000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.support_tickets), 0, 'other tenant sees nothing');
reset role;

-- linked history (amendment 2): C0 is CLOSED, unrouted, DEF not on it;
-- K5 is DEF's follow-up and links to C0
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, accountable_id, status) values
  ('60000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'TK-AAAAC0', 'PRE_PURCHASE', 'OTHER',
   null, null, 'CLOSED');
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, accountable_id,
                                    previous_ticket_id) values
  ('60000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', 'TK-AAAAK5', 'PRE_PURCHASE', 'OTHER',
   null, '20000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000010');
insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body) values
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000010', 'CUSTOMER', null, 'first time'),
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000010', 'CUSTOMER', null, 'still waiting'),
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000011', 'CUSTOMER', null, 'back again');
insert into public.support_ticket_contacts (ticket_id, tenant_id, territory_id, customer_name, customer_phone) values
  ('60000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', null, 'Chidi', '+2348012345670');
-- a chain C0 <- C1 <- C2: C1 is CLOSED too; TM_B handles only C2
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, accountable_id,
                                    status, previous_ticket_id) values
  ('60000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', 'TK-AAAAC1', 'PRE_PURCHASE', 'OTHER',
   null, null, 'CLOSED', '60000000-0000-0000-0000-000000000010');
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, accountable_id,
                                    previous_ticket_id) values
  ('60000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', 'TK-AAAAC2', 'PRE_PURCHASE', 'OTHER',
   null, '20000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000012');

select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000010'),
          2, 'handler reads the linked closed ticket');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_ticket_contacts where ticket_id = '60000000-0000-0000-0000-000000000010'),
          0, 'a direct link does not expose earlier contacts');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000010'),
          2, 'handler reads the whole chain');
select is((select count(*)::int from public.support_ticket_contacts where ticket_id = '60000000-0000-0000-0000-000000000010'),
          0, 'linked history does not expose earlier contacts');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000010'),
          0, 'others do not');
reset role;
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000005';
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000010'),
          0, 'disabled handler loses the history too');
reset role;

-- ORDER tickets follow A2 (user decision 2026-10-21): the ZSM and the
-- territory TM only, never the accountable selling agent. O1 is an Ikeja
-- ORDER ticket whose accountable is the DSA.
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount) values
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'FIELD_SALES',
   '20000000-0000-0000-0000-000000000004', 5000);
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, order_id, territory_id, accountable_id) values
  ('60000000-0000-0000-0000-000000000020', '10000000-0000-0000-0000-000000000001', 'TK-AAAAD1', 'ORDER', 'PAYMENT',
   '80000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004');
insert into public.support_ticket_contacts (ticket_id, tenant_id, territory_id, customer_name, customer_phone) values
  ('60000000-0000-0000-0000-000000000020', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'Dayo', '+2348012345671');
insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body) values
  ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000020', 'CUSTOMER', '40000000-0000-0000-0000-000000000001', 'where is my order');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_ticket_contacts where ticket_id = '60000000-0000-0000-0000-000000000020'),
          0, 'on an ORDER ticket the accountable DSA reads no contacts');
select is((select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000020'),
          0, '…and no messages');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.support_ticket_contacts where ticket_id = '60000000-0000-0000-0000-000000000020')
        + (select count(*)::int from public.support_messages where ticket_id = '60000000-0000-0000-0000-000000000020'),
          2, 'the territory TM still reads them');
reset role;

select throws_ok($$update public.support_tickets set previous_ticket_id = id
                   where id = '60000000-0000-0000-0000-000000000011'$$, '23514', null, 'no self link');
-- system keys: one live ticket per key, a CLOSED key is free again
insert into public.support_tickets (tenant_id, public_reference, kind, category, system_key, status) values
  ('10000000-0000-0000-0000-000000000001', 'TK-AAAAS1', 'SYSTEM', 'SYSTEM', 'TEST:LIVE', 'OPEN'),
  ('10000000-0000-0000-0000-000000000001', 'TK-AAAAS2', 'SYSTEM', 'SYSTEM', 'TEST:DONE', 'CLOSED');
select throws_ok($$insert into public.support_tickets (tenant_id, public_reference, kind, category, system_key, status)
  values ('10000000-0000-0000-0000-000000000001', 'TK-AAAAS3', 'SYSTEM', 'SYSTEM', 'TEST:LIVE', 'IN_PROGRESS')$$,
  '23505', null, 'one live ticket per key');
select lives_ok($$insert into public.support_tickets (tenant_id, public_reference, kind, category, system_key)
  values ('10000000-0000-0000-0000-000000000001', 'TK-AAAAS4', 'SYSTEM', 'SYSTEM', 'TEST:DONE')$$,
  'closed keys can be reused');

-- Realtime
select ok(exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'support_messages'), 'messages in Realtime');
select ok(exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'support_tickets'), 'tickets in Realtime');

select * from finish();
rollback;
