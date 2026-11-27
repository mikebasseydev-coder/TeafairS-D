-- Admin provisioning and batch loads (20261127120000): provision_tenant
-- (PLATFORM_SUPER_ADMIN, collision-free codes), upsert_tenant_skus (the CSM,
-- a CATALOGUE decision, batch rules) and post_opening_stock (the CSM or LM, a
-- STOCK decision, insert-only receipts). Idempotent replays, cross-tenant
-- isolation, invalid SKU codes, and no personal data in their audit rows.
begin;
create extension if not exists pgtap with schema extensions;

select plan(55);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- tenant A = TEAFAIR: 1 CSM · 2 ZSM · 3 LOGISTICS_MANAGER · 4 TENANT_ADMIN
-- tenant B (Unilever): 7 ZSM · 8 CSM · 5 = PLATFORM_SUPER_ADMIN (no membership)
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 8) n;
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN' where id = '20000000-0000-0000-0000-000000000005';
insert into public.tenant_users (id, tenant_id, profile_id, role, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'CLIENT_SERVICE_MANAGER', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'LOGISTICS_MANAGER', '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TENANT_ADMIN', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007',
   'ZSM', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'CLIENT_SERVICE_MANAGER', null, 'ACTIVE', true);
insert into public.warehouses (id, tenant_id, name, kind) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'OPEN-A1', 'CENTRAL'),
  ('70000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'OPEN-A2', 'CENTRAL'),
  ('70000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'OPEN-A3', 'CENTRAL'),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'OPEN-B', 'CENTRAL');

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
create function pg_temp.w(n integer) returns uuid language sql as
  $$ select ('70000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.w(integer) to authenticated;

-- a citable report with a CATALOGUE and a STOCK decision (as 049)
create function pg_temp.rep() returns jsonb language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'MEETING',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
    'summary', 'Agreed the opening catalogue and stock.',
    'decisions', jsonb_build_array(
      jsonb_build_object('subject', 'CATALOGUE', 'text', 'Catalogue'),
      jsonb_build_object('subject', 'STOCK', 'text', 'Stock')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222')));
$$;
grant execute on function pg_temp.rep() to authenticated;
create temp table cd (n text, subject text, id uuid, primary key (n, subject));
grant select on cd to authenticated;
create function pg_temp.cite(p_name text, p_tenant uuid, p_csm uuid, p_zsm uuid, p_kb integer) returns void
language plpgsql as $$
declare v_rid uuid; v_slot jsonb;
begin
  perform pg_temp.act_as(p_csm, p_tenant);
  v_rid := (public.file_contact_report(pg_temp.k(p_kb), pg_temp.rep()) ->> 'report_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into cd select p_name, d.subject, d.id from public.contact_report_decisions d where d.report_id = v_rid;
  perform pg_temp.act_as(p_zsm, p_tenant);
  perform public.review_contact_report(pg_temp.k(p_kb + 1), v_rid, 'APPROVED');
  perform pg_temp.act_as(p_csm, p_tenant);
  v_slot := public.request_contact_report_hard_copy(pg_temp.k(p_kb + 2), v_rid, 'application/pdf', 1000);
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('contact-reports', v_slot ->> 'storage_path', jsonb_build_object('size', '1000', 'mimetype', 'application/pdf'));
  perform pg_temp.act_as(p_csm, p_tenant);
  perform public.attach_contact_report_hard_copy(pg_temp.k(p_kb + 3), (v_slot ->> 'hard_copy_id')::uuid);
  perform set_config('role', 'postgres', true);
end; $$;
create function pg_temp.d(p_n text, p_subject text) returns uuid language sql as
  $$ select id from cd where n = p_n and subject = p_subject $$;
grant execute on function pg_temp.d(text, text) to authenticated;
select pg_temp.cite('A', '7eaf0000-0000-4000-8000-000000000001', pg_temp.u(1), pg_temp.u(2), 100);
select pg_temp.cite('B', '10000000-0000-0000-0000-000000000002', pg_temp.u(8), pg_temp.u(7), 130);
reset role;

-- two cosmetics SKUs in the house format
create function pg_temp.sku(p_code text, p_price numeric default 500) returns jsonb language sql as $$
  select jsonb_build_object('sku_code', p_code, 'product_name', 'Coconut oil ' || p_code, 'brand', 'Purerigin',
    'category', 'Oil', 'sale_category', 'COSMETICS', 'unit_price', p_price, 'wholesale_price', p_price - 100,
    'nafdac_number', 'LG-IKJ-02-2134', 'carton_units', 48, 'break_bulk_units', 12) $$;
grant execute on function pg_temp.sku(text, numeric) to authenticated;

-- ── provision_tenant ────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.provision_tenant(pg_temp.k(1), 'Lagos FMCG')$$,
  '42501', 'not permitted for this platform role', 'a CSM cannot provision a tenant');
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.provision_tenant(pg_temp.k(1), 'Lagos FMCG')$$,
  '42501', null, 'a ZSM cannot provision a tenant');

select pg_temp.act_as(pg_temp.u(5), null);
create temp table pt (n text primary key, r jsonb);
grant select, insert on pt to authenticated;
insert into pt values ('lagos', public.provision_tenant(pg_temp.k(1), 'Lagos FMCG'));
select is((select r ->> 'code' from pt where n = 'lagos'), 'LAGOS_FMCG', 'the code is the normalised name');
insert into pt values ('lagos2', public.provision_tenant(pg_temp.k(2), 'Lagos FMCG'));
select is((select r ->> 'code' from pt where n = 'lagos2'), 'LAGOS_FMCG_02', 'a colliding code gets _02');
insert into pt values ('lagos3', public.provision_tenant(pg_temp.k(3), 'Lagos  fmcg!'));
select is((select r ->> 'code' from pt where n = 'lagos3'), 'LAGOS_FMCG_03', 'then _03; punctuation and case fold');
select is(public.provision_tenant(pg_temp.k(1), 'Lagos FMCG'), (select r from pt where n = 'lagos'),
  'a replayed key returns the first answer');
insert into pt values ('nestle', public.provision_tenant(pg_temp.k(4), 'Nestlé Nigeria Plc', ' nestle-ng '));
select is((select r ->> 'code' from pt where n = 'nestle'), 'NESTLE_NG', 'a preferred code wins over the name');
insert into pt values ('long', public.provision_tenant(pg_temp.k(5), 'Supercalifragilistic Foods Limited'));
select is((select r ->> 'code' from pt where n = 'long'), 'SUPERCALIFRAG', 'a long code is cut to 13 characters');
select is((select r ->> 'status' from pt where n = 'lagos'), 'ACTIVE', 'a new tenant is ACTIVE');
select throws_ok($$select public.provision_tenant(pg_temp.k(1), 'Another name')$$,
  'TF002', null, 'the same key for a different tenant is an idempotency mismatch');
select throws_ok($$select public.provision_tenant(pg_temp.k(6), '   ')$$,
  'P0001', 'a tenant needs a name of 1 to 120 characters', 'a blank name is refused');
select throws_ok($$select public.provision_tenant(pg_temp.k(7), 'Okay name', '-x-')$$,
  'P0001', 'the tenant code needs at least two letters or digits', 'a one-character code is refused');
reset role;
select is((select count(*)::int from public.tenants where name = 'Lagos FMCG'), 2,
  'the replay created no third Lagos FMCG');
select ok(exists (select 1 from public.tenant_settings s join pt on (pt.r ->> 'tenant_id')::uuid = s.tenant_id
                   where pt.n = 'lagos' and s.currency = 'NGN'),
  'the tenant gets its default settings');
select is((select array_agg(category order by category) from public.tenant_allowed_categories a
             join pt on (pt.r ->> 'tenant_id')::uuid = a.tenant_id where pt.n = 'lagos'),
  array['COSMETICS', 'FOOD'], 'the tenant starts with FOOD and COSMETICS');
select is((select actor_role || ':' || entity_type from public.audit_logs
            where operation = 'provision_tenant' and idempotency_key = pg_temp.k(1)),
  'PLATFORM_SUPER_ADMIN:tenants', 'one audit row, attributed to the platform role');
select is((select count(*)::int from public.audit_logs a join pt on (pt.r ->> 'tenant_id')::uuid = a.tenant_id
            where a.operation = 'provision_tenant'), 5, 'each provisioned tenant has its audit row');
select ok(not has_function_privilege('anon', 'public.provision_tenant(uuid,text,text)', 'execute'),
  'anon cannot provision');

-- ── upsert_tenant_skus ──────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(200), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-15ML-SACHET')))$$,
  '42501', null, 'a ZSM cannot load the catalogue');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(200), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-15ML-SACHET')))$$,
  '42501', null, 'the TENANT_ADMIN cannot load the catalogue');

select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select is(public.upsert_tenant_skus(pg_temp.k(201), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-15ML-SACHET'), pg_temp.sku('OIL-COC-200ML'))),
  '{"created": 2, "updated": 0, "skipped": 0}'::jsonb, 'the CSM creates two SKUs in one batch');
select is(public.upsert_tenant_skus(pg_temp.k(201), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-15ML-SACHET'), pg_temp.sku('OIL-COC-200ML'))),
  '{"created": 2, "updated": 0, "skipped": 0}'::jsonb, 'a replay returns the first answer');
select is(public.upsert_tenant_skus(pg_temp.k(202), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-15ML-SACHET', 600), pg_temp.sku('OIL-COC-200ML'),
                      pg_temp.sku('OIL-COC-500ML'))),
  '{"created": 1, "updated": 1, "skipped": 1}'::jsonb, 'a re-upload counts created, updated and unchanged rows');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(203), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-1L'), pg_temp.sku('oil-coc-15ml')))$$,
  'P0001', 'item 2: sku_code must be 3 to 40 upper-case letters, digits, _ or -', 'a lower-case SKU is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(204), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OI')))$$,
  'P0001', null, 'a SKU under 3 characters is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(205), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL COC')))$$,
  'P0001', null, 'a SKU with a space is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(206), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-1L'), pg_temp.sku('OIL-COC-1L', 900)))$$,
  'P0001', 'item 2: sku_code OIL-COC-1L appears twice in this batch', 'a SKU twice in one batch is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(207), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-1L') || '{"carton_units": 0}'))$$,
  'P0001', 'item 1: carton_units must be a positive whole number', 'a zero pack factor is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(208), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-1L') || '{"tenant_id": "10000000-0000-0000-0000-000000000002"}'))$$,
  'P0001', 'item 1: unknown product field tenant_id', 'a tenant_id key is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(209), pg_temp.d('A', 'STOCK'),
    jsonb_build_array(pg_temp.sku('OIL-COC-1L')))$$,
  'P0001', 'cite a decision on CATALOGUE', 'a STOCK decision is refused');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(210), pg_temp.d('B', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-1L')))$$,
  '42501', 'decision not found', 'another tenant''s decision is not found');
