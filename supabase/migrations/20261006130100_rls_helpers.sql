-- Spec A §8 — RLS helpers. All in `public`, never in the Supabase-managed
-- `auth` schema (decision 16). Claims are read through auth.jwt(); the
-- per-claim request.jwt.claim.* settings no longer exist on current PostgREST.
--
-- Membership is always read LIVE from tenant_users (§4.4): a revoked member
-- loses access on their next query, not when their JWT expires.

-- The active tenant the JWT proposes. A proposal only: every use is paired
-- with a live membership check.
create or replace function public.jwt_tenant_id()
returns uuid
language sql
stable
set search_path = public, pg_temp
as $$
  select nullif((select auth.jwt()) -> 'app_metadata' ->> 'active_tenant_id', '')::uuid;
$$;

create or replace function public.is_tenant_member(p_tenant_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.tenant_users tu
    where tu.tenant_id = p_tenant_id
      and tu.profile_id = (select auth.uid())
      and tu.status = 'ACTIVE'
  );
$$;

create or replace function public.tenant_role(p_tenant_id uuid)
returns public.tenant_role_enum
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select tu.role from public.tenant_users tu
  where tu.tenant_id = p_tenant_id
    and tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
  limit 1;
$$;

-- ── set-returning forms, used by the policies ───────────────────────────
-- `tenant_id in (select public.my_tenant_ids())` is the same live check as
-- is_tenant_member(tenant_id), but Postgres evaluates the subquery once per
-- statement and hashes it, instead of calling a function for every row.

create or replace function public.my_tenant_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select tu.tenant_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE';
$$;

create or replace function public.my_tenant_ids_with_role(p_roles public.tenant_role_enum[])
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select tu.tenant_id from public.tenant_users tu
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE'
    and tu.role = any (p_roles);
$$;

-- Profiles sharing at least one ACTIVE tenant with the caller (both sides
-- ACTIVE). Shop owners' identities stay behind this (§4.3).
create or replace function public.my_peer_profile_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select distinct peer.profile_id
  from public.tenant_users me
  join public.tenant_users peer on peer.tenant_id = me.tenant_id
  where me.profile_id = (select auth.uid())
    and me.status = 'ACTIVE'
    and peer.status = 'ACTIVE';
$$;

-- True when any of the caller's ACTIVE tenants allows the shared network
-- (§4.3). A tenant with no settings row takes the column default, true.
create or replace function public.sees_shared_network()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.tenant_users tu
    left join public.tenant_settings ts on ts.tenant_id = tu.tenant_id
    where tu.profile_id = (select auth.uid())
      and tu.status = 'ACTIVE'
      and coalesce(ts.allow_shared_network, true)
  );
$$;

-- Shops covered by any of the caller's ACTIVE tenants.
create or replace function public.my_covered_shop_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select c.retail_shop_id
  from public.tenant_shop_coverage c
  join public.tenant_users tu on tu.tenant_id = c.tenant_id
  where tu.profile_id = (select auth.uid())
    and tu.status = 'ACTIVE';
$$;

grant execute on function
  public.jwt_tenant_id(),
  public.is_tenant_member(uuid),
  public.tenant_role(uuid),
  public.my_tenant_ids(),
  public.my_tenant_ids_with_role(public.tenant_role_enum[]),
  public.my_peer_profile_ids(),
  public.sees_shared_network(),
  public.my_covered_shop_ids()
to authenticated;
