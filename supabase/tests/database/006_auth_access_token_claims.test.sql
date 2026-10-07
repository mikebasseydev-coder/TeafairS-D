-- Spec A §4.4 — the access-token hook's claims: proposals the database
-- re-checks live, computed here so the rules are tested.
begin;
create extension if not exists pgtap with schema extensions;

select plan(16);

insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Nestle Nigeria',   'NESTLE'),
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
-- 1 TM in both (primary at Nestle) · 2 one membership, not primary
-- 3 two memberships, neither primary · 4 only INVITED, platform admin
-- 6 primary membership DISABLED, one ACTIVE elsewhere
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
update public.profiles set platform_role = 'PLATFORM_SUPER_ADMIN'
 where id = '20000000-0000-0000-0000-000000000004';

insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000002', 'Ikeja');

insert into public.tenant_users (id, tenant_id, profile_id, role, territory_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000001', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000001', 'TM', '40000000-0000-0000-0000-000000000002', 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000003', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000032', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000003', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false),
  ('50000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 'RETAIL_SHOP_OWNER', null, 'INVITED', false),
  ('50000000-0000-0000-0000-000000000061', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000006', 'RETAIL_SHOP_OWNER', null, 'DISABLED', true),
  ('50000000-0000-0000-0000-000000000062', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000006', 'RETAIL_SHOP_OWNER', null, 'ACTIVE', false);

-- privileges: only the system-flavoured hook may compute claims
select ok(not has_function_privilege('authenticated', 'public.access_token_claims(uuid)', 'execute'),
  'authenticated cannot compute anyone''s claims');
select ok(not has_function_privilege('anon', 'public.access_token_claims(uuid)', 'execute'),
  'anon cannot compute claims');
select ok(has_function_privilege('service_role', 'public.access_token_claims(uuid)', 'execute'),
  'the hook (service_role) can compute claims');

-- primary membership wins
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000001', 'the primary ACTIVE membership is the active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') ->> 'tenant_role',
  'TM', 'tenant_role is the role in the active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') -> 'tenant_ids',
  '["10000000-0000-0000-0000-000000000001", "10000000-0000-0000-0000-000000000002"]'::jsonb,
  'tenant_ids lists every ACTIVE membership');

-- a single membership is active without being primary
select is(public.access_token_claims('20000000-0000-0000-0000-000000000002') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000001', 'a lone ACTIVE membership is the active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000002') ->> 'tenant_role',
  'RETAIL_SHOP_OWNER', 'and carries its role');

-- several memberships and no primary: the user must choose
select ok(public.access_token_claims('20000000-0000-0000-0000-000000000003') ->> 'active_tenant_id' is null,
  'no active tenant is guessed among several');
select is(jsonb_array_length(public.access_token_claims('20000000-0000-0000-0000-000000000003') -> 'tenant_ids'),
  2, 'but both memberships are listed');

-- invited only: nothing yet; platform role is carried
select is(public.access_token_claims('20000000-0000-0000-0000-000000000004') -> 'tenant_ids',
  '[]'::jsonb, 'an INVITED membership grants no tenant');
select ok(public.access_token_claims('20000000-0000-0000-0000-000000000004') ->> 'active_tenant_id' is null,
  'and no active tenant');
select is(public.access_token_claims('20000000-0000-0000-0000-000000000004') ->> 'platform_role',
  'PLATFORM_SUPER_ADMIN', 'platform_role comes from the profile');

-- unknown user
select is(public.access_token_claims('29999999-0000-0000-0000-000000000000') -> 'tenant_ids',
  '[]'::jsonb, 'an unknown user gets empty claims, not an error');

-- a DISABLED primary is ignored; the remaining ACTIVE membership is used
select is(public.access_token_claims('20000000-0000-0000-0000-000000000006') ->> 'active_tenant_id',
  '10000000-0000-0000-0000-000000000002', 'a disabled primary falls back to the lone ACTIVE membership');

update public.tenant_users set status = 'DISABLED' where id = '50000000-0000-0000-0000-000000000012';
select is(public.access_token_claims('20000000-0000-0000-0000-000000000001') -> 'tenant_ids',
  '["10000000-0000-0000-0000-000000000001"]'::jsonb, 'a disabled membership drops out of tenant_ids');

select * from finish();
rollback;
