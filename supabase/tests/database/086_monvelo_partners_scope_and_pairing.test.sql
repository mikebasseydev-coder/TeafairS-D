-- Addendum A6 §23.1-§23.4 (rulings 2026-11-27): platform partner codes and
-- kinds, the 200 m radius, ZSA/ASA field scope (agents and financings), direct
-- pairing and unpairing with fallback, the field dashboard and TM oversight.
begin;
create extension if not exists pgtap with schema extensions;

select plan(69);

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

-- requests are open all day inside this transaction (085 tests the cutoff)
update public.monvelo_platform_settings set order_cutoff_local = time '23:59:59.999999';
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- an ASM in Ikeja (19), to prove ASM reads no Monvelo financing
insert into auth.users (id, phone, phone_confirmed_at) values ('20000000-0000-0000-0000-000000000019', '2348000000019', now());
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000019', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000019',
   'ASM', null, '40000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);

create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
grant execute on function pg_temp.ag(integer) to authenticated;
create function pg_temp.allen() returns uuid language sql as $$ select '60000000-0000-0000-0000-000000000001'::uuid $$;
grant execute on function pg_temp.allen() to authenticated;
create temp table got (n text primary key, r jsonb);
grant select, insert, update on got to authenticated;
-- run p_sql as p_user in p_tenant and keep its jsonb reply as p_n
create function pg_temp.as_user(p_n text, p_user integer, p_tenant uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), p_tenant);
  execute p_sql into v;
  perform set_config('role', 'postgres', true);
  insert into got values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.g(p_n text) returns jsonb language sql as $$ select r from got where n = p_n $$;
grant execute on function pg_temp.g(text) to authenticated;
create function pg_temp.refusal(p_fin uuid, p_agent integer, p_member integer) returns text language sql as $$
  select public.monvelo_claim_refusal(f, a, pg_temp.u(p_member), p, false, 100000000)
    from public.monvelo_financings f, public.monvelo_agents a
    left join public.monvelo_pledges p on p.agent_id = a.id and p.area_id = pg_temp.allen()
                                       and p.supply_date = public.monvelo_today() + 1
   where f.id = p_fin and a.id = pg_temp.ag(p_agent) $$;

-- ── §23.2 partner kinds and codes ───────────────────────────────────────
select ok((select bool_and(partner_code ~ '^MP-[A-Z2-7]{8}$' and partner_kind = 'LIQUIDITY_PARTNER')
             from public.monvelo_agents where id in (pg_temp.ag(1), pg_temp.ag(2))),
  'every agent is a liquidity partner with an MP- code');
select isnt((select partner_code from public.monvelo_agents where id = pg_temp.ag(1)),
            (select partner_code from public.monvelo_agents where id = pg_temp.ag(2)), 'codes are distinct');
select ok(has_column_privilege('authenticated', 'public.monvelo_agents', 'partner_code', 'select')
      and has_column_privilege('authenticated', 'public.monvelo_agents', 'partner_kind', 'select'),
  'the app may read a partner''s code and kind');
select throws_ok($$update public.monvelo_agents set partner_kind = 'RETAIL_INDEPENDENT_PARTNER' where id = pg_temp.ag(1)$$,
  'P0001', 'a partner''s kind and code never change', 'the kind never changes');
select throws_ok($$update public.monvelo_agents set partner_code = 'MP-AAAAAAAA' where id = pg_temp.ag(1)$$,
  'P0001', 'a partner''s kind and code never change', 'nor the code');

select pg_temp.as_user('reg', 2, pg_temp.t1(), $q$select public.register_monvelo_agent(pg_temp.k(401), 'test-gw-secret',
  jsonb_build_object('business_name', 'Ikeja Retail Partner', 'pos_network', 'MONIEPOINT', 'network_agent_id', 'RP-1',
    'contact_phone', '+2348031119999', 'latitude', 6.6001, 'longitude', 3.3501, 'address_text', '1 Allen Avenue',
    'settlement_account_number', '0123450000', 'settlement_bank_code', '058',
    'settlement_account_name', 'Ikeja Retail Partner', 'network_kyc_reference', 'KYC-RP-1',
    'partner_kind', 'RETAIL_INDEPENDENT_PARTNER'))$q$);
