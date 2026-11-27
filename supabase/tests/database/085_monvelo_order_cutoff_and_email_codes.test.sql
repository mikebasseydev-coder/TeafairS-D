-- Addendum A6 §23.5 and §23.6 (rulings 2026-11-27): the 3:00 PM Lagos
-- consolidation cutoff for next-day supply, and the shop owner's codes by
-- email. The cutoff is moved inside this transaction (always open, or already
-- passed) so the file passes at any hour; the shipped values are asserted first.
begin;
create extension if not exists pgtap with schema extensions;

select plan(29);

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
-- A6 §23.6: the owner's codes go by email; a fixture with a verified phone gets a verified email
update auth.users set email = id::text || '@fixture.test', email_confirmed_at = now()
 where phone_confirmed_at is not null and email is null;

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
-- A6 §23.5: tomorrow is a supply day in Allen and Allen B; Opebi supplies today only
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by)
select a.tenant_id, a.id, extract(isodow from public.monvelo_today() + 1)::int, true, '20000000-0000-0000-0000-000000000001'
  from public.areas a where a.id in ('60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000011');
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by)
select a.tenant_id, a.id, extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001'
  from public.areas a where a.id = '60000000-0000-0000-0000-000000000002';

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

create function pg_temp.cutoff(p_local text) returns void language sql as
  $$ update public.monvelo_platform_settings set order_cutoff_local = p_local::time $$;
create function pg_temp.lagos_midnight(p_date date) returns timestamptz language sql as
  $$ select (p_date::timestamp at time zone 'Africa/Lagos') $$;

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- orders, all by the ASA of Allen unless named
select pg_temp.place('O1', 1, 4, pg_temp.t1(), 1, pg_temp.pr(12));    -- 48000, within the limit
select pg_temp.place('O2', 2, 4, pg_temp.t1(), 1, pg_temp.pr(24));    -- 96000, above it: the TM approves
select pg_temp.place('O3', 3, 4, pg_temp.t1(), 1, pg_temp.pr(3));     -- 12000, for the refusals
select pg_temp.place('O6', 6, 4, pg_temp.t1(), 2, pg_temp.pr(3));     -- S2: owner 11 has no verified contact

-- ── shipped values ──────────────────────────────────────────────────────
select is((select order_cutoff_local from public.monvelo_platform_settings), time '15:00',
  'the consolidation cutoff is 15:00 Lagos');
select is((select supply_lead_days from public.monvelo_platform_settings), 1, 'supply is next-day');
select is((select column_default from information_schema.columns where table_schema = 'public'
            and table_name = 'monvelo_platform_settings' and column_name = 'supply_lead_days'),
  '1', 'and next-day is the column default');
select is(public.monvelo_request_supply_date(), public.monvelo_today() + 1, 'a request raised now is for tomorrow');
select is(public.monvelo_order_cutoff_at(public.monvelo_today() + 1),
  ((public.monvelo_today())::timestamp + time '15:00') at time zone 'Africa/Lagos',
  'tomorrow''s requests close at 15:00 Lagos today');
