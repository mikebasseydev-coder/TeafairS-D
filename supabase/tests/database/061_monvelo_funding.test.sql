-- Addendum A6 §4.4, §7.4, §11 F1 (Monvelo Step 3, Task 1) — funding: the
-- agent's payment (start_monvelo_funding), the payer check on the transfer
-- (monvelo_payer_matches), FUNDED with the rebate payable
-- (settle_monvelo_funding), the late-payment route, the flags and their review,
-- and settle_paystack_payment leaving MV- payments alone.
begin;
create extension if not exists pgtap with schema extensions;

select plan(180);

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

-- A6 §19: one agent funds several 48000 financings here, more than the 100000
-- open exposure ceiling; this file is not about the cap (065 is), so the
-- ceiling is raised for this transaction only
create or replace function public.monvelo_open_exposure_ceiling() returns numeric language sql immutable
set search_path = public, pg_temp as $$ select 100000000.00::numeric(15,2) $$;

-- ── fixtures (as postgres), tenant TEAFAIR ──────────────────────────────
-- 01 ZSM · 03 TM (Ikeja) · 04 ASA (Allen, the raiser) · 07 TENANT_ADMIN · 10 owner of S1 and S2
-- 06 MONVELO_FINANCE · 09 MONVELO_OPERATOR
-- agent members: 21 P (S1's preferred agent, "ADE, BISI O.", ...0011) · 22 N ("CHIOMA NNE OKAFOR", ...0022)
--                28 a stranger
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 6, 7, 9, 10, 21, 22, 28]) n;
update public.profiles set platform_role = 'MONVELO_FINANCE'  where id = '20000000-0000-0000-0000-000000000006';
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000009';

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
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.zones set zsm_id = '20000000-0000-0000-0000-000000000001' where id = '30000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'IKEJA', 'REGIONAL', '40000000-0000-0000-0000-000000000001');

insert into public.monvelo_tenant_settings (tenant_id, enabled, opening_limit, approval_cap) values
  ('7eaf0000-0000-4000-8000-000000000001', true, 10000000, 0)
on conflict (tenant_id) do update set enabled = true, opening_limit = 10000000;
-- Purerigin's approved terms: 10 %, 30 days, 10 % (A6 §5)
insert into public.monvelo_brand_terms (tenant_id, brand, rebate_bps, interest_free_days, late_charge_bps, valid_from,
                                        status, proposed_by, approved_by, approved_at) values
  ('7eaf0000-0000-4000-8000-000000000001', 'Purerigin', 1000, 30, 1000, public.monvelo_today() - 1, 'APPROVED',
   '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', now());
insert into public.monvelo_supply_days (tenant_id, area_id, day_of_week, active, set_by) values
  ('7eaf0000-0000-4000-8000-000000000001', '60000000-0000-0000-0000-000000000001',
   extract(isodow from public.monvelo_today())::int, true, '20000000-0000-0000-0000-000000000001');

-- P about 400 m and N about 600 m north of the shops at (3.35, 6.60)
insert into public.monvelo_agents (id, business_name, pos_network, network_agent_id, contact_phone, location, address_text,
  settlement_account_number, settlement_account_last4, settlement_bank_code, settlement_account_name, network_kyc_reference,
  recruited_by, status, daily_cap, per_financing_cap)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'POS ' || n, 'OPAY', 'OP-' || n, '+23480311100' || lpad(n::text, 2, '0'),
       extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60 + dlat), 4326)::extensions.geography, 'a',
       '012345' || last4, last4, '058', holder, 'K' || n,
       '20000000-0000-0000-0000-000000000004', 'ACTIVE', 500000, 200000
  from (values (21, 0.0036, '0011', 'ADE, BISI O.'), (22, 0.0054, '0022', 'CHIOMA NNE OKAFOR')) v (n, dlat, last4, holder);
insert into public.monvelo_agent_members (agent_id, profile_id)
select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;
insert into public.monvelo_pledges (id, tenant_id, agent_id, area_id, supply_date, amount, remaining, pledged_by)
select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '7eaf0000-0000-4000-8000-000000000001',
       ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '60000000-0000-0000-0000-000000000001',
       public.monvelo_today(), 150000, 150000, ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(21, 22) n;