select is(pg_temp.g('reg') ->> 'partner_kind', 'RETAIL_INDEPENDENT_PARTNER', 'a ZSA registers a retail independent partner');
select ok(pg_temp.g('reg') ->> 'partner_code' ~ '^MP-[A-Z2-7]{8}$', 'and the reply carries its platform code');
select is((select partner_code from public.monvelo_agents where id = (pg_temp.g('reg') ->> 'agent_id')::uuid),
  pg_temp.g('reg') ->> 'partner_code', 'the code is the stored one');
select pg_temp.act_as(pg_temp.u(2), pg_temp.t1());
select throws_ok($q$select public.register_monvelo_agent(pg_temp.k(402), 'test-gw-secret',
  jsonb_build_object('business_name', 'X', 'pos_network', 'OPAY', 'network_agent_id', 'RP-2',
    'contact_phone', '+2348031119998', 'latitude', 6.6, 'longitude', 3.35, 'address_text', 'x',
    'settlement_account_number', '0123450001', 'settlement_bank_code', '058',
    'settlement_account_name', 'X', 'network_kyc_reference', 'K', 'partner_kind', 'LENDER'))$q$,
  'P0001', 'partner_kind must be LIQUIDITY_PARTNER or RETAIL_INDEPENDENT_PARTNER', 'an unknown kind is refused');
reset role;
-- the retail partner is approved and has a member (12)
update public.monvelo_agents set status = 'ACTIVE' where id = (pg_temp.g('reg') ->> 'agent_id')::uuid;
insert into public.monvelo_agent_members (agent_id, profile_id) values ((pg_temp.g('reg') ->> 'agent_id')::uuid, pg_temp.u(12));
select pg_temp.act_as(pg_temp.u(12), null);
select throws_ok($$select public.pledge_monvelo_funds(pg_temp.k(403), (select (r ->> 'agent_id')::uuid from got where n = 'reg'),
  pg_temp.allen(), public.monvelo_today() + 1, 50000)$$,
  '42501', 'only a liquidity partner may pledge funds', 'a retail independent partner cannot pledge');
reset role;
select throws_ok($$update public.retail_shops set preferred_agent_id = (pg_temp.g('reg') ->> 'agent_id')::uuid
                    where id = pg_temp.s(2)$$,
  '42501', 'only a liquidity partner may be paired with a shop', 'nor be paired with a shop, by any writer');

-- ── §23.3 the radius ────────────────────────────────────────────────────
select is((select offer_radius_m from public.monvelo_platform_settings), 200, 'the claim radius is 200 m');
select is((select column_default from information_schema.columns where table_schema = 'public'
            and table_name = 'monvelo_platform_settings' and column_name = 'offer_radius_m'), '200', 'and so is the default');

-- liquidity: both partners pledge for tomorrow in Allen
select pg_temp.act_as(pg_temp.u(13), null);
select public.pledge_monvelo_funds(pg_temp.k(410), pg_temp.ag(1), pg_temp.allen(), public.monvelo_today() + 1, 500000);
select pg_temp.act_as(pg_temp.u(14), null);
select public.pledge_monvelo_funds(pg_temp.k(411), pg_temp.ag(2), pg_temp.allen(), public.monvelo_today() + 1, 500000);
reset role;

select pg_temp.place('O1', 1, 4, pg_temp.t1(), 1, pg_temp.pr(3));   -- 12000 each: both stay within S1's 50000 limit
select pg_temp.place('O2', 2, 4, pg_temp.t1(), 1, pg_temp.pr(3));
select pg_temp.req('F1', 101, 4, pg_temp.t1(), 'O1');
select is((select preferred_agent_id from public.monvelo_financings where id = pg_temp.f('F1')), pg_temp.ag(1),
  'the paired partner (AG1, pledged) gets the exclusive window on the offer');

