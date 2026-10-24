-- Addendum A5 §3.1–3.2, §3.4: refund policy, sellable categories, catalogue notes.
begin;
create extension if not exists pgtap with schema extensions;

select plan(56);

-- the TEAFAIR tenant is seeded in every environment (005)
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price)
select t.id, v.sku, v.name, 'Teafair', v.cat, v.price, v.wholesale
  from public.tenants t,
       (values ('TEA-1', 'Black tea', 'Beverages', 500, 400),
               ('GAD-1', 'Charger',   'Gadgets',    900, 700)) as v(sku, name, cat, price, wholesale)
 where t.code = 'TEAFAIR';

create temp table pol0 as select content from public.refund_policies where version_tag = 'v2.0-food';

-- T1
select is((select count(*) from public.refund_policies where is_active), 1::bigint, 'one active policy');
select is(public.web_active_refund_policy() ->> 'version_tag', 'v2.0-food', 'v2.0-food is active');
select throws_ok(
  $$insert into public.refund_policies (version_tag, title, content, categories, is_active)
    values ('v2.1-food', 'Second', 'x', '{FOOD}', true)$$,
  '23505', null, 'only one active policy');
select throws_ok(
  $$insert into public.refund_policies (version_tag, title, content, categories)
    values ('food', 'Bad tag', 'x', '{FOOD}')$$,
  '23514', null, 'version tag format');
select ok(public.web_category_sellable('FOOD') and not public.web_category_sellable('ELECTRONICS')
          and not public.web_category_sellable('TELECOM'), 'only FOOD sellable');
select throws_ok(
  $$update public.central_products set sale_category = 'TOYS' where sku_code = 'TEA-1'$$,
  '23514', null, 'category set is fixed');

update public.central_products set sale_category = 'ELECTRONICS' where sku_code = 'GAD-1';
select ok(
  exists (select 1 from jsonb_array_elements(public.storefront_catalogue(null) -> 'products') e
           where e ->> 'sku_code' = 'TEA-1')
  and not exists (select 1 from jsonb_array_elements(public.storefront_catalogue(null) -> 'products') e
                   where e ->> 'sku_code' = 'GAD-1')
  and public.storefront_catalogue(null) -> 'refund_policy' ->> 'version_tag' = 'v2.0-food',
  'unsellable products hidden');
select is(public.storefront_catalogue(null) -> 'refund_notes' ->> 'FOOD',
  'Opened food items can''t be refunded. Report transit damage within 24 hours of delivery with photos.',
  'food note');
select ok(not has_table_privilege('anon', 'public.refund_policies', 'select')
      and not has_table_privilege('authenticated', 'public.refund_policies', 'select')
      and not has_table_privilege('service_role', 'public.refund_policies', 'select'),
  'policy table not readable by any API role');
select ok(position('PLACEHOLDER' in (select content from public.refund_policies where version_tag = 'v2.0-food')) > 0,
  'seed marked for legal review');

-- ══ T2: WhatsApp verification and consent on web orders (§3.3, §3.5, §3.6) ═
-- fixtures: a ZSM-held house code on the TEAFAIR tenant, deliverable in Ikeja
insert into auth.users (id, phone) values ('a5000000-0000-0000-0000-000000000001', '2348000000091');
insert into public.zones (id, tenant_id, zone_name)
select 'a5000000-0000-0000-0000-000000000010', t.id, 'Lagos' from public.tenants t where t.code = 'TEAFAIR';
insert into public.territories (id, tenant_id, zone_id, territory_name)
select 'a5000000-0000-0000-0000-000000000011', t.id, 'a5000000-0000-0000-0000-000000000010', 'Ikeja'
  from public.tenants t where t.code = 'TEAFAIR';
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, status, is_primary)
select 'a5000000-0000-0000-0000-000000000012', t.id, 'a5000000-0000-0000-0000-000000000001',
       'ZSM', 'a5000000-0000-0000-0000-000000000010', 'ACTIVE', true
  from public.tenants t where t.code = 'TEAFAIR';
