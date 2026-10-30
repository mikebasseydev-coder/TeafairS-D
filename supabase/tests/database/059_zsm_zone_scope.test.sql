-- Addendum A6 §18.3 (plan Task 1e; user ruling 2026-10-30): a ZSM's
-- administrative and approval powers, and every ZSM-scoped read, reach only
-- the ZSM's own zones (zones.zsm_id). Objects with no zone stay with any
-- ACTIVE ZSM of the tenant. ZSM-to-ZSM direct chat is always open.
begin;
create extension if not exists pgtap with schema extensions;

select plan(90);

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

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- Tenant A (Nestle). Zones: Lagos (Z) and Oyo (Z2).
-- Territories: Ikeja, Lekki (Lagos); Ibadan (Oyo). No territory has a TM.
-- 01 Z · 02 Z2 · 03 LM (logistics manager) · 04 DSA Ikeja · 05 DSA Ibadan
-- 06 POS agent Ikeja · 07 POS agent Ibadan · 08 platform administrator
-- 09 TM of Ikeja (a membership only: territories.tm_id stays empty, so routing
--    still falls back to the zone's ZSM)
-- 10, 11 accounts with verified phones, not yet members (invitees)
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0'), now()
from generate_series(1, 11) n;
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN' where id = '20000000-0000-0000-0000-000000000008';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000033', '10000000-0000-0000-0000-000000000001', 'Oyo',   'OY');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000031', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000042', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000031', 'Lekki'),
  ('40000000-0000-0000-0000-000000000043', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000033', 'Ibadan');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000051', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000052', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000053', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'LOGISTICS_MANAGER', null, null, '50000000-0000-0000-0000-000000000051', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000054', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000041', '50000000-0000-0000-0000-000000000051', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000055', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSA', null, '40000000-0000-0000-0000-000000000043', '50000000-0000-0000-0000-000000000052', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000056', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000041', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000057', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'POS_AGENT', null, '40000000-0000-0000-0000-000000000043', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000059', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000009',
   'TM', null, '40000000-0000-0000-0000-000000000041', null, 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000031';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000002' where id = '30000000-0000-0000-0000-000000000033';

insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'NES-CENTRAL', 'CENTRAL', null, null),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'NES-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000041', null),
  ('70000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'NES-IBADAN', 'REGIONAL',
   '40000000-0000-0000-0000-000000000043', null);

-- web POS partner and venues in Ikeja and Ibadan
insert into public.web_pos_partners (id, tenant_id, business_name, pos_network, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000061', '10000000-0000-0000-0000-000000000001', 'Grace POS', 'MONIEPOINT',
   '+2348000000099', 'ACCT_grace59', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());
insert into public.web_pos_venues (id, tenant_id, partner_id, agent_id, network_terminal_id, territory_id) values
  ('61000000-0000-0000-0000-000000000061', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000061',
   '20000000-0000-0000-0000-000000000006', 'MP-5901', '40000000-0000-0000-0000-000000000041'),
  ('61000000-0000-0000-0000-000000000063', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000061',
   '20000000-0000-0000-0000-000000000007', 'MP-5903', '40000000-0000-0000-0000-000000000043'),
  -- terminals with no territory: zoned by their POS agent's territory
  ('61000000-0000-0000-0000-000000000064', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000061',
   '20000000-0000-0000-0000-000000000006', 'MP-5904', null),
  ('61000000-0000-0000-0000-000000000065', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000061',
   '20000000-0000-0000-0000-000000000007', 'MP-5905', null);

-- orders: O1 Lagos (Ikeja) and O2 Oyo (Ibadan) PAID web orders; O3 a field
-- order with no territory
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('90000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000004', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-ZAAAA1',
   (select id from public.ng_lgas where state_code = 'LA' order by name limit 1),
   '40000000-0000-0000-0000-000000000041', '70000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000005', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-ZAAAA2',
   (select id from public.ng_lgas where state_code = 'OY' order by name limit 1),
   '40000000-0000-0000-0000-000000000043', '70000000-0000-0000-0000-000000000001');
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status) values
  ('90000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'FIELD_SALES',
   '20000000-0000-0000-0000-000000000004', 0, 'PENDING');
insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone) values
  ('90000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000041', 'Buyer 1', '+2348011111101'),
  ('90000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000043', 'Buyer 2', '+2348011111102'),
  ('90000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   null, 'Buyer 3', '+2348011111103');

-- tickets: T1 Lagos, T2 Oyo, T3 no territory; each with a contact and a message
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, territory_id, status) values
  ('62000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'TK-ZSCAB1', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000041', 'OPEN'),
  ('62000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'TK-ZSCAB2', 'PRE_PURCHASE', 'PRODUCT',
   '40000000-0000-0000-0000-000000000043', 'OPEN'),
  ('62000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'TK-ZSCAB3', 'PRE_PURCHASE', 'PRODUCT',
   null, 'OPEN');
insert into public.support_ticket_contacts (ticket_id, tenant_id, territory_id, customer_name, customer_phone)
select t.id, t.tenant_id, t.territory_id, 'Asker', '+23480222222' || right(t.id::text, 2)
  from public.support_tickets t where t.public_reference like 'TK-ZSCAB%';
insert into public.support_messages (tenant_id, ticket_id, sender_type, territory_id, body)
select t.tenant_id, t.id, 'CUSTOMER', t.territory_id, 'hello'
  from public.support_tickets t where t.public_reference like 'TK-ZSCAB%';

-- audit and notification rows about the orders and tickets
insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, source)
select '10000000-0000-0000-0000-000000000001', 'zsm_scope_fixture', e.t, e.id, 'USER'
  from (values ('orders', '90000000-0000-0000-0000-000000000001'),
               ('orders', '90000000-0000-0000-0000-000000000002'),
               ('orders', '90000000-0000-0000-0000-000000000003'),
               ('support_tickets', '62000000-0000-0000-0000-000000000001'),
               ('support_tickets', '62000000-0000-0000-0000-000000000002'),
               ('support_tickets', '62000000-0000-0000-0000-000000000003'),
               ('tenant_settings', '10000000-0000-0000-0000-000000000001')) as e (t, id);
insert into public.notification_logs (tenant_id, purpose, channel, status, phone_last4, related_id) values
  ('10000000-0000-0000-0000-000000000001', 'DELIVERY_CODE', 'WHATSAPP', 'SENT', '0001', '90000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000001', 'DELIVERY_CODE', 'WHATSAPP', 'SENT', '0002', '90000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000001', 'DELIVERY_CODE', 'WHATSAPP', 'SENT', '0003', '90000000-0000-0000-0000-000000000003'),
  ('10000000-0000-0000-0000-000000000001', 'OTP',           'WHATSAPP', 'SENT', '0004', null);

-- fix round 1: O4, another PAID Oyo web order; T4, an ORDER ticket on O2;
-- a payment and commission on O2; a buyer photo slot on T2
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('90000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000005', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-ZAAAA4',
   (select id from public.ng_lgas where state_code = 'OY' order by name limit 1),
   '40000000-0000-0000-0000-000000000043', '70000000-0000-0000-0000-000000000001');
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, order_id, territory_id, status) values
  ('62000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'TK-ZSCAB4', 'ORDER', 'DELIVERY',
   '90000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000043', 'OPEN');
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, paystack_reference) values
  ('91000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000005', 2500, 'TFW-00000000-0000-0000-0000-000000000592');
insert into public.web_commissions (id, tenant_id, order_id, payment_id, web_pos_partner_id, teafair_agent_id,
                                    amount, bps_applied, paystack_subaccount_code) values
  ('92000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002',
   '91000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000061',
   '20000000-0000-0000-0000-000000000005', 25, 100, 'ACCT_grace59');
insert into public.upload_slots (id, tenant_id, purpose, ticket_id, storage_path, mime_type, size_bytes,
                                 uploaded_by_type) values
  ('93000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'SUPPORT_TICKET',
   '62000000-0000-0000-0000-000000000002',
   'tickets/62000000-0000-0000-0000-000000000002/93000000-0000-0000-0000-000000000002.jpg', 'image/jpeg', 900,
   'CUSTOMER');
