-- Addendum A6 §7.1, §7.3, §18.1, §18.2 (Monvelo Step 2, Task 8) — claims under
-- the allocation rule (preferred window, radius, pledge, caps), open offers, the
-- minute sweep (lapse, expiry at the end of the supply day, financings whose
-- trade order the stock sweep cancelled), and the raiser's overdue share.
begin;
create extension if not exists pgtap with schema extensions;

select plan(61);

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

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen) · 10 owner of S1 and S2 (verified)
-- agent members: 21 P (preferred, 400 m) · 22 N (600 m) · 23 F (5 km) · 24 X (no pledge)
--                25 C (small pledge) · 26 K (per-financing cap 10000) · 27 D (daily cap 20000)
--                28 a stranger
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 10, 21, 22, 23, 24, 25, 26, 27, 28]) n;

update public.operational_states set app_enabled = true, web_enabled = true;
set local session_replication_role = replica;
insert into public.tenant_operational_states (tenant_id, state_code, app_enabled, web_enabled, decision_id)
select t.id, s.code, true, true, gen_random_uuid() from public.tenants t cross join public.ng_states s
on conflict do nothing;
set local session_replication_role = origin;

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

-- a high opening limit keeps every request OFFERED unless a test lowers it
insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, valid_from, status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 200, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');

-- agents north of the shop at (3.35, 6.60): about 400 m, 600 m, 5 km, and four near ones
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'POS ' || n, 'OPAY', 'OP-' || n, '+23480311100' || lpad(n::text, 2, '0'),
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60 + dlat), 4326)::extensions.geography, 'a',
       '01234567' || lpad(n::text, 2, '0'), '67' || lpad(n::text, 2, '0'), '058', 'POS ' || n, 'K' || n,
       '20000000-0000-0000-0000-000000000004', 'ACTIVE', dcap, pcap
  from (values (21, 0.0036, 500000, 200000), (22, 0.0054, 500000, 200000), (23, 0.0450, 500000, 200000),
               (24, 0.0030, 500000, 200000), (25, 0.0030, 500000, 200000), (26, 0.0030, 500000, 10000),
               (27, 0.0030, 20000, 20000)) v (n, dlat, dcap, pcap);
insert into public.monvelo_agent_members (agent_id, profile_id)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 27) n;
-- pledges for Allen today; X (24) has none
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), amt, amt, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from (values (21, 150000), (22, 100000), (23, 100000), (25, 20000), (26, 100000), (27, 100000)) v (n, amt);

