-- Phase 1 — constraints and triggers hold the invariants Spec A relies on.
-- Runs as the postgres owner: this exercises the schema itself, not RLS
-- (RLS and grants are Phase 2).
begin;
create extension if not exists pgtap with schema extensions;

select plan(42);

-- ── fixtures ────────────────────────────────────────────────────────────
-- Two tenants; users are created through auth.users so handle_new_user runs.
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');

insert into auth.users (id, phone, raw_user_meta_data) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', '{"full_name":"Zainab ZSM"}'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002', '{"full_name":"Tunde TM"}'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003', '{"full_name":"Dayo DSA"}'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004', '{"full_name":"Uche ZSM other tenant"}');

-- ── handle_new_user (§6.3) ─────────────────────────────────────────────
select is(
  (select phone_number from public.profiles where id = '20000000-0000-0000-0000-000000000001'),
  '+2348000000001', 'a new auth user gets a profile with an E.164 phone');
select is(
  (select full_name from public.profiles where id = '20000000-0000-0000-0000-000000000001'),
  'Zainab ZSM', 'full_name is copied from user metadata');
select throws_ok(
  $$insert into auth.users (id, email) values ('20000000-0000-0000-0000-0000000000ff', 'nophone@example.com')$$,
  'P0001', null, 'an auth user without a phone number is refused');

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE'),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE'),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000004', 'ZSM', '30000000-0000-0000-0000-000000000002', null, null, 'ACTIVE');

-- ── tenancy: tenants are never deleted (decision 6) ────────────────────
select throws_ok(
  $$delete from public.tenants where id = '10000000-0000-0000-0000-000000000001'$$,
  '23503', null, 'a tenant with dependants cannot be deleted');
select throws_ok(
  $$insert into public.tenants (name, code) values ('Dup', 'NESTLE')$$,
  '23505', null, 'tenant code is unique');

-- ── tenant_users scope shape (§5.2) ─────────────────────────────────────
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, zone_id)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSM', '30000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'one membership per (tenant, profile)');
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role)
    values ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'ZSM')$$,
  '23514', null, 'a ZSM must be anchored to a zone');
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, territory_id, reports_to_id)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'DSA',
            '40000000-0000-0000-0000-000000000001', null)$$,
  '23514', null, 'a DSA must report to someone');
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, territory_id, reports_to_id)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'DSA',
            '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000004')$$,
  '23503', null, 'reports_to_id cannot point into another tenant');
select throws_ok(
  $$insert into public.tenant_users (tenant_id, profile_id, role, territory_id)
    values ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003', 'TM',
            '40000000-0000-0000-0000-000000000001')$$,
  '23503', null, 'territory_id cannot point into another tenant');
select throws_ok(
  $$update public.tenant_users set pin_hash = '1234' where id = '50000000-0000-0000-0000-000000000002'$$,
  '23514', null, 'pin_hash only accepts a bcrypt hash, never a raw PIN');

-- ── zone / territory managers (§6.9) ────────────────────────────────────
select throws_ok(
  $$update public.zones set zsm_id = '20000000-0000-0000-0000-000000000002'
    where id = '30000000-0000-0000-0000-000000000001'$$,
  'P0001', null, 'a TM cannot be set as zone manager');
select throws_ok(
  $$update public.zones set zsm_id = '20000000-0000-0000-0000-000000000004'
    where id = '30000000-0000-0000-0000-000000000001'$$,
  'P0001', null, 'a ZSM of another tenant cannot be set as zone manager');
select lives_ok(
  $$update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001'
    where id = '30000000-0000-0000-0000-000000000001'$$,
  'the tenant''s own active ZSM can be set as zone manager');
select lives_ok(
  $$update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
    where id = '40000000-0000-0000-0000-000000000001'$$,
  'the tenant''s own active TM can be set as territory manager');
select throws_ok(
  $$insert into public.territories (tenant_id, zone_id, territory_name)
    values ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', 'Cross')$$,
  '23503', null, 'a territory cannot sit in another tenant''s zone');

