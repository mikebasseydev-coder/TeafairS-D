-- Per-tenant sale categories (NCC licence) and NAFDAC numbers on products.
--
-- A5 made a category sellable when the active refund policy covers it, for
-- every tenant at once. TELECOM may only ever be sold by Sureach Nigeria
-- Limited, which holds the NCC licence, so each tenant now carries its own
-- allowed categories. Regulated categories (FOOD, COSMETICS) need a NAFDAC
-- number before a product can be active.

-- ── tenant_allowed_categories ───────────────────────────────────────────
-- A platform decision per tenant, written by migration only (like
-- refund_policies): there is no RPC. Members read their own tenant's rows.
create table public.tenant_allowed_categories (
  tenant_id   uuid not null references public.tenants (id) on delete restrict,
  category    text not null check (category in ('FOOD', 'COSMETICS', 'ELECTRONICS', 'TELECOM')),
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, category)
);
alter table public.tenant_allowed_categories enable row level security;
revoke all on public.tenant_allowed_categories from anon, authenticated, service_role;
grant select on public.tenant_allowed_categories to authenticated;
create trigger tenant_allowed_categories_set_updated_at before update on public.tenant_allowed_categories
  for each row execute function public.set_updated_at();

create policy tenant_allowed_categories_select_tenant_member on public.tenant_allowed_categories
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── guard: TELECOM is Sureach's alone; no withdrawal under live products ─
-- Withdrawing a category while active products use it would leave them on
-- sale without permission, so the products are deactivated first.
create function public.tenant_allowed_categories_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and (new.tenant_id, new.category) is distinct from (old.tenant_id, old.category) then
    raise exception 'a tenant category row cannot be moved; delete it and insert a new one'
      using errcode = 'P0001';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.enabled and new.category = 'TELECOM'
     and new.tenant_id <> '5eac0000-0000-4000-8000-000000000001' then
    raise exception 'Only Sureach Nigeria Limited holds the NCC licence to sell TELECOM products.'
      using errcode = 'P0001';
  end if;
  if (tg_op = 'DELETE' and old.enabled) or (tg_op = 'UPDATE' and old.enabled and not new.enabled) then
    if exists (select 1 from public.central_products p
                where p.tenant_id = old.tenant_id and p.sale_category = old.category and p.is_active) then
      raise exception 'Deactivate this tenant''s % products before withdrawing the category.', old.category
        using errcode = 'P0001';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;
revoke all on function public.tenant_allowed_categories_guard() from public, anon, authenticated, service_role;

create trigger tenant_allowed_categories_guard
  before insert or update or delete on public.tenant_allowed_categories
  for each row execute function public.tenant_allowed_categories_guard();

-- ── every tenant starts with FOOD and COSMETICS ─────────────────────────
create function public.tenants_default_categories()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.tenant_allowed_categories (tenant_id, category)
  values (new.id, 'FOOD'), (new.id, 'COSMETICS')
  on conflict do nothing;
  return null;
end;
$$;
revoke all on function public.tenants_default_categories() from public, anon, authenticated, service_role;

create trigger tenants_default_categories after insert on public.tenants
  for each row execute function public.tenants_default_categories();

insert into public.tenant_allowed_categories (tenant_id, category)
select t.id, c.category
  from public.tenants t
 cross join (values ('FOOD'), ('COSMETICS')) as c(category)
on conflict do nothing;

-- ── Sureach Nigeria Limited ─────────────────────────────────────────────
-- The NCC licence holder, wholly owned by Teafair's owner. Seeded here for the
-- same reason as TEAFAIR (20261006130600): a real business entity that must
-- exist in every environment, with a fixed id that the guard above names.
insert into public.tenants (id, name, code, status)
values ('5eac0000-0000-4000-8000-000000000001', 'Sureach Nigeria Limited', 'SUREACH', 'ACTIVE')
on conflict (id) do nothing;

insert into public.tenant_settings (tenant_id)
values ('5eac0000-0000-4000-8000-000000000001')
on conflict (tenant_id) do nothing;

insert into public.tenant_allowed_categories (tenant_id, category)
values ('5eac0000-0000-4000-8000-000000000001', 'ELECTRONICS'),
       ('5eac0000-0000-4000-8000-000000000001', 'TELECOM')
