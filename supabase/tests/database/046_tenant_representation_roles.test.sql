-- Addendum A6 §16.3 (Monvelo Step 1c, Task 1) — CLIENT_SERVICE_MANAGER,
-- TENANT_ADMIN and LOGISTICS_MANAGER: appointment, invites, anchors,
-- dispatch and the staff read helper.
begin;
create extension if not exists pgtap with schema extensions;

select plan(36);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- 1 platform admin · 2 ZSM (A) · 3 CSM candidate · 4 LM candidate
-- · 5 TENANT_ADMIN candidate · 6 TM (A) · 7 MONVELO_OPERATOR · 8 ZSM (B)
-- · 9, 10 spare · 11 shop owner
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 11) n;
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN'
 where id = '20000000-0000-0000-0000-000000000001';
update public.profiles set platform_role = 'MONVELO_OPERATOR'
 where id = '20000000-0000-0000-0000-000000000007';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000002', 'Allen');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000006',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'ZSM', null, null, null, 'ACTIVE', true);
insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006'),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'UNI-LAGOS', 'CENTRAL',
   null, '20000000-0000-0000-0000-000000000008');

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

-- 1, 2: paid web orders of tenant A (the LM dispatches 1; the TENANT_ADMIN is refused on 2)
-- 3: a paid web order of tenant B
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000006', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-AAAAA1', md5('ng_lga:LA:Ikeja')::uuid,
   '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000006', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-AAAAA2', md5('ng_lga:LA:Ikeja')::uuid,
   '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'ONLINE',
   '20000000-0000-0000-0000-000000000008', 2500, 'PAID', 'PAYSTACK_WEB', 'TF-BBBBB3', md5('ng_lga:LA:Ikeja')::uuid,
   '40000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000009');
insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'Buyer 1', '+2348011111101');

-- a SYSTEM ticket of tenant A
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, system_key, status) values
  ('a0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAS1', 'SYSTEM', 'SYSTEM', 'TEST:046', 'OPEN');

-- one shop enrolment in each tenant
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('b0000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000011',
   'SUBURBAN', extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1');
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by) values
  ('c0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'b0000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', 'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000006'),
  ('c0000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000002', 'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000008');
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id) values
  ('7eaf0000-0000-4000-8000-000000000001', 'b0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006', now(), 'MV-SHARE-2026-10', 'c0000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000008', now(), 'MV-SHARE-2026-10', 'c0000000-0000-0000-0000-000000000002');

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

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

-- ── CSM appointment ─────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select lives_ok(
  $$select public.appoint_client_service_manager(pg_temp.k(1), '7eaf0000-0000-4000-8000-000000000001', '2348000000003')$$,
  'the platform admin appoints a CSM for tenant A');
select is(
  public.appoint_client_service_manager(pg_temp.k(1), '7eaf0000-0000-4000-8000-000000000001', '2348000000003'),
  public.appoint_client_service_manager(pg_temp.k(1), '7eaf0000-0000-4000-8000-000000000001', '2348000000003'),
  'the same key replays');
reset role;
select is(
  (select role::text || ':' || status || ':' || (zone_id is null and territory_id is null and area_id is null and reports_to_id is null)::text
     from public.tenant_users where tenant_id = '7eaf0000-0000-4000-8000-000000000001'
      and profile_id = '20000000-0000-0000-0000-000000000003'),
  'CLIENT_SERVICE_MANAGER:INVITED:true', 'the CSM row is INVITED with no anchors');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(2), '2348000000009', 'CLIENT_SERVICE_MANAGER', null, null)$$,
  '42501', 'only a platform administrator appoints a client service manager', 'a ZSM cannot invite a CSM');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(3), '2348000000009', 'TENANT_ADMIN', null, null)$$,
  '42501', 'the client service manager invites tenant admins and logistics managers', 'a ZSM cannot invite a TENANT_ADMIN');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000007', null);
