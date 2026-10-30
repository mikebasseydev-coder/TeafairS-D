-- Addendum A5 §6 — the ZSM dispute evidence bundle, and the grants sweep over
-- every function the A5 migrations create or change.
begin;
create extension if not exists pgtap with schema extensions;

select plan(179);

-- ── fixtures ────────────────────────────────────────────────────────────
-- TEAFAIR: ZSM (1), Ikeja TM (2), Ikeja DSA (4), DSM (5, manages warehouse W).
-- UNILEVER: ZSM (6).
insert into public.tenants (id, name, code) values
  ('10000000-0000-0000-0000-000000000002', 'Unilever Nigeria', 'UNILEVER');
insert into auth.users (id, phone)
select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, '23480000000' || lpad(n::text, 2, '0')
  from generate_series(1, 6) n;
insert into public.zones (id, tenant_id, zone_name, state_code) values
  ('30000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'Lagos', 'LA'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Lagos', 'LA');
insert into public.territories (id, tenant_id, zone_id, territory_name) values
  ('40000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'Ikeja');
insert into public.tenant_users (id, tenant_id, profile_id, role, zone_id, territory_id, reports_to_id, status, is_primary) values
  ('50000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000001',
   'ZSM', null, null, null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000002',
   'TM', null, '40000000-0000-0000-0000-000000000001', null, 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000004', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000004',
   'DSA', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000005', '7eaf0000-0000-4000-8000-000000000001', '20000000-0000-0000-0000-000000000005',
   'DSM', null, '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'ACTIVE', true),
  ('50000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000006',
   'ZSM', null, null, null, 'ACTIVE', true);
insert into public.warehouses (id, tenant_id, name, kind, territory_id, manager_id) values
  ('70000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'REG-IKEJA', 'REGIONAL',
   '40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005');
update public.territories set tm_id = '20000000-0000-0000-0000-000000000002'
 where id = '40000000-0000-0000-0000-000000000001';
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price, nafdac_number)
values ('7eaf0000-0000-4000-8000-000000000001', 'TEA-1', 'Black tea', 'Teafair', 'Beverages', 500, 400, 'A1-0007');

-- one delivered, paid, part-refunded web order with a ticket and two photos
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id,
                           policy_version_tag, policy_accepted_at) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000004', 1000, 'DELIVERED', 'PAYSTACK_WEB', 'TF-AAAAAA',
   md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   'v2.0-food-cosmetics', '2026-10-23 10:00+00');
insert into public.order_items (tenant_id, order_id, sku_code, qty, unit_price) values
  ('7eaf0000-0000-4000-8000-000000000001', '90000000-0000-0000-0000-000000000001', 'TEA-1', 2, 500);
insert into public.order_contacts (order_id, tenant_id, territory_id, customer_name, customer_phone, customer_email,
                                   delivery_address, consent_ip, phone_verified_at, phone_verified_channel) values
  ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'Ada', '+2348011111111', 'ada@example.com', '1 Allen Ave',
   '203.0.113.7', '2026-10-23 09:59+00', 'WHATSAPP');
insert into public.payments (id, tenant_id, order_id, teafair_agent_id, amount, paystack_reference, payment_status) values
  ('91000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', '90000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', 1000, 'TFW-EVIDENCE-1', 'SUCCESS');
insert into public.audit_logs (tenant_id, operation, entity_type, entity_id, after, source) values
  ('7eaf0000-0000-4000-8000-000000000001', 'PARTIAL_REFUND', 'payments', '91000000-0000-0000-0000-000000000001',
   '{"refund_id":"rf_1","reason":"REFUND","amount_minor":20000,"currency":"NGN"}', 'WEBHOOK');
insert into public.order_fulfilments (order_id, tenant_id, dispatched_by, tracking_reference, delivery_pin_hash,
                                      delivered_at, delivered_by, delivered_via, damage_claim_deadline, delivery_photo_path)
values ('90000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
        '20000000-0000-0000-0000-000000000001', 'TRK-9', extensions.crypt('1234', extensions.gen_salt('bf')),
        '2026-10-23 12:00+00', '20000000-0000-0000-0000-000000000004', 'FIELD_STAFF', '2026-10-24 12:00+00',
        'orders/90000000-0000-0000-0000-000000000001/b0000000-0000-0000-0000-000000000001.jpg');
insert into public.upload_slots (id, tenant_id, purpose, order_id, storage_path, mime_type, size_bytes,
                                 uploaded_by_type, uploaded_by, claimed_at) values
  ('b0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'DELIVERY_PROOF',
   '90000000-0000-0000-0000-000000000001',
   'orders/90000000-0000-0000-0000-000000000001/b0000000-0000-0000-0000-000000000001.jpg',
   'image/jpeg', 900, 'STAFF', '20000000-0000-0000-0000-000000000004', now());