-- S1 (preferred agent P) and S2 (none), both enrolled in Allen, owner 10
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
  $$ select ('d6100000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.ag(n integer) returns uuid language sql as
  $$ select ('80000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.pl(n integer) returns uuid language sql as
  $$ select ('82000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
grant execute on function pg_temp.k(integer), pg_temp.u(integer), pg_temp.ag(integer), pg_temp.pl(integer), pg_temp.t1()
  to authenticated;
create temp table ord (n text primary key, id uuid);
create temp table fin (n text primary key, id uuid);
create temp table res (n text primary key, r jsonb);
grant select, insert, update on ord, fin, res to authenticated;
create function pg_temp.o(p_n text) returns uuid language sql as $$ select id from ord where n = p_n $$;
create function pg_temp.f(p_n text) returns uuid language sql as $$ select id from fin where n = p_n $$;
create function pg_temp.r(p_n text) returns jsonb language sql as $$ select r from res where n = p_n $$;
grant execute on function pg_temp.o(text), pg_temp.f(text), pg_temp.r(text) to authenticated;
-- the ASA places 12 Purerigin 200 ml (4000 each: 48000) for shop p_shop and requests its financing
create function pg_temp.raise(p_n text, p_key integer, p_shop integer default 1) returns uuid
language plpgsql as $$
declare v_o uuid; v_f uuid;
begin
  perform pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
  v_o := (public.place_trade_order(pg_temp.k(p_key), ('71000000-0000-0000-0000-' || lpad(p_shop::text, 12, '0'))::uuid,
          jsonb_build_array(jsonb_build_object('sku_code', 'PURERIGIN-COCONUT-OIL-200ML', 'qty', 12))) ->> 'order_id')::uuid;
  v_f := (public.request_monvelo_financing(pg_temp.k(p_key + 1), v_o) ->> 'financing_id')::uuid;
  perform set_config('role', 'postgres', true);
  insert into ord values (p_n, v_o);
  insert into fin values (p_n, v_f);
  return v_f;
end; $$;
create function pg_temp.claim(p_key integer, p_agent integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.claim_monvelo_financing(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent), (select o.net_yield_bps from public.get_monvelo_offer_cover(pg_temp.f(p_fin), pg_temp.ag(p_agent)) o));
  perform set_config('role', 'postgres', true);
  return v;
end; $$;
-- a member of agent p_agent starts the funding payment; kept as p_n
create function pg_temp.start(p_n text, p_key integer, p_agent integer, p_fin text) returns jsonb
language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_agent), null);
  v := public.start_monvelo_funding(pg_temp.k(p_key), pg_temp.f(p_fin), pg_temp.ag(p_agent));
  perform set_config('role', 'postgres', true);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
-- what Paystack's Verify returns for a transfer
create function pg_temp.v(p_name text, p_acct text, p_channel text default 'bank_transfer') returns jsonb
language sql as $$
  select jsonb_build_object('status', 'success', 'channel', p_channel,
    'authorization', jsonb_build_object('channel', p_channel, 'sender_bank', 'Guaranty Trust Bank',
                                        'sender_name', p_name, 'sender_bank_account_number', p_acct))
$$;
-- settle as the gateway would (service_role); the result is kept as p_n
create function pg_temp.settle(p_n text, p_event text, p_payment text, p_status text, p_minor bigint, p_verified jsonb)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  v := public.settle_monvelo_funding(p_event, coalesce(pg_temp.r(p_payment) ->> 'reference', p_payment), p_status,
                                     p_minor, 'NGN', p_verified, 'T-' || p_n);
  insert into res values (p_n, v) on conflict (n) do update set r = excluded.r;
  return v;
end; $$;
create function pg_temp.pid(p_n text) returns uuid language sql as $$ select (pg_temp.r(p_n) ->> 'payment_id')::uuid $$;
-- the payer check against P with one field changed
create function pg_temp.pm(p_holder text, p_sender text, p_acct text default 'XXXXXX0011', p_channel text default 'bank_transfer')
returns boolean language plpgsql as $$
declare a public.monvelo_agents;
begin
  select * into a from public.monvelo_agents where id = pg_temp.ag(21);
  a.settlement_account_name := p_holder;
  return public.monvelo_payer_matches(a, pg_temp.v(p_sender, p_acct, p_channel));
end; $$;
create function pg_temp.lapse(p_fin text) returns void language plpgsql as $$
begin
  update public.monvelo_financings set claim_expires_at = now() - interval '1 second' where id = pg_temp.f(p_fin);
  perform public.monvelo_sweep_offers();
end; $$;

-- ── shape and security ──────────────────────────────────────────────────
select has_column('public', 'payments', 'monvelo_financing_id', 'payments.monvelo_financing_id exists');
select ok(not has_column_privilege('authenticated', 'public.payments', 'monvelo_financing_id', 'select')
      and not has_column_privilege('authenticated', 'public.payments', 'monvelo_agent_id', 'select')
      and not has_column_privilege('authenticated', 'public.payments', 'monvelo_started_by', 'select'),
  'the Monvelo payments columns are not granted to the API');
-- R13: each agent's claims and fundings queue on one advisory lock (a race cannot be shown here)
select ok((select bool_and(prosrc ~ 'pg_advisory_xact_lock\(hashtextextended\(''monvelo_agent:''') from pg_proc
            where pronamespace = 'public'::regnamespace and proname in ('claim_monvelo_financing', 'settle_monvelo_funding'))
      and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
             and proname in ('claim_monvelo_financing', 'settle_monvelo_funding')) = 2,
  'claim and settle take the per-agent advisory lock');
select ok(has_function_privilege('authenticated', 'public.start_monvelo_funding(uuid,uuid,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.start_monvelo_funding(uuid,uuid,uuid)', 'execute'),
  'start_monvelo_funding is for signed-in members');
select ok(not has_function_privilege('authenticated', 'public.settle_monvelo_funding(text,text,text,bigint,text,jsonb,text)', 'execute')
      and not has_function_privilege('anon', 'public.settle_monvelo_funding(text,text,text,bigint,text,jsonb,text)', 'execute')
      and has_function_privilege('service_role', 'public.settle_monvelo_funding(text,text,text,bigint,text,jsonb,text)', 'execute'),
  'authenticated cannot execute settle_monvelo_funding; service_role can');
select ok(not has_function_privilege('authenticated', 'public.monvelo_payer_matches(public.monvelo_agents,jsonb)', 'execute')
      and not has_function_privilege('service_role', 'public.monvelo_payer_matches(public.monvelo_agents,jsonb)', 'execute'),
  'the payer check is internal');
select ok(has_function_privilege('authenticated', 'public.review_monvelo_flag(uuid,uuid,text)', 'execute'),
  'review_monvelo_flag is callable (the RPC checks the operator)');
select ok(not has_table_privilege('authenticated', 'public.monvelo_rebate_payables', 'insert')
      and not has_table_privilege('service_role', 'public.monvelo_rebate_payables', 'insert')
      and not has_table_privilege('authenticated', 'public.monvelo_flags', 'update')
      and not has_table_privilege('anon', 'public.monvelo_rebate_payable_lines', 'select'),
  'no API role writes payables or flags, and anon reads nothing');

-- ── the payer check (F1) ────────────────────────────────────────────────
select is(public.monvelo_name_tokens('Ade, Bisi O.'), array['ADE', 'BISI', 'O'], 'tokens are upper-case words, punctuation removed');
select ok(pg_temp.pm('ADE, BISI O.', 'BISI ADE'), '"BISI ADE" matches "ADE, BISI O."');
select ok(pg_temp.pm('BISI ADE', 'ADE, BISI O.'), 'and the reverse');
select ok(not pg_temp.pm('BISI ADE', 'BISI'), '"BISI" does not match "BISI ADE" (one token)');
select ok(not pg_temp.pm('ADE, BISI O.', 'BISI ADE', 'XXXXXX9999'), 'other last four digits do not match');
select ok(not pg_temp.pm('ADE, BISI O.', 'BISI ADE', 'XXXXXX0011', 'card'), 'a card charge does not match');
select ok(pg_temp.pm('ADE, BISI O.', 'BISI ADE', 'XXXXXX0011', 'dedicated_nuban'), 'a dedicated NUBAN transfer matches');
select ok(not pg_temp.pm('ADE, BISI O.', 'TUNDE ADE'), 'another holder does not match');
select ok(not pg_temp.pm('ADE, BISI O.', null), 'no sender name does not match');
-- R18: initials do not count toward the 2-token minimum
select ok(not pg_temp.pm('ADE B. O.', 'B O'), '"B O" does not match "ADE B. O." (two initials)');
select ok(pg_temp.pm('BISI ADE', 'BISI ADE STORES LTD'), 'reverse containment is allowed: "BISI ADE STORES LTD" matches "BISI ADE"');

