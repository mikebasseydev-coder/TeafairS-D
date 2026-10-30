-- Addendum A6 §4.4, §7.2, §18.2 (Monvelo Step 2, Task 7) — financings and their
-- brand lines, per-brand shop limits with history, the request (ZSA, ASA or TM,
-- on the order's raiser), TM approval above the limit, cancel (which cancels the
-- trade order and releases its stock, A6 §18.1), the platform hard freeze and
-- each tenant's cure rules.
begin;
create extension if not exists pgtap with schema extensions;

select plan(90);

-- A6 Task 6b: placing an order reserves stock. This file is not about stock,
-- so every ordered line finds ample stock in its order's fulfilment warehouse.
create function pg_temp.a6_stock_for_line() returns trigger language plpgsql as $f$
begin
  insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
  select o.tenant_id, o.fulfilment_warehouse_id, new.sku_code, 'FIXTURE', 100000
    from public.orders o
   where o.tenant_id = new.tenant_id and o.id = new.order_id and o.fulfilment_warehouse_id is not null
  on conflict (warehouse_id, sku_code, batch_number) do nothing;
  return null;
end;
$f$;
create trigger a6_stock_for_line after insert on public.order_items
  for each row execute function pg_temp.a6_stock_for_line();

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- T1 = TEAFAIR (Purerigin approved, Tiger no terms), T2 = Unilever (Omo approved)
-- T1: 01 ZSM · 02 ZSA (Lagos) · 03 TM (Ikeja) · 04 ASA (Allen) · 05 ASA (Opebi)
--     06 TM (Ikorodu) · 07 TENANT_ADMIN · 08 LM · 09 DSA · 18 CSM
-- owners: 10 (S1, S3; verified) · 11 (S2; unverified) · agents: 13 (AG1) · 14 (AG2)
-- T2: 15 ZSM · 16 TM · 17 ASA
insert into tenants (id, name, code) values ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'),
       case when n = 11 then null else now() end
  from generate_series(1, 18) n;

-- A6 §18.4: every state on, and every tenant opted in
update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikorodu'),
  ('40000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000011', 'Ikeja B');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen'),
  ('60000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Opebi'),
  ('60000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000011', 'Allen B');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000018', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000018', 'CLIENT_SERVICE_MANAGER', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000006', 'TM', null, '40000000-0000-0000-0000-000000000002', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000015', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000016', 'TM', null, '40000000-0000-0000-0000-000000000011', null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002', 'ZSA', '30000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000008', 'LOGISTICS_MANAGER', null, null, null, '50000000-0000-0000-0000-000000000018', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000009', 'DSA', null, '40000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000017', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000017', 'ASA', null, '40000000-0000-0000-0000-000000000011', '60000000-0000-0000-0000-000000000011', '50000000-0000-0000-0000-000000000016', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000015' where id = '30000000-0000-0000-0000-000000000011';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'IKORODU', 'REGIONAL', '40000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', 'IKEJA B', 'REGIONAL', '40000000-0000-0000-0000-000000000011');
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, nafdac_number, unit_price, wholesale_price) values
  ('7eaf0000-0000-4000-8000-000000000001', 'TIGER-1', 'Tiger tea', 'Tiger', 'Beverages', 'A7-1001', 1200, 1000),
  ('10000000-0000-0000-0000-000000000002', 'OMO-1', 'Omo sachet', 'Omo', 'Laundry', 'A7-2001', 1200, 1000);