insert into public.support_tickets (id, tenant_id, public_reference, kind, category, order_id, territory_id,
                                    accountable_id, within_damage_window) values
  ('60000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001', 'TK-AAAAA1', 'ORDER', 'DELIVERY',
   '90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000004', true);
insert into public.support_messages (id, tenant_id, ticket_id, sender_type, body) values
  ('c0000000-0000-0000-0000-000000000001', '7eaf0000-0000-4000-8000-000000000001',
   '60000000-0000-0000-0000-000000000001', 'CUSTOMER', 'The box was crushed');
insert into public.upload_slots (id, tenant_id, purpose, ticket_id, storage_path, mime_type, size_bytes,
                                 uploaded_by_type, message_id, claimed_at) values
  ('b0000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'SUPPORT_TICKET',
   '60000000-0000-0000-0000-000000000001',
   'tickets/60000000-0000-0000-0000-000000000001/b0000000-0000-0000-0000-000000000002.png',
   'image/png', 700, 'CUSTOMER', 'c0000000-0000-0000-0000-000000000001', now());

create procedure pg_temp.as_user(n integer, p_tenant uuid default '7eaf0000-0000-4000-8000-000000000001')
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0')), 'role', 'authenticated',
    'app_metadata', json_build_object('active_tenant_id', p_tenant))::text, true);
end $$;
create function pg_temp.ev(p_order uuid default '90000000-0000-0000-0000-000000000001')
returns jsonb language sql as $$ select public.get_order_dispute_evidence(p_order) $$;
grant execute on function pg_temp.ev(uuid) to authenticated;

-- ── the ZSM gets every block ────────────────────────────────────────────
create temp table pol as select content from public.refund_policies where version_tag = 'v2.0-food-cosmetics';
grant select on pol to authenticated;
call pg_temp.as_user(1);
create temp table ev as select pg_temp.ev() as b;
grant select on ev to authenticated;
select is((select b -> 'order' ->> 'public_reference' from ev), 'TF-AAAAAA', 'order header');
select is((select b -> 'order' ->> 'transport_fare' from ev), '0.00', 'the order header carries the transport fare');
select is((select b -> 'lines' -> 0 ->> 'sale_category' from ev), 'FOOD', 'lines carry sale_category');
select is((select b -> 'lines' -> 0 ->> 'nafdac_number' from ev), 'A1-0007', 'lines carry the NAFDAC number');
select is((select (b -> 'lines' -> 0 ->> 'nafdac_regulated')::boolean from ev), true, 'lines flag NAFDAC-regulated categories');
select is((select b -> 'lines' -> 0 ->> 'line_total' from ev), '1000.00', 'line total');
select is((select b -> 'payments' -> 0 ->> 'paystack_reference' from ev), 'TFW-EVIDENCE-1', 'payment reference');
select is((select b -> 'payments' -> 0 ->> 'payment_status' from ev), 'SUCCESS', 'payment status');
select ok((select b -> 'payments' -> 0 ? 'settlement' from ev), 'payment carries a settlement key');
select is((select jsonb_array_length(b -> 'refunds') from ev), 1, 'one refund');
select is((select b -> 'refunds' -> 0 ->> 'refund_id' from ev), 'rf_1', 'refund id');
select is((select b -> 'refunds' -> 0 ->> 'kind' from ev), 'PARTIAL', 'refund kind');
select is((select b -> 'refunds' -> 0 ->> 'amount_minor' from ev), '20000', 'refund amount');
select is((select b -> 'consent' ->> 'policy_version_tag' from ev), 'v2.0-food-cosmetics', 'consent policy tag');
select ok((select b -> 'consent' ->> 'policy_accepted_at' from ev) is not null, 'consent accepted at');
select is((select b -> 'consent' ->> 'consent_ip' from ev), '203.0.113.7', 'consent ip');
select is((select b -> 'consent' ->> 'content' from ev),
          (select content from pol),
          'consent holds the accepted policy text');
