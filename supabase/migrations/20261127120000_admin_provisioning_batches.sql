-- Admin provisioning and batch loads (pre-Spec B, 2026-11-27).
--
-- The audit before Spec B found three gaps in the TeafairWeb admin workflow:
--
--   1. provision_tenant(key, name, preferred_code): no RPC created a tenant;
--      TEAFAIR and SUREACH are seeded by migration. PLATFORM_SUPER_ADMIN only.
--      The code is normalised to the tenants CHECK (^[A-Z0-9_]{2,16}$; the
--      schema has no hyphen) and made collision-free with _02, _03, ... The
--      insert triggers already give the tenant its chat channel and its FOOD
--      and COSMETICS categories; tenant_settings is created here with its
--      defaults, as the TEAFAIR and SUREACH seeds do. The first staff come
--      from the existing platform RPCs (appoint_client_service_manager,
--      appoint_zone_manager, create_zone).
--   2. upsert_tenant_skus(key, decision_id, items): the batch form of
--      upsert_catalogue_product (the CSV upload). Same role (the CSM), same
--      citation (a CATALOGUE decision, A6 §16.4: no backdoor), same fields.
--      Batch rules: 1-500 items, each sku_code ^[A-Z0-9_-]{3,40}$ and unique
--      in the batch, positive pack factors. An item that changes nothing is
--      skipped and writes no audit row. Replies {created, updated, skipped}.
--   3. post_opening_stock(key, decision_id, warehouse_id, items, reference):
--      the first stock of a warehouse, as RECEIPT movements (insert-only) and
--      batch increments (never an overwrite). The CSM or the logistics
--      manager, citing a STOCK decision, as record_stock_receipt. A warehouse
--      that already has any movement is refused: later stock is a receipt.
--
-- The tenant comes from the caller's live membership (assert_tenant_role);
-- none of these takes a tenant id. No audit row or reply carries personal
-- data: the tenant, product and movement rows hold none.

-- ── provision_tenant ────────────────────────────────────────────────────
create function public.provision_tenant(
  p_idempotency_key uuid, p_name text, p_preferred_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := public.assert_platform_role(array['PLATFORM_SUPER_ADMIN']::public.platform_role_enum[]);
  v_prior  jsonb;
  v_name   text := btrim(coalesce(p_name, ''));
  v_base   text;
  v_code   text;
  v_n      integer := 1;
  v_tenant public.tenants;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'provision_tenant',
    jsonb_build_object('name', p_name, 'preferred_code', p_preferred_code));
  if v_prior is not null then
    return v_prior;
  end if;

  if v_name = '' or length(v_name) > 120 then
    raise exception 'a tenant needs a name of 1 to 120 characters' using errcode = 'P0001';
  end if;

  -- upper-case, every run of other characters one underscore, no edge underscores
  v_base := btrim(regexp_replace(upper(coalesce(nullif(btrim(p_preferred_code), ''), v_name)),
                                 '[^A-Z0-9]+', '_', 'g'), '_');
  v_base := rtrim(left(v_base, 13), '_');
  if length(v_base) < 2 then
    raise exception 'the tenant code needs at least two letters or digits' using errcode = 'P0001';
  end if;

  -- one provisioning at a time, so two callers cannot pick the same suffix
  perform pg_advisory_xact_lock(hashtext('public.provision_tenant'));
  v_code := v_base;
  while exists (select 1 from public.tenants t where t.code = v_code) loop
    v_n := v_n + 1;
    if v_n > 99 then
      raise exception 'no free tenant code for %', v_base using errcode = 'P0001';
    end if;
    v_code := v_base || '_' || lpad(v_n::text, 2, '0');
  end loop;

  insert into public.tenants (name, code, status)
  values (v_name, v_code, 'ACTIVE')
  returning * into v_tenant;
  insert into public.tenant_settings (tenant_id) values (v_tenant.id);

  perform public.write_audit(v_tenant.id, 'provision_tenant', 'tenants', v_tenant.id::text,
                             null, to_jsonb(v_tenant), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('tenant_id', v_tenant.id, 'code', v_tenant.code, 'name', v_tenant.name,
                       'status', v_tenant.status));