-- settings: T1 opens at 50000 and waits 7 days after a cleared default; T2
-- opens at 20000, waits 0 days and restarts at half its opening limit
insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap, default_cure_days) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 50000, 0, 7)
on conflict (tenant_id) do update set enabled = true, opening_limit = 50000, default_cure_days = 7;
insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap, default_cure_days, post_default_limit_bps) values
  ('10000000-0000-0000-0000-000000000002', true, 20000, 0, 0, 5000);
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, valid_from, status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 200, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000018', now()),
  ('10000000-0000-0000-0000-000000000002', 'Omo', 200, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000015', '20000000-0000-0000-0000-000000000016', now());
-- today is a supply day in Allen, Opebi and Allen B
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by)
select a.tenant_id, a.id, extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001'
  from public.areas a where a.id in ('60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000002',
                                     '60000000-0000-0000-0000-000000000011');

-- agents: AG1 (member 13) is S1's preferred agent; AG2 (member 14)
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status) values
  ('80000000-0000-0000-0000-000000000001', 'Near POS', 'OPAY', 'OP-1', '+2348031110001',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
   '0123456789', '6789', '058', 'Near POS', 'K1', '20000000-0000-0000-0000-000000000002', 'ACTIVE'),
  ('80000000-0000-0000-0000-000000000002', 'Other POS', 'OPAY', 'OP-2', '+2348031110002',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.6036), 4326)::extensions.geography, 'a',
   '0123456780', '6780', '058', 'Other POS', 'K2', '20000000-0000-0000-0000-000000000002', 'ACTIVE');
insert into public.monvelo_agent_members (agent_id, profile_id) values
  ('80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000013'),
  ('80000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000014');

-- shops: S1 (owner 10, verified) enrolled in T1 Allen and T2 Allen B; S2 (owner 11,
-- unverified) enrolled in Allen; S3 (owner 10) withdrawn from Allen
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text, preferred_agent_id) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1', '80000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000002', 'Shop 2', '+234803111002', '20000000-0000-0000-0000-000000000011', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 2', null),
  ('71000000-0000-0000-0000-000000000003', 'Shop 3', '+234803111003', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 3', null);
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by)
select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, t, s, a, 'x', now() + interval '1 hour', i
  from (values (1, '7eaf0000-0000-4000-8000-000000000001'::uuid, '71000000-0000-0000-0000-000000000001'::uuid,
                '60000000-0000-0000-0000-000000000001'::uuid, '20000000-0000-0000-0000-000000000004'::uuid),
               (2, '7eaf0000-0000-4000-8000-000000000001', '71000000-0000-0000-0000-000000000002',
                '60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004'),
               (3, '7eaf0000-0000-4000-8000-000000000001', '71000000-0000-0000-0000-000000000003',
                '60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004'),
               (4, '10000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000001',
                '60000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-000000000017')) v (n, t, s, a, i);
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version,
                                            consent_challenge_id, status, withdrawn_at)
select c.tenant_id, c.shop_id, c.area_id, c.issued_by, now(), 'MV-SHARE-2026-10', c.id,
       case when c.shop_id = '71000000-0000-0000-0000-000000000003' then 'WITHDRAWN' else 'ACTIVE' end,
       case when c.shop_id = '71000000-0000-0000-0000-000000000003' then now() end
  from public.monvelo_consent_challenges c where c.id::text like 'c0000000-%';