select ok(length((select b -> 'consent' ->> 'content' from ev)) > 50, 'policy text is not empty');
select is((select b -> 'contact' ->> 'customer_phone' from ev), '+2348011111111', 'contact phone');
select is((select b -> 'contact' ->> 'delivery_address' from ev), '1 Allen Ave', 'contact address');
select is((select b -> 'contact' ->> 'phone_verified_channel' from ev), 'WHATSAPP', 'phone verification channel');
select ok((select b -> 'contact' ->> 'phone_verified_at' from ev) is not null, 'phone verified at');
select is((select b -> 'fulfilment' ->> 'tracking_reference' from ev), 'TRK-9', 'tracking reference');
select is((select b -> 'fulfilment' ->> 'pin_verified' from ev), 'true', 'pin verified');
select is((select b -> 'fulfilment' ->> 'delivered_via' from ev), 'FIELD_STAFF', 'delivered via');
select is((select b -> 'fulfilment' -> 'delivery_photo' ->> 'bucket' from ev), 'delivery-proofs', 'photo bucket');
select ok((select b -> 'fulfilment' -> 'delivery_photo' ->> 'storage_path' from ev) like 'orders/%', 'photo path');
select is((select b -> 'tickets' -> 0 ->> 'public_reference' from ev), 'TK-AAAAA1', 'ticket');
select is((select b -> 'tickets' -> 0 ->> 'within_damage_window' from ev), 'true', 'within_damage_window');
select is((select b -> 'tickets' -> 0 -> 'messages' -> 0 ->> 'body' from ev), 'The box was crushed', 'ticket message');
select is((select b -> 'tickets' -> 0 -> 'messages' -> 0 -> 'attachments' -> 0 ->> 'bucket' from ev),
          'support-attachments', 'attachment bucket');
select is((select b -> 'tickets' -> 0 -> 'messages' -> 0 -> 'attachments' -> 0 ->> 'mime_type' from ev),
          'image/png', 'attachment mime type');
select ok((select b -> 'tickets' -> 0 -> 'messages' -> 0 -> 'attachments' -> 0 ->> 'storage_path' from ev)
          like 'tickets/%', 'attachment path');
reset role;

-- an order with no fulfilment, contact or tickets: empty blocks, no failure
insert into public.orders (id, tenant_id, channel, teafair_agent_id, total_amount, status, payment_route,
                           public_reference, delivery_lga_id, territory_id, fulfilment_warehouse_id,
                           policy_version_tag, policy_accepted_at) values
  ('90000000-0000-0000-0000-000000000002', '7eaf0000-0000-4000-8000-000000000001', 'ONLINE',
   '20000000-0000-0000-0000-000000000004', 500, 'PAID', 'PAYSTACK_WEB', 'TF-AAAAAB',
   md5('ng_lga:LA:Ikeja')::uuid, '40000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
   'v2.0-food-cosmetics', now());
call pg_temp.as_user(1);
select is((select pg_temp.ev('90000000-0000-0000-0000-000000000002') -> 'tickets'), '[]'::jsonb, 'no tickets: empty array');
select is((select pg_temp.ev('90000000-0000-0000-0000-000000000002') -> 'fulfilment'), 'null'::jsonb, 'no fulfilment: null');
reset role;

-- ── nobody else ─────────────────────────────────────────────────────────
call pg_temp.as_user(2);
select throws_ok($$select pg_temp.ev()$$, '42501', null, 'TM is refused');
reset role;
call pg_temp.as_user(4);
select throws_ok($$select pg_temp.ev()$$, '42501', null, 'DSA is refused');
reset role;
call pg_temp.as_user(5);
select throws_ok($$select pg_temp.ev()$$, '42501', null, 'the warehouse manager is refused');
reset role;
call pg_temp.as_user(6, '10000000-0000-0000-0000-000000000002');
select throws_ok($$select pg_temp.ev()$$, '42501', null, 'another tenant''s ZSM is refused');
reset role;
call pg_temp.as_user(1);
select throws_ok($$select pg_temp.ev('99999999-9999-9999-9999-999999999999')$$, '42501', null, 'an unknown order is refused alike');
reset role;
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select throws_ok($$select public.get_order_dispute_evidence('90000000-0000-0000-0000-000000000001')$$, '42501', null,
                 'no session is refused');
reset role;

-- ── the audit ───────────────────────────────────────────────────────────
-- ev was filled by one call and the empty order added two; refusals add none
select is((select count(*) from public.audit_logs where operation = 'DISPUTE_EVIDENCE_VIEWED'), 3::bigint,
          'one audit row per successful call');
select is((select count(*) from public.audit_logs where operation = 'DISPUTE_EVIDENCE_VIEWED'
            and entity_id = '90000000-0000-0000-0000-000000000001'), 1::bigint, 'one for the first order');
select is((select after from public.audit_logs where operation = 'DISPUTE_EVIDENCE_VIEWED'
            and entity_id = '90000000-0000-0000-0000-000000000001'),
          '{"order_id":"90000000-0000-0000-0000-000000000001"}'::jsonb, 'after-image is {order_id} only');
select is((select before from public.audit_logs where operation = 'DISPUTE_EVIDENCE_VIEWED'
            and entity_id = '90000000-0000-0000-0000-000000000001'), null, 'no before-image');
