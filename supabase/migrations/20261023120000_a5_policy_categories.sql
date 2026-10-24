-- Addendum A5 §3.1–3.2, §3.4 — refund policy versions, sellable product
-- categories, and the catalogue's refund notes.

-- ── refund_policies (platform table, not tenant-owned) ──────────────────
-- Versions are written by migration or seed only; there is no RPC. RLS on,
-- no policy, no client grant: the storefront reads through
-- web_active_refund_policy() via the public gateway.
create table public.refund_policies (
  id            uuid primary key default gen_random_uuid(),
  version_tag   text not null unique check (version_tag ~ '^v[0-9]+\.[0-9]+-[a-z0-9-]+$'),
  title         text not null,
  content       text not null,
  categories    text[] not null,
  is_active     boolean not null default false,
  published_at  timestamptz,
  created_at    timestamptz not null default now()
);
alter table public.refund_policies enable row level security;
revoke all on public.refund_policies from anon, authenticated, service_role;
-- exactly one active version
create unique index refund_policies_one_active on public.refund_policies (is_active) where is_active;

-- ── versions are immutable (R20) ────────────────────────────────────────
-- An order's consent points at version_tag, and the dispute evidence bundle
-- shows that version's text: editing a row in place would rewrite what every
-- past buyer accepted. Only is_active may change (and published_at, when a
-- version is activated); new wording ships as a new version. Rows are never
-- deleted. The function is internal: trigger only, no grant.
create function public.refund_policies_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'refund policy versions cannot be deleted; publish a new version and activate it instead'
      using errcode = 'P0001';
  end if;
  if (new.id, new.version_tag, new.title, new.content, new.categories, new.created_at)
       is distinct from (old.id, old.version_tag, old.title, old.content, old.categories, old.created_at)
     or (new.published_at is distinct from old.published_at and not (new.is_active and not old.is_active)) then
    raise exception 'refund policy % is immutable: publish a new version (e.g. v2.1-food) instead of editing it', old.version_tag
      using errcode = 'P0001',
            hint = 'Only is_active may change, and published_at when activating.';
  end if;
  return new;
end;
$$;
revoke all on function public.refund_policies_immutable() from public, anon, authenticated, service_role;

create trigger refund_policies_immutable
  before update or delete on public.refund_policies
  for each row execute function public.refund_policies_immutable();
create trigger refund_policies_no_truncate
  before truncate on public.refund_policies
  for each statement execute function public.refund_policies_immutable();

-- PLACEHOLDER wording: counsel must review it before go-live.
insert into public.refund_policies (version_tag, title, content, categories, is_active, published_at)
values (
  'v2.0-food',
  'Refund policy for food orders',
  $md$<!-- PLACEHOLDER: requires legal review before go-live -->
# Refund policy for food orders

## General terms

- Approved refunds are paid back to the original payment source through Paystack within 5 to 7 business days of approval.
- If you have a problem with an order, contact Teafair support first, before you open a dispute with your bank. We will work to resolve it quickly.

## Food orders

- Opened food items cannot be refunded.
- If food is damaged in transit, report it within 24 hours of delivery and include photos of the damage.

## WhatsApp number

- You must give a WhatsApp number that you control. Order updates and your delivery code are sent to that number.
- If an order cannot be completed because the number you gave was not reachable on WhatsApp, that is not grounds for a refund dispute.
$md$,
  '{FOOD}', true, now());

-- ── product categories ──────────────────────────────────────────────────
-- The free-text `category` stays as the merchandising label.
alter table public.central_products
  add column sale_category text not null default 'FOOD'
    check (sale_category in ('FOOD', 'ELECTRONICS', 'TELECOM'));

-- ── internal: is a category covered by the active policy? ───────────────
create function public.web_category_sellable(p_category text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.refund_policies rp
                  where rp.is_active and p_category = any (rp.categories));
$$;

-- ── web_active_refund_policy (service_role, via storefront-refund-policy) ─
create function public.web_active_refund_policy()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
           'version_tag', rp.version_tag, 'title', rp.title, 'content', rp.content,
           'categories', to_jsonb(rp.categories), 'published_at', rp.published_at)
    from public.refund_policies rp
   where rp.is_active;
$$;

-- ── storefront_catalogue ────────────────────────────────────────────────
-- The A1/D1 body unchanged, except unsellable products are hidden and the
-- response carries the policy version and a refund note per sellable category.
create or replace function public.storefront_catalogue(p_code text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_code public.agent_codes := public.web_storefront_code(p_code);
begin
  return jsonb_build_object(
    'code', v_code.code,
    'tenant', (select jsonb_build_object('name', t.name, 'logo_url', t.logo_url)
                 from public.tenants t where t.id = v_code.tenant_id),
    'currency', coalesce((select s.currency from public.tenant_settings s where s.tenant_id = v_code.tenant_id), 'NGN'),
    'discount', case when v_code.discount_type is null then null
                     else jsonb_build_object('type', v_code.discount_type, 'value', v_code.discount_value) end,
    'venue', (select case when ft.venue_name is null then null
                          else jsonb_build_object('name', ft.venue_name, 'channel', ft.venue_channel) end
                from public.fintech_terminals ft
               where ft.tenant_id = v_code.tenant_id and ft.id = v_code.terminal_id),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku_code', p.sku_code, 'product_name', p.product_name, 'brand', p.brand,
               'category', p.category, 'unit_price', p.unit_price, 'description', p.description)
             order by p.brand, p.product_name)
        from public.central_products p
       where p.tenant_id = v_code.tenant_id and p.is_active
         and public.web_category_sellable(p.sale_category)), '[]'::jsonb),
    'refund_policy', (select jsonb_build_object('version_tag', rp.version_tag)
                        from public.refund_policies rp where rp.is_active),
    'refund_notes', coalesce((
      select jsonb_object_agg(c, case c
               when 'FOOD' then 'Opened food items can''t be refunded. Report transit damage within 24 hours of delivery with photos.'
             end)
        from public.refund_policies rp, unnest(rp.categories) as c
       where rp.is_active and c = 'FOOD'), '{}'::jsonb));
end;
$$;

-- ── grants ──────────────────────────────────────────────────────────────
revoke all on function public.web_category_sellable(text) from public, anon, authenticated, service_role;
revoke all on function public.web_active_refund_policy() from public, anon, authenticated, service_role;
revoke all on function public.storefront_catalogue(text) from public, anon, authenticated, service_role;
grant execute on function public.web_active_refund_policy() to service_role;
grant execute on function public.storefront_catalogue(text) to service_role;
