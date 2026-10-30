-- Addendum A6 §16.3, §16.4 (Monvelo Step 1c, Task 4) — the catalogue and stock
-- movements cite a current CATALOGUE / STOCK contact-report decision, every
-- movement is one insert-only row, and a catalog guard proves that no function
-- writes the guarded tables without citing a decision or being named here.
begin;
create extension if not exists pgtap with schema extensions;

select plan(55);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- tenant A = TEAFAIR: 1 CSM · 2 ZSM · 3 LOGISTICS_MANAGER · 4 TENANT_ADMIN · 5 TM · 6 DSA
-- tenant B (Unilever): 7 ZSM · 8 CSM
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 8) n;
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
   'LOGISTICS_MANAGER', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TENANT_ADMIN', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000005', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000007',
   'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true);
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'CENTRAL-A', 'CENTRAL', null),
  ('70000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', 'CENTRAL-B', 'CENTRAL', null);

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

-- a report with one decision of each subject the tests cite
create function pg_temp.rep(p_sup uuid default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'MEETING',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
    'summary', 'Agreed terms, settings, fee and catalogue.', 'supersedes_id', p_sup,
    'decisions', jsonb_build_array(
      jsonb_build_object('subject', 'CATALOGUE', 'text', 'Catalogue'),
      jsonb_build_object('subject', 'STOCK', 'text', 'Stock')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222')));
$$;
grant execute on function pg_temp.rep(uuid) to authenticated;

-- cd: named decisions; cr: named reports
create temp table cr (n text primary key, id uuid);
create temp table cd (n text, subject text, id uuid, primary key (n, subject));
grant select on cr, cd to authenticated;

-- file (CSM), review (ZSM), request + upload stand-in + attach (CSM); keys kb..kb+3
create function pg_temp.cite(p_name text, p_tenant uuid, p_csm uuid, p_zsm uuid, p_kb integer,
                             p_sup uuid default null, p_finish boolean default true) returns void
language plpgsql as $$
declare v_rid uuid; v_slot jsonb;
begin
  perform pg_temp.act_as(p_csm, p_tenant);
  v_rid := (public.file_contact_report(pg_temp.k(p_kb), pg_temp.rep(p_sup)) ->> 'report_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into cr values (p_name, v_rid);
  insert into cd select p_name, d.subject, d.id from public.contact_report_decisions d where d.report_id = v_rid;
  if not p_finish then return; end if;
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

create function pg_temp.w(n integer) returns uuid language sql as
  $$ select ('70000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.w(integer) to authenticated;
create function pg_temp.qty(p_wh integer) returns numeric language sql as
  $$ select quantity from public.inventory_batches where warehouse_id = pg_temp.w(p_wh) and batch_number = 'B1' and sku_code = 'PUR-200' $$;
grant execute on function pg_temp.qty(integer) to authenticated;
-- the detail of a refused call, for the TF001 assertions
create function pg_temp.detail_of(p_sql text) returns text language plpgsql as $$
declare v_d text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics v_d = pg_exception_detail;
  return v_d;
end; $$;
grant execute on function pg_temp.detail_of(text) to authenticated;

-- ── catalogue ───────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select is(public.upsert_catalogue_product(pg_temp.k(300), pg_temp.d('A', 'CATALOGUE'), jsonb_build_object(
    'sku_code', 'PUR-200', 'product_name', 'Purerigin 200ml', 'brand', 'Purerigin', 'category', 'Oil',
    'sale_category', 'COSMETICS', 'unit_price', 5000, 'wholesale_price', 4000, 'nafdac_number', 'LG-IKJ-02-2134',
    'carton_units', 12, 'break_bulk_units', 3)) ->> 'created',
  'true', 'the CSM creates a COSMETICS product with a NAFDAC number');
select is(public.upsert_catalogue_product(pg_temp.k(301), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_object('sku_code', 'PUR-200', 'wholesale_price', 4100)) ->> 'created',
  'false', 'an update of the wholesale price is not a creation');
reset role;
select is((select wholesale_price::text || ':' || (decision_id = pg_temp.d('A', 'CATALOGUE'))::text || ':' || brand
             from public.central_products where sku_code = 'PUR-200'),
  '4100.00:true:Purerigin', 'the given key changed, the others stayed, and decision_id is set');
select is((select (before ->> 'wholesale_price') || '>' || (after ->> 'wholesale_price')
             from public.audit_logs where operation = 'upsert_catalogue_product' and idempotency_key = pg_temp.k(301)),
  '4000.00>4100.00', 'the audit row holds the before and after rows');

select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(302), pg_temp.d('A', 'CATALOGUE'), jsonb_build_object(
    'sku_code', 'PUR-NONAF', 'product_name', 'No number', 'brand', 'Purerigin', 'category', 'Oil',
    'sale_category', 'COSMETICS', 'unit_price', 1, 'wholesale_price', 1))$$,
  '23514', null, 'a COSMETICS product without a NAFDAC number breaks the CHECK');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(303), pg_temp.d('A', 'CATALOGUE'), jsonb_build_object(
    'sku_code', 'SIM-1', 'product_name', 'SIM', 'brand', 'X', 'category', 'Airtime',
    'sale_category', 'TELECOM', 'unit_price', 1, 'wholesale_price', 1))$$,
  'P0001', null, 'TELECOM for a non-Sureach tenant keeps the existing refusal');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(304), pg_temp.d('A', 'STOCK'),
    jsonb_build_object('sku_code', 'PUR-200', 'unit_price', 1))$$,
  'P0001', 'cite a decision on CATALOGUE', 'a STOCK decision is refused');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(305), null,
    jsonb_build_object('sku_code', 'PUR-200', 'unit_price', 1))$$,
  'P0001', 'cite the contact report decision that agreed this catalogue change', 'no decision is refused');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(306), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_object('sku_code', 'PUR-200', 'tenant_id', '10000000-0000-0000-0000-000000000002'))$$,
  'P0001', 'unknown product field tenant_id', 'a tenant_id key is refused');
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(307), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_object('sku_code', 'PUR-200', 'unit_price', 1))$$,
  '42501', null, 'a ZSM cannot change the catalogue');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(308), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_object('sku_code', 'PUR-200', 'unit_price', 1))$$,
  '42501', null, 'a logistics manager cannot change the catalogue');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(309), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_object('sku_code', 'PUR-200', 'unit_price', 1))$$,
  '42501', null, 'a TENANT_ADMIN cannot change the catalogue');
