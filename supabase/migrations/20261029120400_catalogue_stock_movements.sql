-- Addendum A6 §16.3, §16.4 (Monvelo Step 1c, Task 4) — the catalogue and stock
-- movements. The client service manager changes the catalogue; the CSM or the
-- logistics manager receives, transfers and adjusts stock. Each call cites a
-- current contact-report decision (CATALOGUE or STOCK). Every movement is one
-- insert-only stock_movements row.

-- ── central_products.decision_id ────────────────────────────────────────
alter table public.central_products add column decision_id uuid;
alter table public.central_products
  add constraint central_products_decision_fkey
  foreign key (tenant_id, decision_id) references public.contact_report_decisions (tenant_id, id) on delete restrict;
create index idx_central_products_decision on public.central_products (tenant_id, decision_id);

-- ── stock_movements ─────────────────────────────────────────────────────
create table public.stock_movements (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete restrict,
  kind            text not null check (kind in ('RECEIPT', 'TRANSFER', 'ADJUSTMENT')),
  warehouse_id    uuid not null,
  to_warehouse_id uuid,
  sku_code        text not null,
  batch_number    text not null check (length(btrim(batch_number)) > 0),
  quantity        numeric(14,3) not null,
  reason          text,
  decision_id     uuid not null,
  recorded_by     uuid not null references public.profiles (id) on delete restrict,
  created_at      timestamptz not null default now(),
  unique (tenant_id, id),
  check ((kind = 'ADJUSTMENT' and quantity <> 0) or (kind <> 'ADJUSTMENT' and quantity > 0)),
  check ((kind = 'TRANSFER') = (to_warehouse_id is not null)),
  check (to_warehouse_id is null or to_warehouse_id <> warehouse_id),
  check (kind <> 'ADJUSTMENT' or length(btrim(coalesce(reason, ''))) > 0),
  foreign key (tenant_id, warehouse_id)    references public.warehouses (tenant_id, id) on delete restrict,
  foreign key (tenant_id, to_warehouse_id) references public.warehouses (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sku_code)        references public.central_products (tenant_id, sku_code) on delete restrict,
  foreign key (tenant_id, decision_id)     references public.contact_report_decisions (tenant_id, id) on delete restrict
);
create index idx_stock_movements_tenant      on public.stock_movements (tenant_id, created_at desc);
create index idx_stock_movements_warehouse   on public.stock_movements (tenant_id, warehouse_id);
create index idx_stock_movements_to_warehouse on public.stock_movements (tenant_id, to_warehouse_id);
create index idx_stock_movements_sku         on public.stock_movements (tenant_id, sku_code);
create index idx_stock_movements_decision    on public.stock_movements (tenant_id, decision_id);
create index idx_stock_movements_recorded_by on public.stock_movements (recorded_by);

create or replace function public.stock_movements_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'stock movements are insert-only; record an adjustment' using errcode = 'P0001';
end;
$$;
revoke all on function public.stock_movements_insert_only() from public, anon, authenticated, service_role;
create trigger stock_movements_no_change before update or delete on public.stock_movements
  for each row execute function public.stock_movements_insert_only();
create trigger stock_movements_no_truncate before truncate on public.stock_movements
  for each statement execute function public.stock_movements_insert_only();