-- audit rows of those types: a live Oyo slot, a purged slot of an Oyo ticket
-- (only its payload names the ticket), an Oyo commission, a message hidden in
-- the Oyo ZONE room; and a Lagos room moderation for contrast
insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, after, source)
select '10000000-0000-0000-0000-000000000001', 'zsm_scope_fixture2', e.t, e.id, e.a, 'USER'
  from (values
    ('upload_slots', '93000000-0000-0000-0000-000000000002',
     jsonb_build_object('ticket_id', '62000000-0000-0000-0000-000000000002')),
    ('upload_slots', '93000000-0000-0000-0000-000000000009',
     jsonb_build_object('ticket_id', '62000000-0000-0000-0000-000000000002')),
    ('web_commissions', '92000000-0000-0000-0000-000000000002', null::jsonb),
    ('chat_messages', '94000000-0000-0000-0000-000000000033',
     jsonb_build_object('channel_id', (select c.id from public.chat_channels c
                                        where c.channel_type = 'ZONE' and c.zone_id = '30000000-0000-0000-0000-000000000033'))),
    ('chat_messages', '94000000-0000-0000-0000-000000000031',
     jsonb_build_object('channel_id', (select c.id from public.chat_channels c
                                        where c.channel_type = 'ZONE' and c.zone_id = '30000000-0000-0000-0000-000000000031')))
  ) as e (t, id, a);

-- audit rows about the Ikeja and Lekki territories (both Lagos)
insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, source) values
  ('10000000-0000-0000-0000-000000000001', 'zsm_scope_fixture3', 'territories', '40000000-0000-0000-0000-000000000041', 'USER'),
  ('10000000-0000-0000-0000-000000000001', 'zsm_scope_fixture3', 'territories', '40000000-0000-0000-0000-000000000042', 'USER');

-- web routing: Lagos and Oyo state coverage
insert into public.territory_coverage (tenant_id, state_code, territory_id) values
  ('10000000-0000-0000-0000-000000000001', 'OY', '40000000-0000-0000-0000-000000000043');

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