-- S1 (preferred agent P) and S2, both enrolled in Allen, owner 10
insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text, preferred_agent_id) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1', '80000000-0000-0000-0000-000000000021'),
  ('71000000-0000-0000-0000-000000000002', 'Shop 2', '+234803111002', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 2', null);
update public.retail_shops set shop_code = 'SH-AAAAA' || chr(65 + right(id::text, 1)::int) where id::text like '71000000-%';
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by)
select ('c0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('71000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000004'
  from generate_series(1, 2) n;
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id)
select c.tenant_id, c.shop_id, c.area_id, c.issued_by, now(), 'MV-SHARE-2026-10', c.id
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
  $$ select ('d3000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.t1() to authenticated;
create temp table ord (n text primary key, id uuid);
create temp table fin (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert on ord, fin, res to authenticated;
create function pg_temp.o(p_n text) returns uuid language sql as $$ select id from ord where n = p_n $$;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
grant execute on function pg_temp.o(text), pg_temp.f(text) to authenticated;
-- the ASA places p_qty Purerigin 200 ml (4000 each) for shop p_shop and requests its financing
create function pg_temp.raise(p_n text, p_key integer, p_qty integer, p_shop integer default 1) returns uuid
language plpgsql as $$
declare v_o uuid; v_f uuid;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid,
          jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', p_qty))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into ord values (p_n, v_o);
  insert into fin values (p_n, v_f);
  return v_f;
end; $$;
-- a member of agent p_agent claims; the result is kept as p_n
create function pg_temp.claim(p_n text, p_key integer, p_agent integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.claim_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
-- as postgres, walk a financing from OFFERED along the whitelist to p_to, due p_due
create function pg_temp.walk(p_fin text, p_to text, p_due timestamptz) returns void language plpgsql as $$
begin
  update public.monvelo_financings set status = 'CLAIMED', claimed_by_agent_id = pg_temp.ag(22), claimed_by = pg_temp.u(22),
         claim_expires_at = now() + interval '15 minutes', pledge_id = '82000000-0000-0000-0000-000000000022'
   where id = pg_temp.f(p_fin);
  update public.monvelo_financings set status = 'FUNDED', funder_agent_id = pg_temp.ag(22), funded_at = now() - interval '40 days'
   where id = pg_temp.f(p_fin);
  update public.monvelo_financings set status = 'DELIVERED', delivered_at = now() - interval '40 days', due_at = p_due,
         outstanding = principal where id = pg_temp.f(p_fin);
  if p_to = 'DEFAULTED_WITH_LATE_CHARGE' then
    update public.monvelo_financings set status = p_to where id = pg_temp.f(p_fin);
  end if;
end; $$;
create function pg_temp.claim_msg(p_fin text) returns text language sql as $$
  select 'the shop''s preferred agent has first claim until '
         || to_char(preferred_window_ends_at at time zone 'Africa/Lagos', 'HH24:MI')
    from public.monvelo_financings where id = pg_temp.f(p_fin) $$;
grant execute on function pg_temp.claim_msg(text) to authenticated;

-- ── shape and security ──────────────────────────────────────────────────
select has_table('public', 'monvelo_financing_claims', 'monvelo_financing_claims exists');
select ok(not has_table_privilege('authenticated', 'public.monvelo_financing_claims', 'insert')
      and not has_table_privilege('anon', 'public.monvelo_financing_claims', 'select'),
  'the API holds no write grant on claims, and anon nothing');
select ok(not has_function_privilege('authenticated', 'public.monvelo_sweep_offers()', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_sweep_offers()', 'execute'),
  'no API role can run the sweep');
select ok(has_function_privilege('authenticated', 'public.claim_monvelo_financing(uuid,uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.monvelo_open_offers(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_open_offers(uuid)', 'execute'),
  'claim and open offers are for signed-in members');
select ok(pg_get_function_result('public.monvelo_open_offers(uuid)'::regprocedure) !~* '(owner|phone)',
  'open offers carry no owner or phone column');
select is((select schedule from cron.job where jobname = 'monvelo-offer-sweep'), '* * * * *', 'the sweep runs every minute');
select ok((select command ~ 'monvelo_sweep_offers' from cron.job where jobname = 'monvelo-offer-sweep'), 'and calls monvelo_sweep_offers');

-- ── the preferred window ────────────────────────────────────────────────
select pg_temp.raise('A', 100, 3);
select ok((select preferred_agent_id = pg_temp.ag(21) and preferred_window_ends_at > now()
             from public.monvelo_financings where id = pg_temp.f('A')), 'fixture: P has the window on A');
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(110), pg_temp.f('A'), pg_temp.ag(22))$$,
  'P0001', pg_temp.claim_msg('A'), 'N cannot claim during P''s window; the message names the Lagos time');
select pg_temp.act_as(pg_temp.u(28), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(111), pg_temp.f('A'), pg_temp.ag(21))$$,
  '42501', null, 'a non-member cannot claim for P');
select throws_ok($$select * from public.monvelo_open_offers(pg_temp.ag(21))$$,
  '42501', null, 'nor read P''s open offers');
reset role;
select lives_ok($$select pg_temp.claim('PA', 112, 21, 'A')$$, 'P claims inside its window');
select is((select r ->> 'status' from res where n = 'PA'), 'CLAIMED', 'CLAIMED');
select ok((select (r ->> 'claim_expires_at')::timestamptz between now() + interval '14 minutes' and now() + interval '16 minutes'
             from res where n = 'PA'), 'the claim lasts about 15 minutes');
select is((select row(claimed_by_agent_id = pg_temp.ag(21), claimed_by = pg_temp.u(21),
                      pledge_id = '82000000-0000-0000-0000-000000000021', preferred_window_ends_at is null)::text
             from public.monvelo_financings where id = pg_temp.f('A')),
  '(t,t,t,t)', 'the claim fields are set and the window is cleared');
select pg_temp.act_as(pg_temp.u(21), null);
select is(public.claim_monvelo_financing(pg_temp.k(112), pg_temp.f('A'), pg_temp.ag(21)), (select r from res where n = 'PA'),
  'P''s replay returns the same response');
reset role;
select is((select count(*)::int from public.audit_logs where operation = 'claim_monvelo_financing'
            and idempotency_key = pg_temp.k(112) and tenant_id is null), 1,
  'the claim is audited with no tenant: the row names the agent (A6 §16.2.2, Step 3 R15)');

-- ── one at a time ───────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(120), pg_temp.f('A'), pg_temp.ag(22))$$,
  'P0001', 'this request is no longer open', 'N cannot claim a claimed request');