select throws_ok($$select public.upsert_tenant_skus(pg_temp.k(211), pg_temp.d('A', 'CATALOGUE'), '[]'::jsonb)$$,
  'P0001', 'p_items must be an array of 1 to 500 products', 'an empty batch is refused');
reset role;
select is((select count(*)::int from public.central_products where sku_code = 'OIL-COC-1L'), 0,
  'a refused batch writes nothing (its valid first item included)');

select pg_temp.act_as(pg_temp.u(8), '10000000-0000-0000-0000-000000000002');
select is(public.upsert_tenant_skus(pg_temp.k(212), pg_temp.d('B', 'CATALOGUE'),
    jsonb_build_array(pg_temp.sku('OIL-COC-15ML-SACHET', 999))) ->> 'created',
  '1', 'tenant B creates the same sku_code as its own product');
reset role;
select is((select string_agg(t.code || '=' || p.unit_price::text, ',' order by t.code)
             from public.central_products p join public.tenants t on t.id = p.tenant_id
            where p.sku_code = 'OIL-COC-15ML-SACHET'),
  'TEAFAIR=600.00,UNILEVER=999.00', 'the two tenants'' rows stay separate');
select is((select count(*)::int from public.audit_logs where operation = 'upsert_tenant_skus'), 5,
  'one audit row per created or updated SKU; skipped rows and replays write none');
