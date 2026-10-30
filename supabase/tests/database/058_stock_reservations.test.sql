-- Addendum A6 §18.1 (Step 2, Task 6b; user rulings 2026-10-30) — stock is
-- reserved at placement (web and trade, first expiry first out), deducted at
-- dispatch, released on a cancel or a refund before dispatch; unpaid web orders
-- and unfinished cash trade orders lapse through the sweep; record_order_return
-- restores goods after dispatch. inventory_batches.quantity_reserved always
-- equals the sum of the batch's RESERVED rows.
begin;
create extension if not exists pgtap with schema extensions;

select plan(96);

-- A6 §18.4: every state is on, and every tenant opted in, for this file's fixtures
update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 1 ZSM · 2 CSM · 3 LOGISTICS_MANAGER · 4 TENANT_ADMIN · 5 TM (Ikeja) · 6 DSA (Ikeja) · 7 shop owner
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from generate_series(1, 7) n;
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'CLIENT_SERVICE_MANAGER', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003',
   'LOGISTICS_MANAGER', null, null, '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'TENANT_ADMIN', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000005', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
update public.territories set tm_id = '20000000-0000-0000-0000-000000000005' where id = '40000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'CENTRAL', 'CENTRAL', null);
update public.territories set web_fulfilment_warehouse_id = '70000000-0000-0000-0000-000000000001'
 where id = '40000000-0000-0000-0000-000000000001';
insert into public.web_referral_codes (tenant_id, code, agent_id, created_by) values
  ('7eaf0000-0000-4000-8000-000000000001', 'SR-DSA', '20000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000001');
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000007', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
                                     nafdac_number, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'SR-1', 'Oil 1', 'Purerigin', 'Skin care', 'COSMETICS', 'A7-3001', 100, 80),
  ('7eaf0000-0000-4000-8000-000000000001', 'SR-2', 'Oil 2', 'Purerigin', 'Skin care', 'COSMETICS', 'A7-3002', 100, 80);
-- SR-1: E1 (5, early), L1 (10, late), X1 (50, already expired: never reserved)
-- SR-2: E2 (2, early), L2 (4, no expiry: last)
insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity, expires_at) values
  ('7eaf0000-0000-4000-8000-000000000001', '70000000-0000-0000-0000-000000000001', 'SR-1', 'L1', 10, now() + interval '90 days'),
  ('7eaf0000-0000-4000-8000-000000000001', '70000000-0000-0000-0000-000000000001', 'SR-1', 'E1', 5, now() + interval '30 days'),
  ('7eaf0000-0000-4000-8000-000000000001', '70000000-0000-0000-0000-000000000001', 'SR-1', 'X1', 50, now() - interval '1 day'),
  ('7eaf0000-0000-4000-8000-000000000001', '70000000-0000-0000-0000-000000000001', 'SR-2', 'L2', 4, null),
  ('7eaf0000-0000-4000-8000-000000000001', '70000000-0000-0000-0000-000000000001', 'SR-2', 'E2', 2, now() + interval '10 days');