reset role;
select is((select count(*)::int from public.monvelo_financing_claims where outcome is null and financing_id in (select id from fin)), 1,
  'one open claim row');
select throws_ok($$insert into public.monvelo_financing_claims (tenant_id, financing_id, agent_id, claimed_by, pledge_id, expires_at)
                   values (pg_temp.t1(), pg_temp.f('A'), pg_temp.ag(22), pg_temp.u(22), '82000000-0000-0000-0000-000000000022', now())$$,
  '23505', null, 'a second open claim on one financing is refused by the index');

-- ── lapse ───────────────────────────────────────────────────────────────
update public.monvelo_financings set claim_expires_at = now() - interval '1 second' where id = pg_temp.f('A');
select is((public.monvelo_sweep_offers() ->> 'lapsed')::int, 1, 'the sweep lapses the claim');
select is((select status || ':' || coalesce(claimed_by_agent_id::text, '-') || ':' || coalesce(preferred_window_ends_at::text, '-')
             from public.monvelo_financings where id = pg_temp.f('A')),
  'OFFERED:-:-', 'A is OFFERED again, its claim fields cleared, with no new window');
select is((select outcome from public.monvelo_financing_claims where financing_id = pg_temp.f('A')), 'LAPSED', 'the claim row is LAPSED');
select ok((select source = 'CRON' and teafair_agent_id = pg_temp.u(4) from public.audit_logs
            where operation = 'monvelo_sweep_offers' and entity_id = pg_temp.f('A')::text limit 1),
  'the sweep audits as CRON on the raiser');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(130), pg_temp.f('A'), pg_temp.ag(21))$$,
  'P0001', 'your claim on this request lapsed; another agent may claim it', 'P cannot re-claim after its claim lapsed');
reset role;
select lives_ok($$select pg_temp.claim('NA', 131, 22, 'A')$$, 'N claims once the window is gone');
select is((select r ->> 'status' from res where n = 'NA'), 'CLAIMED', 'N holds A');

-- ── distance and money (new financings, windows ended) ──────────────────
select pg_temp.raise('B', 200, 3);
select pg_temp.raise('C', 202, 3);
select pg_temp.raise('D', 204, 3);
update public.monvelo_financings set preferred_window_ends_at = now() - interval '1 second'
 where id in (pg_temp.f('B'), pg_temp.f('C'), pg_temp.f('D'));
select lives_ok($$select pg_temp.claim('CC', 210, 25, 'C')$$, 'C claims C (12000 of its 20000 pledge)');
select lives_ok($$select pg_temp.claim('DD', 211, 27, 'D')$$, 'D claims D (12000 of its 20000 daily cap)');
select pg_temp.act_as(pg_temp.u(23), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(212), pg_temp.f('B'), pg_temp.ag(23))$$,
  'P0001', 'this shop is outside your area', 'F, 5 km away, is outside the radius');
select pg_temp.act_as(pg_temp.u(24), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(213), pg_temp.f('B'), pg_temp.ag(24))$$,
  'P0001', 'pledge enough funds for this area and day first', 'X has no pledge');
select pg_temp.act_as(pg_temp.u(25), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(214), pg_temp.f('B'), pg_temp.ag(25))$$,
  'P0001', 'pledge enough funds for this area and day first', 'C''s pledge is committed to its other CLAIMED financing');
select pg_temp.act_as(pg_temp.u(26), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(215), pg_temp.f('B'), pg_temp.ag(26))$$,
  'P0001', 'this request is above your per-financing cap', 'K''s per-financing cap is 10000');
select pg_temp.act_as(pg_temp.u(27), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(216), pg_temp.f('B'), pg_temp.ag(27))$$,
  'P0001', 'this request would pass your daily cap', 'D''s claimed 12000 + 12000 passes its 20000 daily cap');