select is((select decision_id from public.central_products
            where tenant_id = '7eaf0000-0000-4000-8000-000000000001' and sku_code = 'OIL-COC-500ML'),
  pg_temp.d('A', 'CATALOGUE'), 'each product records the decision it cites');

-- ── post_opening_stock ──────────────────────────────────────────────────
create function pg_temp.line(p_sku text, p_batch text, p_qty numeric) returns jsonb language sql as
  $$ select jsonb_build_object('sku_code', p_sku, 'batch_number', p_batch, 'quantity', p_qty) $$;
grant execute on function pg_temp.line(text, text, numeric) to authenticated;

select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.post_opening_stock(pg_temp.k(300), pg_temp.d('A', 'STOCK'), pg_temp.w(1),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 48)))$$,
  '42501', null, 'a ZSM cannot post opening stock');

select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select is(public.post_opening_stock(pg_temp.k(301), pg_temp.d('A', 'STOCK'), pg_temp.w(1),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 48),
                      pg_temp.line('OIL-COC-15ML-SACHET', 'S1', 120) || '{"expires_at": "2027-06-30T00:00:00Z"}'),
    'GRN-2026/001'),
  jsonb_build_object('warehouse_id', pg_temp.w(1), 'lines', 2, 'total_quantity', 168),
  'the CSM posts a two-line opening load');
