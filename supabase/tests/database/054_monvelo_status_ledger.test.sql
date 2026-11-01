-- Addendum A6 §16.5, §16.6 (Monvelo Step 2, Task 9) — the order financing-status
-- read the app shows on order lists, and the insert-only tenant ledger table
-- (Steps 3 and 5 add its writers).
begin;
create extension if not exists pgtap with schema extensions;

select plan(31);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
-- T1 = TEAFAIR: 01 ZSM · 03 TM · 04 ASA · 07 TENANT_ADMIN · 18 CSM
--               10 RETAIL_SHOP_OWNER (owns S1) · 11 owner of S2 · 12 POS_AGENT
-- T2 = Unilever: 15 ZSM · 09 MONVELO_FINANCE (no tenant)
insert into public.tenants (id, name, code) values ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone, phone_confirmed_at)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '234800000' || lpad(n::text, 4, '0'), now()
  from unnest(array[1, 3, 4, 7, 9, 10, 11, 12, 15, 18]) n;
update public.profiles set platform_role = 'MONVELO_FINANCE' where id = '20000000-0000-0000-0000-000000000009';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000011', 'Ikeja B');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '40000000-0000-0000-0000-000000000001', 'Allen');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001', 'ZSM', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000003', 'TM', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000007', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000007', 'TENANT_ADMIN', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000018', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000018', 'CLIENT_SERVICE_MANAGER', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000010', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000010', 'RETAIL_SHOP_OWNER', null, null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000012', 'POS_AGENT', null, '40000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000015', 'ZSM', null, null, null, null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004', 'ASA', null, '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);