-- ── start_monvelo_funding ───────────────────────────────────────────────
select pg_temp.raise('A', 100);                        -- S1: P's preferred window
select pg_temp.raise('W', 102);                        -- stays OFFERED
select pg_temp.claim(104, 21, 'A');
select pg_temp.act_as(pg_temp.u(28), null);
select throws_ok($$select public.start_monvelo_funding(pg_temp.k(110), pg_temp.f('A'), pg_temp.ag(21))$$,
  '42501', null, 'a non-member cannot fund for P');
select pg_temp.act_as(pg_temp.u(22), null);
select throws_ok($$select public.start_monvelo_funding(pg_temp.k(111), pg_temp.f('A'), pg_temp.ag(22))$$,
  'P0001', 'fund only a request your agent holds the claim on', 'N cannot fund P''s claim');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.start_monvelo_funding(pg_temp.k(112), pg_temp.f('W'), pg_temp.ag(21))$$,
  'P0001', 'fund only a request your agent holds the claim on', 'an OFFERED financing cannot be funded');
reset role;
update public.monvelo_financings set claim_expires_at = now() + interval '30 seconds' where id = pg_temp.f('A');
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.start_monvelo_funding(pg_temp.k(113), pg_temp.f('A'), pg_temp.ag(21))$$,
  'P0001', 'your claim ends in under a minute; it cannot be funded now', 'refused inside the claim''s last 60 s');
reset role;
update public.monvelo_financings set claim_expires_at = now() + interval '15 minutes' where id = pg_temp.f('A');
-- R57: a suspended agent's member cannot start a funding, even on its own claim
update public.monvelo_agents set status = 'SUSPENDED' where id = pg_temp.ag(21);
select pg_temp.act_as(pg_temp.u(21), null);
select throws_ok($$select public.start_monvelo_funding(pg_temp.k(119), pg_temp.f('A'), pg_temp.ag(21))$$,
  '42501', 'the agent is not active', 'R57: a suspended agent cannot start a funding');
reset role;
select is((select count(*)::int from public.payments where monvelo_financing_id = pg_temp.f('A')), 0,
  'and no payment was created');
update public.monvelo_agents set status = 'ACTIVE' where id = pg_temp.ag(21);

select lives_ok($$select pg_temp.start('A1', 114, 21, 'A')$$, 'P starts the funding of A');
select is(pg_temp.r('A1') ->> 'reference', (select reference || '-1' from public.monvelo_financings where id = pg_temp.f('A')),
  'the reference is the financing''s, then -1');
select ok((pg_temp.r('A1') ->> 'reference') ~ '^MV-[A-Z2-7]{8}-[1-9][0-9]*$', 'and matches the MV- pattern');
select is(row(pg_temp.r('A1') ->> 'amount_minor', pg_temp.r('A1') ->> 'currency')::text, '(4800000,NGN)',
  'amount_minor is the principal in kobo, in naira');
select ok((pg_temp.r('A1') ->> 'claim_expires_at')::timestamptz = (select claim_expires_at from public.monvelo_financings where id = pg_temp.f('A')),
  'it returns the claim''s expiry');
select is((select row(p.order_id = pg_temp.o('A'), p.teafair_agent_id = pg_temp.u(4), p.customer_id is null, p.amount,
                      p.payment_status, p.monvelo_financing_id = pg_temp.f('A'), p.monvelo_agent_id = pg_temp.ag(21),
                      p.monvelo_started_by = pg_temp.u(21))::text
             from public.payments p where p.id = pg_temp.pid('A1')),
  '(t,t,t,48000.00,INITIATED,t,t,t)', 'one INITIATED payment for the trade order, on the raiser, for the principal');
select is(pg_temp.r('A1') ->> 'replayed', 'false', 'the first call says it is not a replay');
select pg_temp.act_as(pg_temp.u(21), null);
select is(public.start_monvelo_funding(pg_temp.k(114), pg_temp.f('A'), pg_temp.ag(21)),
  (pg_temp.r('A1') - 'replayed') || '{"replayed": true}'::jsonb,
  'the replay returns the same payment, marked replayed, with no checkout while none is stored');
reset role;
select is((select count(*)::int from public.payments where monvelo_financing_id = pg_temp.f('A')), 1, 'and creates no second row');

-- ── R53: the checkout is stored after Initialize; a replay hands it back ─
select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'payments'
                       and column_name = 'monvelo_authorization_url')
          and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'payments'
                       and column_name = 'monvelo_access_code'),
  'payments has monvelo_authorization_url and monvelo_access_code');
select ok(not has_column_privilege('authenticated', 'public.payments', 'monvelo_authorization_url', 'select')
      and not has_column_privilege('authenticated', 'public.payments', 'monvelo_access_code', 'select')
      and not has_column_privilege('anon', 'public.payments', 'monvelo_access_code', 'select'),
  'neither column is granted to the API');
-- R59: the gateway records it on the caller's JWT with the gateway proof (R16), never the service role
delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;
select is(to_regprocedure('public.record_monvelo_checkout(uuid,text,text)'), null, 'R59: the service-role signature is gone');
select ok(has_function_privilege('authenticated', 'public.record_monvelo_checkout(uuid,text,uuid,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.record_monvelo_checkout(uuid,text,uuid,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.record_monvelo_checkout(uuid,text,uuid,text,text)', 'execute'),
  'record_monvelo_checkout is for signed-in callers only (the RPC checks the proof and the starter)');
select ok((select p.prosecdef and p.proconfig @> array['search_path=public, pg_temp'] from pg_proc p
            where p.oid = 'public.record_monvelo_checkout(uuid,text,uuid,text,text)'::regprocedure),
  'it is SECURITY DEFINER with the pinned search_path');
-- member p_user stores a checkout for payment p_pay under key k(p_key)
create function pg_temp.rc(p_key integer, p_user integer, p_pay uuid, p_url text, p_code text, p_proof text default 'test-gw-secret')
returns jsonb language plpgsql as $f$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.u(p_user), null);
  v := public.record_monvelo_checkout(pg_temp.k(p_key), p_proof, p_pay, p_url, p_code);
  perform set_config('role', 'postgres', true);
  return v;
end; $f$;
create temp table a1 as select pg_temp.pid('A1') as id;
select throws_ok($$select pg_temp.rc(120, 21, (select id from a1), 'https://checkout.paystack.com/x', 'x', 'wrong')$$,
  '42501', 'this operation must come through its gateway', 'without the gateway proof it is refused');
select throws_ok($$select pg_temp.rc(121, 22, (select id from a1), 'https://checkout.paystack.com/x', 'x')$$,
  '42501', 'only the member who started this payment records its checkout', 'another agent''s member is refused');