select pg_temp.act_as(pg_temp.u(8), '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.upsert_catalogue_product(pg_temp.k(310), pg_temp.d('A', 'CATALOGUE'),
    jsonb_build_object('sku_code', 'PUR-200', 'unit_price', 1))$$,
  '42501', 'decision not found', 'another tenant''s CSM cannot cite tenant A''s decision');

-- ── stock ───────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is(public.record_stock_receipt(pg_temp.k(320), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 24,
    timestamptz '2027-06-30 00:00+00') ->> 'quantity', '24.000', 'the LM receives 24 units into batch B1');
select is(public.record_stock_receipt(pg_temp.k(321), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 24, null) ->> 'quantity',
  '48.000', 'receiving again adds to 48');
select throws_ok($$select public.record_stock_receipt(pg_temp.k(322), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 1,
    timestamptz '2028-01-01 00:00+00')$$,
  'P0001', 'this batch already has a different expiry', 'a different expiry on an existing batch is refused');
select is(public.record_stock_receipt(pg_temp.k(321), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 24, null) ->> 'quantity',
  '48.000', 'a replayed receipt returns the first answer');
reset role;
select is(pg_temp.qty(1), 48.000, 'and adds nothing');

select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is(public.record_stock_transfer(pg_temp.k(323), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'B1', 12) ->> 'quantity',
  '36.000', 'transferring 12 leaves 36 at the source');
reset role;
select is(pg_temp.qty(2), 12.000, 'and 12 at the regional warehouse');
select is((select count(*)::int from public.inventory_batches b1 join public.inventory_batches b2
             on b2.sku_code = b1.sku_code and b2.batch_number = b1.batch_number
            where b1.warehouse_id = pg_temp.w(1) and b2.warehouse_id = pg_temp.w(2)
              and b1.expires_at = b2.expires_at and b1.expires_at is not null), 1,
  'the destination batch has the source''s expiry');

select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_stock_transfer(pg_temp.k(324), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'B1', 100)$$,
  'TF001', 'insufficient stock', 'transferring 100 is insufficient stock');