-- ── helpers ─────────────────────────────────────────────────────────────
create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.k(n integer) returns uuid language sql as
  $$ select ('d2000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.k(integer) to authenticated;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.u(integer) to authenticated;
create temp table ord (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert on ord, res to authenticated;
create function pg_temp.o(p_n text) returns uuid language sql as $$ select id from ord where n = p_n $$;
grant execute on function pg_temp.o(text) to authenticated;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select (r ->> 'financing_id')::uuid from res where n = p_n $$;
grant execute on function pg_temp.f(text) to authenticated;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.t2() returns uuid language sql as $$ select '10000000-0000-0000-0000-000000000002'::uuid $$;
grant execute on function pg_temp.t1(), pg_temp.t2() to authenticated;
create function pg_temp.s(n integer) returns uuid language sql as
  $$ select ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.s(integer) to authenticated;
-- place a trade order as p_user and name it p_n
create function pg_temp.place(p_n text, p_key integer, p_user integer, p_tenant uuid, p_shop integer, p_lines jsonb,
                              p_terr uuid default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), p_tenant);
  v := (public.place_trade_order(pg_temp.k(p_key), pg_temp.s(p_shop), p_lines, p_terr) ->> 'order_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into ord values (p_n, v);
  return v;
end; $$;
-- request a financing as p_user and keep the result as p_n
create function pg_temp.req(p_n text, p_key integer, p_user integer, p_tenant uuid, p_order text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), p_tenant);
  v := public.request_monvelo_financing(pg_temp.k(p_key), pg_temp.o(p_order));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.pr(p_qty integer) returns jsonb language sql as
  $$ select jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', p_qty)) $$;
create function pg_temp.omo(p_qty integer) returns jsonb language sql as
  $$ select jsonb_build_array(jsonb_build_object('sku_code', 'OMO-1', 'qty', p_qty)) $$;

-- the orders (raised by the ASA of Allen unless named)
select pg_temp.place('O1', 1, 4, pg_temp.t1(), 1, pg_temp.pr(12));    -- 48000
select pg_temp.place('O2', 2, 4, pg_temp.t1(), 1, pg_temp.pr(24));    -- 96000
select pg_temp.place('O3', 3, 4, pg_temp.t1(), 1, pg_temp.pr(3));     -- 12000, for the refusals
select pg_temp.place('O4', 4, 4, pg_temp.t1(), 3, pg_temp.pr(3));     -- the withdrawn shop
select pg_temp.place('O5', 5, 5, pg_temp.t1(), 1, pg_temp.pr(3));     -- the ASA of Opebi
select pg_temp.place('O6', 6, 4, pg_temp.t1(), 2, pg_temp.pr(3));     -- the unverified owner
select pg_temp.place('O7', 7, 4, pg_temp.t1(), 1, jsonb_build_array(
  jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 3), jsonb_build_object('sku_code', 'TIGER-1', 'qty', 1)));
select pg_temp.place('O8', 8, 4, pg_temp.t1(), 1, pg_temp.pr(3));     -- after the default
select pg_temp.place('O9', 9, 2, pg_temp.t1(), 1, pg_temp.pr(3), '40000000-0000-0000-0000-000000000002'); -- a ZSA, in Ikorodu
select pg_temp.place('B1', 11, 17, pg_temp.t2(), 1, pg_temp.omo(5));  -- T2, defaults
select pg_temp.place('B2', 12, 17, pg_temp.t2(), 1, pg_temp.omo(5));  -- T2, after the cure

-- ── shape ───────────────────────────────────────────────────────────────
select has_table('public', 'monvelo_financings', 'monvelo_financings exists');
select has_table('public', 'monvelo_financing_lines', 'monvelo_financing_lines exists');
select has_table('public', 'monvelo_shop_limits', 'monvelo_shop_limits exists');
select has_table('public', 'monvelo_shop_limit_events', 'monvelo_shop_limit_events exists');
select ok(not has_table_privilege('authenticated', 'public.monvelo_financings', 'insert')
      and not has_table_privilege('authenticated', 'public.monvelo_financing_lines', 'update')
      and not has_table_privilege('authenticated', 'public.monvelo_shop_limits', 'insert')
      and not has_table_privilege('authenticated', 'public.monvelo_shop_limit_events', 'insert')
      and not has_table_privilege('anon', 'public.monvelo_financings', 'select'),
  'the API holds no write grant, and anon nothing');
select ok(not has_function_privilege('authenticated', 'public.monvelo_offer(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.monvelo_shop_limit_for(uuid,uuid,text)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_brand_exposure(uuid,uuid,text,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.monvelo_draw_reference()', 'execute'),
  'the internal helpers have no API grant');
