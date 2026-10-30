-- Addendum A6 §16.5, §16.6 (Monvelo Step 2, Task 9) — the order financing-status
-- read, and the insert-only tenant ledger.
--
-- The ledger is the tenant's settlement record: what was funded for its shops
-- (FUNDED_GROSS, positive) and what came off it (REBATE, FEE, REFUND,
-- REMITTANCE, negative). Step 2 builds only the table; Steps 3 and 5 add the
-- writers, and Step 5 adds rebate_payable_id with its FK.

-- ── monvelo_order_financing_status ──────────────────────────────────────
-- For each asked order of the caller's active tenant: its live financing's
-- status (not CANCELLED or EXPIRED), else NONE. A RETAIL_SHOP_OWNER sees only
-- the orders of shops they own; a POS_AGENT sees none. At most 200 ids.
create or replace function public.monvelo_order_financing_status(p_order_ids uuid[])
returns table (order_id uuid, financing_state text, financing_id uuid, reference text, principal numeric)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_me public.tenant_users := public.assert_tenant_role(null);
begin
  if coalesce(cardinality(p_order_ids), 0) > 200 then
    raise exception 'ask for at most 200 orders at a time' using errcode = 'P0001';
  end if;
  if v_me.role = 'POS_AGENT' then
    return;
  end if;

  return query
  select o.id, coalesce(f.status, 'NONE'), f.id, f.reference, f.principal
    from unnest(p_order_ids) with ordinality as a (id, n)
    join public.orders o on o.tenant_id = v_me.tenant_id and o.id = a.id
    left join public.monvelo_financings f
      on f.tenant_id = o.tenant_id and f.order_id = o.id and f.status not in ('CANCELLED', 'EXPIRED')
   where v_me.role <> 'RETAIL_SHOP_OWNER'
      or o.retail_shop_id in (select s.id from public.retail_shops s where s.owner_id = v_me.profile_id)
   order by a.n;
end;
$$;
revoke all on function public.monvelo_order_financing_status(uuid[]) from public, anon;
grant execute on function public.monvelo_order_financing_status(uuid[]) to authenticated;

-- ── monvelo_tenant_ledger_entries ───────────────────────────────────────
create table public.monvelo_tenant_ledger_entries (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete restrict,
  business_date date not null,
  entry_type    text not null check (entry_type in ('FUNDED_GROSS', 'REBATE', 'FEE', 'REFUND', 'REMITTANCE')),
  financing_id  uuid,
  amount        numeric(15,2) not null,
  created_at    timestamptz not null default now(),
  unique (tenant_id, id),
  constraint monvelo_tenant_ledger_entries_sign
    check ((entry_type = 'FUNDED_GROSS' and amount > 0) or (entry_type <> 'FUNDED_GROSS' and amount < 0)),
  foreign key (tenant_id, financing_id) references public.monvelo_financings (tenant_id, id) on delete restrict
);
create index idx_monvelo_tenant_ledger_entries_date      on public.monvelo_tenant_ledger_entries (tenant_id, business_date);
create index idx_monvelo_tenant_ledger_entries_financing on public.monvelo_tenant_ledger_entries (financing_id);
create index idx_monvelo_tenant_ledger_entries_fin_fk    on public.monvelo_tenant_ledger_entries (tenant_id, financing_id);

create or replace function public.monvelo_ledger_insert_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'ledger entries are insert-only' using errcode = 'P0001';
end;
$$;
revoke all on function public.monvelo_ledger_insert_only() from public, anon, authenticated, service_role;
create trigger monvelo_tenant_ledger_entries_insert_only before update or delete on public.monvelo_tenant_ledger_entries
  for each row execute function public.monvelo_ledger_insert_only();
create trigger monvelo_tenant_ledger_entries_no_truncate before truncate on public.monvelo_tenant_ledger_entries
  for each statement execute function public.monvelo_ledger_insert_only();

alter table public.monvelo_tenant_ledger_entries enable row level security;
revoke all on public.monvelo_tenant_ledger_entries from anon, authenticated, service_role;
grant select on public.monvelo_tenant_ledger_entries to authenticated;
create policy monvelo_tenant_ledger_entries_select on public.monvelo_tenant_ledger_entries for select to authenticated
  using (
    tenant_id in (select public.my_tenant_ids_with_role(
      array['TENANT_ADMIN', 'CLIENT_SERVICE_MANAGER', 'ZSM']::public.tenant_role_enum[]))
    or (select public.is_monvelo_staff()));