-- ── catalogue, brand tiers, inventory ───────────────────────────────────
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price) values
  ('10000000-0000-0000-0000-000000000001', 'MILO-400', 'Milo 400g', 'Milo', 'Beverages', 2500, 2200),
  ('10000000-0000-0000-0000-000000000002', 'OMO-1KG',  'Omo 1kg',   'Omo',  'Detergent', 1800, 1600);
insert into public.warehouses (id, tenant_id, name, kind) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Apapa Central', 'CENTRAL'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Ikeja Stockist', 'STOCKIST');

select throws_ok(
  $$insert into public.brand_approval_policies (tenant_id, brand, required_approval_level, updated_by)
    values ('10000000-0000-0000-0000-000000000001', 'Milo', 'DSA', '20000000-0000-0000-0000-000000000001')$$,
  '23514', null, 'a brand policy level must be DSM, ASM, TM or ZSM');
select lives_ok(
  $$insert into public.brand_approval_policies (tenant_id, brand, required_approval_level, updated_by)
    values ('10000000-0000-0000-0000-000000000001', 'Milo', 'TM', '20000000-0000-0000-0000-000000000001')$$,
  'a TM-level brand policy is accepted');
select throws_ok(
  $$insert into public.brand_approval_policies (tenant_id, brand, required_approval_level, updated_by)
    values ('10000000-0000-0000-0000-000000000001', 'MILO', 'ZSM', '20000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'brand policies are unique per tenant regardless of case');
select throws_ok(
  $$insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price)
    values ('10000000-0000-0000-0000-000000000001', 'X-1', 'X', '  ', 'Misc', 1, 1)$$,
  '23514', null, 'a product needs a non-blank brand');
select throws_ok(
  $$insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
    values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'MILO-400', 'B1', -1)$$,
  '23514', null, 'stock quantity cannot go negative');
select throws_ok(
  $$insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
    values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'OMO-1KG', 'B1', 5)$$,
  '23503', null, 'a batch cannot reference another tenant''s SKU');
select lives_ok(
  $$insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
    values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'MILO-400', 'B1', 12.5)$$,
  'fractional quantities are stored');

-- ── commerce ────────────────────────────────────────────────────────────
insert into public.requisitions (id, tenant_id, source_warehouse_id, dest_warehouse_id, requested_by) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002');

select throws_ok(
  $$update public.requisitions set status = 'HQ_APPROVED' where id = '70000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'requisition status is restricted to its workflow set');
select throws_ok(
  $$insert into public.requisitions (tenant_id, source_warehouse_id, dest_warehouse_id, requested_by)
    values ('10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
            '60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002')$$,
  '23514', null, 'a requisition cannot move stock to its own source');
select throws_ok(
  $$insert into public.requisition_items (tenant_id, requisition_id, sku_code, requested_qty)
    values ('10000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000001', 'OMO-1KG', 1)$$,
  '23503', null, 'a child row cannot carry a different tenant_id from its parent');
select throws_ok(
  $$insert into public.requisition_items (tenant_id, requisition_id, sku_code, requested_qty, approved_qty)
    values ('10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 'MILO-400', 5, 6)$$,
  '23514', null, 'approved quantity cannot exceed requested quantity');

insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount) values
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   'FIELD_DSA', '20000000-0000-0000-0000-000000000003', 5000);
insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price) values
  ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001', 'MILO-400', 2, 2500);

select is(
  (select line_total from public.order_items where order_id = '80000000-0000-0000-0000-000000000001'),
  5000.00::numeric(15,2), 'line_total is derived from qty × unit_price');
select throws_ok(
  $$insert into public.orders (tenant_id, channel, total_amount)
    values ('10000000-0000-0000-0000-000000000001', 'ONLINE', 1)$$,
  '23502', null, 'an order must name its accountable Teafair agent');

-- ── money ───────────────────────────────────────────────────────────────
select throws_ok(
  $$insert into public.fintech_partners (tenant_id, business_name, pos_network, commission_bps, contact_phone, paystack_subaccount_code)
    values ('10000000-0000-0000-0000-000000000001', 'Ade POS', 'OPAY', 10001, '+2348000000009', 'ACCT_abc')$$,
  '23514', null, 'commission_bps cannot exceed 10000');