select is((select column_default from information_schema.columns
            where table_schema = 'public' and table_name = 'monvelo_tenant_settings' and column_name = 'post_default_limit_bps'),
  '10000', 'after a cure the limit restarts at the opening limit unless the tenant says otherwise');

-- ── the happy path ──────────────────────────────────────────────────────
select lives_ok($$select pg_temp.req('F1', 101, 4, pg_temp.t1(), 'O1')$$, 'the ASA requests financing for her order');
select is((select r ->> 'status' || '|' || (r ->> 'approval_required') || '|' || (r ->> 'principal') from res where n = 'F1'),
  'OFFERED|false|48000.00', 'within the limit: OFFERED at once, no approval');
select ok((select r ->> 'reference' ~ '^MV-[A-Z2-7]{8}$' from res where n = 'F1'), 'an MV- reference');
select is((select string_agg(brand || ':' || brand_key || ':' || amount, ',') from public.monvelo_financing_lines
            where financing_id = pg_temp.f('F1')), 'Purerigin:purerigin:48000.00', 'one line, Purerigin, 48000');
select is((select row(f.shop_id = pg_temp.s(1), f.area_id = '60000000-0000-0000-0000-000000000001',
                      f.territory_id = '40000000-0000-0000-0000-000000000001', f.raised_by = pg_temp.u(4),
                      f.supply_date = public.monvelo_today(), f.offered_at is not null)::text
             from public.monvelo_financings f where f.id = pg_temp.f('F1')),
  '(t,t,t,t,t,t)', 'shop, area, territory, raiser, supply date and offer time are recorded');
select is((select limit_amount || ':' || status from public.monvelo_shop_limits
            where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(1) and brand_key = 'purerigin'),
  '50000.00:ACTIVE', 'the shop''s Purerigin limit opens at 50000');
select is((select string_agg(kind || ':' || coalesce(old_limit::text, '-') || ':' || new_limit, ',') from public.monvelo_shop_limit_events
            where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(1) and brand_key = 'purerigin'),
  'OPENED:-:50000.00', 'with an OPENED event');
select is((select preferred_agent_id::text || preferred_window_ends_at::text from public.monvelo_financings where id = pg_temp.f('F1')),
  null, 'no pledge for today: no preferred window');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is(public.request_monvelo_financing(pg_temp.k(101), pg_temp.o('O1')), (select r from res where n = 'F1'),
  'the same key replays the first result');
reset role;
select is((select count(*)::int from public.monvelo_financings where order_id = pg_temp.o('O1')), 1, 'and writes no second row');
select is((select count(*)::int from public.audit_logs where operation = 'request_monvelo_financing' and idempotency_key = pg_temp.k(101)),
  1, 'one audit row');

-- ── above the limit: the TM approves ────────────────────────────────────
select lives_ok($$select pg_temp.req('F2', 102, 4, pg_temp.t1(), 'O2')$$, 'a second order of 96000');
select is((select r ->> 'status' || '|' || (r ->> 'approval_required') from res where n = 'F2'),
  'AWAITING_APPROVAL|true', '48000 + 96000 is above the 50000 limit: AWAITING_APPROVAL');
select pg_temp.act_as(pg_temp.u(6), pg_temp.t1());
select throws_ok($$select public.approve_monvelo_financing(pg_temp.k(110), pg_temp.f('F2'))$$,
  '42501', null, 'another territory''s TM cannot approve');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.approve_monvelo_financing(pg_temp.k(111), pg_temp.f('F2'))$$,
  '42501', null, 'the ASA cannot approve');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok($$select public.approve_monvelo_financing(pg_temp.k(112), pg_temp.f('F2'))$$,
  '42501', null, 'a TENANT_ADMIN cannot approve');
