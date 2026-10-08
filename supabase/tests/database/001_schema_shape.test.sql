-- Phase 1 — the schema exists in the shape Spec A §6 defines.
begin;
create extension if not exists pgtap with schema extensions;

select plan(65);

-- extensions (§14 phase 1)
select has_extension('pgcrypto');
select has_extension('postgis');
select has_extension('pg_cron');

-- the 33 tables (§6.1)
select tables_are('public', array[
  -- tenancy and identity (6)
  'tenants', 'tenant_settings', 'tenant_users', 'profiles',
  'user_secure_profiles', 'devices',
  -- geography and shared network (7)
  'zones', 'territories', 'retail_shops', 'tenant_shop_coverage',
  'routes', 'route_waypoints', 'field_check_ins',
  -- catalogue and inventory (4)
  'warehouses', 'brand_approval_policies', 'central_products',
  'inventory_batches',
  -- commerce (6)
  'requisitions', 'requisition_items', 'orders', 'order_items',
  'retail_stock_pickups', 'retail_stock_pickup_items',
  -- money and the liquidity engine (6)
  'fintech_partners', 'payments', 'commission_records', 'fintech_terminals',
  'fintech_advances', 'cash_audit_batches',
  -- platform (4)
  'otp_challenges', 'idempotency_logs', 'audit_logs', 'notifications'
], 'public holds exactly the 33 Spec A tables');

-- every table has RLS enabled, even before Phase 2 adds policies:
-- no table is ever readable by accident between phases
select is(
  (select count(*)::int from pg_tables
    where schemaname = 'public' and rowsecurity),
  33, 'RLS is enabled on all 33 tables');

-- enums (§6.2)
select enum_has_labels('public', 'platform_role_enum', array['PLATFORM_SUPER_ADMIN']);
select enum_has_labels('public', 'tenant_role_enum',
  array['ZSM','TM','ASM','DSM','DSA','FINTECH_AGENT','RETAIL_SHOP_OWNER']);
select enum_has_labels('public', 'tenant_status_enum', array['ACTIVE','SUSPENDED','INACTIVE']);
select enum_has_labels('public', 'tenant_user_status_enum', array['ACTIVE','INVITED','DISABLED']);
select enum_has_labels('public', 'kyc_status_enum', array['UNVERIFIED','PENDING','VERIFIED','REJECTED']);
select enum_has_labels('public', 'density_category_enum',
  array['HIGH_DENSITY','MARKET_SQUARE','EVENT_CENTER','SUBURBAN']);
select enum_has_labels('public', 'gateway_provider_enum', array['PAYSTACK']);
select enum_has_labels('public', 'pos_network_enum', array['MONIEPOINT','OPAY','PALMPAY']);
select enum_has_labels('public', 'payment_status_enum',
  array['INITIATED','PROCESSING','SUCCESS','FAILED','REFUNDED']);
select enum_has_labels('public', 'commission_status_enum', array['SPLIT','SETTLED','DISPUTED']);
select enum_has_labels('public', 'warehouse_kind_enum', array['CENTRAL','REGIONAL','STOCKIST']);
select enum_has_labels('public', 'order_channel_enum', array['ONLINE','FIELD_DSA','RETAIL']);
select enum_has_labels('public', 'audit_source_enum', array['USER','SYSTEM','WEBHOOK','CRON']);
select enum_has_labels('public', 'otp_purpose_enum', array['PICKUP_CONFIRM','POS_SETTLEMENT']);

-- decision 8: there is no global role column
select hasnt_column('public', 'profiles', 'user_role', 'profiles.user_role does not exist');
-- decision 16: the BVN hash is never on the peer-readable profile
select hasnt_column('public', 'profiles', 'bvn_nin_hash', 'profiles carries no BVN hash');
-- removed by the commission ruling
select hasnt_column('public', 'tenants', 'commission_rate', 'tenants.commission_rate is removed');

-- money is NUMERIC(15,2) (§6.9)
select col_type_is('public', 'central_products', 'unit_price', 'numeric(15,2)', 'central_products.unit_price is numeric(15,2)');
select col_type_is('public', 'central_products', 'wholesale_price', 'numeric(15,2)', 'central_products.wholesale_price is numeric(15,2)');
select col_type_is('public', 'requisitions', 'total_value', 'numeric(15,2)', 'requisitions.total_value is numeric(15,2)');
select col_type_is('public', 'orders', 'total_amount', 'numeric(15,2)', 'orders.total_amount is numeric(15,2)');
select col_type_is('public', 'order_items', 'unit_price', 'numeric(15,2)', 'order_items.unit_price is numeric(15,2)');
select col_type_is('public', 'order_items', 'line_total', 'numeric(15,2)', 'order_items.line_total is numeric(15,2)');
select col_type_is('public', 'payments', 'amount', 'numeric(15,2)', 'payments.amount is numeric(15,2)');
select col_type_is('public', 'commission_records', 'amount', 'numeric(15,2)', 'commission_records.amount is numeric(15,2)');
select col_type_is('public', 'fintech_advances', 'requested_amount', 'numeric(15,2)', 'fintech_advances.requested_amount is numeric(15,2)');
select col_type_is('public', 'cash_audit_batches', 'declared_cash_amount', 'numeric(15,2)', 'cash_audit_batches.declared_cash_amount is numeric(15,2)');
select col_type_is('public', 'cash_audit_batches', 'digital_collection_total', 'numeric(15,2)', 'cash_audit_batches.digital_collection_total is numeric(15,2)');