insert into public.web_phone_verifications (phone, code_hash, expires_at, verified_at, token_hash, token_expires_at)
select '+23480311111' || lpad(n::text, 2, '0'), 'x', now() + interval '10 minutes', now(),
       encode(extensions.digest('tok-' || n, 'sha256'), 'hex'), now() + interval '30 minutes'
  from generate_series(1, 9) n;
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d6000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated, service_role;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer) to authenticated, service_role;
create function pg_temp.w(n integer) returns uuid language sql as
  $$ select ('70000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.w(integer) to authenticated, service_role;
-- a web order through the live checkout RPC: buyer n, its own phone, token and reference
create function pg_temp.web(p_key integer, p_n integer, p_lines jsonb, p_total numeric) returns jsonb language sql as $$
  select public.place_web_order(pg_temp.k(p_key), 'SR-DSA', p_lines,
    jsonb_build_object('name', 'Buyer ' || p_n, 'phone', '+23480311111' || lpad(p_n::text, 2, '0'),
                       'delivery_address', '5 Opebi Road, Ikeja'), null,
    'PAYSTACK_WEB', p_total,
    jsonb_build_object('reference', 'TFW-sr-' || p_n, 'access_code', 'ac',
                       'authorization_url', 'https://checkout.paystack.com/ac', 'split', null),
    md5('ng_lga:LA:Ikeja')::uuid, true, 'v2.0-food-cosmetics', '10.0.0.9', 'tok-' || p_n)
$$;
grant execute on function pg_temp.web(integer, integer, jsonb, numeric) to service_role;
create function pg_temp.trade(p_key integer, p_lines jsonb) returns jsonb language sql as
  $$ select public.place_trade_order(pg_temp.k(p_key), '71000000-0000-0000-0000-000000000001', p_lines) $$;
grant execute on function pg_temp.trade(integer, jsonb) to authenticated;
create function pg_temp.dispatch(p_key integer, p_order uuid) returns jsonb language sql as
  $$ select public.mark_order_dispatched(pg_temp.k(p_key), p_order, null, '4321', 'test-gw-secret') $$;
grant execute on function pg_temp.dispatch(integer, uuid) to authenticated;
create function pg_temp.ret(p_key integer, p_order uuid, p_lines jsonb) returns jsonb language sql as
  $$ select public.record_order_return(pg_temp.k(p_key), p_order, p_lines) $$;
grant execute on function pg_temp.ret(integer, uuid, jsonb) to authenticated;
-- a batch's numbers, by batch number (one warehouse, one row per number here)
create function pg_temp.q(p_batch text) returns numeric language sql as
  $$ select trim_scale(quantity) from public.inventory_batches where warehouse_id = pg_temp.w(1) and batch_number = p_batch $$;
create function pg_temp.r(p_batch text) returns numeric language sql as
  $$ select trim_scale(quantity_reserved) from public.inventory_batches where warehouse_id = pg_temp.w(1) and batch_number = p_batch $$;
-- an order's reservations as 'batch:qty:status', in batch-number order
create function pg_temp.res(p_order uuid) returns text[] language sql as $$
  select coalesce(array_agg(b.batch_number || ':' || trim_scale(r.quantity) || ':' || r.status order by b.batch_number), '{}')
    from public.stock_reservations r join public.inventory_batches b on b.id = r.batch_id
   where r.order_id = p_order $$;
-- the ledger: every batch's quantity_reserved is the sum of its RESERVED rows
create function pg_temp.ledger() returns text language sql as $$
  select string_agg(b.batch_number || ' ' || b.quantity_reserved || ' <> ' || coalesce(s.q, 0), '; ')
    from public.inventory_batches b
    left join (select batch_id, sum(quantity) q from public.stock_reservations where status = 'RESERVED' group by batch_id) s
      on s.batch_id = b.id
   where b.quantity_reserved <> coalesce(s.q, 0) $$;
-- the detail of a refused call
create function pg_temp.detail_of(p_sql text) returns text language plpgsql as $$
declare v_d text;
begin
  execute p_sql;
  return 'no error';
exception when others then
  get stacked diagnostics v_d = pg_exception_detail;
  return v_d;
end; $$;
grant execute on function pg_temp.detail_of(text) to authenticated, service_role;
create temp table o (n text primary key, id uuid);
grant select, insert on o to authenticated, service_role;

-- ── schema ──────────────────────────────────────────────────────────────
select has_table('public', 'stock_reservations', 'stock_reservations exists');
select col_type_is('public', 'inventory_batches', 'quantity_reserved', 'numeric(14,3)', 'quantity_reserved is numeric(14,3)');
select col_default_is('public', 'tenant_settings', 'web_reservation_hours', '24', 'web_reservation_hours defaults to 24');
select is((select web_reservation_hours from public.tenant_settings where tenant_id = '7eaf0000-0000-4000-8000-000000000001'),
  24, 'TEAFAIR holds web orders for 24 hours');
select is((select schedule from cron.job where jobname = 'stock-reservation-sweep'), '*/15 * * * *',
  'the stock-reservation-sweep runs every 15 minutes');
select is((select command from cron.job where jobname = 'stock-reservation-sweep'), 'select public.stock_reservation_sweep()',
  'the sweep is pure SQL');
select ok(not has_function_privilege('authenticated', 'public.stock_reservation_sweep()', 'execute')
      and not has_function_privilege('service_role', 'public.stock_reservation_sweep()', 'execute')
      and not has_function_privilege('authenticated', 'public.stock_reserve_order(public.orders, timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.stock_consume_order(public.orders, uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.stock_release_order(uuid, uuid, text)', 'execute'),
  'the sweep and the reserve, consume and release helpers have no API grant');
select ok(has_function_privilege('authenticated', 'public.record_order_return(uuid, uuid, jsonb)', 'execute'),
  'record_order_return is granted to authenticated');
select throws_ok($$update public.inventory_batches set quantity_reserved = quantity + 1 where batch_number = 'L1'$$,
  '23514', null, 'a batch can never reserve more than it holds');

-- ── reserve at placement: a trade order, FEFO across two batches ────────
select pg_temp.act_as(pg_temp.u(5), '7eaf0000-0000-4000-8000-000000000001');
insert into o select 'TO1', (pg_temp.trade(1, '[{"sku_code":"SR-1","qty":7}]') ->> 'order_id')::uuid;
reset role;
select is(pg_temp.res((select id from o where n = 'TO1')), array['E1:5:RESERVED', 'L1:2:RESERVED'],
  'a trade order reserves first expiry first: all of E1, then L1; the expired X1 is skipped');
select is(array[pg_temp.q('E1'), pg_temp.q('L1'), pg_temp.q('X1')], array[5, 10, 50]::numeric[],
  'quantity does not move at placement');
select is(array[pg_temp.r('E1'), pg_temp.r('L1'), pg_temp.r('X1')], array[5, 2, 0]::numeric[],
  'quantity_reserved rises by what each batch reserved');
select is((select trim_scale(sum(quantity - quantity_reserved)) from public.inventory_batches
            where sku_code = 'SR-1' and expires_at > now()), 8::numeric, 'available SR-1 drops from 15 to 8');
select is((select distinct expires_at from public.stock_reservations where order_id = (select id from o where n = 'TO1')),
  ((now() at time zone 'Africa/Lagos')::date + 1)::timestamp at time zone 'Africa/Lagos',
  'a trade reservation lapses at the end of its Lagos supply day');
select is((select status from public.orders where id = (select id from o where n = 'TO1')), 'PENDING', 'the trade order is PENDING');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (trade placement)');

-- ── reserve at placement: a web order of two lines ──────────────────────
select pg_temp.as_service();
insert into o select 'WO1', (pg_temp.web(10, 1, '[{"sku_code":"SR-1","qty":3},{"sku_code":"SR-2","qty":3}]', 1350.00) ->> 'order_id')::uuid;
reset role;
select is(pg_temp.res((select id from o where n = 'WO1')), array['E2:2:RESERVED', 'L1:3:RESERVED', 'L2:1:RESERVED'],
  'a web order reserves each line FEFO: SR-1 from L1 (E1 is held), SR-2 across E2 then L2');
select is(array[pg_temp.r('L1'), pg_temp.r('E2'), pg_temp.r('L2')], array[5, 2, 1]::numeric[],
  'the web order''s quantities are reserved on their batches');
select is(array[pg_temp.q('L1'), pg_temp.q('E2'), pg_temp.q('L2')], array[10, 2, 4]::numeric[], 'and nothing is deducted');
select is((select count(*)::int from public.stock_reservations r join public.orders x on x.id = r.order_id
            where r.order_id = (select id from o where n = 'WO1') and r.expires_at = x.created_at + interval '24 hours'), 3,
  'an unpaid web reservation lapses web_reservation_hours after placement');
select pg_temp.as_service();
select is(pg_temp.web(10, 1, '[{"sku_code":"SR-1","qty":3},{"sku_code":"SR-2","qty":3}]', 1350.00) ->> 'order_id',
  (select id::text from o where n = 'WO1'), 'a replayed checkout returns the same order');
reset role;
select is((select count(*)::int from public.stock_reservations), 5, 'and reserves nothing twice');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (web placement)');

-- ── strict refusal: not enough available stock ──────────────────────────
-- SR-1 holds 15 unexpired (and 50 expired); 10 are reserved, so 5 are available
select pg_temp.as_service();
select throws_ok($$select pg_temp.web(11, 2, '[{"sku_code":"SR-1","qty":6}]', 1350.00)$$,
  'TF001', 'insufficient stock', 'a web order beyond available stock is TF001');
select is(pg_temp.detail_of($$select pg_temp.web(11, 2, '[{"sku_code":"SR-1","qty":6}]', 1350.00)$$)::jsonb,
  '{"sku_code":"SR-1","available":5,"requested":6}'::jsonb, 'with detail {sku_code, available, requested}');
reset role;
select pg_temp.act_as(pg_temp.u(5), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.trade(12, '[{"sku_code":"SR-2","qty":1},{"sku_code":"SR-1","qty":6}]')$$,
  'TF001', 'insufficient stock', 'a trade order beyond available stock is TF001');
select is(pg_temp.detail_of($$select pg_temp.trade(12, '[{"sku_code":"SR-2","qty":1},{"sku_code":"SR-1","qty":6}]')$$)::jsonb,
  '{"sku_code":"SR-1","available":5,"requested":6}'::jsonb, 'naming the line that failed');
reset role;
select is((select count(*)::int from public.orders), 2, 'no order is written by a refused placement');
select is((select count(*)::int from public.stock_reservations), 5, 'no reservation is written either (SR-2 included)');
select is((select count(*)::int from public.idempotency_logs where key in (pg_temp.k(11), pg_temp.k(12))), 0,
  'and no idempotency record, so the buyer can retry');
select is((select consumed_at from public.web_phone_verifications where phone = '+2348031111102'), null,
  'the refused buyer''s verification is not consumed');
select is(pg_temp.r('E2'), 2::numeric, 'quantity_reserved is unchanged by the refusal');

-- ── deduct at dispatch ──────────────────────────────────────────────────
select public.settle_paystack_payment('charge.success', 'TFW-sr-1', 'success', 135000, 'NGN', '{}', '9301', null, null);
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select is(pg_temp.dispatch(20, (select id from o where n = 'WO1')) ->> 'status', 'IN_TRANSIT', 'the ZSM dispatches the paid web order');
reset role;
select is(pg_temp.res((select id from o where n = 'WO1')), array['E2:2:CONSUMED', 'L1:3:CONSUMED', 'L2:1:CONSUMED'],
  'its reservations are CONSUMED');
select is((select count(*)::int from public.stock_reservations
            where order_id = (select id from o where n = 'WO1') and close_reason = 'IN_TRANSIT' and closed_at is not null), 3,
  'closed with the reason IN_TRANSIT');
select is(array[pg_temp.q('L1'), pg_temp.q('E2'), pg_temp.q('L2')], array[7, 0, 3]::numeric[],
  'quantity falls by what was dispatched');
select is(array[pg_temp.r('L1'), pg_temp.r('E2'), pg_temp.r('L2')], array[2, 0, 0]::numeric[],
  'quantity_reserved falls with it (L1 keeps the trade order''s 2)');
select is((select count(*)::int from public.stock_movements
            where kind = 'SALE_DISPATCH' and order_id = (select id from o where n = 'WO1')
              and decision_id is null and recorded_by = pg_temp.u(1)), 3,
  'one SALE_DISPATCH movement per batch, citing the order and no decision');
select is((select array_agg(batch_number || ':' || trim_scale(quantity) order by batch_number) from public.stock_movements
            where order_id = (select id from o where n = 'WO1')), array['E2:2', 'L1:3', 'L2:1'],
  'each movement carries its batch and quantity');
select ok((select (r.after -> 'stock') is not null and jsonb_array_length(r.after -> 'stock') = 3
             from public.audit_logs r where r.operation = 'mark_order_dispatched'
              and r.entity_id = (select id::text from o where n = 'WO1')),
  'the dispatch audit row lists the movements');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (dispatch)');

-- an order with nothing reserved (placed before this migration) cannot be dispatched
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route, public_reference,
                           delivery_lga_id, territory_id, fulfilment_warehouse_id, policy_version_tag, policy_accepted_at)
values ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE', pg_temp.u(6), 850, 'PAID',
        'PAYSTACK_WEB', 'TF-00000A', md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', pg_temp.w(1),
        'v2.0-food-cosmetics', now());
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.dispatch(21, '90000000-0000-0000-0000-000000000001')$$,
  'P0001', 'this order has no stock reserved; reserve it first', 'dispatching an order with no reservation is refused');
reset role;
select is((select status from public.orders where id = '90000000-0000-0000-0000-000000000001'), 'PAID',
  'and it stays PAID, with no fulfilment row');

-- ── refunds: before dispatch releases, after dispatch does not ──────────
select pg_temp.as_service();
insert into o select 'WO2', (pg_temp.web(30, 3, '[{"sku_code":"SR-1","qty":1}]', 850.00) ->> 'order_id')::uuid;
reset role;
select public.settle_paystack_payment('charge.success', 'TFW-sr-3', 'success', 85000, 'NGN', '{}', '9302', null, null);
select is(pg_temp.r('L1'), 3::numeric, 'a second web order reserves 1 more of L1');
select is(public.apply_paystack_refund('webhook', 'RF-1', 'TFW-sr-3', 85000, 'NGN', 'REFUND', '{}') ->> 'order_status',
  'REFUNDED', 'the paid order is refunded before dispatch');