reset role;
-- AG1 pledges 150000 for Allen today
insert into public.monvelo_pledges (tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by) values
  (pg_temp.t1(), '80000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', public.monvelo_today(),
   150000, 150000, pg_temp.u(13));
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is(public.approve_monvelo_financing(pg_temp.k(113), pg_temp.f('F2')) ->> 'status', 'OFFERED', 'the Ikeja TM approves: OFFERED');
select throws_ok($$select public.approve_monvelo_financing(pg_temp.k(114), pg_temp.f('F2'))$$,
  'P0001', 'only a financing awaiting approval can be approved', 'approving twice');
reset role;
select is((select (approved_by = pg_temp.u(3) and approved_at is not null)::text from public.monvelo_financings where id = pg_temp.f('F2')),
  'true', 'approved_by and approved_at are set');
select is((select preferred_agent_id from public.monvelo_financings where id = pg_temp.f('F2')),
  '80000000-0000-0000-0000-000000000001'::uuid, 'the shop''s preferred agent has pledged enough: it gets the window');
select ok((select preferred_window_ends_at between now() + interval '9 minutes' and now() + interval '11 minutes'
             from public.monvelo_financings where id = pg_temp.f('F2')), 'the window ends about 10 minutes from now');

-- ── refusals ────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(120), pg_temp.o('O3'))$$,
  '42501', null, 'a TENANT_ADMIN cannot request');
select pg_temp.act_as(pg_temp.u(9), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(121), pg_temp.o('O3'))$$,
  '42501', null, 'a DSA cannot request');
reset role;
update public.monvelo_tenant_settings set enabled = false where tenant_id = pg_temp.t1();
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(122), pg_temp.o('O3'))$$,
  'P0001', 'Monvelo is not switched on for this tenant', 'the tenant is switched off');
reset role;
update public.monvelo_tenant_settings set enabled = true where tenant_id = pg_temp.t1();
update public.orders set status = 'PAID' where id = pg_temp.o('O3');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(123), pg_temp.o('O3'))$$,
  'P0001', 'only a pending trade order can be financed', 'a paid order');
reset role;
update public.orders set status = 'PENDING' where id = pg_temp.o('O3');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(124), pg_temp.o('O3'))$$,
  '42501', 'only the order''s raiser requests its financing', 'the TM cannot request the ASA''s order');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(125), pg_temp.o('O1'))$$,
  'P0001', 'this order already has a Monvelo financing', 'a second request for the same order');
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(126), pg_temp.o('O4'))$$,
  'P0001', 'the shop is not enrolled in Monvelo', 'a withdrawn enrolment');
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(127), pg_temp.o('O6'))$$,
  'P0001', 'the shop owner has no verified phone', 'an owner with no verified phone');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(128), pg_temp.o('O5'))$$,
  '42501', 'the shop is not on your beat', 'the ASA of another area');
select pg_temp.act_as(pg_temp.u(2), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(129), pg_temp.o('O9'))$$,
  'P0001', 'the order was placed in another territory', 'a ZSA''s order in Ikorodu for an Allen shop');
reset role;
update public.monvelo_supply_days set active = false where area_id = '60000000-0000-0000-0000-000000000001';
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(130), pg_temp.o('O3'))$$,
  'P0001', 'today is not a supply day for this area', 'not a supply day');
reset role;
update public.monvelo_supply_days set active = true where area_id = '60000000-0000-0000-0000-000000000001';
update public.operational_states set app_enabled = false where state_code = 'LA';
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(131), pg_temp.o('O3'))$$,
  'P0001', 'Teafair is not operating in Lagos yet', 'Lagos is switched off for the app (A6 §18.4)');
reset role;
update public.operational_states set app_enabled = true where state_code = 'LA';
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(132), pg_temp.o('O7'))$$,
  'P0001', 'Tiger has no approved Monvelo terms', 'Purerigin + Tiger is refused whole, naming Tiger');
reset role;
select is((select count(*)::int from public.monvelo_financings where order_id = pg_temp.o('O7')), 0,
  'and no financing row is written for the eligible part');