select is(pg_temp.detail_of($$select public.record_stock_transfer(pg_temp.k(325), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'B1', 100)$$)::jsonb ->> 'available',
  '36', 'the detail names the available quantity');
select is(pg_temp.detail_of($$select public.record_stock_transfer(pg_temp.k(326), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'B1', 100)$$)::jsonb ->> 'requested',
  '100', 'and the requested quantity');
select is(pg_temp.detail_of($$select public.record_stock_transfer(pg_temp.k(327), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'B1', 100)$$)::jsonb ->> 'sku_code',
  'PUR-200', 'and the sku_code');
reset role;
select is(pg_temp.qty(1)::text || ':' || pg_temp.qty(2)::text, '36.000:12.000', 'a failed transfer leaves both batches unchanged');

select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_stock_transfer(pg_temp.k(328), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'NOPE', 1)$$,
  'TF001', 'insufficient stock', 'transferring from a batch that does not exist is insufficient stock');
select throws_ok($$select public.record_stock_adjustment(pg_temp.k(329), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', -40, 'breakage')$$,
  'TF001', 'insufficient stock', 'an adjustment of -40 is insufficient stock');
select throws_ok($$select public.record_stock_adjustment(pg_temp.k(330), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', -1, null)$$,
  'P0001', 'a reason is required for an adjustment', 'an adjustment without a reason is refused');
select is(public.record_stock_adjustment(pg_temp.k(331), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', -6, 'breakage') ->> 'quantity',
  '30.000', 'an adjustment of -6 leaves 30');

-- refusals
select throws_ok($$select public.record_stock_receipt(pg_temp.k(332), pg_temp.d('A', 'STOCK'), pg_temp.w(9), 'PUR-200', 'B1', 1, null)$$,
  '42501', 'warehouse not found in this tenant', 'a warehouse of tenant B is refused');
select throws_ok($$select public.record_stock_receipt(pg_temp.k(333), pg_temp.d('A', 'CATALOGUE'), pg_temp.w(1), 'PUR-200', 'B1', 1, null)$$,
  'P0001', 'cite a decision on STOCK', 'a CATALOGUE decision is refused');
select throws_ok($$select public.record_stock_receipt(pg_temp.k(334), null, pg_temp.w(1), 'PUR-200', 'B1', 1, null)$$,
  'P0001', 'cite the contact report decision that agreed this stock movement', 'no decision is refused');
select throws_ok($$select public.record_stock_receipt(pg_temp.k(335), pg_temp.d('B', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 1, null)$$,
  '42501', 'decision not found', 'another tenant''s decision is refused');
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_stock_receipt(pg_temp.k(336), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 1, null)$$,
  '42501', null, 'a TENANT_ADMIN cannot receive stock');
select throws_ok($$select public.record_stock_transfer(pg_temp.k(337), pg_temp.d('A', 'STOCK'), pg_temp.w(1), pg_temp.w(2), 'PUR-200', 'B1', 1)$$,
  '42501', null, 'a TENANT_ADMIN cannot transfer stock');
select throws_ok($$select public.record_stock_adjustment(pg_temp.k(338), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 1, 'x')$$,
  '42501', null, 'a TENANT_ADMIN cannot adjust stock');
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select public.record_stock_receipt(pg_temp.k(339), pg_temp.d('A', 'STOCK'), pg_temp.w(1), 'PUR-200', 'B1', 1, null)$$,
  '42501', null, 'a ZSM cannot receive stock');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select is(public.record_stock_receipt(pg_temp.k(340), pg_temp.d('A', 'STOCK'), pg_temp.w(2), 'PUR-200', 'B2', 5, null) ->> 'quantity',
  '5.000', 'the CSM may receive stock too');

-- ── movement records ────────────────────────────────────────────────────
reset role;
select is((select count(*)::int from public.stock_movements), 5,
  'one movement row per successful call (receipt x3, transfer, adjustment)');
select is((select string_agg(kind || ':' || quantity::text || ':' || (decision_id = pg_temp.d('A', 'STOCK'))::text, ',' order by created_at, kind)
             from public.stock_movements where kind = 'ADJUSTMENT'),
  'ADJUSTMENT:-6.000:true', 'a movement holds its kind, signed quantity and decision');
select throws_ok($$update public.stock_movements set quantity = 1$$, 'P0001', null, 'as postgres, update is refused');
select throws_ok($$delete from public.stock_movements$$, 'P0001', null, 'delete is refused');
select throws_ok($$truncate public.stock_movements$$, 'P0001', null, 'truncate is refused');
select throws_ok($$insert into public.stock_movements (tenant_id, kind, warehouse_id, to_warehouse_id, sku_code, batch_number, quantity, decision_id, recorded_by)
  values ('7eaf0000-0000-4000-8000-000000000001', 'TRANSFER', pg_temp.w(1), pg_temp.w(1), 'PUR-200', 'B1', 1, pg_temp.d('A', 'STOCK'), pg_temp.u(3))$$,
  '23514', null, 'a transfer to its own warehouse breaks the CHECK');
select throws_ok($$insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, decision_id, recorded_by)
  values ('7eaf0000-0000-4000-8000-000000000001', 'RECEIPT', pg_temp.w(1), 'PUR-200', 'B1', -1, pg_temp.d('A', 'STOCK'), pg_temp.u(3))$$,
  '23514', null, 'a receipt of a negative quantity breaks the CHECK');

select pg_temp.act_as(pg_temp.u(6), '7eaf0000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.stock_movements), 5, 'a DSA of the tenant reads the movements');
select throws_ok($$insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, decision_id, recorded_by)
  values ('7eaf0000-0000-4000-8000-000000000001', 'RECEIPT', pg_temp.w(1), 'PUR-200', 'B1', 1, pg_temp.d('A', 'STOCK'), pg_temp.u(6))$$,
  '42501', null, 'the API cannot write a movement');
select pg_temp.act_as(pg_temp.u(7), '10000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.stock_movements), 0, 'tenant B''s ZSM reads none');

-- ── zero unaudited backdoors (A6 §16.4; user, 2026-10-29) ───────────────
reset role;
create temp table writers as
select p.proname::text as proname,
       pg_get_function_identity_arguments(p.oid) as args,
       (pg_get_function_identity_arguments(p.oid) ~ 'p_decision_id uuid') as takes_decision,
       (p.prosrc ~ 'assert_citable_decision') as cites
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~*
       '(insert\s+into|update|delete\s+from|truncate(\s+table)?|merge\s+into)\s+(only\s+)?(public\.)?(monvelo_brand_terms|monvelo_tenant_settings|monvelo_tenant_fee_terms|central_products|inventory_batches|stock_movements)\y';

-- Named allowlist, each with its reason (A6 §16.4). No other function may write
-- these tables without citing a decision. There are no order-fulfilment stock
-- decrements today; one added later is operational and joins this list with that
-- reason. Trigger and guard functions that read these tables but do not mutate
-- them never match the scan.
create temp table allowlist (proname text primary key, reason text not null);
insert into allowlist values
  ('propose_monvelo_brand_terms', 'a draft: PROPOSED terms have no effect until approved, and approval cites a decision');

select ok(exists (select 1 from writers where proname = 'set_monvelo_tenant_settings'),
  'positive control: the scan finds set_monvelo_tenant_settings');
select ok(exists (select 1 from writers where proname = 'record_stock_transfer')
      and exists (select 1 from writers where proname = 'upsert_catalogue_product'),
  'positive control: the scan finds the catalogue and stock RPCs');
select is((select string_agg(proname || '(' || args || ')', ', ' order by proname) from writers
            where not (takes_decision and cites) and proname not in (select proname from allowlist)),
  null, 'every writer of the guarded tables cites a decision or is on the named allowlist');
select is((select count(*)::int from allowlist where proname not in (select proname from writers)), 0,
  'every allowlist entry still writes a guarded table (no stale entries)');
select is((select count(*)::int from writers w where takes_decision and not cites), 0,
  'a writer that takes p_decision_id also checks it with assert_citable_decision');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
              and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~*
                  '(execute|copy)\s[^;]*(monvelo_brand_terms|monvelo_tenant_settings|monvelo_tenant_fee_terms|central_products|inventory_batches|stock_movements)'), 0,
  'no function reaches a guarded table through dynamic SQL or COPY');

select * from finish();
rollback;