insert into public.warehouses (id, tenant_id, name, kind, territory_id)
select 'a5000000-0000-0000-0000-000000000013', t.id, 'REG-IKEJA', 'REGIONAL', 'a5000000-0000-0000-0000-000000000011'
  from public.tenants t where t.code = 'TEAFAIR';
update public.territories set web_fulfilment_warehouse_id = 'a5000000-0000-0000-0000-000000000013'
 where id = 'a5000000-0000-0000-0000-000000000011';
insert into public.territory_coverage (tenant_id, state_code, lga_id, territory_id)
select t.id, 'LA', md5('ng_lga:LA:Ikeja')::uuid, 'a5000000-0000-0000-0000-000000000011'
  from public.tenants t where t.code = 'TEAFAIR';
insert into public.agent_codes (id, tenant_id, code, agent_id, created_by)
select 'a5000000-0000-0000-0000-000000000014', t.id, 'ZSM-A5', 'a5000000-0000-0000-0000-000000000001',
       'a5000000-0000-0000-0000-000000000001'
  from public.tenants t where t.code = 'TEAFAIR';

create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
grant execute on function pg_temp.as_service() to service_role;
-- sha256 hex of a raw token, as the gateway would send it
create function pg_temp.h(p_token text) returns text language sql security definer as $$
  select encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;
grant execute on function pg_temp.h(text) to service_role;
create function pg_temp.vid(p_phone text) returns uuid language sql security definer as $$
  select id from public.web_phone_verifications where phone = p_phone order by created_at desc limit 1;
$$;
grant execute on function pg_temp.vid(text) to service_role;
-- place a one-line Paystack order on the house code
create function pg_temp.place(p_key uuid, p_phone text, p_token text,
                              p_accept boolean default true, p_tag text default 'v2.0-food',
                              p_sku text default 'TEA-1', p_ip inet default '10.0.0.9')
returns jsonb language sql as $$
  select public.place_web_order(p_key, 'ZSM-A5',
    jsonb_build_array(jsonb_build_object('sku_code', p_sku, 'qty', 1)),
    jsonb_build_object('name', 'Ada Obi', 'phone', p_phone, 'delivery_address', '5 Opebi Road, Ikeja'),
    null, 'PAYSTACK_WEB', case when p_sku = 'GAD-1' then 900.00 else 500.00 end,
    jsonb_build_object('reference', 'TFW-' || p_key, 'access_code', 'ac', 'authorization_url', 'https://checkout.paystack.com/ac',
                       'split', null),
    md5('ng_lga:LA:Ikeja')::uuid, p_accept, p_tag, p_ip, p_token);
$$;
grant execute on function pg_temp.place(uuid, text, text, boolean, text, text, inet) to service_role;
-- the GAD-1 product is ELECTRONICS from the T1 section; keep a second sellable one
-- (TEA-1 stays FOOD)

select pg_temp.as_service();
select is(public.start_web_phone_verification('+2348011111111', '123456', '10.0.0.1') ? 'verification_id',
  true, 'verification started');
select lives_ok($$select public.start_web_phone_verification('+2348011111111', '123456', '10.0.0.1')$$, 'second start');
select lives_ok($$select public.start_web_phone_verification('+2348011111111', '123456', '10.0.0.1')$$, 'third start');
select throws_ok($$select public.start_web_phone_verification('+2348011111111', '123456', '10.0.0.1')$$,
  'P0001', 'Too many messages. Please wait a few minutes.', 'phone throttle');
reset role;
insert into public.web_phone_verifications (phone, code_hash, client_ip, expires_at)
select '+23480999999' || g, 'x', '10.0.0.77', now() + interval '10 minutes' from generate_series(10, 19) g;
select pg_temp.as_service();
select throws_ok($$select public.start_web_phone_verification('+2348012121212', '123456', '10.0.0.77')$$,
  'P0001', 'Too many messages. Please wait a few minutes.', 'IP throttle');
select throws_ok($$select public.start_web_phone_verification('08012121212', '123456', null)$$,
  'P0001', null, 'start needs an E.164 phone');