-- ── cancel ──────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(9), pg_temp.t1());
select throws_ok($$select public.cancel_monvelo_financing(pg_temp.k(140), pg_temp.f('F1'), 'shop changed its mind')$$,
  '42501', null, 'a DSA cannot cancel');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.cancel_monvelo_financing(pg_temp.k(141), pg_temp.f('F1'), '  ')$$,
  'P0001', 'give a reason for the cancellation', 'a reason is required');
select is(public.cancel_monvelo_financing(pg_temp.k(142), pg_temp.f('F1'), 'shop changed its mind') ->> 'status', 'CANCELLED',
  'the raiser cancels an OFFERED financing');
select throws_ok($$select public.cancel_monvelo_financing(pg_temp.k(143), pg_temp.f('F1'), 'again')$$,
  'P0001', 'this financing can no longer be cancelled', 'a cancelled financing cannot be cancelled again');
reset role;
select is((select (cancelled_by = pg_temp.u(4))::text || ':' || cancel_reason from public.monvelo_financings where id = pg_temp.f('F1')),
  'true:shop changed its mind', 'cancelled_by and the reason are recorded');
select is((select status from public.orders where id = pg_temp.o('O1')), 'CANCELLED',
  'the trade order is cancelled with its financing (A6 §18.1)');
select is((select string_agg(distinct status || ':' || close_reason, ',') from public.stock_reservations where order_id = pg_temp.o('O1')),
  'RELEASED:CANCELLED', 'and its stock is released');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(144), pg_temp.o('O1'))$$,
  'P0001', 'only a pending trade order can be financed', 'a cancelled order cannot be financed again');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'cancel_monvelo_financing' and idempotency_key = pg_temp.k(142)),
  1, 'the cancel is audited');

-- ── the platform hard freeze and the cure rules (A6 §18.2) ──────────────
-- T2's Omo financing for S1 walks the whitelist to a default (as postgres)
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by) values
  ('82000000-0000-0000-0000-000000000011', pg_temp.t2(), '80000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000011',
   public.monvelo_today(), 100000, 100000, pg_temp.u(13));
insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
                                       principal, supply_date, status, approval_required) values
  ('f0000000-0000-0000-0000-000000000001', pg_temp.t2(), 'MV-AAAAAAAA', pg_temp.s(1), pg_temp.o('B1'),
   '60000000-0000-0000-0000-000000000011', '40000000-0000-0000-0000-000000000011', pg_temp.u(17),
   5000, public.monvelo_today(), 'REQUESTED', false);
update public.monvelo_financings set status = 'OFFERED', offered_at = now() where id = 'f0000000-0000-0000-0000-000000000001';
update public.monvelo_financings set status = 'CLAIMED', claimed_by_agent_id = '80000000-0000-0000-0000-000000000001',
       claimed_by = pg_temp.u(13), claim_expires_at = now() + interval '15 minutes',
       pledge_id = '82000000-0000-0000-0000-000000000011' where id = 'f0000000-0000-0000-0000-000000000001';
update public.monvelo_financings set status = 'FUNDED', funder_agent_id = '80000000-0000-0000-0000-000000000001', funded_at = now()
 where id = 'f0000000-0000-0000-0000-000000000001';
update public.monvelo_financings set status = 'DELIVERED', delivered_at = now(), due_at = now() where id = 'f0000000-0000-0000-0000-000000000001';
update public.monvelo_financings set status = 'DEFAULTED_WITH_LATE_CHARGE', outstanding = 5000
 where id = 'f0000000-0000-0000-0000-000000000001';
select is((select status from public.monvelo_financings where id = 'f0000000-0000-0000-0000-000000000001'),
  'DEFAULTED_WITH_LATE_CHARGE', 'fixture: the whitelist walks REQUESTED to a default');

select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(150), pg_temp.o('O8'))$$,
  'P0001', 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared',
  'a default with another tenant''s brand freezes the shop for Purerigin too; the message names no tenant or brand');