alter table public.stock_movements enable row level security;
revoke all on public.stock_movements from anon, authenticated, service_role;
grant select on public.stock_movements to authenticated;
create policy stock_movements_select on public.stock_movements for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- ── upsert_catalogue_product ────────────────────────────────────────────
create or replace function public.upsert_catalogue_product(
  p_idempotency_key uuid, p_decision_id uuid, p_product jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(array['CLIENT_SERVICE_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_allowed constant text[] := array['sku_code', 'product_name', 'brand', 'category', 'sale_category', 'unit_price',
    'wholesale_price', 'description', 'nafdac_number', 'carton_units', 'break_bulk_units', 'is_active'];
  v_required constant text[] := array['product_name', 'brand', 'category', 'sale_category', 'unit_price', 'wholesale_price'];
  v_key    text;
  v_sku    text;
  v_before public.central_products;
  v_rec    public.central_products;
  v_after  public.central_products;
  v_created boolean;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'upsert_catalogue_product',
    jsonb_build_object('decision_id', p_decision_id, 'product', p_product));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_product is null or jsonb_typeof(p_product) <> 'object' then
    raise exception 'p_product must be a JSON object' using errcode = 'P0001';
  end if;
  for v_key in select jsonb_object_keys(p_product) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'unknown product field %', v_key using errcode = 'P0001';
    end if;
  end loop;
  v_sku := btrim(p_product ->> 'sku_code');
  if v_sku is null or v_sku = '' then
    raise exception 'sku_code is required' using errcode = 'P0001';
  end if;

  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this catalogue change' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'CATALOGUE');

  select * into v_before from public.central_products
   where tenant_id = v_me.tenant_id and sku_code = v_sku for update;
  v_created := not found;

  if v_created then
    foreach v_key in array v_required loop
      if (p_product -> v_key) is null or jsonb_typeof(p_product -> v_key) = 'null' then
        raise exception 'a new product needs %', v_key using errcode = 'P0001';
      end if;
    end loop;
    v_rec := jsonb_populate_record(null::public.central_products, p_product);
    insert into public.central_products (tenant_id, sku_code, product_name, brand, category, sale_category,
        unit_price, wholesale_price, description, nafdac_number, carton_units, break_bulk_units, is_active, decision_id)
    values (v_me.tenant_id, v_sku, v_rec.product_name, v_rec.brand, v_rec.category, v_rec.sale_category,
        v_rec.unit_price, v_rec.wholesale_price, v_rec.description, v_rec.nafdac_number, v_rec.carton_units,
        v_rec.break_bulk_units, coalesce(v_rec.is_active, true), p_decision_id)
    returning * into v_after;
  else
    -- only the keys given change; sku_code is the identity
    v_rec := jsonb_populate_record(v_before, p_product - 'sku_code');
    update public.central_products
       set product_name = v_rec.product_name, brand = v_rec.brand, category = v_rec.category,
           sale_category = v_rec.sale_category, unit_price = v_rec.unit_price,
           wholesale_price = v_rec.wholesale_price, description = v_rec.description,
           nafdac_number = v_rec.nafdac_number, carton_units = v_rec.carton_units,
           break_bulk_units = v_rec.break_bulk_units, is_active = v_rec.is_active,
           decision_id = p_decision_id
     where id = v_before.id
    returning * into v_after;
  end if;

  perform public.write_audit(v_me.tenant_id, 'upsert_catalogue_product', 'central_products', v_after.id::text,
                             case when v_created then null else to_jsonb(v_before) end, to_jsonb(v_after),
                             p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('product_id', v_after.id, 'sku_code', v_after.sku_code, 'created', v_created));
end;
$$;
revoke all on function public.upsert_catalogue_product(uuid, uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.upsert_catalogue_product(uuid, uuid, jsonb) to authenticated, service_role;

-- ── internal: a warehouse of the caller's tenant ────────────────────────
create or replace function public.stock_assert_warehouse(p_tenant_id uuid, p_warehouse_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if p_warehouse_id is null
     or not exists (select 1 from public.warehouses w where w.id = p_warehouse_id and w.tenant_id = p_tenant_id) then
    raise exception 'warehouse not found in this tenant' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.stock_assert_warehouse(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.stock_assert_sku(p_tenant_id uuid, p_sku_code text, p_batch_number text)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if p_batch_number is null or length(btrim(p_batch_number)) = 0 then
    raise exception 'batch_number is required' using errcode = 'P0001';
  end if;
  if p_sku_code is null
     or not exists (select 1 from public.central_products p where p.tenant_id = p_tenant_id and p.sku_code = p_sku_code) then
    raise exception 'unknown sku_code' using errcode = 'P0001';
  end if;
end;
$$;
revoke all on function public.stock_assert_sku(uuid, text, text) from public, anon, authenticated, service_role;

create or replace function public.stock_insufficient(p_sku text, p_available numeric, p_requested numeric)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  raise exception 'insufficient stock' using errcode = 'TF001',
    detail = jsonb_build_object('sku_code', p_sku, 'available', trim_scale(p_available), 'requested', trim_scale(p_requested))::text;
end;
$$;
revoke all on function public.stock_insufficient(text, numeric, numeric) from public, anon, authenticated, service_role;

-- ── record_stock_receipt ────────────────────────────────────────────────
create or replace function public.record_stock_receipt(
  p_idempotency_key uuid, p_decision_id uuid, p_warehouse_id uuid, p_sku_code text,
  p_batch_number text, p_quantity numeric, p_expires_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(
             array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.inventory_batches;
  v_batch  public.inventory_batches;
  v_mov    uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_stock_receipt',
    jsonb_build_object('decision_id', p_decision_id, 'warehouse_id', p_warehouse_id, 'sku_code', p_sku_code,
                       'batch_number', p_batch_number, 'quantity', p_quantity, 'expires_at', p_expires_at));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'quantity must be greater than zero' using errcode = 'P0001';
  end if;
  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this stock movement' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'STOCK');
  perform public.stock_assert_warehouse(v_me.tenant_id, p_warehouse_id);
  perform public.stock_assert_sku(v_me.tenant_id, p_sku_code, p_batch_number);

  insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity, expires_at)
  values (v_me.tenant_id, p_warehouse_id, p_sku_code, p_batch_number, 0, p_expires_at)
  on conflict (warehouse_id, sku_code, batch_number) do nothing;

  select * into v_before from public.inventory_batches
   where warehouse_id = p_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number for update;
  if p_expires_at is not null and v_before.expires_at is not null and v_before.expires_at <> p_expires_at then
    raise exception 'this batch already has a different expiry' using errcode = 'P0001';
  end if;

  update public.inventory_batches
     set quantity = quantity + p_quantity, expires_at = coalesce(expires_at, p_expires_at)
   where id = v_before.id
  returning * into v_batch;

  insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, decision_id, recorded_by)
  values (v_me.tenant_id, 'RECEIPT', p_warehouse_id, p_sku_code, p_batch_number, p_quantity, p_decision_id, v_me.profile_id)
  returning id into v_mov;

  perform public.write_audit(v_me.tenant_id, 'record_stock_receipt', 'stock_movements', v_mov::text,
                             to_jsonb(v_before), to_jsonb(v_batch), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('movement_id', v_mov, 'batch_id', v_batch.id, 'quantity', v_batch.quantity));
end;
$$;
revoke all on function public.record_stock_receipt(uuid, uuid, uuid, text, text, numeric, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.record_stock_receipt(uuid, uuid, uuid, text, text, numeric, timestamptz) to authenticated, service_role;

-- ── record_stock_transfer ───────────────────────────────────────────────
create or replace function public.record_stock_transfer(
  p_idempotency_key uuid, p_decision_id uuid, p_from_warehouse_id uuid, p_to_warehouse_id uuid,
  p_sku_code text, p_batch_number text, p_quantity numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me      public.tenant_users := public.assert_tenant_role(
              array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior   jsonb;
  v_src_id  uuid;
  v_src     public.inventory_batches;
  v_dst     public.inventory_batches;
  v_src_new public.inventory_batches;
  v_dst_new public.inventory_batches;
  v_mov     uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_stock_transfer',
    jsonb_build_object('decision_id', p_decision_id, 'from', p_from_warehouse_id, 'to', p_to_warehouse_id,
                       'sku_code', p_sku_code, 'batch_number', p_batch_number, 'quantity', p_quantity));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'quantity must be greater than zero' using errcode = 'P0001';
  end if;
  if p_from_warehouse_id is not distinct from p_to_warehouse_id then
    raise exception 'a transfer needs two different warehouses' using errcode = 'P0001';
  end if;
  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this stock movement' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'STOCK');
  perform public.stock_assert_warehouse(v_me.tenant_id, p_from_warehouse_id);
  perform public.stock_assert_warehouse(v_me.tenant_id, p_to_warehouse_id);
  perform public.stock_assert_sku(v_me.tenant_id, p_sku_code, p_batch_number);

  select id into v_src_id from public.inventory_batches
   where warehouse_id = p_from_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number;
  if v_src_id is null then
    perform public.stock_insufficient(p_sku_code, 0, p_quantity);
  end if;

  -- the destination batch exists before both rows are locked, in id order
  insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity, expires_at)
  select v_me.tenant_id, p_to_warehouse_id, p_sku_code, p_batch_number, 0, s.expires_at
    from public.inventory_batches s where s.id = v_src_id
  on conflict (warehouse_id, sku_code, batch_number) do nothing;

  perform 1 from public.inventory_batches
   where warehouse_id in (p_from_warehouse_id, p_to_warehouse_id) and sku_code = p_sku_code and batch_number = p_batch_number
   order by id for update;

  select * into v_src from public.inventory_batches where id = v_src_id;
  select * into v_dst from public.inventory_batches
   where warehouse_id = p_to_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number;

  if v_src.quantity < p_quantity then
    perform public.stock_insufficient(p_sku_code, v_src.quantity, p_quantity);
  end if;
  if v_src.expires_at is not null and v_dst.expires_at is not null and v_src.expires_at <> v_dst.expires_at then
    raise exception 'this batch already has a different expiry' using errcode = 'P0001';
  end if;

  update public.inventory_batches set quantity = quantity - p_quantity where id = v_src.id returning * into v_src_new;
  update public.inventory_batches set quantity = quantity + p_quantity, expires_at = coalesce(expires_at, v_src.expires_at)
   where id = v_dst.id returning * into v_dst_new;

  insert into public.stock_movements (tenant_id, kind, warehouse_id, to_warehouse_id, sku_code, batch_number, quantity,
                                      decision_id, recorded_by)
  values (v_me.tenant_id, 'TRANSFER', p_from_warehouse_id, p_to_warehouse_id, p_sku_code, p_batch_number, p_quantity,
          p_decision_id, v_me.profile_id)
  returning id into v_mov;

  perform public.write_audit(v_me.tenant_id, 'record_stock_transfer', 'stock_movements', v_mov::text,
                             jsonb_build_object('from', to_jsonb(v_src), 'to', to_jsonb(v_dst)),
                             jsonb_build_object('from', to_jsonb(v_src_new), 'to', to_jsonb(v_dst_new)),
                             p_idempotency_key);

  -- batch_id and quantity are the source batch; the destination is added alongside
  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('movement_id', v_mov, 'batch_id', v_src_new.id, 'quantity', v_src_new.quantity,
                       'to_batch_id', v_dst_new.id, 'to_quantity', v_dst_new.quantity));
end;
$$;
revoke all on function public.record_stock_transfer(uuid, uuid, uuid, uuid, text, text, numeric) from public, anon, authenticated, service_role;
grant execute on function public.record_stock_transfer(uuid, uuid, uuid, uuid, text, text, numeric) to authenticated, service_role;

-- ── record_stock_adjustment ─────────────────────────────────────────────
create or replace function public.record_stock_adjustment(
  p_idempotency_key uuid, p_decision_id uuid, p_warehouse_id uuid, p_sku_code text,
  p_batch_number text, p_quantity_delta numeric, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me     public.tenant_users := public.assert_tenant_role(
             array['CLIENT_SERVICE_MANAGER', 'LOGISTICS_MANAGER']::public.tenant_role_enum[]);
  v_prior  jsonb;
  v_before public.inventory_batches;
  v_batch  public.inventory_batches;
  v_mov    uuid;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, 'record_stock_adjustment',
    jsonb_build_object('decision_id', p_decision_id, 'warehouse_id', p_warehouse_id, 'sku_code', p_sku_code,
                       'batch_number', p_batch_number, 'quantity_delta', p_quantity_delta, 'reason', p_reason));
  if v_prior is not null then
    return v_prior;
  end if;

  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'an adjustment must change the quantity' using errcode = 'P0001';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'a reason is required for an adjustment' using errcode = 'P0001';
  end if;
  if p_decision_id is null then
    raise exception 'cite the contact report decision that agreed this stock movement' using errcode = 'P0001';
  end if;
  perform public.assert_citable_decision(v_me.tenant_id, p_decision_id, 'STOCK');
  perform public.stock_assert_warehouse(v_me.tenant_id, p_warehouse_id);
  perform public.stock_assert_sku(v_me.tenant_id, p_sku_code, p_batch_number);

  if p_quantity_delta > 0 then
    insert into public.inventory_batches (tenant_id, warehouse_id, sku_code, batch_number, quantity)
    values (v_me.tenant_id, p_warehouse_id, p_sku_code, p_batch_number, 0)
    on conflict (warehouse_id, sku_code, batch_number) do nothing;
  end if;

  select * into v_before from public.inventory_batches
   where warehouse_id = p_warehouse_id and sku_code = p_sku_code and batch_number = p_batch_number for update;
  if not found then
    perform public.stock_insufficient(p_sku_code, 0, -p_quantity_delta);
  end if;
  if v_before.quantity + p_quantity_delta < 0 then
    perform public.stock_insufficient(p_sku_code, v_before.quantity, -p_quantity_delta);
  end if;

  update public.inventory_batches set quantity = quantity + p_quantity_delta where id = v_before.id returning * into v_batch;

  insert into public.stock_movements (tenant_id, kind, warehouse_id, sku_code, batch_number, quantity, reason,
                                      decision_id, recorded_by)
  values (v_me.tenant_id, 'ADJUSTMENT', p_warehouse_id, p_sku_code, p_batch_number, p_quantity_delta, btrim(p_reason),
          p_decision_id, v_me.profile_id)
  returning id into v_mov;

  perform public.write_audit(v_me.tenant_id, 'record_stock_adjustment', 'stock_movements', v_mov::text,
                             to_jsonb(v_before), to_jsonb(v_batch), p_idempotency_key);

  return public.idempotency_complete(p_idempotency_key,
    jsonb_build_object('movement_id', v_mov, 'batch_id', v_batch.id, 'quantity', v_batch.quantity));
end;
$$;
revoke all on function public.record_stock_adjustment(uuid, uuid, uuid, text, text, numeric, text) from public, anon, authenticated, service_role;
grant execute on function public.record_stock_adjustment(uuid, uuid, uuid, text, text, numeric, text) to authenticated, service_role;
