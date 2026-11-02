-- Domain separation, Task 5 (A6 section 15.4): the Monvelo agent tables and
-- the settlement-change RPCs, and the boundary between the web and Monvelo
-- domains.
begin;
create extension if not exists pgtap with schema extensions;

select plan(22);

-- fixtures (as postgres): one tenant with Monvelo on, a ZSM and a ZSA
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');
insert into auth.users (id, phone, phone_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001', now()),
  ('20000000-0000-0000-0000-000000000002', '2348000000002', now());
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos', 'LA');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSA', '30000000-0000-0000-0000-000000000001', null, '50000000-0000-0000-0000-000000000001', 'ACTIVE', true);
insert into public.monvelo_tenant_settings (tenant_id, enabled) values
  ('10000000-0000-0000-0000-000000000001', true);

delete from vault.secrets where name = 'gateway_secret';
do $$ begin perform vault.create_secret('test-gw-secret', 'gateway_secret'); end $$;

-- shape
select has_table('public', 'monvelo_agents', 'monvelo_agents exists');
select has_table('public', 'monvelo_agent_members', 'monvelo_agent_members exists');
select hasnt_table('public', 'monvelo_fintech_agents', 'monvelo_fintech_agents is renamed');
select hasnt_table('public', 'monvelo_fintech_members', 'monvelo_fintech_members is renamed');
select policies_are('public', 'monvelo_agents', array['monvelo_agents_select']);
select policies_are('public', 'monvelo_agent_members', array['monvelo_agent_members_select']);
select fk_ok('public', 'retail_shops', 'preferred_agent_id', 'public', 'monvelo_agents', 'id');
select fk_ok('public', 'monvelo_agent_nominations', 'recruited_agent_id', 'public', 'monvelo_agents', 'id');
select is((select count(*)::int from pg_constraint
            where connamespace = 'public'::regnamespace and conname ~ 'monvelo_fintech'), 0,
  'no constraint keeps monvelo_fintech in its name');

-- grants
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'settlement_account_number', 'SELECT'),
  false, 'authenticated cannot read the settlement account number');
select is(has_column_privilege('authenticated', 'public.monvelo_agents', 'business_name', 'SELECT'),
  true, 'authenticated can read business_name');

-- renamed RPCs
select hasnt_function('public', 'request_settlement_change', 'request_settlement_change is gone');
select hasnt_function('public', 'approve_settlement_change', 'approve_settlement_change is gone');
select is((select array_agg(g.grantee::regrole::text order by g.grantee::regrole::text)
             from (select (aclexplode(proacl)).grantee from pg_proc
                    where oid = 'public.approve_monvelo_settlement_change(uuid,uuid)'::regprocedure) g),
  array['authenticated','postgres','service_role'], 'approve_monvelo_settlement_change keeps its grants');
select is((select array_agg(g.grantee::regrole::text order by g.grantee::regrole::text)
             from (select (aclexplode(proacl)).grantee from pg_proc
                    where oid = 'public.request_monvelo_settlement_change(uuid,text,uuid,jsonb)'::regprocedure) g),
  array['authenticated','postgres','service_role'], 'request_monvelo_settlement_change keeps its grants');

-- behaviour: the same network agent twice is a 23505 with the plain message
select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', json_build_object(
         'sub', '20000000-0000-0000-0000-000000000002', 'role', 'authenticated',
         'app_metadata', json_build_object('active_tenant_id', '10000000-0000-0000-0000-000000000001'))::text, true);
select lives_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000001', 'test-gw-secret',
    '{"business_name":"Mama","pos_network":"MONIEPOINT","network_agent_id":"MP-1","contact_phone":"+2348031112222","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"0123456789","settlement_bank_code":"058","settlement_account_name":"Mama","network_kyc_reference":"K"}'::jsonb)$$,
  'a ZSA registers an agent');
select throws_ok(
  $$select public.register_monvelo_agent('cccccccc-0000-0000-0000-000000000002', 'test-gw-secret',
    '{"business_name":"Mama","pos_network":"MONIEPOINT","network_agent_id":"MP-1","contact_phone":"+2348031112222","latitude":6.5,"longitude":3.3,"address_text":"a","settlement_account_number":"0123456789","settlement_bank_code":"058","settlement_account_name":"Mama","network_kyc_reference":"K"}'::jsonb)$$,
  '23505', 'this agent is already registered with Monvelo', 'the same (pos_network, network_agent_id) twice is a 23505');
reset role;

-- boundary
select is((select array_agg(proname::text order by proname) from pg_proc
            where pronamespace = 'public'::regnamespace
              and prosrc ~ '(^|[^a-z_])(web_pos_partners|web_pos_venues|web_referral_codes|web_commissions)\y'
              and prosrc ~ '(^|[^a-z_])monvelo_[a-z]'),
  null::text[], 'no body names both a web table and a Monvelo table');
select is((select array_agg(conname::text order by conname) from pg_constraint
            where contype = 'f' and connamespace = 'public'::regnamespace
              and ((conrelid::regclass::text ~ '^monvelo_' and confrelid::regclass::text ~ '^web_')
                or (conrelid::regclass::text ~ '^web_' and confrelid::regclass::text ~ '^monvelo_'))),
  null::text[], 'no foreign key joins the web and Monvelo domains');
select is((select array_agg(proname::text order by proname) from pg_proc
            where pronamespace = 'public'::regnamespace and proname !~ 'monvelo'
              -- A6 §19: the lender summary is Monvelo's, under the name the user approved
              and proname <> 'get_lender_reconciliation_summary'
              and prosrc ~ '(^|[^a-z_])monvelo_[a-z]'),
  null::text[], 'no function without monvelo in its name reads a Monvelo table');
-- positive control: the boundary pattern bites a known Monvelo body
select is((select count(*)::int > 0 from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'register_monvelo_agent'
              and prosrc ~ '(^|[^a-z_])monvelo_[a-z]'), true, 'the boundary pattern matches a known Monvelo body');

-- A6 §15: the lenders are Monvelo agents; no function still calls them fintech (Ruling 2, Task 10)
select is((select string_agg(p.proname, ', ' order by p.proname) from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prosrc ~* 'fintech'), null,
  'no public function body says fintech');

select * from finish();
rollback;
