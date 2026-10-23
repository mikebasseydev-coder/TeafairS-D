-- Addendum A5 §3.1–3.2, §3.4: refund policy, sellable categories, catalogue notes.
begin;
create extension if not exists pgtap with schema extensions;

select plan(10);

-- the TEAFAIR tenant is seeded in every environment (005)
insert into public.central_products (tenant_id, sku_code, product_name, brand, category, unit_price, wholesale_price)
select t.id, v.sku, v.name, 'Teafair', v.cat, v.price, v.wholesale
  from public.tenants t,
       (values ('TEA-1', 'Black tea', 'Beverages', 500, 400),
               ('GAD-1', 'Charger',   'Gadgets',    900, 700)) as v(sku, name, cat, price, wholesale)
 where t.code = 'TEAFAIR';

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
      and not has_table_privilege('authenticated', 'public.refund_policies', 'select'),
  'policy table not client-readable');
select ok(position('PLACEHOLDER' in (select content from public.refund_policies where version_tag = 'v2.0-food')) > 0,
  'seed marked for legal review');

select * from finish();
rollback;