create function pg_temp.act_as(p_user integer) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', ('20000000-0000-0000-0000-0000000000' || lpad(p_user::text, 2, '0'))::uuid, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', '10000000-0000-0000-0000-000000000001'))::text, true);
$$;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('a0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.dispatch(p_key integer, p_order integer) returns jsonb language sql as
  $$ select public.mark_order_dispatched(pg_temp.k(p_key), ('90000000-0000-0000-0000-00000000000' || p_order)::uuid,
                                         null, '1234', 'test-gw-secret') $$;
create function pg_temp.resend(p_key integer, p_order integer) returns jsonb language sql as
  $$ select public.resend_delivery_pin(pg_temp.k(p_key), ('90000000-0000-0000-0000-00000000000' || p_order)::uuid,
                                       '5678', 'test-gw-secret') $$;
create function pg_temp.ids(p_sql text) returns text[] language plpgsql as $$
declare v text[];
begin
  execute 'select coalesce(array_agg(x order by x), ''{}'') from (' || p_sql || ') s(x)' into v;
  return v;
end $$;
grant execute on function pg_temp.act_as(integer), pg_temp.k(integer), pg_temp.dispatch(integer, integer),
  pg_temp.resend(integer, integer), pg_temp.ids(text) to authenticated;

-- ── helpers ─────────────────────────────────────────────────────────────
select ok(not has_function_privilege('authenticated', 'public.zsm_covers_territory(uuid,uuid,uuid)', 'execute')
          and not has_function_privilege('anon', 'public.zsm_covers_territory(uuid,uuid,uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.zsm_covers_territory(uuid,uuid,uuid)', 'execute'),
  'zsm_covers_territory is internal');
select ok(has_function_privilege('authenticated', 'public.my_zsm_territory_ids()', 'execute')
          and not has_function_privilege('anon', 'public.my_zsm_territory_ids()', 'execute')
          and has_function_privilege('authenticated', 'public.my_zsm_out_of_zone_keys()', 'execute')
          and not has_function_privilege('anon', 'public.my_zsm_out_of_zone_keys()', 'execute'),
  'the policy helpers are for authenticated callers only');
select ok((select bool_and(p.prosecdef and p.provolatile = 's' and p.proconfig @> array['search_path=public, pg_temp'])
             from pg_proc p
            where p.oid in ('public.zsm_covers_territory(uuid,uuid,uuid)'::regprocedure,
                            'public.my_zsm_territory_ids()'::regprocedure,
                            'public.my_zsm_out_of_zone_keys()'::regprocedure)),
  'the new helpers are SECURITY DEFINER, STABLE, search_path pinned');
select ok((select bool_and(cmd = 'SELECT') from pg_policies
            where schemaname = 'public'
              and policyname in ('order_contacts_select_zsm_or_tm', 'audit_logs_select_zsm_tm',
                                 'notification_logs_select_zsm', 'support_messages_select_handler',
                                 'support_ticket_contacts_select_handler')),
  'the narrowed policies stay FOR SELECT');

-- ── ticket assignment ───────────────────────────────────────────────────
select pg_temp.act_as(1);
select throws_ok(
  $$select public.assign_ticket(pg_temp.k(1), '62000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000043')$$,
  '42501', null, 'Z cannot route a Lagos ticket into an Oyo territory');
select throws_ok(
  $$select public.assign_ticket(pg_temp.k(2), '62000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000041')$$,
  '42501', null, 'Z cannot route an Oyo ticket at all');
select lives_ok(
  $$select public.assign_ticket(pg_temp.k(3), '62000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000042')$$,
  'Z routes a Lagos ticket into another Lagos territory');
select lives_ok(
  $$select public.assign_ticket(pg_temp.k(4), '62000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000041')$$,
  'Z routes a ticket with no territory into Lagos');
-- put T1 and T3 back for the reads below
select public.assign_ticket(pg_temp.k(5), '62000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000041');
reset role;
update public.support_tickets set territory_id = null where id = '62000000-0000-0000-0000-000000000003';
update public.support_ticket_contacts set territory_id = null where ticket_id = '62000000-0000-0000-0000-000000000003';
update public.support_messages set territory_id = null where ticket_id = '62000000-0000-0000-0000-000000000003';

select pg_temp.act_as(2);
select lives_ok(
  $$select public.assign_ticket(pg_temp.k(6), '62000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000043')$$,
  'Z2 routes the Oyo ticket within Oyo');

-- the ZSM override in support_lock_ticket (through redact)
select pg_temp.act_as(1);
select throws_ok(
  $$select public.redact_ticket_customer_data(pg_temp.k(7), '62000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'Z cannot redact an Oyo ticket');
select throws_ok(
  $$select public.update_ticket_status(pg_temp.k(8), '62000000-0000-0000-0000-000000000002', 'RESOLVED')$$,
  '42501', null, 'Z cannot change the status of an Oyo ticket');

-- ── territory coverage and web warehouse ────────────────────────────────
select lives_ok(
  $$select public.set_territory_coverage(pg_temp.k(10), 'LA', null, '40000000-0000-0000-0000-000000000041')$$,
  'Z sets Lagos coverage to Ikeja');
select throws_ok(
  $$select public.set_territory_coverage(pg_temp.k(11), 'OY', null, '40000000-0000-0000-0000-000000000043')$$,
  '42501', null, 'Z cannot set coverage to an Oyo territory');
select throws_ok(
  $$select public.set_territory_coverage(pg_temp.k(12), 'OY', null, '40000000-0000-0000-0000-000000000041')$$,
  '42501', null, 'Z cannot take over coverage that points into Oyo');
select throws_ok(
  $$select public.set_territory_coverage(pg_temp.k(13), 'OY', null, null)$$,
  '42501', null, 'Z cannot remove coverage that points into Oyo');
select lives_ok(
  $$select public.set_territory_web_warehouse(pg_temp.k(14), '40000000-0000-0000-0000-000000000041', '70000000-0000-0000-0000-000000000002')$$,
  'Z sets the web warehouse of a Lagos territory');
select throws_ok(
  $$select public.set_territory_web_warehouse(pg_temp.k(15), '40000000-0000-0000-0000-000000000043', '70000000-0000-0000-0000-000000000003')$$,
  '42501', null, 'Z cannot set the web warehouse of an Oyo territory');

-- ── venues and referral codes ───────────────────────────────────────────
select lives_ok(
  $$select public.set_web_pos_venue(pg_temp.k(16), '61000000-0000-0000-0000-000000000061', 'OTHER', 'Grace Shop',
      '1 Allen Avenue', 'Lagos', 'Ikeja', 6.6, 3.35, null)$$,
  'Z sets the venue of an Ikeja terminal');
select throws_ok(
  $$select public.set_web_pos_venue(pg_temp.k(17), '61000000-0000-0000-0000-000000000063', 'OTHER', 'Grace Ibadan',
      '1 Ring Road', 'Oyo', 'Ibadan North', 7.4, 3.9, null)$$,
  '42501', null, 'Z cannot set the venue of an Ibadan terminal');
select lives_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(18), 'IKEJA-DSA', '20000000-0000-0000-0000-000000000004',
      null, null, null, null, null, true)$$,
  'Z issues a code for an Ikeja DSA');
select throws_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(19), 'IBADAN-DSA', '20000000-0000-0000-0000-000000000005',
      null, null, null, null, null, true)$$,
  '42501', null, 'Z cannot issue a code for an Ibadan DSA');