select throws_ok(
  $$insert into public.fintech_partners (tenant_id, business_name, pos_network, commission_bps, contact_phone)
    values ('10000000-0000-0000-0000-000000000001', 'Ade POS', 'OPAY', 150, '+2348000000009')$$,
  '23502', null, 'a partner cannot exist without a Paystack subaccount');

insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference) values
  ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 5000, 'TF-REF-1');

select throws_ok(
  $$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference)
    values ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
            '20000000-0000-0000-0000-000000000003', 5000, 'TF-REF-1')$$,
  '23505', null, 'a Paystack reference is recorded once per tenant');
select throws_ok(
  $$insert into public.payments (tenant_id, order_id, teafair_agent_id, amount, paystack_reference)
    values ('10000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
            '20000000-0000-0000-0000-000000000003', 0, 'TF-REF-2')$$,
  '23514', null, 'a payment amount must be positive');
select throws_ok(
  $$insert into public.fintech_advances (tenant_id, agent_id, requested_amount, repayment_duration_days)
    values ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 1000, 31)$$,
  '23514', null, 'an advance runs for at most 30 days');

-- ── BVN hash (decision 17) ──────────────────────────────────────────────
insert into public.user_secure_profiles (user_id, bvn_nin_hash, bvn_hash_version) values
  ('20000000-0000-0000-0000-000000000001', 'hash-a', 1);
select throws_ok(
  $$insert into public.user_secure_profiles (user_id, bvn_nin_hash, bvn_hash_version)
    values ('20000000-0000-0000-0000-000000000002', 'hash-a', 1)$$,
  '23505', null, 'one BVN, one person');
select throws_ok(
  $$update public.user_secure_profiles set bvn_nin_hash_prev = 'hash-old'
    where user_id = '20000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a previous hash must carry its version');

-- ── pickups ─────────────────────────────────────────────────────────────
insert into public.retail_shops (id, shop_name, contact_phone, density_category, location) values
  ('90000000-0000-0000-0000-000000000001', 'Mama Nkechi Provisions', '+2348000000010', 'MARKET_SQUARE',
   extensions.st_setsrid(extensions.st_makepoint(3.3515, 6.6018), 4326));

select throws_ok(
  $$insert into public.retail_stock_pickups (tenant_id, retail_shop_id, dsa_agent_id, status)
    values ('10000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001',
            '20000000-0000-0000-0000-000000000003', 'CONFIRMED')$$,
  '23514', null, 'a CONFIRMED pickup must record who confirmed it and when');
insert into public.retail_stock_pickups (id, tenant_id, retail_shop_id, dsa_agent_id)
  values ('a0000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
          '90000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003');
select is(
  (select status from public.retail_stock_pickups where id = 'a0000000-0000-0000-0000-000000000001'),
  'PENDING_CONFIRMATION', 'a pickup lands as PENDING_CONFIRMATION by default');

-- ── updated_at advances (§6.9) ──────────────────────────────────────────
update public.tenants set updated_at = '2020-01-01' where code = 'NESTLE';
update public.tenants set name = 'Nestle Nigeria Plc' where code = 'NESTLE';
select ok(
  (select updated_at > '2020-01-01'::timestamptz from public.tenants where code = 'NESTLE'),
  'set_updated_at advances updated_at on every update');

-- ── audit_logs is append-only (§4.6) ────────────────────────────────────
insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, source)
  values ('10000000-0000-0000-0000-000000000001', 'TEST', 'tenants', 'x', 'SYSTEM');
select throws_ok(
  $$update public.audit_logs set operation = 'TAMPERED'$$,
  'P0001', null, 'audit_logs rows cannot be updated, even by the owner');
select throws_ok(
  $$delete from public.audit_logs$$,
  'P0001', null, 'audit_logs rows cannot be deleted, even by the owner');
select throws_ok(
  $$truncate public.audit_logs$$,
  'P0001', null, 'audit_logs cannot be truncated, even by the owner');

select * from finish();
rollback;