-- quantities are NUMERIC(14,3)
select col_type_is('public', 'inventory_batches', 'quantity', 'numeric(14,3)', 'inventory_batches.quantity is numeric(14,3)');
select col_type_is('public', 'requisition_items', 'requested_qty', 'numeric(14,3)', 'requisition_items.requested_qty is numeric(14,3)');
select col_type_is('public', 'requisition_items', 'approved_qty', 'numeric(14,3)', 'requisition_items.approved_qty is numeric(14,3)');
select col_type_is('public', 'requisition_items', 'fulfilled_qty', 'numeric(14,3)', 'requisition_items.fulfilled_qty is numeric(14,3)');
select col_type_is('public', 'order_items', 'qty', 'numeric(14,3)', 'order_items.qty is numeric(14,3)');
select col_type_is('public', 'retail_stock_pickup_items', 'quantity_picked', 'numeric(14,3)', 'retail_stock_pickup_items.quantity_picked is numeric(14,3)');

-- geometry columns (§6.4)
select col_type_is('public', 'zones', 'boundary', 'geometry(MultiPolygon,4326)', 'zones.boundary is geometry(MultiPolygon,4326)');
select col_type_is('public', 'territories', 'boundary', 'geometry(MultiPolygon,4326)', 'territories.boundary is geometry(MultiPolygon,4326)');
select col_type_is('public', 'retail_shops', 'location', 'geometry(Point,4326)', 'retail_shops.location is geometry(Point,4326)');
select col_type_is('public', 'route_waypoints', 'location', 'geometry(Point,4326)', 'route_waypoints.location is geometry(Point,4326)');
select col_type_is('public', 'field_check_ins', 'location', 'geometry(Point,4326)', 'field_check_ins.location is geometry(Point,4326)');

-- GIST indexes on every geometry column (§6.4)
select has_index('public', 'retail_shops', 'idx_retail_shops_geo', 'location'::name, 'gist index idx_retail_shops_geo');
select has_index('public', 'route_waypoints', 'idx_route_waypoints_geo', 'location'::name, 'gist index idx_route_waypoints_geo');
select has_index('public', 'field_check_ins', 'idx_field_checkins_geo', 'location'::name, 'gist index idx_field_checkins_geo');
select has_index('public', 'zones', 'idx_zones_boundary', 'boundary'::name, 'gist index idx_zones_boundary');
select has_index('public', 'territories', 'idx_territories_boundary', 'boundary'::name, 'gist index idx_territories_boundary');

-- audit indexes (§4.6)
select has_index('public'::name, 'audit_logs'::name, 'idx_audit_logs_tenant_time'::name, 'index idx_audit_logs_tenant_time');
select has_index('public'::name, 'audit_logs'::name, 'idx_audit_logs_entity'::name, 'index idx_audit_logs_entity');
select has_index('public'::name, 'audit_logs'::name, 'idx_audit_logs_idempotency'::name, 'index idx_audit_logs_idempotency');

-- versioned BVN hash (decision 17)
select has_column('public', 'user_secure_profiles', 'bvn_hash_version', 'public.user_secure_profiles.bvn_hash_version: has_column');
select has_column('public', 'user_secure_profiles', 'bvn_nin_hash_prev', 'public.user_secure_profiles.bvn_nin_hash_prev: has_column');
select has_column('public', 'user_secure_profiles', 'bvn_hash_prev_version', 'public.user_secure_profiles.bvn_hash_prev_version: has_column');

-- PIN and scope columns (§5.2, §5.5)
select has_column('public', 'tenant_users', 'zone_id', 'public.tenant_users.zone_id: has_column');
select has_column('public', 'tenant_users', 'pin_hash', 'public.tenant_users.pin_hash: has_column');
select has_column('public', 'tenant_users', 'pin_failed_attempts', 'public.tenant_users.pin_failed_attempts: has_column');
select has_column('public', 'tenant_users', 'pin_locked_until', 'public.tenant_users.pin_locked_until: has_column');

-- agent accountability (§6.10): NOT NULL on commerce, nullable on audit
select col_not_null('public', 'orders', 'teafair_agent_id', 'public.orders.teafair_agent_id: col_not_null');
select col_not_null('public', 'payments', 'teafair_agent_id', 'public.payments.teafair_agent_id: col_not_null');
select col_not_null('public', 'commission_records', 'teafair_agent_id', 'public.commission_records.teafair_agent_id: col_not_null');
select col_is_null('public', 'audit_logs', 'teafair_agent_id', 'public.audit_logs.teafair_agent_id: col_is_null');

-- brand tiers and escalation (decisions 18, 19)
select col_not_null('public', 'central_products', 'brand', 'public.central_products.brand: col_not_null');
select has_column('public', 'retail_stock_pickups', 'escalated_at', 'public.retail_stock_pickups.escalated_at: has_column');

select * from finish();
rollback;