select is(pg_temp.res((select id from o where n = 'WO2')), array['L1:1:RELEASED'], 'its reservation is RELEASED');
select is((select close_reason from public.stock_reservations where order_id = (select id from o where n = 'WO2')),
  'REFUNDED', 'with the reason REFUNDED');
select is(array[pg_temp.q('L1'), pg_temp.r('L1')], array[7, 2]::numeric[], 'the stock is free again and nothing was deducted');
select is((select (after ->> 'reservations_released')::int from public.audit_logs
            where operation = 'apply_paystack_refund' and entity_type = 'orders'
              and entity_id = (select id::text from o where n = 'WO2')), 1, 'the refund audit row counts the release');
select is(public.apply_paystack_refund('webhook', 'RF-2', 'TFW-sr-1', 135000, 'NGN', 'REFUND', '{}') ->> 'order_status',
  'REFUNDED', 'the dispatched order is refunded too');
select is(pg_temp.res((select id from o where n = 'WO1')), array['E2:2:CONSUMED', 'L1:3:CONSUMED', 'L2:1:CONSUMED'],
  'but a refund after dispatch leaves its reservations CONSUMED');
select is(array[pg_temp.q('L1'), pg_temp.q('E2'), pg_temp.q('L2')], array[7, 0, 3]::numeric[],
  'and restores no stock (goods come back through record_order_return)');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (refunds)');