select ok((select idempotency_key is null and source = 'USER' from public.audit_logs
            where operation = 'DISPUTE_EVIDENCE_VIEWED' and entity_id = '90000000-0000-0000-0000-000000000001'),
          'no idempotency key; source USER');
select ok(not exists(select 1 from public.audit_logs where operation = 'DISPUTE_EVIDENCE_VIEWED'
            and (after::text ~* '(tickets/|orders/|\+234|203\.0)')), 'the audit holds no path, phone or ip');
select is((select provolatile from pg_proc where oid = 'public.get_order_dispute_evidence(uuid)'::regprocedure),
          'v'::"char", 'the function is volatile');
select ok((select prosecdef from pg_proc where oid = 'public.get_order_dispute_evidence(uuid)'::regprocedure),
          'the function is security definer');

-- ── the grants sweep: one assertion per function per role ───────────────
-- expected = which of (anon, authenticated, service_role) may execute
create temp table want (sig text, a boolean, u boolean, s boolean);
insert into want values
  -- service_role only
  ('public.web_active_refund_policy()', false, false, true),
  ('public.start_web_phone_verification(text,text,inet)', false, false, true),
  ('public.confirm_web_phone_verification(uuid,text,text)', false, false, true),
  ('public.place_web_order(uuid,text,jsonb,jsonb,jsonb,text,numeric,jsonb,uuid,boolean,text,inet,text)', false, false, true),
  ('public.log_message_delivery(uuid,text,text,text,text,uuid,text)', false, false, true),
  ('public.request_ticket_attachment(uuid,text,text,text,bigint)', false, false, true),
  ('public.storage_purge_batch(integer)', false, false, true),
  ('public.storage_purge_done(uuid[])', false, false, true),
  ('public.add_ticket_message(uuid,text,text,text,uuid[])', false, false, true),
  -- authenticated
  ('public.request_staff_ticket_attachment(uuid,uuid,text,bigint)', false, true, false),
  ('public.mark_order_dispatched(uuid,uuid,text,text,text)', false, true, false),
  ('public.mark_delivery_pin_sent(uuid,uuid,text,text)', false, true, false),
  ('public.resend_delivery_pin(uuid,uuid,text,text)', false, true, false),
  ('public.mark_order_delivered(uuid,uuid,text,uuid)', false, true, false),
  ('public.request_delivery_photo(uuid,uuid,text,bigint)', false, true, false),
  ('public.get_order_dispute_evidence(uuid)', false, true, false),
  ('public.my_support_message_ticket_ids()', false, true, false),
  ('public.my_fulfilment_order_ids()', false, true, false),
  ('public.my_support_attachment_paths()', false, true, false),
  ('public.my_delivery_proof_paths()', false, true, false),
  -- internal helpers: no grant at all
  ('public.web_category_sellable(text)', false, false, false),
  ('public.claim_support_attachments(uuid,uuid,uuid[],text)', false, false, false),
  ('public.cleanup_pending_upload_slots()', false, false, false),
  ('public.fulfilment_can_dispatch(public.tenant_users,public.orders)', false, false, false),
  ('public.fulfilment_delivery_path(public.tenant_users,public.orders)', false, false, false),
  ('public.fulfilment_lock_order(public.tenant_users,uuid)', false, false, false),
  ('public.fulfilment_today()', false, false, false),
  ('public.assert_gateway_proof(text)', false, false, false),
  ('public.upload_slot_extension(text,bigint)', false, false, false),
  ('public.support_new_slot(public.support_tickets,text,uuid,text,bigint)', false, false, false),
  ('public.refund_policies_immutable()', false, false, false),
  ('public.cleanup_web_phone_verifications()', false, false, false);
-- reply_ticket keeps its A3 grant: authenticated, and (as in A3) service_role
select is((select count(*) from want), 32::bigint, 'thirty-two functions in the sweep');
select ok(to_regprocedure(sig) is not null, sig || ' exists') from want order by sig;
select ok(coalesce(has_function_privilege('anon', to_regprocedure(sig), 'execute'), false) = a, 'anon: ' || sig)
  from want order by sig;
select ok(coalesce(has_function_privilege('authenticated', to_regprocedure(sig), 'execute'), false) = u, 'authenticated: ' || sig)
  from want order by sig;
select ok(coalesce(has_function_privilege('service_role', to_regprocedure(sig), 'execute'), false) = s, 'service_role: ' || sig)
  from want order by sig;
select ok(has_function_privilege('authenticated', 'public.reply_ticket(uuid,uuid,text,uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.reply_ticket(uuid,uuid,text,uuid[])', 'execute'),
          'reply_ticket keeps its A3 grant');

select * from finish();
rollback;
