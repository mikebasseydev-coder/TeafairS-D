-- 20261123120000 — monvelo-agent-register authorises and replays before the
-- Paystack call: monvelo_agent_register_preflight, and the client-only request
-- hash of register_monvelo_agent and request_monvelo_settlement_change.
begin;
create extension if not exists pgtap with schema extensions;

select plan(32);

-- ── fixtures (as postgres) ──────────────────────────────────────────────
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Teafair Preflight Test', 'TFPRE'),
  ('10000000-0000-0000-0000-000000000002', 'Lagos FMCG Preflight Test', 'LFPRE');

-- 1 ZSM · 2 ZSA · 3 TM · 4 ASA · 5 MONVELO_OPERATOR (no tenant) · 6 second ASA
-- · 8 ASA of the opted-out tenant · 9 TM of the opted-out tenant
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348100000001', now()),
  ('20000000-0000-0000-0000-000000000002', '2348100000002', now()),
  ('20000000-0000-0000-0000-000000000003', '2348100000003', now()),
  ('20000000-0000-0000-0000-000000000004', '2348100000004', now()),
  ('20000000-0000-0000-0000-000000000005', '2348100000005', now()),
  ('20000000-0000-0000-0000-000000000006', '2348100000006', now()),
  ('20000000-0000-0000-0000-000000000008', '2348100000008', now()),
  ('20000000-0000-0000-0000-000000000009', '2348100000009', now());
update public.profiles set platform_role = 'MONVELO_OPERATOR' where id = '20000000-0000-0000-0000-000000000005';

insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ojodu'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');
insert into public.areas (id, tenant_id, territory_id, area_name) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'Ojodu Central'),
  ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '40000000-0000-0000-0000-000000000002', 'Allen');

insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000009',
   'TM', null, '40000000-0000-0000-0000-000000000002', null, 'ACTIVE', true);
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, area_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004',
   'ASA', '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'ASA', '40000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000008',
   'ASA', '40000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000009', 'ACTIVE', true);

-- the first tenant opted in; the second did not
insert into public.monvelo_tenant_settings (tenant_id, enabled) values
  ('10000000-0000-0000-0000-000000000001', true),
  ('10000000-0000-0000-0000-000000000002', false);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- the client's request (no holder name), as the gateway sends it to the preflight
create function pg_temp.req(p_name text default 'Preflight Ventures') returns jsonb language sql as $$
  select jsonb_build_object(
    'business_name', p_name, 'pos_network', 'MONIEPOINT', 'network_agent_id', 'MP-PRE-1',
    'contact_phone', '+2348031112222', 'latitude', 6.6285, 'longitude', 3.3612,
    'address_text', '7 Ojodu Road, Lagos', 'settlement_account_number', '0123456789',
    'settlement_bank_code', '058', 'network_kyc_reference', 'KYC-PRE-1');
$$;
grant execute on function pg_temp.req(text) to authenticated;

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- ── shape and grants ────────────────────────────────────────────────────
select has_function('public', 'monvelo_agent_register_preflight', array['uuid', 'text', 'jsonb'], 'the preflight exists');
select is(has_function_privilege('authenticated', 'public.monvelo_agent_register_preflight(uuid, text, jsonb)', 'execute'),
  true, 'authenticated may call the preflight');
select is(has_function_privilege('anon', 'public.monvelo_agent_register_preflight(uuid, text, jsonb)', 'execute'),
  false, 'anon may not call the preflight');
select is(has_function_privilege('authenticated', 'public.monvelo_recruitment_request(text, jsonb)', 'execute'),
  false, 'the request builder is internal');
select is((select provolatile from pg_proc where oid = 'public.monvelo_agent_register_preflight(uuid, text, jsonb)'::regprocedure),
  's', 'the preflight is STABLE (read-only)');

-- ── allowed callers, unknown key ────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is(public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000001', 'register_monvelo_agent', pg_temp.req()),
  '{"replay": false}'::jsonb, 'an ACTIVE ASA of an opted-in tenant passes; an unknown key is not a replay');
select is((select count(*)::int from public.idempotency_logs where key = 'aaaaaaaa-0000-4000-8000-000000000001'),
  0, 'the preflight writes no idempotency row');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select is(public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000002', 'register_monvelo_agent', pg_temp.req()),
  '{"replay": false}'::jsonb, 'an ACTIVE ZSA of an opted-in tenant passes');

-- ── refused callers ─────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000003',
  'register_monvelo_agent', pg_temp.req())$$, '42501', null, 'a TM is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000003',
  'register_monvelo_agent', pg_temp.req())$$, '42501', null, 'a ZSM is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000005', null);
select throws_ok($$select public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000003',
  'register_monvelo_agent', pg_temp.req())$$, '42501', null, 'a MONVELO_OPERATOR (no tenant role) is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000003',
  'register_monvelo_agent', pg_temp.req())$$, '42501', 'Monvelo is not enabled for this tenant',
  'an ASA of a tenant not opted in is refused');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000002');
select throws_ok($$select public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000003',
  'register_monvelo_agent', pg_temp.req())$$, '42501', null, 'a claimed tenant the caller does not belong to is refused');

-- ── bad arguments ───────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.monvelo_agent_register_preflight(null, 'register_monvelo_agent', pg_temp.req())$$,
  'P0001', 'p_idempotency_key is required', 'a null key is refused');
select throws_ok($$select public.monvelo_agent_register_preflight('aaaaaaaa-0000-4000-8000-000000000004',
  'approve_monvelo_agent', pg_temp.req())$$, 'P0001', 'unknown Monvelo recruitment operation', 'only the two recruitment operations');