select throws_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(20), 'IBADAN-POS', '20000000-0000-0000-0000-000000000007',
      '61000000-0000-0000-0000-000000000063', null, null, null, null, true)$$,
  '42501', null, 'Z cannot issue a code bound to an Ibadan terminal');
select pg_temp.act_as(2);
select lives_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(21), 'IBADAN-DSA', '20000000-0000-0000-0000-000000000005',
      null, null, null, null, null, true)$$,
  'Z2 issues the code for the Ibadan DSA');
select pg_temp.act_as(1);
select lives_ok(
  $$select public.set_web_pos_venue(pg_temp.k(22), '61000000-0000-0000-0000-000000000064', 'OTHER', 'Grace Two',
      '2 Allen Avenue', 'Lagos', 'Ikeja', 6.6, 3.35, null)$$,
  'Z sets a terminal with no territory whose agent is in Ikeja');
select throws_ok(
  $$select public.set_web_pos_venue(pg_temp.k(23), '61000000-0000-0000-0000-000000000065', 'OTHER', 'Grace Three',
      '2 Ring Road', 'Oyo', 'Ibadan North', 7.4, 3.9, null)$$,
  '42501', null, 'Z cannot set a terminal with no territory whose agent is in Ibadan');
select lives_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(24), 'Z-HOUSE', '20000000-0000-0000-0000-000000000001',
      null, null, null, null, null, true)$$,
  'Z issues a code for itself');
select throws_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(25), 'Z2-HOUSE', '20000000-0000-0000-0000-000000000002',
      null, null, null, null, null, true)$$,
  '42501', 'this agent is not in your zones', 'Z cannot issue a code for a ZSM with no shared zone');
select throws_ok(
  $$select public.upsert_web_referral_code(pg_temp.k(26), 'LM-HOUSE', '20000000-0000-0000-0000-000000000003',
      null, null, null, null, null, true)$$,
  '42501', 'this agent is not in your zones', 'Z cannot issue a code for a zone-less logistics manager');

-- ── reads: buyer contacts, ticket contacts and messages, audit, notifications
select pg_temp.act_as(1);
select is(pg_temp.ids($$select order_id::text from public.order_contacts$$),
  array['90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000003'],
  'Z reads the buyer contacts of Lagos orders and of the order with no territory');
select is(pg_temp.ids($$select ticket_id::text from public.support_ticket_contacts$$),
  array['62000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000003'],
  'Z reads the contacts of Lagos tickets and of the ticket with no territory');
select is(pg_temp.ids($$select distinct ticket_id::text from public.support_messages$$),
  array['62000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000003'],
  'Z reads the messages of Lagos tickets and of the ticket with no territory');
select is(pg_temp.ids($$select distinct entity_id from public.audit_logs where operation = 'zsm_scope_fixture'$$),
  array['10000000-0000-0000-0000-000000000001',
        '62000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000003',
        '90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000003'],
  'Z reads the audit rows of Lagos and zone-less objects, and tenant-wide rows');
select is(pg_temp.ids($$select phone_last4 from public.notification_logs$$),
  array['0001', '0003', '0004'],
  'Z reads the notification rows of Lagos and zone-less orders, and of no order');
select is(pg_temp.ids($$select public.my_support_message_ticket_ids()::text$$),
  array['62000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000003'],
  'Z''s ticket attachments reach Lagos and zone-less tickets only');
select is((select count(*)::int from public.audit_logs
            where entity_type = 'territories' and entity_id = '40000000-0000-0000-0000-000000000041'
              and operation = 'set_territory_web_warehouse'), 1,
  'Z reads the audit row of the Lagos web-warehouse change');

select pg_temp.act_as(2);
select is(pg_temp.ids($$select order_id::text from public.order_contacts$$),
  array['90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000003'],
  'Z2 reads the buyer contacts of Oyo orders and of the order with no territory');