end;
$$;
revoke all on function public.provision_tenant(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.provision_tenant(uuid, text, text) to authenticated;

-- ── upsert_tenant_skus ──────────────────────────────────────────────────
create function public.upsert_tenant_skus(
  p_idempotency_key uuid, p_decision_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_allowed constant text[] := array['sku_code', 'product_name', 'brand', 'category', 'sale_category', 'unit_price',
    'wholesale_price', 'description', 'nafdac_number', 'carton_units', 'break_bulk_units', 'is_active'];
  v_required constant text[] := array['product_name', 'brand', 'category', 'sale_category', 'unit_price', 'wholesale_price'];
  v_item    jsonb;
  v_i       integer := 0;
  v_key     text;
  v_sku     text;
  v_seen    text[] := '{}';
  v_before  public.central_products;
  v_rec     public.central_products;
  v_after   public.central_products;
  v_created integer := 0;
  v_updated integer := 0;
  v_skipped integer := 0;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_tenant_skus',
    jsonb_build_object('decision_id', p_decision_id, 'items', p_items));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this catalogue change' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'CATALOGUE');

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 500 then
    raise exception 'p_items must be an array of 1 to 500 products' using errcode = 'P0001';
  end if;

  -- validate the whole batch before the first write
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_i := v_i + 1;
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'item % must be a JSON object', v_i using errcode = 'P0001';
    end if;
    for v_key in select jsonb_object_keys(v_item) loop
      if not (v_key = any (v_allowed)) then
        raise exception 'item %: unknown product field %', v_i, v_key using errcode = 'P0001';
      end if;
    end loop;
    v_sku := v_item ->> 'sku_code';
    if v_sku is null or v_sku !~ '^[A-Z0-9_-]{3,40}$' then
      raise exception 'item %: sku_code must be 3 to 40 upper-case letters, digits, _ or -', v_i using errcode = 'P0001';
    end if;
    if v_sku = any (v_seen) then
      raise exception 'item %: sku_code % appears twice in this batch', v_i, v_sku using errcode = 'P0001';
    end if;
    v_seen := v_seen || v_sku;
    foreach v_key in array array['carton_units', 'break_bulk_units'] loop
      if (v_item -> v_key) is not null and jsonb_typeof(v_item -> v_key) <> 'null'
         and (jsonb_typeof(v_item -> v_key) <> 'number' or (v_item ->> v_key)::numeric <= 0
              or (v_item ->> v_key)::numeric <> trunc((v_item ->> v_key)::numeric)) then
        raise exception 'item %: % must be a positive whole number', v_i, v_key using errcode = 'P0001';
      end if;
    end loop;
  end loop;

  v_i := 0;
  -- sku order, so concurrent batches lock rows in the same order
  for v_item in select value from jsonb_array_elements(p_items) order by value ->> 'sku_code' loop
    v_i := v_i + 1;
    v_sku := v_item ->> 'sku_code';
    select * into v_before from public.central_products
     where tenant_id = v_me.tenant_id and sku_code = v_sku for update;

    if not found then
      foreach v_key in array v_required loop
        if (v_item -> v_key) is null or jsonb_typeof(v_item -> v_key) = 'null' then
          raise exception 'a new product (%) needs %', v_sku, v_key using errcode = 'P0001';
        end if;
      end loop;
      v_rec := jsonb_populate_record(null::public.central_products, v_item);
      insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
          unit_price, wholesale_price, description, nafdac_number, carton_units, break_bulk_units, is_active, decision_id)
      values (v_me.tenant_id, v_sku, v_rec.product_name, v_rec.brand, v_rec.category, v_rec.sale_category,
          v_rec.unit_price, v_rec.wholesale_price, v_rec.description, v_rec.nafdac_number, v_rec.carton_units,
          v_rec.break_bulk_units, coalesce(v_rec.is_active, true), p_decision_id)
      returning * into v_after;
      v_created := v_created + 1;
      perform public.write_audit(v_me.tenant_id, 'upsert_tenant_skus', 'central_products', v_after.id::text,
                                 null, to_jsonb(v_after), p_idempotency_key);
    else
      v_rec := jsonb_populate_record(v_before, v_item - 'sku_code');
      if not exists (select 1 from unnest(v_allowed) k
                      where to_jsonb(v_rec) -> k is distinct from to_jsonb(v_before) -> k) then
        v_skipped := v_skipped + 1;
        continue;
      end if;
      update public.central_products
         set product_name = v_rec.product_name, brand = v_rec.brand, category = v_rec.category,
             sale_category = v_rec.sale_category, unit_price = v_rec.unit_price,
             wholesale_price = v_rec.wholesale_price, description = v_rec.description,
             nafdac_number = v_rec.nafdac_number, carton_units = v_rec.carton_units,
             break_bulk_units = v_rec.break_bulk_units, is_active = v_rec.is_active,
             decision_id = p_decision_id
       where id = v_before.id
      returning * into v_after;
      v_updated := v_updated + 1;
      perform public.write_audit(v_me.tenant_id, 'upsert_tenant_skus', 'central_products', v_after.id::text,
                                 to_jsonb(v_before), to_jsonb(v_after), p_idempotency_key);
    end if;
  end loop;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped));