-- ── §23.1 visibility ────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_agents), 2, 'the ASA of Allen sees the two partners pledged to Allen');
select is((select count(*)::int from public.monvelo_financings where id = pg_temp.f('F1')), 1, 'and its own request');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select is((select count(*)::int from public.monvelo_agents), 0, 'the ASA of Opebi sees no partner outside its area');
select is((select count(*)::int from public.monvelo_financings), 0, 'nor Allen''s financing');
select pg_temp.act_as(pg_temp.u(2), pg_temp.t1());
select is((select count(*)::int from public.monvelo_agents), 3, 'the ZSA sees its three recruits');
select is((select count(*)::int from public.monvelo_financings where id = pg_temp.f('F1')), 1,
  'and every financing of its zone, though another raised it');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings where id = pg_temp.f('F1')), 1, 'the TM sees its territory''s');
select pg_temp.act_as(pg_temp.u(19), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financings), 0, 'an ASM reads no Monvelo financing');
select pg_temp.act_as(pg_temp.u(17), pg_temp.t2());
select is((select count(*)::int from public.monvelo_financings where id = pg_temp.f('F1')), 0, 'nor another tenant''s ASA');
reset role;
select ok(not exists (select 1 from public.tenant_users tu where tu.role = 'ASM'
                       and public.monvelo_field_covers_area(tu, pg_temp.allen())), 'an ASM covers no field area');

-- ── §23.4 pairing ───────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select throws_ok($$select public.pair_monvelo_shop_agent(pg_temp.k(501), pg_temp.s(1), pg_temp.ag(2))$$,
  '42501', 'the shop is not in your field scope', 'the ASA of Opebi cannot pair a shop of Allen');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.pair_monvelo_shop_agent(pg_temp.k(502), pg_temp.s(1), pg_temp.ag(2))$$,
  '42501', null, 'a TM does not pair');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.pair_monvelo_shop_agent(pg_temp.k(503), pg_temp.s(1), pg_temp.ag(2))$$,
  'P0001', 'the shop is paired with another partner; unpair it first', 'a paired shop is unpaired first');
select throws_ok($$select public.pair_monvelo_shop_agent(pg_temp.k(504), pg_temp.s(3), pg_temp.ag(2))$$,
  'P0001', 'this shop is not enrolled', 'a withdrawn shop is not paired');
select throws_ok($$select public.unpair_monvelo_shop_agent(pg_temp.k(505), pg_temp.s(1), 'short')$$,
  'P0001', 'give a reason of 10 to 500 characters', 'unpairing needs a reason');
reset role;
select pg_temp.as_user('un1', 4, pg_temp.t1(),
  $q$select public.unpair_monvelo_shop_agent(pg_temp.k(506), pg_temp.s(1), 'the partner moved out of the market')$q$);
select is((pg_temp.g('un1') ->> 'offers_opened')::int, 1, 'unpairing opens the shop''s offer to everyone at once');
select ok((select preferred_agent_id is null and preferred_window_ends_at is null
             from public.monvelo_financings where id = pg_temp.f('F1')), 'the offer has no exclusive window left');
select is((select preferred_agent_id from public.retail_shops where id = pg_temp.s(1)), null::uuid, 'the shop is unpaired');

-- the radius, now that AG2 (about 400 m away) is not paired
select is(pg_temp.refusal(pg_temp.f('F1'), 2, 14), 'this shop is outside your area', 'beyond 200 m an unpaired partner cannot claim');
update public.monvelo_platform_settings set offer_radius_m = 1000;
select isnt(coalesce(pg_temp.refusal(pg_temp.f('F1'), 2, 14), ''), 'this shop is outside your area',
  'at the old 1,000 m it could');
update public.monvelo_platform_settings set offer_radius_m = 200;