select is(pg_temp.ids($$select ticket_id::text from public.support_ticket_contacts$$),
  array['62000000-0000-0000-0000-000000000002', '62000000-0000-0000-0000-000000000003'],
  'Z2 reads the contacts of Oyo tickets and of the ticket with no territory');
select is(pg_temp.ids($$select distinct ticket_id::text from public.support_messages$$),
  array['62000000-0000-0000-0000-000000000002', '62000000-0000-0000-0000-000000000003'],
  'Z2 reads the messages of Oyo tickets and of the ticket with no territory');
select is(pg_temp.ids($$select distinct entity_id from public.audit_logs where operation = 'zsm_scope_fixture'$$),
  array['10000000-0000-0000-0000-000000000001',
        '62000000-0000-0000-0000-000000000002', '62000000-0000-0000-0000-000000000003',
        '90000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000003'],
  'Z2 reads the audit rows of Oyo and zone-less objects, and tenant-wide rows');
select is(pg_temp.ids($$select phone_last4 from public.notification_logs$$),
  array['0002', '0003', '0004'],
  'Z2 reads the notification rows of Oyo and zone-less orders, and of no order');
select is((select count(*)::int from public.audit_logs
            where entity_type = 'territories' and entity_id = '40000000-0000-0000-0000-000000000041'
              and operation = 'set_territory_web_warehouse'), 0,
  'Z2 does not read the audit row of the Lagos web-warehouse change');
select is(pg_temp.ids($$select entity_id from public.audit_logs where operation = 'zsm_scope_fixture2'$$),
  array['92000000-0000-0000-0000-000000000002', '93000000-0000-0000-0000-000000000002',
        '93000000-0000-0000-0000-000000000009', '94000000-0000-0000-0000-000000000033'],
  'Z2 reads the audit rows of Oyo slots, commissions and room moderation');
select pg_temp.act_as(1);
select is((select count(*)::int from public.audit_logs
            where operation = 'zsm_scope_fixture2' and entity_type = 'upload_slots'), 0,
  'Z reads no audit row of an Oyo photo slot, live or purged');
select is((select count(*)::int from public.audit_logs
            where operation = 'zsm_scope_fixture2' and entity_type = 'web_commissions'), 0,
  'Z reads no audit row of an Oyo commission');
select is(pg_temp.ids($$select entity_id from public.audit_logs
                         where operation = 'zsm_scope_fixture2' and entity_type = 'chat_messages'$$),
  array['94000000-0000-0000-0000-000000000031'], 'Z reads the moderation audit of the Lagos room only');
select is(pg_temp.ids($$select entity_id from public.audit_logs where operation = 'zsm_scope_fixture3'$$),
  array['40000000-0000-0000-0000-000000000041', '40000000-0000-0000-0000-000000000042'],
  'Z reads the audit rows of both Lagos territories');

-- a TM reads audit rows of their own territory only (user ruling 2026-10-30)
select pg_temp.act_as(9);
select is(pg_temp.ids($$select distinct entity_id from public.audit_logs where operation = 'zsm_scope_fixture'$$),
  array['62000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001'],
  'the Ikeja TM reads the audit rows of the Ikeja order and ticket only');
select is(pg_temp.ids($$select entity_id from public.audit_logs where operation = 'zsm_scope_fixture3'$$),
  array['40000000-0000-0000-0000-000000000041'],
  'the Ikeja TM reads no audit row of Lekki, another territory of the zone');
select is((select count(*)::int from public.audit_logs where operation = 'zsm_scope_fixture2'), 0,
  'the Ikeja TM reads no Oyo audit row');
select is((select count(*)::int from public.audit_logs where entity_type = 'tenant_settings'), 0,
  'the Ikeja TM no longer reads zone-less tenant-wide audit rows');
select is((select count(*)::int from public.audit_logs
            where entity_type = 'territories' and entity_id = '40000000-0000-0000-0000-000000000041'
              and operation = 'set_territory_web_warehouse'), 1,
  'the Ikeja TM reads the audit of a change to Ikeja itself');
select pg_temp.act_as(1);

-- ── dispute evidence ────────────────────────────────────────────────────
select pg_temp.act_as(1);
select lives_ok($$select public.get_order_dispute_evidence('90000000-0000-0000-0000-000000000001')$$,
  'Z reads the dispute evidence of a Lagos order');