select throws_ok($$select public.start_web_phone_verification('+2348012121212', '12345', null)$$,
  'P0001', null, 'start needs a 6-digit code');

-- wrong codes, then exhaustion
select public.start_web_phone_verification('+2348022222222', '123456', '10.0.0.2');
select is(
  (select public.confirm_web_phone_verification(pg_temp.vid('+2348022222222'), '000000', pg_temp.h('tok-B')) ->> 'error') is not distinct from 'That code is not right.',
  true, 'wrong code: That code is not right.');
select is(
  (select count(*)::int from generate_series(1, 4) g,
          lateral (select public.confirm_web_phone_verification(pg_temp.vid('+2348022222222'), lpad(g::text, 6, '0'), pg_temp.h('tok-B')) as r) x
    where x.r ->> 'verified' = 'false'),
  4, 'four more wrong codes');
reset role;
select is((select failed_attempts from public.web_phone_verifications where phone = '+2348022222222'), 5,
  'wrong codes are counted');
select pg_temp.as_service();
select throws_ok(
  $$select public.confirm_web_phone_verification(pg_temp.vid('+2348022222222'), '123456', pg_temp.h('tok-B'))$$,
  'P0001', 'Please verify your WhatsApp number again.', 'verification exhausted');

-- right code
select public.start_web_phone_verification('+2348033333333', '123456', '10.0.0.3');
select is((select public.confirm_web_phone_verification(pg_temp.vid('+2348033333333'), '123456', pg_temp.h('tok-C')) ->> 'verified'),
  'true', 'verified');
select throws_ok(
  $$select public.confirm_web_phone_verification(pg_temp.vid('+2348033333333'), '123456', pg_temp.h('tok-C2'))$$,
  'P0001', 'Please verify your WhatsApp number again.', 'a verified row cannot be confirmed twice');
-- expired verification
select public.start_web_phone_verification('+2348077777777', '123456', '10.0.0.7');
reset role;
update public.web_phone_verifications set expires_at = now() - interval '1 second' where phone = '+2348077777777';
select pg_temp.as_service();
select throws_ok(
  $$select public.confirm_web_phone_verification(pg_temp.vid('+2348077777777'), '123456', pg_temp.h('tok-X'))$$,
  'P0001', 'Please verify your WhatsApp number again.', 'an expired verification is refused');

-- the order
select is(pg_temp.place('a5a50000-0000-0000-0000-000000000001', '+2348033333333', 'tok-C') ->> 'public_reference' is not null,
  true, 'verified, consenting order placed');
reset role;
select is(
  (select host(c.consent_ip) || '|' || c.phone_verified_channel || '|' || (c.phone_verified_at is not null)
     from public.order_contacts c
     join public.orders o on o.id = c.order_id where o.public_reference is not null
      and c.customer_phone = '+2348033333333'),
  '10.0.0.9|WHATSAPP|true', 'consent IP and verification stored A2-side');
select is(
  (select o.policy_version_tag || '|' || (o.policy_accepted_at is not null)
     from public.orders o join public.order_contacts c on c.order_id = o.id
    where c.customer_phone = '+2348033333333'),
  'v2.0-food|true', 'the order records the policy it was accepted under');
select ok(
  (select a.after ->> 'policy_version_tag' = 'v2.0-food' and a.after ? 'policy_accepted_at'
          and (a.after ->> 'phone_verified')::boolean
          and a.after::text not like '%10.0.0.9%' and a.after::text not like '%consent_ip%'
     from public.audit_logs a
    where a.operation = 'place_web_order' and a.idempotency_key = 'a5a50000-0000-0000-0000-000000000001'),
  'audit has consent, not IP');
select isnt((select consumed_at from public.web_phone_verifications where phone = '+2348033333333'), null,
  'the verification is consumed by the order');
select pg_temp.as_service();
select throws_ok($$select pg_temp.place('a5a50000-0000-0000-0000-000000000002', '+2348033333333', 'tok-C')$$,
  'P0001', 'Please verify your WhatsApp number again.', 'token is single use');