-- ── the sweep: unpaid web orders and unfinished cash trade orders ───────
select pg_temp.as_service();
insert into o select 'WO3', (pg_temp.web(40, 4, '[{"sku_code":"SR-1","qty":1}]', 850.00) ->> 'order_id')::uuid;
insert into o select 'WO4', (pg_temp.web(41, 5, '[{"sku_code":"SR-1","qty":1}]', 850.00) ->> 'order_id')::uuid;
reset role;
select public.settle_paystack_payment('charge.success', 'TFW-sr-5', 'success', 85000, 'NGN', '{}', '9303', null, null);
-- both reservations lapse (the trigger allows status changes only, so the clock is wound back past it)
set local session_replication_role = replica;
update public.stock_reservations set expires_at = now() - interval '1 minute'
 where order_id in (select id from o where n in ('WO3', 'WO4'));
set local session_replication_role = origin;
select is(public.stock_reservation_sweep(), 1, 'the sweep cancels one order');
select is((select status from public.orders where id = (select id from o where n = 'WO3')), 'CANCELLED',
  'the expired unpaid web order is CANCELLED');
select is(pg_temp.res((select id from o where n = 'WO3')), array['L1:1:RELEASED'], 'and its stock is released');
select is((select close_reason from public.stock_reservations where order_id = (select id from o where n = 'WO3')),
  'CANCELLED', 'with the reason CANCELLED');
