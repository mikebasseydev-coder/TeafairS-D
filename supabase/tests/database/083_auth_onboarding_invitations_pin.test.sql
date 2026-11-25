-- 20261125130000 — onboarding: listing, accepting and declining invitations,
-- and setting and changing the membership PIN.
begin;
create extension if not exists pgtap with schema extensions;

select plan(53);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Onboarding Team A', 'TFONA'),
  ('10000000-0000-0000-0000-000000000002', 'Onboarding Team B', 'TFONB'),
  ('10000000-0000-0000-0000-000000000003', 'Onboarding Team Gone', 'TFONC');
update public.tenants set status = 'INACTIVE' where id = '10000000-0000-0000-0000-000000000003';

-- 1 invited to A (ZSM) and to the inactive C · 2 ACTIVE primary in B, invited
-- to A · 3 a stranger · 4 invited to A, declines
insert into auth.users (id, email, email_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', 'one@example.com', now()),
  ('20000000-0000-0000-0000-000000000002', 'two@example.com', now()),
  ('20000000-0000-0000-0000-000000000003', 'three@example.com', now()),
  ('20000000-0000-0000-0000-000000000004', 'four@example.com', now());

insert into public.tenant_users (id, tenant_id, profile_id, role, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'ZSM', 'INVITED', false),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002', 'TENANT_ADMIN', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'CLIENT_SERVICE_MANAGER', 'INVITED', false),
  ('50000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'TENANT_ADMIN', 'INVITED', false),
  ('50000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000003',
   '20000000-0000-0000-0000-000000000001', 'TENANT_ADMIN', 'INVITED', false);

create function pg_temp.act_as(p_user uuid, p_tenant uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object(
           'sub', p_user, 'role', 'authenticated',
           'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
$$;
grant execute on function pg_temp.act_as(uuid, uuid) to authenticated;

-- ── grants ──────────────────────────────────────────────────────────────
select ok(has_function_privilege('authenticated', 'public.accept_tenant_invitation(uuid, uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.decline_tenant_invitation(uuid, uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.list_my_invitations()', 'execute')
      and has_function_privilege('authenticated', 'public.get_my_pin_status()', 'execute')
      and has_function_privilege('authenticated', 'public.set_tenant_pin(uuid, text)', 'execute')
      and has_function_privilege('authenticated', 'public.change_tenant_pin(uuid, text, text)', 'execute'),
  'the six onboarding RPCs are callable by a signed-in user');
select ok(not has_function_privilege('anon', 'public.accept_tenant_invitation(uuid, uuid)', 'execute')
      and not has_function_privilege('anon', 'public.set_tenant_pin(uuid, text)', 'execute')
      and not has_function_privilege('anon', 'public.list_my_invitations()', 'execute'),
  'anon calls none of them');
select ok(not has_function_privilege('authenticated', 'public.pin_policy_refusal(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.lock_my_invitation(uuid)', 'execute'),
  'the helpers are internal');

-- ── listing ─────────────────────────────────────────────────────────────
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') -> 'active_tenant_id',
  'null'::jsonb, 'before accepting, the invitee''s token has no tenant');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select results_eq(
  $$select tenant_user_id, tenant_name, tenant_code, role::text from public.list_my_invitations()$$,
  $$values ('50000000-0000-0000-0000-000000000001'::uuid, 'Onboarding Team A', 'TFONA', 'ZSM')$$,
  'the invitee lists their pending invitation with the team''s name, not the inactive team''s');
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', null);
select is((select count(*)::int from public.list_my_invitations()), 0, 'a stranger lists nothing');

-- ── accepting ───────────────────────────────────────────────────────────
select throws_ok(
  $$select public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001')$$,
  'P0001', 'invitation not found', 'nobody accepts another person''s invitation');
select throws_ok(
  $$select public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000002', '50000000-0000-0000-0000-0000000000ff')$$,
  'P0001', 'invitation not found', 'an unknown membership is the same refusal');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', null);
select throws_ok(
  $$select public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000005')$$,
  'P0001', 'this team is not active', 'an invitation to an inactive team cannot be accepted');
select is(
  public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001'),
  jsonb_build_object('tenant_user_id', '50000000-0000-0000-0000-000000000001', 'tenant_id', '10000000-0000-0000-0000-000000000001',
                     'role', 'ZSM', 'status', 'ACTIVE', 'is_primary', true, 'refresh_session', true),
  'accepting replies with the membership, primary, and a session refresh');
select is(
  public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001') ->> 'status',
  'ACTIVE', 'a replay with the same key returns the first answer');
select throws_ok(
  $$select public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000005', '50000000-0000-0000-0000-000000000001')$$,
  'P0001', 'invitation not found', 'a second accept under a new key finds no invitation');
select throws_ok(
  $$select public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000005')$$,
  'TF002', null, 'the same key for another membership is TF002');
select is((select count(*)::int from public.list_my_invitations()), 0, 'the accepted invitation leaves the list');
reset role;

select is((select status::text || '/' || is_primary from public.tenant_users where id = '50000000-0000-0000-0000-000000000001'),
  'ACTIVE/true', 'the membership is ACTIVE and primary');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000001', 'the next token carries the accepted team');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') ->> 'tenant_role',
  'ZSM', 'and the role');

-- someone already ACTIVE elsewhere keeps their primary team
select pg_temp.act_as('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');
select is(
  public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000006', '50000000-0000-0000-0000-000000000003') ->> 'is_primary',
  'false', 'a second team is not made primary');
reset role;
select is(public.access_token_claims('20000000-0000-0000-0000-000000000002') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000002', 'the active team stays the one already chosen');
select is(jsonb_array_length(public.access_token_claims('20000000-0000-0000-0000-000000000002') -> 'tenant_ids'),
  2, 'both teams are in tenant_ids');

-- ── declining ───────────────────────────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000004', null);
select is(
  public.decline_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000007', '50000000-0000-0000-0000-000000000004') ->> 'status',
  'DISABLED', 'declining disables the membership');
select is(
  public.decline_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000007', '50000000-0000-0000-0000-000000000004') ->> 'status',
  'DISABLED', 'a declined replay returns the first answer');
select throws_ok(
  $$select public.accept_tenant_invitation('aaaaaaaa-0000-0000-0000-000000000008', '50000000-0000-0000-0000-000000000004')$$,
  'P0001', 'invitation not found', 'a declined invitation cannot be accepted');
reset role;
select is(public.auth_email_context('20000000-0000-0000-0000-000000000004') ->> 'allowed',
  'false', 'a decliner with nothing else gets no sign-in code');

select ok(not exists (select 1 from public.audit_logs
                      where operation in ('accept_tenant_invitation', 'decline_tenant_invitation')
                        and (coalesce(before::text, '') || coalesce(after::text, '')) ~* '@|example'),
  'invitation audit rows name no contact');
select is((select count(*)::int from public.audit_logs
           where operation = 'accept_tenant_invitation' and entity_id = '50000000-0000-0000-0000-000000000001'),
  1, 'one audit row per acceptance, replays included');

-- ── PIN: status and the first PIN ───────────────────────────────────────
select pg_temp.act_as('20000000-0000-0000-0000-000000000003', null);
select throws_ok($$select public.get_my_pin_status()$$, '42501', 'no active tenant selected',
  'a person with no team has no PIN');

select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.get_my_pin_status() ->> 'pin_set', 'false', 'a new member has no PIN');
select throws_ok($$select public.verify_pin('2580')$$, 'P0001', 'no PIN has been set for this membership',
  'verify_pin refuses before a PIN is set');
select throws_ok($$select public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000001', '258')$$,
  'P0001', 'a PIN is exactly four digits', 'three digits are refused');
select throws_ok($$select public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000001', '25a0')$$,
  'P0001', 'a PIN is exactly four digits', 'a letter is refused');
select throws_ok($$select public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000001', '7777')$$,
  'P0001', 'choose a PIN that is not one digit repeated', 'a repeated digit is refused');
select throws_ok($$select public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000001', '1234')$$,
  'P0001', 'choose a PIN that is not a run of digits', 'a run up is refused');
select throws_ok($$select public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000001', '6543')$$,
  'P0001', 'choose a PIN that is not a run of digits', 'a run down is refused');
select is(public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000001', '2580'),
  jsonb_build_object('tenant_user_id', '50000000-0000-0000-0000-000000000001', 'pin_set', true),
  'a good first PIN is set');
select is(public.get_my_pin_status() ->> 'pin_set', 'true', 'the status shows it');
select is((public.verify_pin('2580')).ok, true, 'verify_pin accepts the new PIN');
select is((public.verify_pin('2581')).ok, false, 'and refuses another');
select throws_ok($$select public.set_tenant_pin('bbbbbbbb-0000-0000-0000-000000000002', '3690')$$,
  'P0001', 'a PIN is already set; change it with your current PIN', 'a second first PIN is refused');

-- ── PIN: changing it ────────────────────────────────────────────────────
reset role;
update public.tenant_users set pin_failed_attempts = 0 where id = '50000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select is(public.change_tenant_pin('bbbbbbbb-0000-0000-0000-000000000003', '1111', '3690'),
  '{"changed": false, "attempts_remaining": 4, "locked_until": null}'::jsonb,
  'a wrong current PIN is a reply, with the attempts left');