-- token bound to the phone it verified
select public.start_web_phone_verification('+2348044444444', '123456', '10.0.0.4');
select public.confirm_web_phone_verification(pg_temp.vid('+2348044444444'), '123456', pg_temp.h('tok-D'));
select throws_ok($$select pg_temp.place('a5a50000-0000-0000-0000-000000000003', '+2348022222222', 'tok-D')$$,
  'P0001', 'Please verify your WhatsApp number again.', 'token bound to phone');

-- token lifetime
select public.start_web_phone_verification('+2348066666666', '123456', '10.0.0.6');
select public.confirm_web_phone_verification(pg_temp.vid('+2348066666666'), '123456', pg_temp.h('tok-E'));
reset role;
update public.web_phone_verifications set token_expires_at = now() - interval '1 second' where phone = '+2348066666666';
select pg_temp.as_service();
select throws_ok($$select pg_temp.place('a5a50000-0000-0000-0000-000000000004', '+2348066666666', 'tok-E')$$,
  'P0001', 'Please verify your WhatsApp number again.', 'token expires');

-- consent, policy tag, sellable category
select throws_ok($$select pg_temp.place('a5a50000-0000-0000-0000-000000000005', '+2348044444444', 'tok-D', false)$$,
  'P0001', 'You must accept the refund policy to place an order.', 'consent required');
select throws_ok($$select pg_temp.place('a5a50000-0000-0000-0000-000000000006', '+2348044444444', 'tok-D', true, 'v1.0-old')$$,
  'P0001', 'The refund policy has changed. Please review it and try again.', 'stale policy refused');
select throws_ok($$select pg_temp.place('a5a50000-0000-0000-0000-000000000007', '+2348044444444', 'tok-D', true, 'v2.0-food', 'GAD-1')$$,
  'P0001', 'This product is not available to order yet.', 'unsellable refused');

-- the refused calls above did not burn the good token; D can still order
select is(pg_temp.place('a5a50000-0000-0000-0000-000000000008', '+2348044444444', 'tok-D') ->> 'public_reference' is not null,
  true, 'refusals do not consume the token');

-- replay keeps the original consent, even with a new policy and a new token/IP
reset role;
update public.refund_policies set is_active = false where version_tag = 'v2.0-food';
insert into public.refund_policies (version_tag, title, content, categories, is_active)
values ('v2.1-food', 'Second', 'x', '{FOOD}', true);
select pg_temp.as_service();
select is(pg_temp.place('a5a50000-0000-0000-0000-000000000001', '+2348033333333', 'tok-new', true, 'v2.1-food', 'TEA-1', '10.9.9.9') ->> 'order_id',
  (select e.id::text from public.orders e where e.public_reference is not null
     and exists (select 1 from public.order_contacts c where c.order_id = e.id and c.customer_phone = '+2348033333333')),
  'replay of the first key returns the original order');
reset role;
select is((select o.policy_version_tag from public.orders o join public.order_contacts c on c.order_id = o.id
            where c.customer_phone = '+2348033333333'), 'v2.0-food', 'the original consent is kept');

-- the cut-off CHECK and grants
select throws_ok(
  $$insert into public.orders (tenant_id, channel, teafair_agent_id, total_amount, status, created_at,
                              payment_route, delivery_lga_id, territory_id, fulfilment_warehouse_id)
    select t.id, 'ONLINE', 'a5000000-0000-0000-0000-000000000001', 100, 'PENDING', now(),
           'PAYSTACK_WEB', md5('ng_lga:LA:Ikeja')::uuid, 'a5000000-0000-0000-0000-000000000011',
           'a5000000-0000-0000-0000-000000000013'
      from public.tenants t where t.code = 'TEAFAIR'$$,
  '23514', 'new row for relation "orders" violates check constraint "orders_web_consent_complete"',
  'new web orders must carry consent');