select throws_ok(
  $$select public.appoint_client_service_manager(pg_temp.k(4), '7eaf0000-0000-4000-8000-000000000001', '2348000000009')$$,
  '42501', 'not permitted for this platform role', 'a MONVELO_OPERATOR cannot appoint a CSM');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select throws_ok(
  $$select public.appoint_client_service_manager(pg_temp.k(5), '7eaf0000-0000-4000-8000-000000000001', '2348000000003')$$,
  '23505', 'this person is already a member of the tenant', 'appointing the same person twice is refused');
reset role;

-- ── CSM invites ─────────────────────────────────────────────────────────
update public.tenant_users set status = 'ACTIVE'
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and profile_id = '20000000-0000-0000-0000-000000000003';
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001');
select lives_ok(
  $$select public.invite_tenant_user(pg_temp.k(6), '2348000000004', 'LOGISTICS_MANAGER', null, null)$$,
  'the CSM invites a logistics manager');
reset role;
select is(
  (select reports_to_id from public.tenant_users
    where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and profile_id = '20000000-0000-0000-0000-000000000004'),
  (select id from public.tenant_users
    where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and profile_id = '20000000-0000-0000-0000-000000000003'),
  'the LM reports to the CSM');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(7), '2348000000009', 'TM', '40000000-0000-0000-0000-000000000001', null)$$,
  '42501', 'a client service manager invites tenant admins and logistics managers only', 'a CSM cannot invite a TM');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(8), '2348000000009', 'LOGISTICS_MANAGER', '40000000-0000-0000-0000-000000000001', null)$$,
  'P0001', 'tenant-wide roles have no territory or area', 'a CSM passing a territory is refused');
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(9), '2348000000009', 'LOGISTICS_MANAGER', null, '50000000-0000-0000-0000-000000000002')$$,
  'P0001', 'a logistics manager reports to the inviting client service manager', 'an LM cannot report to someone else');
select lives_ok(
  $$select public.invite_tenant_user(pg_temp.k(10), '2348000000005', 'TENANT_ADMIN', null, null)$$,
  'the CSM invites a TENANT_ADMIN');
reset role;
select is(
  (select reports_to_id is null and zone_id is null and territory_id is null from public.tenant_users
    where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and profile_id = '20000000-0000-0000-0000-000000000005'),
  true, 'the TENANT_ADMIN row has no anchors');

-- ── anchors at insert level ─────────────────────────────────────────────
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, territory_id, reports_to_id, status)
    select tenant_id, '20000000-0000-0000-0000-000000000009', 'LOGISTICS_MANAGER',
           '40000000-0000-0000-0000-000000000001', id, 'INVITED'
      from public.tenant_users where profile_id = '20000000-0000-0000-0000-000000000003'$$,
  '23514', null, 'an LM row with a territory is refused');
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, status)
    values ('7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000010', 'LOGISTICS_MANAGER', 'INVITED')$$,
  '23514', null, 'an LM row without reports_to is refused');

-- ── dispatch and delivery ───────────────────────────────────────────────
update public.tenant_users set status = 'ACTIVE'
 where tenant_id = '7eaf0000-0000-4000-8000-000000000001'
   and profile_id in ('20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000005');
select ok(
  (select public.fulfilment_can_dispatch(tu, o)
     from public.tenant_users tu, public.orders o
    where tu.profile_id = '20000000-0000-0000-0000-000000000004' and o.id = '90000000-0000-0000-0000-000000000001'),
  'an ACTIVE LM can dispatch any warehouse of the tenant');
select ok(
  not (select public.fulfilment_can_dispatch(tu, o)
     from public.tenant_users tu, public.orders o
    where tu.profile_id = '20000000-0000-0000-0000-000000000004' and o.id = '90000000-0000-0000-0000-000000000003'),
  'but not another tenant''s order');
select ok(
  not (select public.fulfilment_can_dispatch(tu, o)
     from public.tenant_users tu, public.orders o
    where tu.profile_id = '20000000-0000-0000-0000-000000000005' and o.id = '90000000-0000-0000-0000-000000000001'),
  'a TENANT_ADMIN cannot dispatch');