update public.monvelo_agents set status = 'SUSPENDED' where id = pg_temp.ag(21);
select throws_ok($$select pg_temp.rc(122, 21, (select id from a1), 'https://checkout.paystack.com/x', 'x')$$,
  '42501', 'only the member who started this payment records its checkout', 'nor the starter while the agent is suspended');
update public.monvelo_agents set status = 'ACTIVE' where id = pg_temp.ag(21);
update public.payments set payment_status = 'FAILED' where id = (select id from a1);
select throws_ok($$select pg_temp.rc(123, 21, (select id from a1), 'https://checkout.paystack.com/x', 'x')$$,
  'P0001', 'only a payment still being started takes its checkout', 'a payment no longer INITIATED is refused');
update public.payments set payment_status = 'INITIATED' where id = (select id from a1);
select throws_ok($$select pg_temp.rc(124, 21, gen_random_uuid(), 'https://checkout.paystack.com/x', 'x')$$,
  'P0001', 'not a Monvelo payment', 'an unknown payment is refused');
select throws_ok($$select pg_temp.rc(125, 21, (select id from a1), 'http://evil.test/x', 'x')$$,
  'P0001', 'the checkout must be a Paystack https URL and an access code', 'a non-https URL is refused');
select is(pg_temp.rc(126, 21, (select id from a1), 'https://checkout.paystack.com/ac_A', 'ac_A') ->> 'recorded', 'true',
  'the starter stores A1''s checkout through the gateway');
select lives_ok($$select pg_temp.rc(126, 21, (select id from a1), 'https://checkout.paystack.com/ac_A', 'ac_A')$$,
  'the same key and checkout again is a replay');
select throws_ok($$select pg_temp.rc(126, 21, (select id from a1), 'https://checkout.paystack.com/ac_B', 'ac_B')$$,
  'TF002', null, 'the same key with another checkout is refused');
select throws_ok($$select pg_temp.rc(127, 21, (select id from a1), 'https://checkout.paystack.com/ac_B', 'ac_B')$$,
  'P0001', 'this payment already has its checkout', 'a second checkout for the payment is refused');
select is((select row(monvelo_authorization_url, monvelo_access_code)::text from public.payments where id = pg_temp.pid('A1')),
  '(https://checkout.paystack.com/ac_A,ac_A)', 'the first checkout is kept');
select pg_temp.act_as(pg_temp.u(21), null);
select is(public.start_monvelo_funding(pg_temp.k(114), pg_temp.f('A'), pg_temp.ag(21)),
  (pg_temp.r('A1') - 'replayed')
    || '{"replayed": true, "authorization_url": "https://checkout.paystack.com/ac_A", "access_code": "ac_A"}'::jsonb,
  'the replay now hands back the stored checkout');
select throws_ok($$select monvelo_access_code from public.payments$$, '42501', null, 'which the member cannot select');
select throws_ok($$select monvelo_authorization_url from public.payments$$, '42501', null, 'nor the URL');
reset role;
select ok((select a.tenant_id is null and a.after::text !~ 'ac_A' and a.actor_id = pg_temp.u(21) from public.audit_logs a
            where a.operation = 'record_monvelo_checkout' and a.entity_id = pg_temp.pid('A1')::text)
      and (select count(*) from public.audit_logs where operation = 'record_monvelo_checkout'
             and entity_id = pg_temp.pid('A1')::text) = 1,
  'one audit row, tenant null, by the starter, holding neither the URL nor the code');
select ok((select bool_and(response::text !~ 'ac_A') from public.idempotency_logs where operation = 'record_monvelo_checkout'),
  'the stored idempotency reply holds no access code');

