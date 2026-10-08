-- Spec A §8 — the policy inventory. Policies are FOR SELECT only. There are
-- no INSERT/UPDATE/DELETE policies anywhere: the grants make those operations
-- unreachable, and writes arrive through SECURITY DEFINER RPCs.
--
-- Every predicate uses (select auth.uid()) or a public.* helper inside a
-- subquery, so it is evaluated once per statement, never per row.

-- ── class A: tenant-scoped (22 tables) ──────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array[
    'zones', 'territories', 'tenant_shop_coverage', 'routes', 'route_waypoints',
    'field_check_ins', 'warehouses', 'brand_approval_policies', 'central_products',
    'inventory_batches', 'requisitions', 'requisition_items', 'orders', 'order_items',
    'retail_stock_pickups', 'retail_stock_pickup_items', 'fintech_partners',
    'fintech_terminals', 'payments', 'commission_records', 'fintech_advances',
    'cash_audit_batches'
  ] loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (tenant_id in (select public.my_tenant_ids()))',
      t || '_select_tenant_member', t);
  end loop;
end;
$$;

-- ── tenancy ─────────────────────────────────────────────────────────────
create policy tenants_select_member on public.tenants
  for select to authenticated
  using (id in (select public.my_tenant_ids()));

create policy tenant_settings_select_member on public.tenant_settings
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids()));

-- own memberships (any status, so an INVITED user can see the invitation)
-- plus every membership of a tenant the caller is ACTIVE in
create policy tenant_users_select_self_or_member on public.tenant_users
  for select to authenticated
  using (profile_id = (select auth.uid())
         or tenant_id in (select public.my_tenant_ids()));

-- ── identity (class C) ──────────────────────────────────────────────────
create policy profiles_select_self_or_peer on public.profiles
  for select to authenticated
  using (id = (select auth.uid())
         or id in (select public.my_peer_profile_ids()));

-- decision 16: owner only, no peer access of any kind
create policy user_secure_profiles_select_owner on public.user_secure_profiles
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy devices_select_owner on public.devices
  for select to authenticated
  using (user_id = (select auth.uid()));

-- ── the shared retail network (class B, §4.3) ───────────────────────────
-- Whole registry when any of the caller's tenants allows the shared network;
-- otherwise only shops their tenants cover. A shop owner always sees their
-- own shop.
create policy retail_shops_select_network on public.retail_shops
  for select to authenticated
  using ((select public.sees_shared_network())
         or id in (select public.my_covered_shop_ids())
         or owner_id = (select auth.uid()));

-- ── plumbing (class D) ──────────────────────────────────────────────────
create policy notifications_select_recipient on public.notifications
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy idempotency_logs_select_actor on public.idempotency_logs
  for select to authenticated
  using (actor_id = (select auth.uid()));

-- code_hash is additionally excluded by column grant (grants migration)
create policy otp_challenges_select_subject on public.otp_challenges
  for select to authenticated
  using (subject_id = (select auth.uid()));

-- the forensic record is for the top of the in-app chain only
create policy audit_logs_select_zsm_tm on public.audit_logs
  for select to authenticated
  using (tenant_id in (select public.my_tenant_ids_with_role(
                         array['ZSM', 'TM']::public.tenant_role_enum[])));
