-- Spec A §5.5 / §7.4 — PIN verification: bcrypt, five attempts, 15-minute lockout.
begin;
create extension if not exists pgtap with schema extensions;

select plan(19);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria', 'NESTLE');
-- 1 TM with PIN 1234 · 2 TM without a PIN · 3 not a member
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, status, is_primary, pin_hash) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000001', 'ACTIVE', true,
   extensions.crypt('1234', extensions.gen_salt('bf'))),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'TM', '40000000-0000-0000-0000-000000000001', 'ACTIVE', true, null);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

select ok(has_function_privilege('authenticated', 'public.verify_pin(text)', 'execute'),
  'the gateway (as the caller) can verify a PIN');
select ok(not has_function_privilege('anon', 'public.verify_pin(text)', 'execute'),
  'anon cannot');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.verify_pin('0000')::text, '(f,4,)', 'a wrong PIN fails and reports attempts left');
select is(public.verify_pin('1234')::text, '(t,5,)', 'the right PIN passes');
select is((select pin_failed_attempts from public.tenant_users where id = '50000000-0000-0000-0000-000000000001'),
  0, 'a pass resets the failure counter');

do $$ begin
  perform public.verify_pin('0000');
  perform public.verify_pin('0000');
  perform public.verify_pin('0000');
end $$;
select is(public.verify_pin('0000')::text, '(f,1,)', 'the fourth wrong PIN leaves one attempt');
select ok((public.verify_pin('0000')).locked_until is not null, 'the fifth wrong PIN locks the membership');
select is((public.verify_pin('1234')).ok, false, 'a locked membership rejects even the right PIN');

reset role;
select is((select count(*)::int from public.audit_logs
            where operation = 'PIN_LOCKED' and entity_id = '50000000-0000-0000-0000-000000000001'),
  1, 'the lockout is audited');
select ok((select pin_locked_until > now() + interval '14 minutes' from public.tenant_users
            where id = '50000000-0000-0000-0000-000000000001'),
  'the lockout lasts fifteen minutes');

update public.tenant_users set pin_locked_until = now() - interval '1 second'
 where id = '50000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((public.verify_pin('1234')).ok, true, 'the right PIN passes once the lockout lapses');
select is(public.verify_pin('12')::text, '(f,4,)', 'a malformed PIN counts as a wrong one');

select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.verify_pin('1234') $$, 'P0001',
  'no PIN has been set for this membership', 'a membership without a PIN cannot pass');

select pg_temp.act_as('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001');
select throws_ok($$ select public.verify_pin('1234') $$, '42501',
  'not an active member of the selected tenant', 'a non-member cannot probe PINs');

-- the PIN pass (plan amendment 2): bound in the database, single use, 60 s,
-- so a PIN-gated RPC called straight through PostgREST still needs the PIN
reset role;
select ok(not has_function_privilege('authenticated', 'public.consume_pin_pass()', 'execute'),
  'the app cannot spend a PIN pass directly; only PIN-gated RPCs can');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is((public.verify_pin('1234')).ok, true, 'the right PIN grants a pass');
reset role;
-- what a SECURITY DEFINER RPC sees: the caller's claims, the owner's privileges
select set_config('request.jwt.claims', json_build_object(
  'sub', '20000000-0000-0000-0000-000000000001', 'role', 'authenticated',
  'app_metadata', json_build_object('active_tenant_id', '10000000-0000-0000-0000-000000000001'))::text, true);
select lives_ok($$ select public.consume_pin_pass() $$, 'a PIN-gated RPC spends a fresh pass');
select throws_ok($$ select public.consume_pin_pass() $$, '42501',
  'a fresh PIN check is required', 'a pass is single use');
update public.tenant_users set pin_pass_at = now() - interval '61 seconds'
 where id = '50000000-0000-0000-0000-000000000001';
select throws_ok($$ select public.consume_pin_pass() $$, '42501',
  'a fresh PIN check is required', 'a pass older than 60 seconds is refused');

select * from finish();
rollback;