-- ── settle: the happy path ──────────────────────────────────────────────
select is(pg_temp.settle('SA', 'charge.success', 'A1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'funded', 'P''s own transfer funds A');
select is((select row(status, funder_agent_id = pg_temp.ag(21), paystack_reference = pg_temp.r('A1') ->> 'reference',
                      funded_at = now())::text
             from public.monvelo_financings where id = pg_temp.f('A')),
  '(FUNDED,t,t,t)', 'A is FUNDED by P with the Paystack reference and funded_at');
select is((select outcome from public.monvelo_financing_claims where financing_id = pg_temp.f('A')), 'FUNDED',
  'the claim''s outcome is FUNDED');
select is((select count(*)::int from public.monvelo_rebate_payables where financing_id = pg_temp.f('A')), 1, 'one payable');
select is((select row(amount, agent_id = pg_temp.ag(21), status, tenant_id = pg_temp.t1())::text
             from public.monvelo_rebate_payables where financing_id = pg_temp.f('A')),
  '(4800.00,t,DUE,t)', 'the payable: 10 % of 48000, to P, DUE');
select ok((select p.due_at = f.funded_at + interval '24 hours'
             from public.monvelo_rebate_payables p join public.monvelo_financings f on f.id = p.financing_id
            where p.financing_id = pg_temp.f('A')), 'due 24 hours after funding');
select is((select string_agg(l.brand_key || ':' || l.amount, ',')
             from public.monvelo_rebate_payable_lines l join public.monvelo_rebate_payables p on p.id = l.payable_id
            where p.financing_id = pg_temp.f('A')), 'purerigin:4800.00', 'the per-brand split');
select is((select remaining from public.monvelo_pledges where id = pg_temp.pl(21)), 102000.00::numeric(15,2),
  'P''s pledge: 150000 -> 102000');
select is((select row(terms_locked_at is not null, terms_id is not null, rebate_bps, interest_free_days, late_charge_bps)::text
             from public.monvelo_financing_lines where financing_id = pg_temp.f('A')),
  '(t,t,1000,30,1000)', 'the line locks its terms');
select is((select status from public.orders where id = pg_temp.o('A')), 'PAID', 'the trade order is PAID');
select is((select row(payment_status, gateway_response_payload is not null)::text from public.payments where id = pg_temp.pid('A1')),
  '(SUCCESS,t)', 'the payment is SUCCESS with the verified payload');
select ok((select source = 'WEBHOOK' and teafair_agent_id = pg_temp.u(4) from public.audit_logs
            where operation = 'settle_monvelo_funding' and entity_type = 'monvelo_financings'
              and entity_id = pg_temp.f('A')::text), 'audited as WEBHOOK on the raiser');
select ok((select bool_and(after::text !~ ('80000000-0000-0000-0000-00000000002|' || pg_temp.pl(21)::text)) from public.audit_logs
            where operation in ('settle_monvelo_funding', 'start_monvelo_funding')),
  'no funding audit row names the agent or its pledge');

-- twice: the webhook then the sweep
select is(pg_temp.settle('SA2', 'sweep', 'A1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'unchanged', 'the sweep after the webhook is unchanged');
select is(pg_temp.settle('SA3', 'charge.success', 'A1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')), pg_temp.r('SA'),
  'the same webhook again replays its first answer');
select is((select count(*)::int from public.monvelo_rebate_payables where financing_id = pg_temp.f('A')), 1, 'still one payable');
select is((select remaining from public.monvelo_pledges where id = pg_temp.pl(21)), 102000.00::numeric(15,2),
  'the pledge is debited once');

-- the stock sweep leaves a PAID trade order alone
set local session_replication_role = replica;
update public.stock_reservations set expires_at = now() - interval '1 second' where order_id = pg_temp.o('A');
set local session_replication_role = origin;
select is(public.stock_reservation_sweep(), 0, 'the stock sweep does not cancel the funded order');
select is((select status from public.orders where id = pg_temp.o('A')), 'PAID', 'it stays PAID');

-- ── -1, a lapse, a re-claim, -2; the first payment lands late ──────────
select pg_temp.raise('C', 200);
select pg_temp.claim(204, 21, 'C');
select pg_temp.start('C1', 205, 21, 'C');
select pg_temp.lapse('C');
select pg_temp.claim(206, 22, 'C');
select lives_ok($$select pg_temp.start('C2', 207, 22, 'C')$$, 'N starts after re-claiming C');
select is(right(pg_temp.r('C1') ->> 'reference', 2) || right(pg_temp.r('C2') ->> 'reference', 2), '-1-2',
  'references -1 then -2 after a lapse and a re-claim');
select is(pg_temp.settle('SC1', 'charge.success', 'C1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'P''s late payment, with N''s claim open, is a late payment');
select is((select count(*)::int from public.monvelo_flags
            where kind = 'LATE_PAYMENT' and financing_id = pg_temp.f('C') and agent_id = pg_temp.ag(21) and status = 'OPEN'),
  1, 'with a LATE_PAYMENT flag on P');
select is((select status || ':' || claimed_by_agent_id::text from public.monvelo_financings where id = pg_temp.f('C')),
  'CLAIMED:' || pg_temp.ag(22)::text, 'C stays CLAIMED by N');
select is((select payment_status::text from public.payments where id = pg_temp.pid('C1')), 'SUCCESS',
  'P''s payment is SUCCESS (staff refund it)');
select is(pg_temp.settle('SC2', 'charge.success', 'C2', 'success', 4800000, pg_temp.v('Okafor Chioma', 'XXXXXX0022')) ->> 'outcome',
  'funded', 'N''s payment funds C');
select is((select remaining from public.monvelo_pledges where id = pg_temp.pl(22)), 102000.00::numeric(15,2), 'N''s pledge -> 102000');
select is((select remaining from public.monvelo_pledges where id = pg_temp.pl(21)), 102000.00::numeric(15,2), 'P''s is untouched');

-- ── mismatches leave the financing CLAIMED ──────────────────────────────
select pg_temp.raise('D', 300, 2);
select pg_temp.claim(302, 22, 'D');
select pg_temp.start('D1', 303, 22, 'D');
select is(pg_temp.settle('SD', 'charge.success', 'D1', 'success', 4799900, pg_temp.v('CHIOMA OKAFOR', 'XXXXXX0022')) ->> 'outcome',
  'mismatch', 'N47,999 is a mismatch');
select is((select count(*)::int from public.monvelo_flags where kind = 'AMOUNT_MISMATCH' and financing_id = pg_temp.f('D')), 1,
  'an AMOUNT_MISMATCH flag');
select is((select status from public.monvelo_financings where id = pg_temp.f('D')), 'CLAIMED', 'D is still CLAIMED');
select is((select payment_status::text from public.payments where id = pg_temp.pid('D1')), 'SUCCESS', 'the payment is SUCCESS');
select is((select count(*)::int from public.monvelo_rebate_payables where financing_id = pg_temp.f('D')), 0, 'no payable');

select pg_temp.raise('E', 310, 2);
select pg_temp.claim(312, 22, 'E');
select pg_temp.start('E1', 313, 22, 'E');
select is(pg_temp.settle('SE', 'charge.success', 'E1', 'success', 4800000, pg_temp.v('CHIOMA OKAFOR', 'XXXXXX9999')) ->> 'outcome',
  'payer_mismatch', 'another account''s last four digits: payer_mismatch');
select is((select count(*)::int from public.monvelo_flags where kind = 'PAYER_MISMATCH' and financing_id = pg_temp.f('E')), 1,
  'a PAYER_MISMATCH flag');
select is((select status from public.monvelo_financings where id = pg_temp.f('E')), 'CLAIMED', 'E is still CLAIMED');
select is((select payment_status::text from public.payments where id = pg_temp.pid('E1')), 'SUCCESS', 'the payment is SUCCESS');
select pg_temp.start('E2', 314, 22, 'E');
select is(pg_temp.settle('SE2', 'charge.success', 'E2', 'success', 4800000, pg_temp.v('CHIOMA OKAFOR', 'XXXXXX0022', 'card')) ->> 'outcome',
  'payer_mismatch', 'a card charge: payer_mismatch');
select is((select status || ':' || (select remaining from public.monvelo_pledges where id = pg_temp.pl(22))
             from public.monvelo_financings where id = pg_temp.f('E')), 'CLAIMED:102000.00',
  'E still CLAIMED, N''s pledge untouched');

-- ── not final, failed ───────────────────────────────────────────────────
select pg_temp.start('E3', 315, 22, 'E');
select is(pg_temp.settle('SE3', 'charge.success', 'E3', 'failed', 4800000, '{}'::jsonb) ->> 'outcome',
  'not_final', 'a young failed charge is not final');
update public.payments set created_at = now() - interval '3 hours' where id = pg_temp.pid('E3');
select is(pg_temp.settle('SE3b', 'sweep', 'E3', 'abandoned', 4800000, '{}'::jsonb) ->> 'outcome',
  'failed', 'abandoned after 2 h is failed');
select is((select payment_status::text from public.payments where id = pg_temp.pid('E3')), 'FAILED', 'the payment is FAILED');
select is((select status from public.monvelo_financings where id = pg_temp.f('E')), 'CLAIMED', 'and the financing untouched');
select is(pg_temp.settle('SX', 'charge.success', 'MV-ZZZZZZZZ-1', 'success', 4800000, '{}'::jsonb) ->> 'outcome',
  'unknown_reference', 'an unknown reference');

-- ── the late route: OFFERED, no open claim ──────────────────────────────
select pg_temp.raise('L', 400);
select pg_temp.claim(402, 21, 'L');
select pg_temp.start('L1', 403, 21, 'L');
select pg_temp.lapse('L');
select is((select status from public.monvelo_financings where id = pg_temp.f('L')), 'OFFERED', 'fixture: L lapsed to OFFERED');
select is(pg_temp.settle('SL', 'sweep', 'L1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'funded', 'a payment landing after its claim lapsed still funds an unclaimed request');
select is((select row(status, funder_agent_id = pg_temp.ag(21), pledge_id = pg_temp.pl(21))::text
             from public.monvelo_financings where id = pg_temp.f('L')), '(FUNDED,t,t)', 'FUNDED by P against P''s pledge');
select is((select outcome from public.monvelo_financing_claims where financing_id = pg_temp.f('L')), 'LAPSED',
  'the lapsed claim keeps LAPSED');
select is((select remaining from public.monvelo_pledges where id = pg_temp.pl(21)), 54000.00::numeric(15,2), 'P''s pledge -> 54000');
select ok((select source = 'CRON' from public.audit_logs
            where operation = 'settle_monvelo_funding' and entity_type = 'monvelo_financings'
              and entity_id = pg_temp.f('L')::text), 'the sweep audits as CRON');

-- after the supply day
select pg_temp.raise('M', 410);
select pg_temp.claim(412, 21, 'M');
select pg_temp.start('M1', 413, 21, 'M');
select pg_temp.lapse('M');
set local session_replication_role = replica;
update public.monvelo_financings set supply_date = public.monvelo_today() - 1 where id = pg_temp.f('M');
set local session_replication_role = origin;
select is(pg_temp.settle('SM', 'charge.success', 'M1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'after the supply day: late_payment');
select is((select count(*)::int from public.monvelo_flags where kind = 'LATE_PAYMENT' and financing_id = pg_temp.f('M')), 1, 'flagged');
select is((select status from public.monvelo_financings where id = pg_temp.f('M')), 'OFFERED', 'M is untouched');

-- R10: the late route re-runs the claim checks (all but the claim itself)
create function pg_temp.reason(p_fin text) returns text language sql as
  $$ select details ->> 'reason' from public.monvelo_flags where financing_id = pg_temp.f(p_fin) $$;
select pg_temp.raise('S', 420);
select pg_temp.claim(422, 21, 'S');
select pg_temp.start('S1', 423, 21, 'S');
select pg_temp.lapse('S');
update public.monvelo_agents set status = 'SUSPENDED' where id = pg_temp.ag(21);
select is(pg_temp.settle('SS', 'charge.success', 'S1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'a suspended agent''s late payment is a late payment');
select is(pg_temp.reason('S'), 'the agent is not active', 'flagged with the claim check''s reason');
select is((select status from public.monvelo_financings where id = pg_temp.f('S')), 'OFFERED', 'S stays OFFERED');
update public.monvelo_agents set status = 'ACTIVE' where id = pg_temp.ag(21);

select pg_temp.raise('R', 430);
select pg_temp.claim(432, 21, 'R');
select pg_temp.start('R1', 433, 21, 'R');
select pg_temp.lapse('R');
update public.monvelo_agent_members set status = 'REVOKED' where agent_id = pg_temp.ag(21) and profile_id = pg_temp.u(21);
select is(pg_temp.settle('SR', 'charge.success', 'R1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'a payment started by a member since revoked is a late payment');
select is(pg_temp.reason('R'), 'not an active member of this agent', 'flagged: not an active member');
update public.monvelo_agent_members set status = 'ACTIVE' where agent_id = pg_temp.ag(21) and profile_id = pg_temp.u(21);

-- P has funded A and L today (96000); a 100000 daily cap leaves no room for 48000 more
select pg_temp.raise('Q', 440);
update public.monvelo_agents set daily_cap = 200000 where id = pg_temp.ag(21);
select pg_temp.claim(442, 21, 'Q');
select pg_temp.start('Q1', 443, 21, 'Q');
select pg_temp.lapse('Q');
update public.monvelo_agents set per_financing_cap = 100000, daily_cap = 100000 where id = pg_temp.ag(21);
select is(pg_temp.settle('SQ', 'charge.success', 'Q1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'a late payment past the daily cap is a late payment');
select is(pg_temp.reason('Q'), 'this request would pass your daily cap', 'flagged: the daily cap');
update public.monvelo_agents set per_financing_cap = 200000, daily_cap = 500000 where id = pg_temp.ag(21);
select is((select remaining from public.monvelo_pledges where id = pg_temp.pl(21)), 54000.00::numeric(15,2),
  'none of them touched P''s pledge');

-- ── the refusals that gate money (R8, R17, review round 1) ──────────────
-- Each refusal leaves the financing, P's pledge and the trade order as they were.
-- P gets room for the open claims this section leaves behind.
update public.monvelo_pledges set amount = amount + 1000000, remaining = remaining + 1000000 where id = pg_temp.pl(21);
update public.monvelo_agents set daily_cap = 2000000 where id = pg_temp.ag(21);
create temp table st (n text primary key, s text);
create function pg_temp.state(p_fin text) returns text language sql as $$
  select f.status || ':' || o.status || ':' || (select remaining from public.monvelo_pledges where id = pg_temp.pl(21))
    from public.monvelo_financings f join public.orders o on o.id = f.order_id where f.id = pg_temp.f(p_fin) $$;
create function pg_temp.keep(p_fin text) returns void language sql as
  $$ insert into st values (p_fin, pg_temp.state(p_fin)) $$;
-- P claims and starts the funding of a fresh S1 request p_fin
create function pg_temp.ready(p_fin text, p_key integer) returns void language plpgsql as $$
begin
  perform pg_temp.raise(p_fin, p_key);
  perform pg_temp.claim(p_key + 2, 21, p_fin);
  perform pg_temp.start(p_fin || '1', p_key + 3, 21, p_fin);
end; $$;
create function pg_temp.flags(p_fin text) returns integer language sql as
  $$ select count(*)::int from public.monvelo_flags where financing_id = pg_temp.f(p_fin) $$;

-- the trade order is no longer PENDING
select pg_temp.ready('K1', 500);
update public.orders set status = 'CANCELLED' where id = pg_temp.o('K1');
select pg_temp.keep('K1');
select is(pg_temp.settle('SK1', 'charge.success', 'K11', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'ORDER_NOT_PENDING: late_payment');
select is(pg_temp.flags('K1') || ':' || pg_temp.reason('K1'), '1:ORDER_NOT_PENDING', 'one flag, ORDER_NOT_PENDING');
select is(pg_temp.state('K1'), (select s from st where n = 'K1'), 'financing, pledge and order unchanged');

-- A8 §6.2: a live claim locks the terms, so a withdrawal after it no longer
-- stops the funding (074). The late route (the claim lapsed) quotes at
-- funding: the terms were withdrawn after the claim lapsed
select pg_temp.ready('K2', 510);
select pg_temp.lapse('K2');
set local session_replication_role = replica;
update public.monvelo_brand_terms set status = 'WITHDRAWN' where tenant_id = pg_temp.t1() and brand = 'Purerigin';
set local session_replication_role = origin;
select pg_temp.keep('K2');
select is(pg_temp.settle('SK2', 'charge.success', 'K21', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'NO_TERMS: late_payment');
select is(pg_temp.flags('K2') || ':' || pg_temp.reason('K2'), '1:NO_TERMS', 'one flag, NO_TERMS');
select is(pg_temp.state('K2'), (select s from st where n = 'K2'), 'financing, pledge and order unchanged');
select is((select count(*)::int from public.monvelo_financing_lines where financing_id = pg_temp.f('K2') and terms_locked_at is not null),
  0, 'and no line locked terms');
set local session_replication_role = replica;
update public.monvelo_brand_terms set status = 'APPROVED' where tenant_id = pg_temp.t1() and brand = 'Purerigin';
set local session_replication_role = origin;

-- the currency is not the tenant's
select pg_temp.ready('K3', 520);
select pg_temp.keep('K3');
select is(public.settle_monvelo_funding('charge.success', pg_temp.r('K31') ->> 'reference', 'success', 4800000, 'USD',
            pg_temp.v('BISI ADE', 'XXXXXX0011'), 'T-K3') ->> 'outcome', 'mismatch', 'USD: mismatch');
select is((select count(*)::int || ':' || min(kind) from public.monvelo_flags where financing_id = pg_temp.f('K3')),
  '1:AMOUNT_MISMATCH', 'one AMOUNT_MISMATCH flag');
select is(pg_temp.state('K3'), (select s from st where n = 'K3'), 'financing, pledge and order unchanged');

-- R17: the CLAIMED route re-checks the agent and the member who started the payment
select pg_temp.ready('K4', 530);
update public.monvelo_agents set status = 'SUSPENDED' where id = pg_temp.ag(21);
select pg_temp.keep('K4');
select is(pg_temp.settle('SK4', 'charge.success', 'K41', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'a suspended agent''s payment on its own claim is a late payment');
select is(pg_temp.flags('K4') || ':' || pg_temp.reason('K4'), '1:the agent is not active', 'one flag: the agent is not active');
select is(pg_temp.state('K4'), (select s from st where n = 'K4'), 'financing, pledge and order unchanged');
update public.monvelo_agents set status = 'ACTIVE' where id = pg_temp.ag(21);

select pg_temp.ready('K5', 540);
update public.monvelo_agent_members set status = 'REVOKED' where agent_id = pg_temp.ag(21) and profile_id = pg_temp.u(21);
select pg_temp.keep('K5');
select is(pg_temp.settle('SK5', 'charge.success', 'K51', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'a payment whose starting member was revoked is a late payment, on the claim too');
select is(pg_temp.flags('K5') || ':' || pg_temp.reason('K5'), '1:not an active member of this agent',
  'one flag: not an active member');
select is(pg_temp.state('K5'), (select s from st where n = 'K5'), 'financing, pledge and order unchanged');
update public.monvelo_agent_members set status = 'ACTIVE' where agent_id = pg_temp.ag(21) and profile_id = pg_temp.u(21);

-- R16: an unfunded Monvelo payment does not hold the stock
select pg_temp.ready('K6', 550);
select is(pg_temp.settle('SK6', 'charge.success', 'K61', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX9999')) ->> 'outcome',
  'payer_mismatch', 'fixture: a payer mismatch leaves a SUCCESS payment on a PENDING order');
set local session_replication_role = replica;
update public.stock_reservations set expires_at = now() - interval '1 second' where order_id = pg_temp.o('K6');
set local session_replication_role = origin;
select is(public.stock_reservation_sweep(), 1, 'the stock sweep still cancels the expired trade order');
select is((select status from public.orders where id = pg_temp.o('K6')), 'CANCELLED', 'the order is CANCELLED');
select is((select count(*)::int from public.stock_reservations where order_id = pg_temp.o('K6') and status = 'RESERVED'), 0,
  'and its stock released');

-- the pledge no longer covers the principal on the CLAIMED route
select pg_temp.ready('K7', 560);
update public.monvelo_pledges set remaining = 47999 where id = pg_temp.pl(21);
select pg_temp.keep('K7');
select is(pg_temp.settle('SK7', 'charge.success', 'K71', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'PLEDGE_EXHAUSTED: late_payment');
select is(pg_temp.flags('K7') || ':' || pg_temp.reason('K7'), '1:PLEDGE_EXHAUSTED', 'one flag, PLEDGE_EXHAUSTED');
select is(pg_temp.state('K7'), (select s from st where n = 'K7'), 'financing, pledge and order unchanged');
update public.monvelo_pledges set remaining = 1054000 where id = pg_temp.pl(21);

-- the late route: remaining covers the principal only before P's other open claims
select pg_temp.ready('G', 570);
select pg_temp.lapse('G');
select pg_temp.raise('H', 580);
select pg_temp.claim(582, 21, 'H');
update public.monvelo_pledges
   set remaining = (select sum(principal) from public.monvelo_financings where pledge_id = pg_temp.pl(21) and status = 'CLAIMED') + 47999
 where id = pg_temp.pl(21);
select ok((select remaining >= 48000 from public.monvelo_pledges where id = pg_temp.pl(21)),
  'fixture: remaining alone covers the principal');
select pg_temp.keep('G');
select is(pg_temp.settle('SG', 'charge.success', 'G1', 'success', 4800000, pg_temp.v('BISI ADE', 'XXXXXX0011')) ->> 'outcome',
  'late_payment', 'net of P''s other open claims it does not: late_payment');
select is(pg_temp.flags('G') || ':' || pg_temp.reason('G'), '1:pledge enough funds for this area and day first',
  'one flag: the pledge check');
select is(pg_temp.state('G'), (select s from st where n = 'G'), 'financing, pledge and order unchanged');
update public.monvelo_pledges set remaining = 1054000 where id = pg_temp.pl(21);
update public.monvelo_agents set daily_cap = 500000 where id = pg_temp.ag(21);

-- ── settle_paystack_payment leaves MV- payments to Monvelo (R3) ─────────
select pg_temp.start('E4', 316, 22, 'E');
select is((public.settle_paystack_payment('charge.success', pg_temp.r('E4') ->> 'reference', 'success', 4800000, 'NGN',
             '{}'::jsonb, 'T', null, null)) ->> 'outcome', 'monvelo_reference',
  'the web settlement refuses an MV- payment');
select is((select payment_status::text from public.payments where id = pg_temp.pid('E4')), 'INITIATED', 'and writes nothing to it');
select is((select count(*)::int from public.audit_logs where operation = 'PAYSTACK_MONVELO_REFERENCE'
            and entity_id = pg_temp.pid('E4')::text), 1, 'but audits it');

-- ── readers: tenants never see lenders (A6 §16.2.2) ─────────────────────
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_rebate_payables) + (select count(*)::int from public.monvelo_rebate_payable_lines)
          + (select count(*)::int from public.monvelo_flags), 0, 'the TM reads no payable, line or flag');
select throws_ok($$select gateway_response_payload from public.payments$$, '42501', null, 'nor the Verify payload');
select throws_ok($$select monvelo_financing_id from public.payments$$, '42501', null, 'nor payments.monvelo_financing_id');
select throws_ok($$select monvelo_agent_id from public.payments$$, '42501', null, 'nor payments.monvelo_agent_id');
-- R9: the financing row without its lender columns
select throws_ok($$select funder_agent_id from public.monvelo_financings$$, '42501', null, 'the TM cannot select funder_agent_id');
select is((select status from public.monvelo_financings where id = pg_temp.f('A')), 'FUNDED', 'but reads the status');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_rebate_payables) + (select count(*)::int from public.monvelo_flags), 0,
  'the raiser reads no payable or flag');
select throws_ok($$select monvelo_financing_id from public.payments$$, '42501', null, 'nor the Monvelo column');
select throws_ok($$select funder_agent_id from public.monvelo_financings$$, '42501', null, 'the raiser cannot select funder_agent_id');
select is((select status from public.monvelo_financings where id = pg_temp.f('A')), 'FUNDED', 'but reads the status');
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from public.monvelo_rebate_payables) + (select count(*)::int from public.monvelo_flags), 0,
  'the TENANT_ADMIN reads no payable or flag');
select throws_ok($$select gateway_response_payload from public.payments$$, '42501', null, 'nor the Verify payload');
select throws_ok($$select monvelo_financing_id from public.payments$$, '42501', null, 'nor the Monvelo column');
select throws_ok($$select funder_agent_id from public.monvelo_financings$$, '42501', null,
  'the TENANT_ADMIN cannot select funder_agent_id');
select is((select status from public.monvelo_financings where id = pg_temp.f('A')), 'FUNDED', 'but reads the status');
select ok((select bool_and(not has_column_privilege('authenticated', 'public.monvelo_financings', c, 'select'))
             from unnest(array['preferred_agent_id', 'claimed_by_agent_id', 'claimed_by', 'pledge_id', 'funder_agent_id',
                               'paystack_reference']) c),
  'no lender column of monvelo_financings is granted to the API');
-- R15: after claims, lapses, pledges and fundings, the tenant's ZSM reads no audit row naming a lender
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select ok((select count(*) > 0 from public.audit_logs where operation = 'request_monvelo_financing'),
  'fixture: the ZSM reads the tenant''s Monvelo audit rows');
select is((select count(*)::int from public.audit_logs a
            where coalesce(a.before::text, '') || coalesce(a.after::text, '')
                  ~ (pg_temp.ag(21)::text || '|' || pg_temp.ag(22)::text || '|' || pg_temp.pl(21)::text || '|' || pg_temp.pl(22)::text)),
  0, 'the ZSM reads no audit row naming an agent or a pledge');
select is((select count(*)::int from public.audit_logs where actor_id in (pg_temp.u(21), pg_temp.u(22))), 0,
  'nor any row whose actor is an agent''s member');
reset role;
select ok((select count(*) >= 3 from public.audit_logs
            where operation in ('claim_monvelo_financing', 'monvelo_sweep_offers') and tenant_id is null
              and coalesce(before::text, '') || coalesce(after::text, '') ~ pg_temp.ag(21)::text),
  'the claim and lapse rows exist, with no tenant');
select pg_temp.act_as(pg_temp.u(21), null);
select is((select count(*)::int from public.monvelo_rebate_payables), 2, 'P''s member reads P''s payables (A and L)');
select is((select count(*)::int from public.monvelo_rebate_payable_lines), 2, 'and their lines');
select is((select count(*)::int from public.monvelo_flags), 0, 'but no flags');
select pg_temp.act_as(pg_temp.u(28), null);
select is((select count(*)::int from public.monvelo_rebate_payables), 0, 'a stranger reads no payables');
select pg_temp.act_as(pg_temp.u(9), null);
select is((select count(*)::int from public.monvelo_flags), 16, 'the operator reads every flag');
select is((select count(*)::int from public.monvelo_rebate_payables), 3, 'and every payable');

-- ── review_monvelo_flag ─────────────────────────────────────────────────
reset role;
create temp table flag as select id from public.monvelo_flags where kind = 'AMOUNT_MISMATCH' and financing_id = pg_temp.f('D');
grant select on flag to authenticated;
select pg_temp.act_as(pg_temp.u(6), null);
select throws_ok($$select public.review_monvelo_flag(pg_temp.k(900), (select id from flag), 'refunded in Paystack')$$,
  '42501', null, 'MONVELO_FINANCE cannot review a flag');
select pg_temp.act_as(pg_temp.u(9), null);
select is(public.review_monvelo_flag(pg_temp.k(901), (select id from flag), 'refunded in Paystack') ->> 'status', 'REVIEWED',
  'the operator reviews it');
select throws_ok($$select public.review_monvelo_flag(pg_temp.k(902), (select id from flag), 'again')$$,
  'P0001', 'this flag was already reviewed', 'a second review is refused');
reset role;
select is((select row(status, reviewed_by = pg_temp.u(9), reviewed_at is not null, review_note)::text
             from public.monvelo_flags where id = (select id from flag)),
  '(REVIEWED,t,t,"refunded in Paystack")', 'reviewed_by, reviewed_at and the note are kept');

-- ── records are kept ────────────────────────────────────────────────────
select throws_ok($$delete from public.monvelo_rebate_payables$$, 'P0001', 'Monvelo records are never deleted', 'payables are never deleted');
select throws_ok($$delete from public.monvelo_flags$$, 'P0001', 'Monvelo records are never deleted', 'nor flags');
select throws_ok($$update public.monvelo_rebate_payables set amount = 1$$, 'P0001', null, 'a payable''s amount never changes');
select throws_ok($$update public.monvelo_flags set status = 'OPEN' where id = (select id from flag)$$, 'P0001', null,
  'a reviewed flag stays reviewed');

select * from finish();
rollback;