reset role;
select is((select count(*)::int from public.monvelo_financings where order_id = pg_temp.o('O8')), 0, 'nothing is written');

-- cleared late: T1 waits 7 days, T2 lends again at once at half its opening limit
update public.monvelo_financings set status = 'REPAID_LATE', outstanding = 0, closed_at = now()
 where id = 'f0000000-0000-0000-0000-000000000001';
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(151), pg_temp.o('O8'))$$,
  'P0001', 'Purerigin credit resumes on ' || to_char(public.monvelo_today() + 7, 'YYYY-MM-DD'),
  'T1''s 7 cure days have not passed');
reset role;
select lives_ok($$select pg_temp.req('FB2', 152, 17, pg_temp.t2(), 'B2')$$, 'T2, with 0 cure days, lends again at once');
select is((select r ->> 'status' from res where n = 'FB2'), 'OFFERED', 'within the restarted limit');
select is((select limit_amount::text from public.monvelo_shop_limits where tenant_id = pg_temp.t2() and shop_id = pg_temp.s(1) and brand_key = 'omo'),
  '10000.00', 'the Omo limit restarts at 5000 bps of the 20000 opening limit');
select is((select string_agg(kind || ':' || new_limit, ',' order by kind) from public.monvelo_shop_limit_events
            where tenant_id = pg_temp.t2() and shop_id = pg_temp.s(1) and brand_key = 'omo'),
  'OPENED:20000.00,RESET:10000.00', 'the history shows the opening and the reset');
-- eight days later T1 lends again
update public.monvelo_financings set closed_at = now() - interval '8 days' where id = 'f0000000-0000-0000-0000-000000000001';
select lives_ok($$select pg_temp.req('F8', 153, 4, pg_temp.t1(), 'O8')$$, 'after its cure days T1 lends again');
select is((select r ->> 'status' from res where n = 'F8'), 'AWAITING_APPROVAL',
  'at the restarted 50000 limit, F2''s 96000 still counts: above it, so approval');
select is((select count(*)::int from public.monvelo_shop_limit_events
            where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(1) and brand_key = 'purerigin' and kind = 'RESET'),
  1, 'T1''s Purerigin limit was reset once');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select lives_ok($$select public.request_monvelo_financing(pg_temp.k(154), pg_temp.o('O3'))$$, 'a later request');
reset role;
select is((select count(*)::int from public.monvelo_shop_limit_events
            where tenant_id = pg_temp.t1() and shop_id = pg_temp.s(1) and brand_key = 'purerigin' and kind = 'RESET'),
  1, 'does not reset the limit again for the same cleared default');

-- ── the guard (as postgres) ─────────────────────────────────────────────
select throws_ok($$update public.monvelo_financings set principal = 1 where id = pg_temp.f('F2')$$,
  'P0001', null, 'the principal is immutable');
select throws_ok($$update public.monvelo_financings set status = 'FUNDED' where id = pg_temp.f('F2')$$,
  'P0001', 'a financing cannot move from OFFERED to FUNDED', 'OFFERED cannot jump to FUNDED');
select throws_ok($$update public.monvelo_financings set status = 'OFFERED' where id = pg_temp.f('F1')$$,
  'P0001', 'a financing cannot move from CANCELLED to OFFERED', 'a cancelled financing stays cancelled');
select throws_ok($$delete from public.monvelo_financing_lines where financing_id = pg_temp.f('F2')$$,
  'P0001', 'Monvelo records are never deleted', 'a line cannot be deleted');
select throws_ok($$update public.monvelo_financing_lines set amount = 1 where financing_id = pg_temp.f('F2')$$,
  'P0001', null, 'a line''s amount cannot change');
select throws_ok($$delete from public.monvelo_financings where id = pg_temp.f('F2')$$,
  'P0001', 'Monvelo records are never deleted', 'a financing cannot be deleted');
