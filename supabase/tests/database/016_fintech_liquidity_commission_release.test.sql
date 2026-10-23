-- Spec D1 §8.1 — commission release: list_unsettled_subaccounts,
-- release_commission and expire_unsettled_commissions.
begin;
create extension if not exists pgtap with schema extensions;

select plan(24);

-- A5: ONLINE orders created from 2026-10-23 must carry refund-policy consent.
-- These fixtures insert ONLINE orders directly and are not about consent, so
-- stamp it for them (027 tests the CHECK itself).
create function pg_temp.a5_stamp_consent() returns trigger language plpgsql as $f$
begin
  if new.channel = 'ONLINE' then
    new.policy_version_tag := coalesce(new.policy_version_tag, 'v2.0-food');
    new.policy_accepted_at := coalesce(new.policy_accepted_at, now());
  end if;
  return new;
end;
$f$;
create trigger a5_stamp_consent before insert on public.orders
  for each row execute function pg_temp.a5_stamp_consent();

-- ── fixtures ────────────────────────────────────────────────────────────
-- 01, 02 ACTIVE ZSMs · 03 TM · 04 warehouse manager · 06 DSA, the agent
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000001', 'Grace Foods', 'GRACE');
insert into public.tenant_settings (tenant_id) values ('10000000-0000-0000-0000-000000000001');
insert into auth.users (id, phone) values
  ('20000000-0000-0000-0000-000000000001', '2348000000001'),
  ('20000000-0000-0000-0000-000000000002', '2348000000002'),
  ('20000000-0000-0000-0000-000000000003', '2348000000003'),
  ('20000000-0000-0000-0000-000000000004', '2348000000004'),
  ('20000000-0000-0000-0000-000000000006', '2348000000006');
insert into public.zones (id, tenant_id, zone_name) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Lagos');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'ZSM', '30000000-0000-0000-0000-000000000001', null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'ACTIVE', true);
update public.territories set tm_id = '20000000-0000-0000-0000-000000000003'
 where tenant_id = '10000000-0000-0000-0000-000000000001';
insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004');
insert into public.fintech_partners (id, tenant_id, business_name, pos_network, commission_bps, contact_phone,
                                     paystack_subaccount_code, status, approved_by, approved_at) values
  ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Grace Moniepoint', 'MONIEPOINT',
   150, '+2348000000007', 'ACCT_grace01', 'ACTIVE', '20000000-0000-0000-0000-000000000001', now());


create function pg_temp.mk(p_n integer, p_ref text, p_pay_status text, p_age interval,
                           p_comm_status text, p_sub text, p_reason text default null)