select is(
  (select public.fulfilment_delivery_path(tu, o)
     from public.tenant_users tu, public.orders o
    where tu.profile_id = '20000000-0000-0000-0000-000000000004' and o.id = '90000000-0000-0000-0000-000000000001'),
  'COURIER', 'the LM delivers by the delivery-code path');

select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
select lives_ok(
  $$select public.mark_order_dispatched(pg_temp.k(11), '90000000-0000-0000-0000-000000000001', null, '1234', 'test-gw-secret')$$,
  'the LM dispatches a paid web order');
reset role;
select is((select status from public.orders where id = '90000000-0000-0000-0000-000000000001'),
  'IN_TRANSIT', 'and the order is IN_TRANSIT');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.order_fulfilments where order_id = '90000000-0000-0000-0000-000000000001'),
  1, 'the LM reads the fulfilment row of the order it dispatched');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok(
  $$select public.mark_order_dispatched(pg_temp.k(12), '90000000-0000-0000-0000-000000000002', null, '1234', 'test-gw-secret')$$,
  '42501', 'not permitted to dispatch this order', 'a TENANT_ADMIN cannot dispatch');

-- ── TENANT_ADMIN is read-only ───────────────────────────────────────────
select throws_ok(
  $$select public.invite_tenant_user(pg_temp.k(13), '2348000000009', 'DSA', '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000006')$$,
  '42501', 'role TENANT_ADMIN may not perform this operation', 'a TENANT_ADMIN cannot invite');
select throws_ok(
  $$select public.claim_ticket(pg_temp.k(14), 'a0000000-0000-0000-0000-000000000001')$$,
  '42501', 'you may not act on this ticket', 'a TENANT_ADMIN cannot claim a SYSTEM ticket');
select is((select count(*)::int from public.monvelo_shop_enrolments
            where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  1, 'a TENANT_ADMIN reads its tenant''s enrolments');
select is((select count(*)::int from public.monvelo_shop_enrolments
            where tenant_id = '10000000-0000-0000-0000-000000000002'),
  0, 'and none of another tenant''s');
select is((select count(*)::int from public.order_fulfilments),
  0, 'a TENANT_ADMIN reads no fulfilment rows');
reset role;

-- ── the web default agent is not a tenant-wide role member ────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001');
select throws_ok(
  $$select public.set_web_defaults(pg_temp.k(15), null, '20000000-0000-0000-0000-000000000005')$$,
  'P0001', 'the default agent must be an active member of this tenant without a tenant-wide role', 'a TENANT_ADMIN cannot be the web default agent');
select throws_ok(
  $$select public.set_web_defaults(pg_temp.k(16), null, '20000000-0000-0000-0000-000000000004')$$,
  'P0001', 'the default agent must be an active member of this tenant without a tenant-wide role', 'nor a logistics manager');
select lives_ok(
  $$select public.set_web_defaults(pg_temp.k(17), null, '20000000-0000-0000-0000-000000000006')$$,
  'a TM can be the web default agent');
reset role;

-- ── appointment needs an ACTIVE tenant ──────────────────────────────────
update public.tenants set status = 'SUSPENDED' where id = '10000000-0000-0000-0000-000000000002';
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select throws_ok(
  $$select public.appoint_client_service_manager(pg_temp.k(18), '10000000-0000-0000-0000-000000000002', '2348000000009')$$,
  'P0001', 'the tenant is not active', 'a CSM cannot be appointed to a suspended tenant');
reset role;

-- ── is_platform_staff and grants ────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select ok(public.is_platform_staff(), 'is_platform_staff is true for the platform admin');
reset role;
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001');
select ok(not public.is_platform_staff(), 'and false for a ZSM');
reset role;
select ok(has_function_privilege('authenticated', 'public.appoint_client_service_manager(uuid,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.appoint_client_service_manager(uuid,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.fulfilment_can_dispatch(public.tenant_users,public.orders)', 'execute'),
  'grants: appoint is for authenticated only; the fulfilment helper stays internal');

select * from finish();
rollback;