-- ── open offers ─────────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(22), null);
select is((select shop_code || ':' || area_name || ':' || principal from public.monvelo_open_offers(pg_temp.ag(22))
            where financing_id = pg_temp.f('B')), 'SH-AAAAAB:Allen:12000.00', 'N sees B with its shop code and area');
select ok((select distance_m between 550 and 650 from public.monvelo_open_offers(pg_temp.ag(22)) where financing_id = pg_temp.f('B')),
  'about 600 m away');
select is((select count(*)::int from public.monvelo_open_offers(pg_temp.ag(22)) where financing_id in (pg_temp.f('A'), pg_temp.f('C'))),
  0, 'claimed requests are not offered');
select pg_temp.act_as(pg_temp.u(23), null);
select is((select count(*)::int from public.monvelo_open_offers(pg_temp.ag(23))), 0, 'F, 5 km away, sees nothing');
select pg_temp.act_as(pg_temp.u(24), null);
select is((select count(*)::int from public.monvelo_open_offers(pg_temp.ag(24))), 0, 'X, with no pledge, sees nothing');
reset role;
select pg_temp.raise('W', 220, 3);
select pg_temp.act_as(pg_temp.u(21), null);
select ok((select preferred_until > now() from public.monvelo_open_offers(pg_temp.ag(21)) where financing_id = pg_temp.f('W')),
  'P sees W inside its own window, with the window''s end');
select pg_temp.act_as(pg_temp.u(22), null);
select is((select count(*)::int from public.monvelo_open_offers(pg_temp.ag(22)) where financing_id = pg_temp.f('W')), 0,
  'N does not see W during P''s window');

-- ── readers ─────────────────────────────────────────────────────────────
select is((select count(*)::int from public.monvelo_financing_claims), 1,
  'N''s member reads only N''s own claim, not P''s lapsed one on the same financing');
select pg_temp.act_as(pg_temp.u(28), null);
select is((select count(*)::int from public.monvelo_financing_claims), 0, 'a stranger reads no claims');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financing_claims), 0,
  'the territory''s TM reads no claims: tenants never see lenders (A6 §16.2.2)');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is((select count(*)::int from public.monvelo_financing_claims), 0, 'nor does the ZSM');
reset role;

-- ── expiry at the end of the supply day ─────────────────────────────────
select pg_temp.raise('E', 300, 3);                            -- stays OFFERED
update public.monvelo_shop_limits set limit_amount = 0 where shop_id = '71000000-0000-0000-0000-000000000001';
select pg_temp.raise('G', 302, 3);                            -- AWAITING_APPROVAL
update public.monvelo_shop_limits set limit_amount = 10000000 where shop_id = '71000000-0000-0000-0000-000000000001';
select is((select string_agg(status, ',' order by status) from public.monvelo_financings where id in (pg_temp.f('E'), pg_temp.f('G'))),
  'AWAITING_APPROVAL,OFFERED', 'fixture: one OFFERED, one AWAITING_APPROVAL');
-- yesterday's: E and G, and D whose claim also lapsed
set local session_replication_role = replica;
update public.monvelo_financings set supply_date = public.monvelo_today() - 1
 where id in (pg_temp.f('E'), pg_temp.f('G'), pg_temp.f('D'));
update public.monvelo_financings set claim_expires_at = now() - interval '1 second' where id = pg_temp.f('D');
set local session_replication_role = origin;

-- H: the stock sweep cancels its trade order at the end of the supply day (6b)
select pg_temp.raise('H', 304, 3);
set local session_replication_role = replica;
update public.stock_reservations set expires_at = now() - interval '1 second' where order_id = pg_temp.o('H');
set local session_replication_role = origin;
select is(public.stock_reservation_sweep(), 1, 'fixture: the stock sweep cancels H''s trade order');
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(310), pg_temp.f('H'), pg_temp.ag(22))$$,
  'P0001', 'this request is no longer open', 'a request whose trade order is cancelled cannot be claimed');
reset role;

select is(public.monvelo_sweep_offers(), '{"lapsed": 1, "expired": 4}'::jsonb,
  'one sweep: D lapses, then D, E, G (yesterday) and H (order cancelled) expire');
select is((select string_agg(status, ',') from public.monvelo_financings
            where id in (pg_temp.f('D'), pg_temp.f('E'), pg_temp.f('G'), pg_temp.f('H'))),
  'EXPIRED,EXPIRED,EXPIRED,EXPIRED', 'all four EXPIRED (a lapse after midnight never ends OFFERED)');