select is((select status from public.orders where id = (select id from o where n = 'WO4')), 'PAID', 'the paid one is left alone');
select is(pg_temp.res((select id from o where n = 'WO4')), array['L1:1:RESERVED'], 'and keeps its reservation');
select is(pg_temp.res((select id from o where n = 'TO1')), array['E1:5:RESERVED', 'L1:2:RESERVED'],
  'a trade order inside its supply day is left alone');
select ok(exists (select 1 from public.audit_logs where operation = 'stock_reservation_sweep' and source = 'CRON'
                    and entity_id = (select id::text from o where n = 'WO3') and teafair_agent_id = pg_temp.u(6)),
  'the cancel is audited as CRON, on the order''s accountable agent');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (web sweep)');
set local session_replication_role = replica;
update public.stock_reservations set expires_at = now() - interval '1 minute'
 where order_id = (select id from o where n = 'TO1');
set local session_replication_role = origin;
select is(public.stock_reservation_sweep(), 1, 'past its supply day, the cash trade order is swept');
select is((select status from public.orders where id = (select id from o where n = 'TO1')), 'CANCELLED',
  'the PENDING trade order is CANCELLED');
select is(array[pg_temp.r('E1'), pg_temp.r('L1')], array[0, 1]::numeric[], 'and its 7 are released (L1 keeps WO4''s 1)');
select is(public.stock_reservation_sweep(), 0, 'a second sweep finds nothing');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (trade sweep)');

-- ── record_order_return: goods back after dispatch ──────────────────────
select pg_temp.act_as(pg_temp.u(4), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.ret(50, (select id from o where n = 'WO1'), '[{"sku_code":"SR-2","qty":1}]')$$,
  '42501', null, 'a TENANT_ADMIN cannot record a return');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.ret(51, (select id from o where n = 'WO1'), '[{"sku_code":"SR-2","qty":1}]')$$,
  '42501', null, 'nor can a ZSM');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.ret(52, (select id from o where n = 'WO4'), '[{"sku_code":"SR-1","qty":1}]')$$,
  'P0001', 'this order has not been dispatched', 'an order never dispatched has nothing to return');
select is(jsonb_array_length(pg_temp.ret(53, (select id from o where n = 'WO1'), '[{"sku_code":"SR-2","qty":2}]') -> 'movements'),
  1, 'the logistics manager returns 2 of SR-2');
