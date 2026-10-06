-- Phase 2 — the write-RPC contract (Spec A §3.3, §3.5), the foundation RPCs,
-- brand-tier evaluation (§5.4) and pickup escalation (§7.4).
begin;
create extension if not exists pgtap with schema extensions;

select plan(48);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');

-- 1 ZSM · 2 TM (also TM at Unilever) · 3 DSA · 6 not yet a member · 7 DSM
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006'),
  ('20000000-0000-0000-0000-000000000007', '2348000000007');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', 'Kano'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000009', 'Fagge'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000007',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007', 'ACTIVE', true);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
-- functions get no PUBLIC execute by default here (grants migration)
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── contract shape (§3.3) ───────────────────────────────────────────────
-- every RPC the app may call takes the idempotency key first and no tenant
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.prorettype = 'jsonb'::regtype
      and (p.proargnames[1] is distinct from 'p_idempotency_key'
           or p.proargtypes[0] <> 'uuid'::regtype)),
  0, 'every app-callable RPC takes p_idempotency_key uuid first');
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.prorettype = 'jsonb'::regtype
      and p.proname <> 'set_active_tenant'
      and 'p_tenant_id' = any(p.proargnames)),
  0, 'no write RPC accepts a tenant id (decision 4); set_active_tenant only proposes one');
select ok(not has_function_privilege('anon', 'public.upsert_zone(uuid,uuid,text,jsonb)', 'execute'),
  'anon cannot execute write RPCs');
select ok(not has_function_privilege('authenticated', 'public.idempotency_begin(uuid,text,jsonb)', 'execute'),
  'the idempotency internals are not callable from the API');
select ok(not has_function_privilege('authenticated', 'public.write_audit(uuid,text,text,text,jsonb,jsonb,uuid,public.audit_source_enum,uuid)', 'execute'),
  'write_audit is not callable from the API');
select ok(not has_function_privilege('authenticated', 'public.requisition_required_level(uuid,text[])', 'execute'),
  'requisition_required_level is internal');
select ok(not has_function_privilege('authenticated', 'public.escalate_stale_pickups()', 'execute'),
  'escalate_stale_pickups is internal');

-- ── upsert_zone: actor and tenant come from the JWT ─────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000001', null, 'Ibadan', null)$$,
  'a ZSM can create a zone');
reset role;
select is(
  (select tenant_id from public.zones where zone_name = 'Ibadan'),
  '10000000-0000-0000-0000-000000000001'::uuid, 'the zone lands in the tenant from the claim');
select is(
  (select count(*)::int from public.audit_logs
    where idempotency_key = 'aaaaaaaa-0000-0000-0000-000000000001'
      and operation = 'upsert_zone' and source = 'USER'
      and actor_id = '20000000-0000-0000-0000-000000000001' and actor_role = 'ZSM'),
  1, 'one audit row records actor, role and key');

-- ── idempotency (§3.3, §7.2) ────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(
  public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000001', null, 'Ibadan', null),
  public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000001', null, 'Ibadan', null),
  'a replayed key returns the original response');
reset role;
select is((select count(*)::int from public.zones where zone_name = 'Ibadan'), 1,
  'a replayed key does not write twice');
select is((select count(*)::int from public.audit_logs where idempotency_key = 'aaaaaaaa-0000-0000-0000-000000000001'), 1,
  'a replayed key does not audit twice');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000001', null, 'Oyo', null)$$,
  'TF002', null, 'a key reused with a different payload is refused (409)');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_active_tenant('aaaaaaaa-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001')$$,
  'TF002', null, 'a key reused by another actor or operation is refused');

-- ── authorisation (§5.3) ────────────────────────────────────────────────
select throws_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000002', null, 'Abuja', null)$$,
  '42501', null, 'a TM cannot create zones');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000003', null, 'Abuja', null)$$,
  '42501', null, 'a call with no subject is refused');
-- profile 6 belongs to no tenant but claims Nestle: claiming grants nothing
select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000004', null, 'Abuja', null)$$,
  '42501', null, 'a non-member claiming a tenant cannot write to it');