select is((select outcome from public.monvelo_financing_claims where financing_id = pg_temp.f('D')), 'LAPSED', 'D''s claim LAPSED');
select is((select string_agg(distinct status, ',') from public.orders
            where id in (pg_temp.o('D'), pg_temp.o('E'), pg_temp.o('G'), pg_temp.o('H'))),
  'CANCELLED', 'their trade orders are cancelled (A6 §18.1)');
select is((select count(*)::int from public.stock_reservations
            where order_id in (pg_temp.o('D'), pg_temp.o('E'), pg_temp.o('G')) and status = 'RESERVED'),
  0, 'and their stock released');
select is((select status from public.monvelo_financings where id = pg_temp.f('B')), 'OFFERED', 'today''s B is untouched');
select is((select count(*)::int from public.audit_logs where operation = 'monvelo_sweep_offers'
            and (source <> 'CRON' or teafair_agent_id is null)), 0, 'every sweep row is CRON with a teafair_agent_id');
select is(public.monvelo_sweep_offers(), '{"lapsed": 0, "expired": 0}'::jsonb, 'a second sweep finds nothing');

-- ── the platform hard freeze at claim (A6 §18.2) ────────────────────────
select pg_temp.raise('P', 400, 3);
select pg_temp.walk('P', 'DEFAULTED_WITH_LATE_CHARGE', now() - interval '31 days');
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$select public.claim_monvelo_financing(pg_temp.k(410), pg_temp.f('B'), pg_temp.ag(22))$$,
  'P0001', 'the shop has an overdue Monvelo financing; no new credit on the platform until it is cleared',
  'an open request for a frozen shop cannot be claimed');
select is((select count(*)::int from public.monvelo_open_offers(pg_temp.ag(22)) where financing_id = pg_temp.f('B')), 0,
  'nor is it offered');
reset role;

-- ── the raiser's overdue share, PAR30 (A6 §7.3) ─────────────────────────
-- S2 orders (no financing yet), placed by the ASA
create function pg_temp.place_s2(p_n text, p_key integer, p_qty integer) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v := (public.place_trade_order(pg_temp.k(p_key), '71000000-0000-0000-0000-000000000002',
        jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', p_qty))) ->> 'order_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into ord values (p_n, v);
  return v;
end; $$;
select pg_temp.place_s2('S2a', 500, 3);
select pg_temp.place_s2('S2b', 502, 3);
select pg_temp.place_s2('S2q', 504, 36);
-- the ASA's delivered book is P alone: 12000, 31 days overdue, so 100 %
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select throws_ok($$select public.request_monvelo_financing(pg_temp.k(510), pg_temp.o('S2a'))$$,
  'P0001', 'more than 10% of the Monvelo credit you raised is over 30 days overdue; you can raise new requests once it drops',
  'an ASA whose overdue share is above 10% cannot raise, even for another shop');
reset role;
-- 29 days overdue is not yet PAR30
update public.monvelo_financings set due_at = now() - interval '29 days' where id = pg_temp.f('P');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select lives_ok($$select public.request_monvelo_financing(pg_temp.k(511), pg_temp.o('S2a'))$$,
  'a default 29 days overdue does not count');
reset role;
update public.monvelo_financings set due_at = now() - interval '31 days' where id = pg_temp.f('P');
-- a current 144000 financing for S2 (delivered, due in 10 days) brings the share to 12000 / 156000
insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
                                       principal, supply_date, status, approval_required) values
  ('f3000000-0000-0000-0000-000000000001', pg_temp.t1(), 'MV-QQQQQQQQ', '71000000-0000-0000-0000-000000000002', pg_temp.o('S2q'),
   '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', pg_temp.u(4),
   144000, public.monvelo_today(), 'REQUESTED', false);
insert into fin values ('Q', 'f3000000-0000-0000-0000-000000000001');
update public.monvelo_financings set status = 'OFFERED', offered_at = now() where id = pg_temp.f('Q');
select pg_temp.walk('Q', 'DELIVERED', now() + interval '10 days');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select lives_ok($$select public.request_monvelo_financing(pg_temp.k(512), pg_temp.o('S2b'))$$,
  'under 10 % the ASA raises again');
reset role;

select * from finish();
rollback;