reset role;
select is((select pin_failed_attempts from public.tenant_users where id = '50000000-0000-0000-0000-000000000001'),
  1, 'and the failure is counted (it committed)');
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
select throws_ok($$select public.change_tenant_pin('bbbbbbbb-0000-0000-0000-000000000004', '2580', '0000')$$,
  'P0001', 'choose a PIN that is not one digit repeated', 'a weak new PIN is refused');
select throws_ok($$select public.change_tenant_pin('bbbbbbbb-0000-0000-0000-000000000005', '2580', '2580')$$,
  'P0001', 'choose a PIN different from your current one', 'the same PIN is refused');
select is(public.change_tenant_pin('bbbbbbbb-0000-0000-0000-000000000006', '2580', '3690') ->> 'changed',
  'true', 'the right current PIN changes it');
select is((public.verify_pin('3690')).ok, true, 'the new PIN verifies');
select is((public.verify_pin('2580')).ok, false, 'the old one no longer does');

-- five wrong current PINs lock it, and a lock answers even the right PIN
reset role;
update public.tenant_users set pin_failed_attempts = 0 where id = '50000000-0000-0000-0000-000000000001';
select pg_temp.act_as('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
do $$
begin
  for n in 0..3 loop
    perform public.change_tenant_pin(('bbbbbbbb-0000-0000-0000-00000000001' || n)::uuid, '1470', '2581');
  end loop;
end $$;
select is(public.change_tenant_pin('bbbbbbbb-0000-0000-0000-000000000020', '1470', '2581') ->> 'attempts_remaining',
  '0', 'the fifth wrong PIN locks the membership');
select ok((public.change_tenant_pin('bbbbbbbb-0000-0000-0000-000000000021', '3690', '2581') ->> 'locked_until') is not null,
  'while locked, even the right PIN changes nothing');
select ok(public.get_my_pin_status() ->> 'locked_until' is not null, 'the status shows the lock');
reset role;
select is((select count(*)::int from public.audit_logs
           where operation = 'PIN_LOCKED' and entity_id = '50000000-0000-0000-0000-000000000001'),
  1, 'the lock is audited once');

-- ── no PIN anywhere it could be read ────────────────────────────────────
select ok(not exists (select 1 from public.audit_logs
                      where (coalesce(before::text, '') || coalesce(after::text, '')) ~ '2580|3690|2581|1470'),
  'no audit row holds a PIN');
select ok(not exists (select 1 from public.idempotency_logs
                      where operation in ('set_tenant_pin', 'change_tenant_pin')
                        and coalesce(response::text, '') ~ '2580|3690|2581|1470'),
  'no idempotency reply holds a PIN');
select ok((select pin_hash from public.tenant_users where id = '50000000-0000-0000-0000-000000000001') ~ '^\$2[aby]\$10\$',
  'the stored PIN is a bcrypt hash (cost 10)');

select * from finish();
rollback;