returns void language plpgsql as $$
begin
  insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                             public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id, created_at)
  values (('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001', 'ONLINE', '20000000-0000-0000-0000-000000000006',
          2500, 'PAID', 'PAYSTACK_WEB', 'TF-CR00' || lpad(p_n::text, 2, '0'),
          md5('ng_lga:LA:Ikeja')::uuid,
          '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', now() - p_age);
  insert into public.payments (id, tenant_id, order_id, teafair_agent_id, fintech_partner_id, amount,
                               payment_status, paystack_reference,
                               split_subaccount_code, split_bps, split_amount, created_at)
  values (('91000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001',
          ('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '20000000-0000-0000-0000-000000000006', '60000000-0000-0000-0000-000000000001',
          2500.00, p_pay_status::public.payment_status_enum, p_ref,
          'ACCT_grace01', 150, 37.50, now() - p_age);
  insert into public.commission_records (id, tenant_id, order_id, payment_id, fintech_partner_id, teafair_agent_id,
                                         amount, bps_applied, paystack_subaccount_code, paystack_split_reference,
                                         status, dispute_reason, created_at)
  values (('92000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '10000000-0000-0000-0000-000000000001',
          ('90000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          ('91000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid,
          '60000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000006',
          37.50, 150, p_sub, '80' || lpad(p_n::text, 2, '0'), p_comm_status::public.commission_status_enum, p_reason, now() - p_age);
end $$;

select pg_temp.mk(1, 'r_new',  'SUCCESS',  interval '2 hours',  'SPLIT', 'ACCT_c');
select pg_temp.mk(2, 'r_c1',   'SUCCESS',  interval '30 hours', 'SPLIT', 'ACCT_a');
select pg_temp.mk(3, 'r_c2',   'SUCCESS',  interval '30 hours', 'SPLIT', 'ACCT_b');
select pg_temp.mk(4, 'r_c3',   'SUCCESS',  interval '30 hours', 'SPLIT', 'ACCT_b');
select pg_temp.mk(5, 'r_old',  'SUCCESS',  interval '8 days',   'SPLIT', 'ACCT_a');
select pg_temp.mk(6, 'r_ref',  'REFUNDED', interval '30 hours', 'DISPUTED', 'ACCT_a', 'ORDER_REFUNDED');

create function pg_temp.audits(p_settlement text, p_ref text) returns integer language sql as $$
  select count(*)::int from public.audit_logs
   where idempotency_key = md5('paystack-settlement:' || p_settlement || ':' || p_ref)::uuid;
$$;
create function pg_temp.crow(p_n integer) returns text language sql as $$
  select status || '/' || coalesce(dispute_reason, '-') || '/' || coalesce(paystack_settlement_id, '-')
         || '/' || (settled_at is not null)::text
    from public.commission_records
   where id = ('92000000-0000-0000-0000-0000000000' || lpad(p_n::text, 2, '0'))::uuid;
$$;
create function pg_temp.notes(p_reason text) returns integer language sql as $$
  select count(distinct payload ->> 'commission_id')::int from public.notifications
   where kind = 'COMMISSION_DISPUTED' and payload ->> 'reason' = p_reason;
$$;
create function pg_temp.audit_field(p_settlement text, p_ref text, p_side text, p_key text) returns text language sql as $$
  select case when p_side = 'after' then after ->> p_key else before ->> p_key end from public.audit_logs
   where idempotency_key = md5('paystack-settlement:' || p_settlement || ':' || p_ref)::uuid
     and entity_type = 'commission_records' limit 1;
$$;
grant execute on function pg_temp.audits(text, text) to service_role;
grant execute on function pg_temp.crow(integer) to service_role;
grant execute on function pg_temp.notes(text) to service_role;
grant execute on function pg_temp.audit_field(text, text, text, text) to service_role;

-- ── privileges ──────────────────────────────────────────────────────────
select ok(has_function_privilege('service_role', 'public.list_unsettled_subaccounts()', 'execute')
  and has_function_privilege('service_role', 'public.release_commission(text,timestamptz,text,bigint)', 'execute')
  and has_function_privilege('service_role', 'public.expire_unsettled_commissions()', 'execute'),
  'the cron gateway (service_role) runs all three');
select ok(not has_function_privilege('authenticated', 'public.list_unsettled_subaccounts()', 'execute')
  and not has_function_privilege('anon', 'public.release_commission(text,timestamptz,text,bigint)', 'execute')
  and not has_function_privilege('authenticated', 'public.expire_unsettled_commissions()', 'execute'),
  'service_role only');

set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

-- ── list ────────────────────────────────────────────────────────────────
select is((select array_agg(subaccount_code order by subaccount_code) from public.list_unsettled_subaccounts()),
  array['ACCT_a', 'ACCT_b'], 'only rows older than 24 h (ACCT_c has a 2 h row)');
select is((select array_agg(r order by r) from public.list_unsettled_subaccounts() l, unnest(l.payment_references) r
            where l.subaccount_code = 'ACCT_b'),
  array['r_c2', 'r_c3'], 'the payments references of the subaccount are returned');
select is((select oldest_at < now() - interval '7 days' from public.list_unsettled_subaccounts()
            where subaccount_code = 'ACCT_a'), true, 'oldest_at is the oldest SPLIT row');

-- ── release ─────────────────────────────────────────────────────────────
select is(public.release_commission('S1', now(), 'r_c1', 3750) ->> 'outcome', 'settled', 'matching share settles');
select is(pg_temp.crow(2), 'SETTLED/-/S1/true', 'settlement recorded');
select is(public.release_commission('S1', now(), 'r_c1', 3750) ->> 'outcome', 'settled',
  'replay of one settlement is the first reply');
select is(pg_temp.audits('S1', 'r_c1'), 1, 'replay writes nothing');
select is(public.release_commission('S1', now(), 'r_c2', 1) ->> 'outcome', 'mismatch', 'wrong share');
select is(pg_temp.crow(3), 'DISPUTED/SETTLEMENT_MISMATCH/-/false', 'reason SETTLEMENT_MISMATCH');
select is(pg_temp.audit_field('S1', 'r_c2', 'after', 'share_minor') || '/' || pg_temp.audit_field('S1', 'r_c2', 'before', 'share_minor'),
  '1/3750', 'the audit row carries both shares');
select is(pg_temp.notes('SETTLEMENT_MISMATCH'), 1, 'the ZSMs are told of the mismatch');
select is(public.release_commission('S1', now(), 'r_c3', null) ->> 'outcome', 'settled',
  'missing share settles on inclusion (F3)');
select is(pg_temp.audit_field('S1', 'r_c3', 'after', 'share_verified'), 'false',
  'the audit row says the share was not verified');
select is(public.release_commission('S1', now(), 'nope', 1) ->> 'outcome', 'no_match', 'unknown reference');
select is(pg_temp.audits('S1', 'nope'), 0, 'no_match takes no key');
select is(public.release_commission('S2', now(), 'r_ref', 3750) ->> 'outcome', 'no_match',
  'a commission on a refunded payment is no_match');
select is(pg_temp.crow(6), 'DISPUTED/ORDER_REFUNDED/-/false', 'and stays DISPUTED / ORDER_REFUNDED');
select is(public.release_commission('S3', now(), 'r_c1', 3750) ->> 'outcome', 'no_match',
  'an already SETTLED row is no_match');
select is(pg_temp.audits('S3', 'r_c1'), 0, 'and takes no key');

-- ── expiry ──────────────────────────────────────────────────────────────
select is(public.expire_unsettled_commissions(), 1, 'one row older than 7 days expires');
select is(pg_temp.crow(5), 'DISPUTED/NOT_SETTLED/-/false', 'NOT_SETTLED');
select is(pg_temp.notes('NOT_SETTLED'), 1, 'the ZSMs are told');

select * from finish();
rollback;