select pg_temp.as_user('p1', 4, pg_temp.t1(), $q$select public.pair_monvelo_shop_agent(pg_temp.k(507), pg_temp.s(1), pg_temp.ag(2))$q$);
select is((select preferred_agent_id from public.retail_shops where id = pg_temp.s(1)), pg_temp.ag(2), 'the ASA pairs the shop with AG2');
select is(pg_temp.g('p1') ->> 'partner_code', (select partner_code from public.monvelo_agents where id = pg_temp.ag(2)),
  'the reply names the partner''s code');
select is((select source || '|' || paired_by::text || '|' || area_id::text || '|' || tenant_id::text
             from public.monvelo_shop_pairings where shop_id = pg_temp.s(1) and unpaired_at is null),
  'FIELD_PAIRING|' || pg_temp.u(4)::text || '|' || pg_temp.allen()::text || '|' || pg_temp.t1()::text,
  'with an open history row in the tenant and area');
select ok(exists (select 1 from public.audit_logs where operation = 'pair_monvelo_shop_agent' and tenant_id is null),
  'audited tenant-null: the row names a partner');
select isnt(coalesce(pg_temp.refusal(pg_temp.f('F1'), 2, 14), ''), 'this shop is outside your area',
  'the paired partner is exempt from the radius');
select pg_temp.as_user('p1r', 4, pg_temp.t1(), $q$select public.pair_monvelo_shop_agent(pg_temp.k(507), pg_temp.s(1), pg_temp.ag(2))$q$);
select is(pg_temp.g('p1r'), pg_temp.g('p1'), 'a replayed pairing returns the first reply');
select is((select count(*)::int from public.monvelo_shop_pairings where shop_id = pg_temp.s(1)), 1, 'and writes nothing more');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.pair_monvelo_shop_agent(pg_temp.k(508), pg_temp.s(1), pg_temp.ag(2))$$,
  'P0001', 'the shop is already paired with this partner', 'pairing twice is refused');
reset role;
select pg_temp.req('F2', 102, 4, pg_temp.t1(), 'O2');
select is((select preferred_agent_id from public.monvelo_financings where id = pg_temp.f('F2')), pg_temp.ag(2),
  'the next request goes to the newly paired partner first');

-- a field agent who acts for a partner never pairs a shop with it (as R78)
insert into public.monvelo_agent_members (agent_id, profile_id) values (pg_temp.ag(1), pg_temp.u(2));
select pg_temp.act_as(pg_temp.u(2), pg_temp.t1());
select throws_ok($$select public.pair_monvelo_shop_agent(pg_temp.k(509), pg_temp.s(2), pg_temp.ag(1))$$,
  '42501', 'you may not pair a shop with a partner you belong to', 'a member of the partner cannot pair with it');
reset role;

-- a recruited nomination is a pairing too
select pg_temp.as_user('nom', 4, pg_temp.t1(),
  $q$select public.nominate_monvelo_agent(pg_temp.k(510), pg_temp.s(2), 'Other POS', '+2348031110002', 'OPAY')$q$);
select pg_temp.as_user('nomc', 4, pg_temp.t1(),
  $q$select public.close_monvelo_nomination(pg_temp.k(511), (pg_temp.g('nom') ->> 'nomination_id')::uuid, pg_temp.ag(2), 'RECRUITED')$q$);
select is((select source from public.monvelo_shop_pairings where shop_id = pg_temp.s(2) and unpaired_at is null), 'NOMINATION',
  'closing a nomination RECRUITED records a NOMINATION pairing');

-- partners to pair with
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_field_partners_near(pg_temp.s(1))), 2,
  'the ASA lists the liquidity partners near its shop (not the retail partner)');
select pg_temp.act_as(pg_temp.u(5), pg_temp.t1());
select throws_ok($$select * from public.monvelo_field_partners_near(pg_temp.s(1))$$,
  '42501', 'the shop is not in your field scope', 'outside its scope the list is refused');