select is(public.post_opening_stock(pg_temp.k(301), pg_temp.d('A', 'STOCK'), pg_temp.w(1),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 48),
                      pg_temp.line('OIL-COC-15ML-SACHET', 'S1', 120) || '{"expires_at": "2027-06-30T00:00:00Z"}'),
    'GRN-2026/001') ->> 'lines',
  '2', 'a replay returns the first answer');
select throws_ok($$select public.post_opening_stock(pg_temp.k(302), pg_temp.d('A', 'STOCK'), pg_temp.w(1),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 10)))$$,
  'P0001', 'this warehouse already has stock movements; record a stock receipt instead',
  'a second opening load on the same warehouse is refused');
select throws_ok($$select public.post_opening_stock(pg_temp.k(303), pg_temp.d('A', 'STOCK'), pg_temp.w(9),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 10)))$$,
  '42501', 'warehouse not found in this tenant', 'another tenant''s warehouse is not found');
select throws_ok($$select public.post_opening_stock(pg_temp.k(304), pg_temp.d('A', 'STOCK'), pg_temp.w(3),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 10), pg_temp.line('NOPE-SKU', 'B1', 10)))$$,
  'P0001', 'unknown sku_code', 'an unknown SKU refuses the whole load');
select throws_ok($$select public.post_opening_stock(pg_temp.k(305), pg_temp.d('A', 'STOCK'), pg_temp.w(3),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 0)))$$,
  'P0001', 'line 1: quantity must be greater than zero', 'a zero quantity is refused');
select throws_ok($$select public.post_opening_stock(pg_temp.k(306), pg_temp.d('A', 'STOCK'), pg_temp.w(3),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 5), pg_temp.line('OIL-COC-200ML', ' B1 ', 5)))$$,
  'P0001', 'line 2: OIL-COC-200ML batch B1 appears twice in this load', 'a batch twice in one load is refused');
select throws_ok($$select public.post_opening_stock(pg_temp.k(307), pg_temp.d('A', 'STOCK'), pg_temp.w(3),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 5)), 'ada@example.com')$$,
  'P0001', null, 'a reference that looks like an email is refused');
select throws_ok($$select public.post_opening_stock(pg_temp.k(308), pg_temp.d('A', 'CATALOGUE'), pg_temp.w(3),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 5)))$$,
  'P0001', 'cite a decision on STOCK', 'a CATALOGUE decision is refused');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is(public.post_opening_stock(pg_temp.k(309), pg_temp.d('A', 'STOCK'), pg_temp.w(2),
    jsonb_build_array(pg_temp.line('OIL-COC-200ML', 'B1', 24))) ->> 'lines',
  '1', 'the logistics manager posts opening stock too');
reset role;
select is((select count(*)::int from public.stock_movements where warehouse_id = pg_temp.w(3)), 0,
  'refused loads write no movement');
select is((select count(*)::int from public.stock_movements
            where warehouse_id = pg_temp.w(1) and kind = 'RECEIPT' and reason = 'opening stock: GRN-2026/001'), 2,
  'the replay wrote no second set of RECEIPT movements');
select is((select string_agg(sku_code || ':' || trim_scale(quantity)::text || ':' || coalesce(to_char(expires_at at time zone 'UTC', 'YYYY-MM-DD'), '-'), ',' order by sku_code)
             from public.inventory_batches where warehouse_id = pg_temp.w(1)),
  'OIL-COC-15ML-SACHET:120:2027-06-30,OIL-COC-200ML:48:-', 'the batches hold exactly the posted quantities');
select ok(not exists (
    select 1 from public.inventory_batches b
     where b.warehouse_id in (pg_temp.w(1), pg_temp.w(2), pg_temp.w(3))
       and b.quantity <> (select coalesce(sum(m.quantity), 0) from public.stock_movements m
                           where m.warehouse_id = b.warehouse_id and m.sku_code = b.sku_code
                             and m.batch_number = b.batch_number)),
  'every balance equals the sum of its movements');
select is((select count(*)::int from public.audit_logs where operation = 'post_opening_stock'), 3,
  'one audit row per movement');

-- ── no personal data in any of the three audits ─────────────────────────
select is((select count(*)::int from public.audit_logs
            where operation in ('provision_tenant', 'upsert_tenant_skus', 'post_opening_stock')
              and (coalesce(before::text, '') || coalesce(after::text, '')) ~* '(\+?234[0-9]{7,}|@|phone|email|pin_hash)'),
  0, 'no audit row carries a phone number, an email or a PIN hash');
select is((select count(*)::int from public.idempotency_logs
            where operation in ('provision_tenant', 'upsert_tenant_skus', 'post_opening_stock')
              and coalesce(response::text, '') ~* '(\+?234[0-9]{7,}|@|phone|email)'),
  0, 'no reply carries personal data');

select * from finish();
rollback;