select ok(has_function_privilege('authenticated', 'public.monvelo_order_cutoff_at(date)', 'execute')
      and has_function_privilege('authenticated', 'public.monvelo_request_supply_date()', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_order_cutoff_at(date)', 'execute'),
  'the app may read the cutoff; anon may not');
select ok(not has_function_privilege('authenticated', 'public.monvelo_owner_code_email(uuid)', 'execute'),
  'the owner email resolver is internal');

-- ── before the cutoff: next-day supply ──────────────────────────────────
select pg_temp.cutoff('23:59:59.999999');
select lives_ok($$select pg_temp.req('F1', 101, 4, pg_temp.t1(), 'O1')$$, 'before the cutoff the ASA requests financing');
select is((select r ->> 'status' from res where n = 'F1'), 'OFFERED', 'within the limit it is offered at once');
select is((select supply_date from public.monvelo_financings where id = pg_temp.f('F1')), public.monvelo_today() + 1,
  'for tomorrow''s supply');
select ok((select bool_and(expires_at = pg_temp.lagos_midnight(public.monvelo_today() + 2))
             from public.stock_reservations where order_id = pg_temp.o('O1') and status = 'RESERVED'),
  'the financed order''s stock is held to the end of its supply date');
select ok((select bool_and(expires_at = pg_temp.lagos_midnight(public.monvelo_today() + 1))
             from public.stock_reservations where order_id = pg_temp.o('O3') and status = 'RESERVED'),
  'an unfinanced trade order still lapses at the end of the day it was placed');
select lives_ok($$select pg_temp.req('F2', 102, 4, pg_temp.t1(), 'O2')$$, 'a request above the limit');
select is((select r ->> 'status' from res where n = 'F2'), 'AWAITING_APPROVAL', 'waits for the TM');

-- a supply date that is not a supply day for the area: Allen stops supplying tomorrow
update public.monvelo_supply_days set active = false
 where area_id = '60000000-0000-0000-0000-000000000001' and day_of_week = extract(isodow from public.monvelo_today() + 1)::int;
select throws_ok($$select pg_temp.req('F5', 105, 4, pg_temp.t1(), 'O3')$$,
  'P0001', 'tomorrow is not a supply day for this area', 'when tomorrow is not a supply day the request is refused');
reset role;
update public.monvelo_supply_days set active = true
 where area_id = '60000000-0000-0000-0000-000000000001' and day_of_week = extract(isodow from public.monvelo_today() + 1)::int;

-- ── after the cutoff ────────────────────────────────────────────────────
select pg_temp.cutoff('00:00');
select throws_ok($$select pg_temp.req('F3', 103, 4, pg_temp.t1(), 'O3')$$,
  'P0001', 'today''s Monvelo order cutoff (00:00 Lagos) has passed; raise the request tomorrow before the cutoff',
  'after the cutoff no request is raised');
reset role;
select is((select count(*)::int from public.monvelo_financings where order_id = pg_temp.o('O3')), 0, 'and nothing is written');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.approve_monvelo_financing(pg_temp.k(201), pg_temp.f('F2'))$$,
  'P0001', 'the Monvelo order cutoff for this supply date has passed', 'after the cutoff the TM cannot approve');
reset role;
select is((select status from public.monvelo_financings where id = pg_temp.f('F2')), 'AWAITING_APPROVAL', 'it still waits');
select pg_temp.cutoff('23:59:59.999999');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((public.approve_monvelo_financing(pg_temp.k(202), pg_temp.f('F2'))) ->> 'status', 'OFFERED',
  'before the cutoff the TM approves and it is offered');
reset role;

-- same-day supply, if the platform ever sets it, closes at the cutoff of the day itself
update public.monvelo_platform_settings set supply_lead_days = 0;
select is(public.monvelo_order_cutoff_at(public.monvelo_today()),
  (public.monvelo_today()::timestamp + time '23:59:59.999999') at time zone 'Africa/Lagos',
  'with no lead day the cutoff falls on the supply date');
update public.monvelo_platform_settings set supply_lead_days = 1;

-- ── §23.6: the owner's verified email ───────────────────────────────────
select throws_ok($$select pg_temp.req('F6', 106, 4, pg_temp.t1(), 'O6')$$,
  'P0001', 'the shop owner has no verified email', 'an owner with no verified email gets no financing');
reset role;
update auth.users set email_confirmed_at = null where id = pg_temp.u(10);
select ok((select phone_confirmed_at is not null from auth.users where id = pg_temp.u(10)), 'owner 10 still has a verified phone');
select throws_ok($$select pg_temp.req('F3', 107, 4, pg_temp.t1(), 'O3')$$,
  'P0001', 'the shop owner has no verified email', 'a verified phone alone is not enough');
reset role;
update auth.users set email_confirmed_at = now() where id = pg_temp.u(10);

-- the consent code goes to the owner's email: a new shop S4 owned by 12
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('71000000-0000-0000-0000-000000000004', 'Shop 4', '+234803111004', '20000000-0000-0000-0000-000000000012', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 4');
create temp table started (r jsonb);
grant select, insert on started to authenticated;
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
insert into started select public.start_monvelo_consent(pg_temp.k(301), 'test-gw-secret',
  '71000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001');
reset role;
select is((select r ->> 'destination_email' from started), '20000000-0000-0000-0000-000000000012@fixture.test',
  'the consent code goes to the owner''s verified sign-in email');
select ok((select not (r ? 'destination_phone') from started), 'no phone is named');
select ok((select (r ->> 'code') ~ '^[0-9]{6}$' from started), 'the gateway gets the 6-digit code once');
select ok(not exists (select 1 from public.idempotency_logs l where l.key = pg_temp.k(301)
                       and l.response ? 'code'), 'the stored reply holds no code');
update auth.users set email_confirmed_at = null where id = pg_temp.u(12);
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.start_monvelo_consent(pg_temp.k(302), 'test-gw-secret',
  '71000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000001')$$,
  'P0001', 'the shop owner has no verified email', 'an owner whose email is unconfirmed gets no consent code');
reset role;

select * from finish();
rollback;