insert into public.retail_shops (id, shop_name, contact_phone, owner_id, density_category, location, address_text) values
  ('71000000-0000-0000-0000-000000000001', 'Shop 1', '+234803111001', '20000000-0000-0000-0000-000000000010', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 1'),
  ('71000000-0000-0000-0000-000000000002', 'Shop 2', '+234803111002', '20000000-0000-0000-0000-000000000011', 'SUBURBAN',
   extensions.st_setsrid(extensions.st_makepoint(3.35, 6.60), 4326), 'Street 2');
insert into public.monvelo_consent_challenges (id, tenant_id, shop_id, area_id, code_hash, expires_at, issued_by) values
  ('c0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '71000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', 'x', now() + interval '1 hour', '20000000-0000-0000-0000-000000000004');
insert into public.monvelo_shop_enrolments (tenant_id, shop_id, area_id, recruited_by, consent_at, consent_version, consent_challenge_id) values
  ('7eaf0000-0000-4000-8000-000000000001', '71000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', now(), 'MV-SHARE-2026-10', 'c0000000-0000-0000-0000-000000000001');

-- orders: 1 cash (S1) · 2 financed, OFFERED (S1) · 3 financing cancelled (S1) · 4 another owner's (S2) · 5 tenant B
insert into public.orders (id, tenant_id, channel, retail_shop_id, agent_id, teafair_agent_id, total_amount, status, territory_id) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES', '71000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000004', 12000, 'PENDING', '40000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES', '71000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000004', 48000, 'PENDING', '40000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES', '71000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000004', 12000, 'PENDING', '40000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', 'FIELD_SALES', '71000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000004', 12000, 'PENDING', '40000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', 'FIELD_SALES', '71000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000015', '20000000-0000-0000-0000-000000000015', 12000, 'PENDING', '40000000-0000-0000-0000-000000000011');
insert into public.monvelo_financings (id, tenant_id, reference, shop_id, order_id, area_id, territory_id, raised_by,
                                       principal, supply_date, status, approval_required) values
  ('f0000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'MV-AAAAAAAB', '71000000-0000-0000-0000-000000000001',
   '90000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 48000, public.monvelo_today(), 'REQUESTED', false),
  ('f0000000-0000-0000-0000-000000000003', '7eaf0000-0000-4000-8000-000000000001', 'MV-AAAAAAAC', '71000000-0000-0000-0000-000000000001',
   '90000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 12000, public.monvelo_today(), 'REQUESTED', false);
update public.monvelo_financings set status = 'OFFERED', offered_at = now() where id = 'f0000000-0000-0000-0000-000000000002';
update public.monvelo_financings set status = 'CANCELLED', cancelled_at = now(), cancelled_by = '20000000-0000-0000-0000-000000000004',
       cancel_reason = 'fixture' where id = 'f0000000-0000-0000-0000-000000000003';

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;
create function pg_temp.u(n integer) returns uuid language sql as
  $$ select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.o(n integer) returns uuid language sql as
  $$ select ('90000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function pg_temp.t1() returns uuid language sql as $$ select '7eaf0000-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.t2() returns uuid language sql as $$ select '10000000-0000-0000-0000-000000000002'::uuid $$;
grant execute on function pg_temp.u(integer), pg_temp.o(integer), pg_temp.t1(), pg_temp.t2() to authenticated;
-- the status of orders 1..5, as one string in the order asked
create function pg_temp.st() returns text language sql as $$
  select string_agg(right(s.order_id::text, 1) || ':' || s.financing_state || ':' || coalesce(s.reference, '-'), ',')
    from public.monvelo_order_financing_status(array[pg_temp.o(1), pg_temp.o(2), pg_temp.o(3), pg_temp.o(4), pg_temp.o(5)]) s $$;
grant execute on function pg_temp.st() to authenticated;

-- ── the status read ─────────────────────────────────────────────────────
select ok(has_function_privilege('authenticated', 'public.monvelo_order_financing_status(uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.monvelo_order_financing_status(uuid[])', 'execute'),
  'the status read is for signed-in members');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is(pg_temp.st(), '1:NONE:-,2:OFFERED:MV-AAAAAAAB,3:NONE:-,4:NONE:-',
  'the ZSM: cash NONE, financed OFFERED, a cancelled financing NONE; tenant B''s order omitted');
select is((select principal from public.monvelo_order_financing_status(array[pg_temp.o(2)])), 48000.00::numeric,
  'with the principal of the live financing');
select throws_ok($$select * from public.monvelo_order_financing_status(
    (select array_agg(gen_random_uuid()) from generate_series(1, 201)))$$,
  'P0001', 'ask for at most 200 orders at a time', '201 ids are refused');
select is((select count(*)::int from public.monvelo_order_financing_status(
    (select array_agg(gen_random_uuid()) from generate_series(1, 200)))), 0, '200 unknown ids return nothing');
select pg_temp.act_as(pg_temp.u(10), pg_temp.t1());
select is(pg_temp.st(), '1:NONE:-,2:OFFERED:MV-AAAAAAAB,3:NONE:-', 'the shop owner gets only the orders of shops they own');
select pg_temp.act_as(pg_temp.u(12), pg_temp.t1());
select is(pg_temp.st(), null, 'a POS_AGENT gets none');
select pg_temp.act_as(pg_temp.u(15), pg_temp.t2());
select is(pg_temp.st(), '5:NONE:-', 'tenant B''s ZSM gets only tenant B''s order');
select pg_temp.act_as(pg_temp.u(11), pg_temp.t1());
select throws_ok($$select pg_temp.st()$$, '42501', null, 'a non-member is refused');
reset role;

-- ── the ledger, as postgres ─────────────────────────────────────────────
select has_table('public', 'monvelo_tenant_ledger_entries', 'the ledger table exists');
select lives_ok($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                  values (pg_temp.t1(), public.monvelo_today(), 'FUNDED_GROSS', 'f0000000-0000-0000-0000-000000000002', 48000)$$,
  'FUNDED_GROSS 48000');
select lives_ok($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                  values (pg_temp.t1(), public.monvelo_today(), 'REBATE', 'f0000000-0000-0000-0000-000000000002', -4800)$$,
  'REBATE -4800');
select throws_ok($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, amount)
                   values (pg_temp.t1(), public.monvelo_today(), 'REBATE', 4800)$$,
  '23514', null, 'a positive REBATE breaks the sign rule');
select throws_ok($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, amount)
                   values (pg_temp.t1(), public.monvelo_today(), 'FUNDED_GROSS', -1)$$,
  '23514', null, 'a negative FUNDED_GROSS breaks the sign rule');
select throws_ok($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, amount)
                   values (pg_temp.t1(), public.monvelo_today(), 'FEE', 0)$$,
  '23514', null, 'a zero FEE breaks the sign rule');
select throws_ok($$insert into public.monvelo_tenant_ledger_entries (tenant_id, business_date, entry_type, financing_id, amount)
                   values (pg_temp.t2(), public.monvelo_today(), 'FEE', 'f0000000-0000-0000-0000-000000000002', -1)$$,
  '23503', null, 'an entry cannot cite another tenant''s financing');
select throws_ok($$update public.monvelo_tenant_ledger_entries set amount = 1$$,
  'P0001', 'ledger entries are insert-only', 'entries cannot be updated');
select throws_ok($$delete from public.monvelo_tenant_ledger_entries$$,
  'P0001', 'ledger entries are insert-only', 'entries cannot be deleted');
select throws_ok($$truncate public.monvelo_tenant_ledger_entries$$,
  'P0001', 'ledger entries are insert-only', 'the ledger cannot be truncated');
select ok(not has_table_privilege('service_role', 'public.monvelo_tenant_ledger_entries', 'UPDATE')
      and not has_table_privilege('service_role', 'public.monvelo_tenant_ledger_entries', 'DELETE')
      and not has_table_privilege('authenticated', 'public.monvelo_tenant_ledger_entries', 'INSERT')
      and not has_table_privilege('anon', 'public.monvelo_tenant_ledger_entries', 'SELECT'),
  'no API role writes the ledger; anon reads nothing');
select is((select string_agg(p.proname, ',' order by p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.prosrc ~* 'insert\s+into\s+(public\.)?monvelo_tenant_ledger_entries'), 'confirm_monvelo_delivery',
  'only the delivery confirmation writes the ledger so far (Step 3 Task 3; Task 5 and Step 5 add the others)');

-- ── ledger readers ──────────────────────────────────────────────────────
select pg_temp.act_as(pg_temp.u(7), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 2, 'the TENANT_ADMIN reads the ledger');
select pg_temp.act_as(pg_temp.u(18), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 2, 'the CSM reads it');
select pg_temp.act_as(pg_temp.u(1), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 2, 'a ZSM reads it');
select pg_temp.act_as(pg_temp.u(9), null);
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 2, 'MONVELO_FINANCE reads it');
select pg_temp.act_as(pg_temp.u(3), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 0, 'a TM reads none');
select pg_temp.act_as(pg_temp.u(4), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 0, 'an ASA reads none');
select pg_temp.act_as(pg_temp.u(10), pg_temp.t1());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 0, 'a shop owner reads none');
select pg_temp.act_as(pg_temp.u(15), pg_temp.t2());
select is((select count(*)::int from public.monvelo_tenant_ledger_entries), 0, 'tenant B''s ZSM reads none');
reset role;
select has_index('public', 'monvelo_tenant_ledger_entries', 'idx_monvelo_tenant_ledger_entries_date', 'indexed by tenant and business date');
select has_index('public', 'monvelo_tenant_ledger_entries', 'idx_monvelo_tenant_ledger_entries_financing', 'indexed by financing');

select * from finish();
rollback;