-- the pairing history's readers
select is((select count(*)::int from public.monvelo_shop_pairings), 0, 'the ASA of Opebi reads no pairing of Allen');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_shop_pairings), 2, 'the ASA of Allen reads both');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_shop_pairings), 0, 'the TM reads no row (counts only, below)');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from public.monvelo_shop_pairings), 0, 'nor the TENANT_ADMIN');
select pg_temp.act_as(pg_temp.u(14), null);
select is((select count(*)::int from public.monvelo_shop_pairings), 2, 'AG2''s member reads its own pairings');
reset role;

-- ── the field dashboard ─────────────────────────────────────────────────
select pg_temp.as_user('d4', 4, pg_temp.t1(), 'select public.get_monvelo_field_dashboard()');
select is(pg_temp.g('d4') -> 'area_ids', jsonb_build_array(pg_temp.allen()), 'the ASA''s scope is its area');
select is(pg_temp.g('d4') -> 'shops', '{"enrolled": 2, "paired": 2, "unpaired": 0}'::jsonb,
  'its enrolled shops, both paired');
select is((select (x ->> 'count')::int from jsonb_array_elements(pg_temp.g('d4') -> 'pipeline') x where x ->> 'status' = 'OFFERED'), 2,
  'its pipeline: two offers');
select is((pg_temp.g('d4') -> 'pledged' -> 0 ->> 'pledged')::numeric, 1000000::numeric, 'tomorrow''s pledges in its area');
select is(pg_temp.g('d4') -> 'my_pairings_30d', '{"paired": 2, "unpaired": 0}'::jsonb, 'its own pairing activity');
select is(pg_temp.g('d4') ->> 'next_supply_date', (public.monvelo_today() + 1)::text, 'and the next supply date');
select pg_temp.as_user('d2', 2, pg_temp.t1(), 'select public.get_monvelo_field_dashboard()');
select is(jsonb_array_length(pg_temp.g('d2') -> 'area_ids'), 2, 'the ZSA''s scope is every area of its zone');
select is(jsonb_array_length(pg_temp.g('d2') -> 'my_recruits'), 3, 'with its recruits, codes included');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.get_monvelo_field_dashboard()$$, '42501', null, 'the dashboard is the field agents''');
reset role;

-- ── TM oversight ────────────────────────────────────────────────────────
select pg_temp.as_user('tm3', 3, pg_temp.t1(), 'select public.get_monvelo_tm_oversight(30)');
select is((select count(*)::int from jsonb_array_elements(pg_temp.g('tm3') -> 'field_agents')), 3,
  'the Ikeja TM oversees its two ASAs and the zone''s ZSA');
select is((select x -> 'pairings' from jsonb_array_elements(pg_temp.g('tm3') -> 'field_agents') x
            where x ->> 'profile_id' = pg_temp.u(4)::text), '{"paired": 2, "unpaired": 0}'::jsonb,
  'with the ASA''s pairings in the territory');
select is((select (x -> 'financings_raised' ->> 'total')::int from jsonb_array_elements(pg_temp.g('tm3') -> 'field_agents') x
            where x ->> 'profile_id' = pg_temp.u(4)::text), 2, 'and the financings it raised');
select ok(pg_temp.g('tm3')::text !~ '80000000-', 'no partner is named');
select pg_temp.as_user('tm6', 6, pg_temp.t1(), 'select public.get_monvelo_tm_oversight(30)');
select is((select string_agg(x ->> 'role', ',') from jsonb_array_elements(pg_temp.g('tm6') -> 'field_agents') x), 'ZSA',
  'the Ikorodu TM sees only the zone''s ZSA');
select is((select (x -> 'pairings' ->> 'paired')::int from jsonb_array_elements(pg_temp.g('tm6') -> 'field_agents') x), 0,
  'and none of Ikeja''s activity');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.get_monvelo_tm_oversight(30)$$, '42501', null, 'oversight is the TM''s');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select throws_ok($$select public.get_monvelo_tm_oversight(0)$$, 'P0001', 'p_days must be between 1 and 366', 'a window of 1 to 366 days');
reset role;

select * from finish();
rollback;