reset role;
select is(array[pg_temp.q('E2'), pg_temp.q('L2')], array[2, 3]::numeric[], 'they go back to the first-expiry batch E2');
select is((select count(*)::int from public.stock_movements
            where kind = 'ORDER_RETURN' and order_id = (select id from o where n = 'WO1') and decision_id is null
              and recorded_by = pg_temp.u(3) and batch_number = 'E2' and quantity = 2), 1,
  'as one ORDER_RETURN movement citing the order, not a decision');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.ret(54, (select id from o where n = 'WO1'), '[{"sku_code":"SR-2","qty":2}]')$$,
  'P0001', 'you cannot return more SR-2 than was dispatched (1 left to return)', 'a return beyond what was dispatched is refused');
select pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
select lives_ok($$select pg_temp.ret(55, (select id from o where n = 'WO1'), '[{"sku_code":"SR-2","qty":1},{"sku_code":"SR-1","qty":3}]')$$,
  'the CSM returns the rest');
reset role;
select is(array[pg_temp.q('L1'), pg_temp.q('E2'), pg_temp.q('L2')], array[10, 2, 4]::numeric[],
  'every batch holds what it held before the dispatch');
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$select pg_temp.ret(56, (select id from o where n = 'WO1'), '[{"sku_code":"SR-1","qty":1}]')$$,
  'P0001', 'you cannot return more SR-1 than was dispatched (0 left to return)', 'nothing more can come back');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'record_order_return'), 2, 'each return is audited');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (returns)');

-- ── the CSM / LM stock RPCs respect reservations ────────────────────────
create function pg_temp.rep() returns jsonb language sql as $$
  select jsonb_build_object(
    'met_at', now() - interval '1 hour', 'channel', 'MEETING',
    'attendees', jsonb_build_array(jsonb_build_object('name', 'Ada', 'side', 'TEAFAIR')),
    'summary', 'Agreed a stock move.',
    'decisions', jsonb_build_array(jsonb_build_object('subject', 'STOCK', 'text', 'Stock')),
    'recipients', jsonb_build_array(
      jsonb_build_object('name', 'Chidi', 'channel', 'WHATSAPP', 'address', '+2348031112222')));
$$;
grant execute on function pg_temp.rep() to authenticated;
create temp table cd (id uuid);
grant select on cd to authenticated;
do $$
declare v_rid uuid; v_slot jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
  v_rid := (public.file_contact_report(pg_temp.k(100), pg_temp.rep()) ->> 'report_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into cd select d.id from public.contact_report_decisions d where d.report_id = v_rid;
  perform pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
  perform public.review_contact_report(pg_temp.k(101), v_rid, 'APPROVED');
  perform pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
  v_slot := public.request_contact_report_hard_copy(pg_temp.k(102), v_rid, 'application/pdf', 1000);
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, metadata)
  values ('contact-reports', v_slot ->> 'storage_path', jsonb_build_object('size', '1000', 'mimetype', 'application/pdf'));
  perform pg_temp.act_as(pg_temp.u(2), '7eaf0000-0000-4000-8000-000000000001');
  perform public.attach_contact_report_hard_copy(pg_temp.k(103), (v_slot ->> 'hard_copy_id')::uuid);
  perform set_config('role', 'postgres', true);
end $$;
reset role;
-- L1 holds 10, of which WO4 reserves 1
select pg_temp.act_as(pg_temp.u(3), '7eaf0000-0000-4000-8000-000000000001');
select is(pg_temp.detail_of($$select public.record_stock_transfer(pg_temp.k(110), (select id from cd), pg_temp.w(1), pg_temp.w(2),
    'SR-1', 'L1', 10)$$)::jsonb, '{"sku_code":"SR-1","available":9,"requested":10}'::jsonb,
  'a transfer cannot move reserved stock (TF001, available = quantity - reserved)');
select is(pg_temp.detail_of($$select public.record_stock_adjustment(pg_temp.k(111), (select id from cd), pg_temp.w(1),
    'SR-1', 'L1', -10, 'Damaged')$$)::jsonb, '{"sku_code":"SR-1","available":9,"requested":10}'::jsonb,
  'an adjustment cannot take a batch below its reserved quantity');
