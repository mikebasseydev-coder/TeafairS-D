-- Spec A §6.9 — shared trigger functions used by every table migration.

-- updated_at is maintained by trigger; a column default alone never advances.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Backstop for append-only tables (§4.6). Grants already deny UPDATE/DELETE;
-- this also stops the table owner and service_role, which bypass grants on
-- their own objects and bypass RLS.
create or replace function public.forbid_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '% is append-only: % is not allowed', tg_table_name, tg_op
    using errcode = 'P0001';
end;
$$;

-- Ladder rank for brand-tier approvals (§5.4): DSM < ASM < TM < ZSM.
-- Returns null for roles that are not on the approval ladder.
create or replace function public.approval_rank(p_role public.tenant_role_enum)
returns smallint
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_role
    when 'DSM' then 1
    when 'ASM' then 2
    when 'TM'  then 3
    when 'ZSM' then 4
  end::smallint;
$$;