-- ── a completed registration replays ────────────────────────────────────
do $$ begin perform set_config('test.reg', public.register_monvelo_agent(
  'bbbbbbbb-0000-4000-8000-000000000001', 'test-gw-secret',
  pg_temp.req() || '{"settlement_account_name": "PREFLIGHT VENTURES"}'::jsonb)::text, true); end $$;
select is(current_setting('test.reg')::jsonb ->> 'status', 'PENDING', 'the ASA registers the agent');

select is(public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000001', 'register_monvelo_agent', pg_temp.req()),
  jsonb_build_object('replay', true, 'response', current_setting('test.reg')::jsonb),
  'the same key and request replays the stored response');
select is(public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000001', 'register_monvelo_agent',
  pg_temp.req() || '{"settlement_account_name": "A NAME THE BANK NOW GIVES"}'::jsonb) ->> 'replay',
  'true', 'a holder name is not part of the request: it cannot break a replay');
select throws_ok($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000001',
  'register_monvelo_agent', pg_temp.req('Changed Ventures'))$$, 'TF002', null, 'a changed request is TF002');
select throws_ok(format($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000001',
  'request_monvelo_settlement_change', jsonb_build_object('agent_id', %L, 'account', '{}'::jsonb))$$,
  current_setting('test.reg')::jsonb ->> 'agent_id'),
  'TF002', null, 'the key reused for the other operation is TF002');
select throws_ok($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000003',
  'request_monvelo_settlement_change', jsonb_build_object('agent_id', gen_random_uuid(), 'account', '{}'::jsonb))$$,
  'P0001', 'unknown Monvelo agent', 'a settlement change for an unknown agent is refused before Paystack');

select pg_temp.act_as('20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000001',
  'register_monvelo_agent', pg_temp.req())$$, 'TF002', null, 'another ASA replaying the key is TF002, never the answer');
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000001',
  'register_monvelo_agent', pg_temp.req())$$, 'TF002', null, 'a ZSA replaying the ASA''s key is TF002');
select throws_ok(format($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000004',
  'request_monvelo_settlement_change', jsonb_build_object('agent_id', %L, 'account', '{}'::jsonb))$$,
  current_setting('test.reg')::jsonb ->> 'agent_id'), '42501',
  'only the street agent who recruited this agent can request an account change',
  'a ZSA who did not recruit the agent is refused a settlement change before Paystack');

-- ── the RPC itself hashes the client request only ───────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select is(public.register_monvelo_agent('bbbbbbbb-0000-4000-8000-000000000001', 'test-gw-secret',
  pg_temp.req() || '{"settlement_account_name": "A NAME THE BANK NOW GIVES"}'::jsonb),
  current_setting('test.reg')::jsonb, 'the RPC replays even if the bank''s name changed since');
select throws_ok($$select public.register_monvelo_agent('bbbbbbbb-0000-4000-8000-000000000001', 'test-gw-secret',
  pg_temp.req('Changed Ventures') || '{"settlement_account_name": "X"}'::jsonb)$$, 'TF002', null,
  'the RPC still refuses a changed client request');
reset role; -- counted as postgres: a PENDING agent is hidden from the ASA by RLS
select is((select count(*)::int from public.monvelo_agents where network_agent_id = 'MP-PRE-1'), 1, 'still one agent');

-- ── a pending key is not replayed ───────────────────────────────────────
insert into public.idempotency_logs (key, tenant_id, actor_id, operation, request_hash, status)
values ('bbbbbbbb-0000-4000-8000-000000000009', '10000000-0000-0000-0000-000000000001',
        '20000000-0000-0000-0000-000000000004', 'register_monvelo_agent',
        encode(extensions.digest(public.monvelo_recruitment_request('register_monvelo_agent', pg_temp.req())::text, 'sha256'), 'hex'),
        'IN_PROGRESS');
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000009',
  'register_monvelo_agent', pg_temp.req())$$, '40001', null, 'an IN_PROGRESS key asks for a retry');

-- ── settlement change: the same contract ────────────────────────────────
do $$ begin perform set_config('test.chg', public.request_monvelo_settlement_change(
  'bbbbbbbb-0000-4000-8000-000000000002', 'test-gw-secret', (current_setting('test.reg')::jsonb ->> 'agent_id')::uuid,
  '{"settlement_account_number": "9876543210", "settlement_bank_code": "044", "settlement_account_name": "PREFLIGHT VENTURES"}'::jsonb)::text, true); end $$;
select is(current_setting('test.chg')::jsonb ->> 'status', 'PENDING_APPROVAL', 'the recruiter requests an account change');
select is(public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000002', 'request_monvelo_settlement_change',
  jsonb_build_object('agent_id', current_setting('test.reg')::jsonb ->> 'agent_id',
                     'account', '{"settlement_account_number": "9876543210", "settlement_bank_code": "044"}'::jsonb)),
  jsonb_build_object('replay', true, 'response', current_setting('test.chg')::jsonb),
  'a settlement change replays from the preflight');
select throws_ok(format($$select public.monvelo_agent_register_preflight('bbbbbbbb-0000-4000-8000-000000000002',
  'request_monvelo_settlement_change', jsonb_build_object('agent_id', %L,
  'account', '{"settlement_account_number": "1111111111", "settlement_bank_code": "044"}'::jsonb))$$,
  current_setting('test.reg')::jsonb ->> 'agent_id'), 'TF002', null, 'a changed account on the same key is TF002');
select is(public.request_monvelo_settlement_change('bbbbbbbb-0000-4000-8000-000000000002', 'test-gw-secret',
  (current_setting('test.reg')::jsonb ->> 'agent_id')::uuid,
  '{"settlement_account_number": "9876543210", "settlement_bank_code": "044", "settlement_account_name": "RENAMED"}'::jsonb),
  current_setting('test.chg')::jsonb, 'the settlement RPC replays even if the bank''s name changed');

select * from finish();
rollback;