-- ── upsert_zone update + boundary ───────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000005', '30000000-0000-0000-0000-000000000001', 'Lagos',
      '{"type":"Polygon","coordinates":[[[3.1,6.4],[3.6,6.4],[3.6,6.7],[3.1,6.7],[3.1,6.4]]]}')$$,
  'a ZSM can set a zone boundary from GeoJSON');
reset role;
select is(
  (select extensions.geometrytype(boundary) from public.zones where id = '30000000-0000-0000-0000-000000000001'),
  'MULTIPOLYGON', 'a Polygon boundary is stored as a MultiPolygon');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.upsert_zone('aaaaaaaa-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000002', 'Hijack', null)$$,
  'P0001', null, 'a ZSM cannot edit another tenant''s zone');

-- ── upsert_territory ────────────────────────────────────────────────────
select lives_ok(
  $$select public.upsert_territory('aaaaaaaa-0000-0000-0000-000000000007', null,
      '30000000-0000-0000-0000-000000000001', 'Surulere', null)$$,
  'a ZSM can create a territory in their own zone');
select throws_ok(
  $$select public.upsert_territory('aaaaaaaa-0000-0000-0000-000000000008', null,
      '30000000-0000-0000-0000-000000000009', 'Nassarawa', null)$$,
  '42501', null, 'a ZSM cannot create a territory in another zone');

-- ── invite_tenant_user ──────────────────────────────────────────────────
select lives_ok(
  $$select public.invite_tenant_user('aaaaaaaa-0000-0000-0000-000000000009', '+2348000000006', 'DSA',
      '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007')$$,
  'a ZSM can invite a DSA into a territory of their zone');
reset role;
select is(
  (select status::text from public.tenant_users where profile_id = '20000000-0000-0000-0000-000000000006'),
  'INVITED', 'the invitee starts INVITED');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.invite_tenant_user('aaaaaaaa-0000-0000-0000-000000000010', '+2348000000099', 'DSA',
      '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000007')$$,
  'P0001', null, 'inviting a phone with no account is a business error');
select throws_ok(
  $$select public.invite_tenant_user('aaaaaaaa-0000-0000-0000-000000000011', '+2348000000006', 'ZSM',
      null, null)$$,
  '42501', null, 'a ZSM cannot invite another ZSM');
select throws_ok(
  $$select public.invite_tenant_user('aaaaaaaa-0000-0000-0000-000000000012', '+2348000000006', 'TM',
      '40000000-0000-0000-0000-000000000009', null)$$,
  '42501', null, 'a ZSM cannot invite into a territory outside their zone');

-- ── register_device ─────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.register_device('aaaaaaaa-0000-0000-0000-000000000013', 'hw-3', 'Tecno Spark', 'tok-1')$$,
  'a DSA registers a device');
select lives_ok(
  $$select public.register_device('aaaaaaaa-0000-0000-0000-000000000014', 'hw-3', 'Tecno Spark', 'tok-2')$$,
  'registering the same hardware again updates it');
reset role;
select results_eq(
  $$select push_token from public.devices where user_id = '20000000-0000-0000-0000-000000000003'$$,
  array['tok-2'], 'one device row, carrying the newest push token');

-- ── set_active_tenant ───────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.set_active_tenant('aaaaaaaa-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000002')$$,
  'a member of two tenants can switch');