on conflict do nothing;

-- ── products: the category must be allowed for the tenant ───────────────
-- Checked on insert, on a category or tenant change, and on activation.
create function public.central_products_category_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (tg_op = 'INSERT'
      or new.tenant_id is distinct from old.tenant_id
      or new.sale_category is distinct from old.sale_category
      or (new.is_active and not old.is_active))
     and not exists (select 1 from public.tenant_allowed_categories a
                      where a.tenant_id = new.tenant_id and a.category = new.sale_category and a.enabled) then
    raise exception 'Tenant is not authorized to sell products in category %.', new.sale_category
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.central_products_category_guard() from public, anon, authenticated, service_role;

create trigger central_products_category_guard
  before insert or update of tenant_id, sale_category, is_active on public.central_products
  for each row execute function public.central_products_category_guard();

-- ── products: NAFDAC number ─────────────────────────────────────────────
-- Upper-case letters and digits in hyphenated groups (A7-0123, LG-IKJ-02-2134).
-- An active FOOD or COSMETICS product must carry one. The requirement is
-- NOT VALID: every new or changed row is checked at once, but products that
-- already exist on push (all FOOD by A5's default) are not, so the push cannot
-- fail on them. Once their numbers are loaded, validate it (supabase/CLAUDE.md).
alter table public.central_products
  add column nafdac_number text
    constraint central_products_nafdac_format
      check (length(nafdac_number) <= 32 and nafdac_number ~ '^[A-Z0-9]+(-[A-Z0-9]+){1,5}$');
alter table public.central_products
  add constraint central_products_nafdac_required
    check (not is_active or sale_category not in ('FOOD', 'COSMETICS') or nafdac_number is not null) not valid;

-- ── Purerigin Coconut Oil (Teafair house brand) ─────────────────────────
-- NAFDAC-registered and branded for skin, hair and body care. Seeded inactive
-- at zero price: the catalogue owner sets the real prices, then activates it.
insert into public.central_products (tenant_id, sku_code, product_name, brand, category,
                                     sale_category, nafdac_number, unit_price, wholesale_price, is_active)
values ('7eaf0000-0000-4000-8000-000000000001', 'PURERIGIN-COCONUT-OIL', 'Purerigin Coconut Oil',
        'Purerigin', 'Skin and hair care', 'COSMETICS', 'LG-IKJ-02-2134', 0, 0, false)
on conflict (tenant_id, sku_code) do update
  set sale_category = excluded.sale_category, nafdac_number = excluded.nafdac_number;

-- ── dispute evidence: the A5 bundle, with NAFDAC facts on each line ─────
create or replace function public.get_order_dispute_evidence(p_order_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_order  public.orders;
  v_policy public.refund_policies;
  v_bundle jsonb;
begin
  -- a missing order and another tenant's order get the same answer
  select * into v_order from public.orders o where o.id = p_order_id;
  if not found or v_order.tenant_id <> v_me.tenant_id then
    raise exception 'not permitted to view the evidence for this order' using errcode = '42501';
  end if;

  select * into v_policy from public.refund_policies rp where rp.version_tag = v_order.policy_version_tag;

  v_bundle := jsonb_build_object(
    'order', jsonb_build_object(
      'order_id', v_order.id,
      'public_reference', v_order.public_reference,
      'channel', v_order.channel,
      'status', v_order.status,
      'payment_route', v_order.payment_route,
      'total_amount', v_order.total_amount,
      'created_at', v_order.created_at),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', i.sku_code,
               'sale_category', cp.sale_category,
               'nafdac_regulated', cp.sale_category in ('FOOD', 'COSMETICS'),
               'nafdac_number', cp.nafdac_number,
               'qty', i.qty,
               'unit_price', i.unit_price,
               'line_total', i.line_total) order by i.sku_code)
        from public.order_items i
        join public.central_products cp on cp.tenant_id = i.tenant_id and cp.sku_code = i.sku_code
       where i.tenant_id = v_order.tenant_id and i.order_id = v_order.id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'payment_id', p.id,
               'paystack_reference', p.paystack_reference,
               'amount', p.amount,
               'payment_status', p.payment_status,
               'created_at', p.created_at,
               'settlement', (select jsonb_build_object('status', c.status, 'settled_at', c.settled_at)
                                from public.commission_records c
                               where c.tenant_id = p.tenant_id and c.payment_id = p.id))
             order by p.created_at, p.id)
        from public.payments p
       where p.tenant_id = v_order.tenant_id and p.order_id = v_order.id), '[]'::jsonb),
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'payment_id', a.entity_id,
               'refund_id', a.after ->> 'refund_id',
               'kind', case a.operation when 'PARTIAL_REFUND' then 'PARTIAL' else 'FULL' end,
               'reason', a.after ->> 'reason',
               'amount_minor', (a.after ->> 'amount_minor')::bigint,
               'currency', a.after ->> 'currency',
               'recorded_at', a.created_at) order by a.created_at, a.id)
        from public.audit_logs a
       where a.tenant_id = v_order.tenant_id
         and a.entity_type = 'payments'
         and a.operation in ('apply_paystack_refund', 'PARTIAL_REFUND')
         and a.entity_id in (select p.id::text from public.payments p
                              where p.tenant_id = v_order.tenant_id and p.order_id = v_order.id)), '[]'::jsonb),
    'consent', jsonb_build_object(
      'policy_version_tag', v_order.policy_version_tag,
      'policy_accepted_at', v_order.policy_accepted_at,
      'consent_ip', (select host(c.consent_ip) from public.order_contacts c
                      where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id),
      'policy_title', v_policy.title,
      'content', v_policy.content),
    'contact', (select jsonb_build_object(
                  'customer_name', c.customer_name,
                  'customer_phone', c.customer_phone,
                  'customer_email', c.customer_email,
                  'delivery_address', c.delivery_address,
                  'phone_verified_at', c.phone_verified_at,
                  'phone_verified_channel', c.phone_verified_channel)
                  from public.order_contacts c
                 where c.tenant_id = v_order.tenant_id and c.order_id = v_order.id),
    'fulfilment', (select jsonb_build_object(
                     'dispatched_at', f.dispatched_at,
                     'tracking_reference', f.tracking_reference,
                     'delivered_at', f.delivered_at,
                     'delivered_via', f.delivered_via,
                     'damage_claim_deadline', f.damage_claim_deadline,
                     -- a delivery is recorded only after the right code
                     'pin_verified', f.delivered_at is not null,
                     'delivery_photo', case when f.delivery_photo_path is null then null
                                            else jsonb_build_object('bucket', 'delivery-proofs',
                                                                    'storage_path', f.delivery_photo_path) end)
                     from public.order_fulfilments f
                    where f.tenant_id = v_order.tenant_id and f.order_id = v_order.id),
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ticket_id', t.id,
               'public_reference', t.public_reference,
               'kind', t.kind,
               'category', t.category,
               'status', t.status,
               'within_damage_window', t.within_damage_window,
               'created_at', t.created_at,
               'messages', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'sender_type', m.sender_type,
                          'body', m.body,
                          'created_at', m.created_at,
                          'attachments', coalesce((
                            select jsonb_agg(jsonb_build_object(
                                     'attachment_id', u.id,
                                     'mime_type', u.mime_type,
                                     'size_bytes', u.size_bytes,
                                     'bucket', u.bucket,
                                     'storage_path', u.storage_path) order by u.claimed_at, u.id)
                              from public.upload_slots u
                             where u.tenant_id = m.tenant_id and u.ticket_id = m.ticket_id
                               and u.message_id = m.id), '[]'::jsonb))
                        order by m.created_at, m.id)
                   from public.support_messages m
                  where m.tenant_id = t.tenant_id and m.ticket_id = t.id), '[]'::jsonb))
             order by t.created_at, t.id)
        from public.support_tickets t
       where t.tenant_id = v_order.tenant_id and t.order_id = v_order.id), '[]'::jsonb));

  perform public.write_audit(v_order.tenant_id, 'DISPUTE_EVIDENCE_VIEWED', 'orders', v_order.id::text,
                             null, jsonb_build_object('order_id', v_order.id), null);
  return v_bundle;
end;
$$;
revoke all on function public.get_order_dispute_evidence(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_order_dispute_evidence(uuid) to authenticated;