select throws_ok($$truncate public.monvelo_shop_limit_events$$,
  'P0001', 'Monvelo records are never deleted', 'the limit history cannot be truncated');
select throws_ok($$update public.monvelo_shop_limit_events set new_limit = 1$$,
  'P0001', null, 'the limit history cannot be rewritten');
select throws_ok($$insert into public.monvelo_financings (tenant_id, reference, shop_id, order_id, area_id, territory_id,
                     raised_by, principal, supply_date, status, approval_required)
                   values (pg_temp.t1(), 'MV-BBBBBBBB', pg_temp.s(1), pg_temp.o('O9'), '60000000-0000-0000-0000-000000000001',
                     '40000000-0000-0000-0000-000000000001', pg_temp.u(2), 1, public.monvelo_today(), 'OFFERED', false)$$,
  'P0001', null, 'a financing is inserted only as REQUESTED');
-- one live financing per order: a cancelled one does not count
select lives_ok($$insert into public.monvelo_financings (tenant_id, reference, shop_id, order_id, area_id, territory_id,
                     raised_by, principal, supply_date, status, approval_required)
                   values (pg_temp.t1(), 'MV-CCCCCCCC', pg_temp.s(1), pg_temp.o('O1'), '60000000-0000-0000-0000-000000000001',
                     '40000000-0000-0000-0000-000000000001', pg_temp.u(4), 48000, public.monvelo_today(), 'REQUESTED', false)$$,
  'a cancelled financing does not block a new one for its order');
select throws_ok($$insert into public.monvelo_financings (tenant_id, reference, shop_id, order_id, area_id, territory_id,
                     raised_by, principal, supply_date, status, approval_required)
                   values (pg_temp.t1(), 'MV-DDDDDDDD', pg_temp.s(1), pg_temp.o('O1'), '60000000-0000-0000-0000-000000000001',
                     '40000000-0000-0000-0000-000000000001', pg_temp.u(4), 48000, public.monvelo_today(), 'REQUESTED', false)$$,
  '23505', null, 'but two live financings for one order are refused');

-- ── readers ─────────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(10), null);
select is((select count(*)::int from public.monvelo_financings where shop_id = pg_temp.s(1) and tenant_id = pg_temp.t1()), 5,
  'the owner reads her shop''s T1 financings');
select ok((select count(*) from public.monvelo_financing_lines) > 0
      and (select count(*) from public.monvelo_shop_limits where shop_id = pg_temp.s(1)) = 2,
  'and their lines and her shop''s limits in both tenants');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 5, 'the TENANT_ADMIN reads the T1 book');
select pg_temp.act_as(pg_temp.u(18), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 5, 'the CSM reads the T1 book');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 5, 'the ZSM reads the financings in her zone');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 5, 'the Ikeja TM reads his territory''s');
select pg_temp.act_as(pg_temp.u(6), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 0, 'the Ikorodu TM reads none');
select pg_temp.act_as(pg_temp.u(8), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 0, 'the LM reads none: nothing is FUNDED');
select pg_temp.act_as(pg_temp.u(9), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 0, 'a DSA reads none');
select is((select count(*)::int from public.monvelo_shop_limits), 0, 'nor the limits');
select pg_temp.act_as(pg_temp.u(15), pg_temp.t2());
select is((select count(*)::int from public.monvelo_financings where tenant_id = pg_temp.t1()), 0, 'tenant B''s ZSM reads none of T1''s');
select pg_temp.act_as(pg_temp.u(14), null);
select is((select count(*)::int from public.monvelo_financings), 0, 'a fintech member with no claim reads none');
select pg_temp.act_as(pg_temp.u(13), null);
select is((select count(*)::int from public.monvelo_financings), 1, 'the claiming agent''s member reads the one it claimed');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 0, 'an ASA reads only what she raised');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 5, 'the raiser reads hers');
reset role;

select * from finish();
rollback;