end;
$$;
revoke all on function public.upsert_tenant_skus(uuid, uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.upsert_tenant_skus(uuid, uuid, jsonb) to authenticated;

-- ── post_opening_stock ──────────────────────────────────────────────────
create function public.post_opening_stock(
  p_idempotency_key uuid, p_decision_id uuid, p_warehouse_id uuid, p_items jsonb, p_reference text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(
              array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_ref     text := nullif(btrim(coalesce(p_reference, '')), '');
  v_item    jsonb;
  v_i       integer := 0;
  v_key     text;
  v_seen    text[] := '{}';
  v_sku     text;
  v_batchno text;
  v_qty     numeric;
  v_exp     timestamptz;
  v_before  public.inventory_batches;
  v_batch   public.inventory_batches;
  v_mov     uuid;
  v_lines   integer := 0;
  v_total   numeric := 0;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'post_opening_stock',
    jsonb_build_object('decision_id', p_decision_id, 'warehouse_id', p_warehouse_id,
                       'items', p_items, 'reference', p_reference));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this stock movement' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'STOCK');
  perform public.stock_assert_warehouse(v_me.tenant_id, p_warehouse_id);
  -- a goods-received note number, never a name or a phone number
  if v_ref is not null and v_ref !~ '^[A-Za-z0-9][A-Za-z0-9 _./-]{0,79}$' then
    raise exception 'the reference is up to 80 letters, digits, spaces and _ . / -' using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 500 then
    raise exception 'p_items must be an array of 1 to 500 lines' using errcode = 'P0001';
  end if;

  -- the warehouse row serialises opening loads; any earlier movement refuses
  perform 1 from public.warehouses w where w.id = p_warehouse_id for update;
  if exists (select 1 from public.stock_movements m
              where m.tenant_id = v_me.tenant_id
                and (m.warehouse_id = p_warehouse_id or m.to_warehouse_id = p_warehouse_id)) then
    raise exception 'this warehouse already has stock movements; record a stock receipt instead'
      using errcode = 'P0001';
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_i := v_i + 1;
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'line % must be a JSON object', v_i using errcode = 'P0001';
    end if;
    for v_key in select jsonb_object_keys(v_item) loop
      if not (v_key = any (array['sku_code', 'batch_number', 'quantity', 'expires_at'])) then
        raise exception 'line %: unknown field %', v_i, v_key using errcode = 'P0001';
      end if;
    end loop;
    if jsonb_typeof(v_item -> 'quantity') is distinct from 'number' or (v_item ->> 'quantity')::numeric <= 0 then
      raise exception 'line %: quantity must be greater than zero', v_i using errcode = 'P0001';
    end if;
    v_sku := v_item ->> 'sku_code';
    v_batchno := btrim(v_item ->> 'batch_number');
    perform public.stock_assert_sku(v_me.tenant_id, v_sku, v_batchno);
    if (v_sku || '|' || v_batchno) = any (v_seen) then
      raise exception 'line %: % batch % appears twice in this load', v_i, v_sku, v_batchno using errcode = 'P0001';
    end if;
    v_seen := v_seen || (v_sku || '|' || v_batchno);
  end loop;

  for v_item in select value from jsonb_array_elements(p_items)
                 order by value ->> 'sku_code', btrim(value ->> 'batch_number') loop
    v_sku := v_item ->> 'sku_code';
    v_batchno := btrim(v_item ->> 'batch_number');
    v_qty := (v_item ->> 'quantity')::numeric(14,3);
    v_exp := nullif(v_item ->> 'expires_at', '')::timestamptz;

    insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity, expires_at)
    values (v_me.tenant_id, p_warehouse_id, v_sku, v_batchno, 0, v_exp)
    on conflict (warehouse_id, sku_code, batch_number) do nothing;

    select * into v_before from public.inventory_batches
     where warehouse_id = p_warehouse_id and sku_code = v_sku and batch_number = v_batchno for update;
    if v_exp is not null and v_before.expires_at is not null and v_before.expires_at <> v_exp then
      raise exception '% batch % already has a different expiry', v_sku, v_batchno using errcode = 'P0001';
    end if;

    update public.inventory_batches
       set quantity = quantity + v_qty, expires_at = coalesce(expires_at, v_exp)
     where id = v_before.id
    returning * into v_batch;

    insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity,
                                        reason, decision_id, recorded_by)
    values (v_me.tenant_id, 'RECEIPT', p_warehouse_id, v_sku, v_batchno, v_qty,
            'opening stock' || coalesce(': ' || v_ref, ''), p_decision_id, v_me.profile_id)
    returning id into v_mov;

    perform public.write_audit(v_me.tenant_id, 'post_opening_stock', 'stock_movements', v_mov::text,
                               to_jsonb(v_before), to_jsonb(v_batch), p_idempotency_key);
    v_lines := v_lines + 1;
    v_total := v_total + v_qty;
  end loop;

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('warehouse_id', p_warehouse_id, 'lines', v_lines, 'total_quantity', trim_scale(v_total)));
end;
$$;
revoke all on function public.post_opening_stock(uuid, uuid, uuid, jsonb, text) from public, anon, authenticated, service_role;
grant execute on function public.post_opening_stock(uuid, uuid, uuid, jsonb, text) to authenticated;