select throws_ok($$select public.get_order_dispute_evidence('90000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'Z cannot read the dispute evidence of an Oyo order');

-- ── dispatch and the delivery code ──────────────────────────────────────
select throws_ok($$select pg_temp.dispatch(30, 2)$$, '42501', null, 'Z cannot dispatch an Oyo order');
select lives_ok($$select pg_temp.dispatch(31, 1)$$, 'Z dispatches a Lagos order');
select pg_temp.act_as(3);
select lives_ok($$select pg_temp.dispatch(32, 2)$$, 'the LM dispatches the Oyo order');
select pg_temp.act_as(1);
select throws_ok($$select pg_temp.resend(33, 2)$$, '42501', null, 'Z cannot re-send the code of an Oyo order');
select lives_ok($$select pg_temp.resend(34, 1)$$, 'Z re-sends the code of a Lagos order');
select is(pg_temp.ids($$select order_id::text from public.order_fulfilments$$),
  array['90000000-0000-0000-0000-000000000001'], 'Z reads the fulfilment of the Lagos order only');
select pg_temp.act_as(3);
select lives_ok($$select pg_temp.resend(35, 1)$$, 'the LM re-sends the code of the Lagos order');
select lives_ok($$select pg_temp.resend(36, 2)$$, 'the LM re-sends the code of the Oyo order');
select is(pg_temp.ids($$select order_id::text from public.order_fulfilments$$),
  array['90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002'],
  'the LM reads every fulfilment of the tenant');
select pg_temp.act_as(2);
select is(pg_temp.ids($$select order_id::text from public.order_fulfilments$$),
  array['90000000-0000-0000-0000-000000000002'], 'Z2 reads the fulfilment of the Oyo order only');

-- ── ZSM direct chat is open across zones ────────────────────────────────
select pg_temp.act_as(1);
select is((public.get_or_create_direct_channel(pg_temp.k(40), '20000000-0000-0000-0000-000000000002') ->> 'created')::boolean,
  true, 'Z opens a direct channel with Z2, who covers another zone');
select lives_ok(
  $$select public.post_chat_message(pg_temp.k(41),
      (select c.id from public.chat_channels c where c.channel_type = 'DIRECT'
          and c.tenant_id = '10000000-0000-0000-0000-000000000001'), 'hello Z2')$$,
  'Z posts in it');
select pg_temp.act_as(2);
select is((select count(*)::int from public.chat_messages m join public.chat_channels c on c.id = m.channel_id
            where c.channel_type = 'DIRECT'), 1, 'Z2 reads the message');
select throws_ok(
  $$select public.get_or_create_direct_channel(pg_temp.k(42), '20000000-0000-0000-0000-000000000004')$$,
  '42501', null, 'Z2 still cannot open a direct channel with a Lagos DSA');

-- ── no orphaned zones (fix round 1) ─────────────────────────────────────
-- Oyo's ZSM is DISABLED: the zone is uncovered, so any ACTIVE ZSM reaches it
reset role;
update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000052';
select pg_temp.act_as(1);
select is(pg_temp.ids($$select order_id::text from public.order_contacts$$),
  array['90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002',
        '90000000-0000-0000-0000-000000000003'],
  'with Oyo''s ZSM disabled, Z reads Oyo buyer contacts');
select lives_ok($$select public.set_ticket_priority(pg_temp.k(50), '62000000-0000-0000-0000-000000000004', 'HIGH')$$,
  'with Oyo''s ZSM disabled, Z acts on an Oyo ORDER ticket');
select is((select count(*)::int from public.audit_logs where operation = 'zsm_scope_fixture2'), 5,
  'with Oyo''s ZSM disabled, Z reads every Oyo audit row');
-- Oyo has no zsm_id at all (Z2 back to ACTIVE, but not covering)
reset role;
update public.tenant_users set status = 'ACTIVE' where id = '50000000-0000-0000-0000-000000000052';
update public.zones set zsm_id = null where id = '30000000-0000-0000-0000-000000000033';
select pg_temp.act_as(1);
select lives_ok($$select pg_temp.dispatch(51, 4)$$, 'with Oyo uncovered, Z dispatches an Oyo order');
select is(pg_temp.ids($$select order_id::text from public.order_fulfilments$$),
  array['90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002',
        '90000000-0000-0000-0000-000000000004'],
  'with Oyo uncovered, Z reads Oyo fulfilments');
-- fix round 2: the administrative powers and chat rooms follow the same rule
select lives_ok(
  $$select public.invite_tenant_user(pg_temp.k(60), '2348000000010', 'TM', '40000000-0000-0000-0000-000000000043', null)$$,
  'with Oyo uncovered, Z invites a TM into an Oyo territory');
select lives_ok(
  $$select public.upsert_territory(pg_temp.k(61), '40000000-0000-0000-0000-000000000043',
      '30000000-0000-0000-0000-000000000033', 'Ibadan', null)$$,
  'with Oyo uncovered, Z edits an Oyo territory');
select lives_ok(
  $$select public.upsert_area(pg_temp.k(62), null, '40000000-0000-0000-0000-000000000043', 'Bodija')$$,
  'with Oyo uncovered, Z edits an Oyo area');
select lives_ok(
  $$select public.upsert_zone(pg_temp.k(63), '30000000-0000-0000-0000-000000000033', null,
      '{"type":"Polygon","coordinates":[[[3.8,7.3],[4.0,7.3],[4.0,7.5],[3.8,7.5],[3.8,7.3]]]}'::jsonb)$$,
  'with Oyo uncovered, Z edits Oyo''s boundary');
select is((select count(*)::int from public.chat_channels
            where channel_type = 'ZONE' and zone_id = '30000000-0000-0000-0000-000000000033'), 1,
  'with Oyo uncovered, Z sees Oyo''s ZONE channel');
select pg_temp.act_as(2);
select lives_ok($$select pg_temp.resend(52, 4)$$, 'with Oyo uncovered, Z2 reaches it too');
-- a platform administrator gives Oyo back to Z2: Z is refused again
select pg_temp.act_as(8);
select lives_ok(
  $$select public.set_zone_zsm(pg_temp.k(53), '30000000-0000-0000-0000-000000000033', '20000000-0000-0000-0000-000000000002')$$,
  'the platform administrator sets Z2 on Oyo');
select pg_temp.act_as(1);
select throws_ok($$select public.set_ticket_priority(pg_temp.k(54), '62000000-0000-0000-0000-000000000004', 'LOW')$$,
  '42501', null, 'with Oyo covered by Z2, Z cannot act on the Oyo ORDER ticket');
select throws_ok($$select pg_temp.resend(55, 4)$$, '42501', null, 'nor re-send the Oyo order''s code');
select is(pg_temp.ids($$select order_id::text from public.order_contacts$$),
  array['90000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000003'],
  'nor read Oyo buyer contacts');
select is((select count(*)::int from public.audit_logs where operation = 'zsm_scope_fixture2'), 1,
  'nor Oyo audit rows');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(64), '2348000000011', 'TM', '40000000-0000-0000-0000-000000000043', null)$$,
  '42501', null, 'with Oyo covered by Z2, Z cannot invite into an Oyo territory');