reset role;
select results_eq(
  $$select tenant_id from public.tenant_users where profile_id = '20000000-0000-0000-0000-000000000002' and is_primary$$,
  array['10000000-0000-0000-0000-000000000002'::uuid], 'the selection moves is_primary');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_active_tenant('aaaaaaaa-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'nobody can select a tenant they are not an ACTIVE member of');

-- ── brand tiers (§5.4) ──────────────────────────────────────────────────
reset role;
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400', 'Milo 400g',        'MILO',         'Beverages', 2500, 2200),
  ('10000000-0000-0000-0000-000000000001', 'MAGGI-1',  'Maggi cube',       'Maggi',        'Seasoning',   50,   40),
  ('10000000-0000-0000-0000-000000000001', 'GP-SEMO',  'Golden Penny Semo','Golden Penny', 'Staples',   1200, 1100);

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select lives_ok(
  $$select public.set_brand_approval_policy('aaaaaaaa-0000-0000-0000-000000000017', 'Milo', 'TM')$$,
  'a ZSM sets a brand policy');
select lives_ok(
  $$select public.set_brand_approval_policy('aaaaaaaa-0000-0000-0000-000000000018', 'Maggi', 'ASM')$$,
  'a ZSM sets a second brand policy');
select throws_ok(
  $$select public.set_brand_approval_policy('aaaaaaaa-0000-0000-0000-000000000019', 'Maggi', 'DSA')$$,
  'P0001', null, 'a policy level must be on the approval ladder');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok(
  $$select public.set_brand_approval_policy('aaaaaaaa-0000-0000-0000-000000000020', 'Milo', 'DSM')$$,
  '42501', null, 'a DSA cannot change brand policy');

reset role;
select is(public.requisition_required_level('10000000-0000-0000-0000-000000000001', array['GP-SEMO']),
  'DSM'::public.tenant_role_enum, 'a brand with no policy clears at DSM');
select is(public.requisition_required_level('10000000-0000-0000-0000-000000000001', array['GP-SEMO', 'MAGGI-1']),
  'ASM'::public.tenant_role_enum, 'a staple plus an ASM brand needs ASM');
select is(public.requisition_required_level('10000000-0000-0000-0000-000000000001', array['MAGGI-1', 'MILO-400', 'GP-SEMO']),
  'TM'::public.tenant_role_enum, 'the highest brand tier wins, matched case-insensitively');
select throws_ok(
  $$select public.requisition_required_level('10000000-0000-0000-0000-000000000001', array['NOPE'])$$,
  'P0001', null, 'an unknown SKU is a business error, not a silent DSM');

-- ── 24-hour pickup escalation (§7.4) ────────────────────────────────────
insert into public.retail_shops (id, shop_name, contact_phone, density_category, location) values
  ('90000000-0000-0000-0000-000000000001', 'Mama Nkechi', '+2348000000010', 'MARKET_SQUARE',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326));
insert into public.retail_stock_pickups (id, tenant_id, retail_shop_id, dsa_agent_id, dsm_supervisor_id, status,
                                         confirmed_by, confirmed_at, escalated_at, created_at) values
  -- A: 25h, explicit DSM  → escalate
  ('a0000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000007', 'PENDING_CONFIRMATION',
   null, null, null, now() - interval '25 hours'),
  -- B: 25h, no DSM recorded → DSA's reporting DSM
  ('a0000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', null, 'PENDING_CONFIRMATION',
   null, null, null, now() - interval '25 hours'),
  -- C: 23h → too early
  ('a0000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', null, 'PENDING_CONFIRMATION',
   null, null, null, now() - interval '23 hours'),
  -- D: already escalated
  ('a0000000-0000-0000-0000-00000000000d', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', null, 'PENDING_CONFIRMATION',
   null, null, now() - interval '1 hour', now() - interval '30 hours'),
  -- E: confirmed
  ('a0000000-0000-0000-0000-00000000000e', '10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', null, 'CONFIRMED',
   '20000000-0000-0000-0000-000000000001', now(), null, now() - interval '30 hours');

select is(public.escalate_stale_pickups(), 2, 'two pickups past 24 hours are escalated');
select results_eq(
  $$select id from public.retail_stock_pickups
     where escalated_at is not null and escalated_at > now() - interval '1 minute' order by id$$,
  array['a0000000-0000-0000-0000-00000000000a'::uuid, 'a0000000-0000-0000-0000-00000000000b'::uuid],
  'exactly the stale, unconfirmed, not-yet-escalated pickups are flagged');
select is(
  (select count(*)::int from public.notifications
    where user_id = '20000000-0000-0000-0000-000000000007' and kind = 'PICKUP_ESCALATED'),
  2, 'the supervising DSM is notified for both (explicit and via reports_to)');
select is(
  (select count(*)::int from public.audit_logs
    where operation = 'escalate_pickup' and source = 'CRON'
      and teafair_agent_id = '20000000-0000-0000-0000-000000000003'),
  2, 'each escalation is audited as CRON against the accountable DSA');
select is(public.escalate_stale_pickups(), 0, 'a second run escalates nothing');
select is(
  (select count(*)::int from cron.job
    where jobname = 'escalate-stale-pickups' and schedule = '*/15 * * * *'),
  1, 'the escalation job is scheduled every 15 minutes');

select * from finish();
rollback;