select throws_ok($$select public.record_stock_adjustment(pg_temp.k(112), (select id from cd), pg_temp.w(1),
    'SR-1', 'L1', -10, 'Damaged')$$, 'TF001', 'insufficient stock', 'with the code TF001');
select lives_ok($$select public.record_stock_transfer(pg_temp.k(113), (select id from cd), pg_temp.w(1), pg_temp.w(2),
    'SR-1', 'L1', 9)$$, 'the unreserved 9 can move');
reset role;
select is(array[pg_temp.q('L1'), pg_temp.r('L1')], array[1, 1]::numeric[], 'leaving exactly the reserved unit');
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (transfer)');

-- ── reservations are a ledger: never deleted, closed once ───────────────
select throws_ok($$delete from public.stock_reservations where order_id = (select id from o where n = 'WO3')$$,
  'P0001', 'stock reservations are never deleted', 'a reservation cannot be deleted');
select throws_ok($$truncate public.stock_reservations$$, 'P0001', 'stock reservations are never deleted',
  'nor truncated');
select throws_ok($$update public.stock_reservations set status = 'RESERVED', closed_at = null, close_reason = null
                    where order_id = (select id from o where n = 'WO1') and sku_code = 'SR-1'$$,
  'P0001', 'a reservation closes once, from RESERVED to CONSUMED or RELEASED', 'a CONSUMED row cannot go back');
select throws_ok($$update public.stock_reservations set status = 'RELEASED', closed_at = now(), close_reason = 'CANCELLED'
                    where order_id = (select id from o where n = 'WO1') and sku_code = 'SR-1'$$,
  'P0001', 'a reservation closes once, from RESERVED to CONSUMED or RELEASED', 'nor be closed a second time');
select throws_ok($$update public.stock_reservations set quantity = 2 where order_id = (select id from o where n = 'WO4')$$,
  'P0001', 'a reservation closes once, from RESERVED to CONSUMED or RELEASED', 'an open row''s quantity cannot change');
select throws_ok($$insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity,
                     decision_id, order_id, recorded_by)
                   values ('7eaf0000-0000-4000-8000-000000000001', 'RECEIPT', pg_temp.w(1), 'SR-1', 'L1', 1,
                           (select id from cd), (select id from o where n = 'WO1'), pg_temp.u(3))$$,
  '23514', null, 'a decision movement cannot also cite an order');
select throws_ok($$insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity,
                     decision_id, order_id, recorded_by)
                   values ('7eaf0000-0000-4000-8000-000000000001', 'SALE_DISPATCH', pg_temp.w(1), 'SR-1', 'L1', 1,
                           (select id from cd), (select id from o where n = 'WO1'), pg_temp.u(3))$$,
  '23514', null, 'a sale movement cites its order and no decision');
select throws_ok($$insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity,
                     recorded_by)
                   values ('7eaf0000-0000-4000-8000-000000000001', 'ADJUSTMENT', pg_temp.w(1), 'SR-1', 'L1', 1, pg_temp.u(3))$$,
  '23514', null, 'a CSM/LM kind still needs its decision');
select pg_temp.act_as(pg_temp.u(1), '7eaf0000-0000-4000-8000-000000000001');
select throws_ok($$insert into public.stock_reservations (tenant_id, order_id, order_item_id, warehouse_id, batch_id, sku_code, quantity)
                   select tenant_id, order_id, order_item_id, warehouse_id, batch_id, sku_code, 1 from public.stock_reservations limit 1$$,
  '42501', null, 'the API cannot write a reservation');
select ok((select count(*) from public.stock_reservations) > 0, 'tenant staff read their tenant''s reservations');
reset role;
select is(pg_temp.ledger(), null, 'ledger: quantity_reserved equals the RESERVED rows (end)');

select * from finish();
rollback;