select throws_ok(
  $$select public.upsert_territory(pg_temp.k(65), '40000000-0000-0000-0000-000000000043',
      '30000000-0000-0000-0000-000000000033', 'Ibadan', null)$$,
  '42501', null, 'nor edit an Oyo territory');
select throws_ok(
  $$select public.upsert_area(pg_temp.k(66), null, '40000000-0000-0000-0000-000000000043', 'Dugbe')$$,
  '42501', null, 'nor an Oyo area');
select throws_ok(
  $$select public.upsert_zone(pg_temp.k(67), '30000000-0000-0000-0000-000000000033', null, null)$$,
  '42501', 'this zone is not yours', 'nor Oyo''s boundary');
select is((select count(*)::int from public.chat_channels
            where channel_type = 'ZONE' and zone_id = '30000000-0000-0000-0000-000000000033'), 0,
  'nor see Oyo''s ZONE channel');

-- ── web routing ─────────────────────────────────────────────────────────
reset role;
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null::public.web_referral_codes,
            (select id from public.ng_lgas where state_code = 'OY' order by name limit 1))).accountable_id,
  '20000000-0000-0000-0000-000000000002'::uuid, 'a codeless Oyo web order goes to Z2');
select is((public.web_route_try('10000000-0000-0000-0000-000000000001', null::public.web_referral_codes,
            (select id from public.ng_lgas where state_code = 'LA' order by name limit 1))).accountable_id,
  '20000000-0000-0000-0000-000000000001'::uuid, 'a codeless Lagos web order goes to Z');

select * from finish();
rollback;