select ok(not has_table_privilege('anon', 'public.web_phone_verifications', 'select')
      and not has_table_privilege('authenticated', 'public.web_phone_verifications', 'select')
      and not has_table_privilege('service_role', 'public.web_phone_verifications', 'select'),
  'verification table has no client grant');
select ok(not has_function_privilege('authenticated', 'public.start_web_phone_verification(text,text,inet)', 'execute')
      and not has_function_privilege('anon', 'public.confirm_web_phone_verification(uuid,text,text)', 'execute')
      and has_function_privilege('service_role', 'public.start_web_phone_verification(text,text,inet)', 'execute')
      and has_function_privilege('service_role', 'public.confirm_web_phone_verification(uuid,text,text)', 'execute'),
  'verification RPCs are service_role only');
select ok(to_regprocedure('public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid)') is null,
  'the consent-free signature is gone');

-- ══ R20: policy versions are immutable ══════════════════════════════════
reset role;
select throws_ok($$update public.refund_policies set content = 'edited' where version_tag = 'v2.0-food'$$,
  'P0001', 'refund policy v2.0-food is immutable: publish a new version (e.g. v2.1-food) instead of editing it',
  'content cannot be edited');
select throws_ok($$update public.refund_policies set title = 'edited' where version_tag = 'v2.0-food'$$,
  'P0001', null, 'title cannot be edited');
select throws_ok($$update public.refund_policies set categories = '{FOOD,ELECTRONICS}' where version_tag = 'v2.0-food'$$,
  'P0001', null, 'categories cannot be edited');
select throws_ok($$update public.refund_policies set version_tag = 'v2.9-food' where version_tag = 'v2.0-food'$$,
  'P0001', null, 'version_tag cannot be edited');
select throws_ok($$update public.refund_policies set published_at = now() - interval '1 day' where version_tag = 'v2.1-food'$$,
  'P0001', null, 'published_at cannot move outside activation');
select throws_ok($$delete from public.refund_policies where version_tag = 'v2.0-food'$$,
  'P0001', 'refund policy versions cannot be deleted; publish a new version and activate it instead',
  'versions cannot be deleted');
set local client_min_messages = warning;  -- the cascade NOTICEs, before the trigger refuses
select throws_ok($$truncate public.refund_policies cascade$$, 'P0001', null, 'versions cannot be truncated');
reset client_min_messages;
select is((select content from public.refund_policies where version_tag = 'v2.0-food'),
  (select content from pol0), 'the consented text is unchanged');

-- toggling is allowed, and activation may stamp published_at
update public.refund_policies set is_active = false where version_tag = 'v2.1-food';
update public.refund_policies set is_active = true, published_at = timestamptz '2026-11-01 00:00:00+00'
 where version_tag = 'v2.0-food';
select is(public.web_active_refund_policy() ->> 'version_tag', 'v2.0-food', 'deactivate and reactivate work');
select is((select published_at from public.refund_policies where version_tag = 'v2.0-food'),
  timestamptz '2026-11-01 00:00:00+00', 'activation stamps published_at');

-- ══ retention: web_phone_verifications older than 7 days go ═════════════
insert into public.web_phone_verifications (phone, code_hash, expires_at, created_at) values
  ('+2348055500001', 'x', now() - interval '8 days', now() - interval '8 days'),
  ('+2348055500002', 'x', now() - interval '30 days', now() - interval '30 days'),
  ('+2348055500003', 'x', now() - interval '6 days', now() - interval '6 days');
select is(public.cleanup_web_phone_verifications(), 2, 'cleanup deletes the two rows older than 7 days');
select is((select count(*) from public.web_phone_verifications where phone like '+23480555000%'), 1::bigint,
  'a 6-day-old row is kept');
select is((select schedule from cron.job where jobname = 'cleanup-web-phone-verifications'), '50 0 * * *',
  'the retention job runs nightly at 00:50');
select is((select command from cron.job where jobname = 'cleanup-web-phone-verifications'),
  'select public.cleanup_web_phone_verifications()', 'the job calls the cleanup');

select * from finish();
rollback;
