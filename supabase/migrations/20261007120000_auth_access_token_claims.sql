-- Spec A §4.4 — the claims the auth-verify-claims hook mints into every
-- access token, under app_metadata. Computed in SQL so the Edge Function is a
-- thin, signature-checking shell and the rules are pgTAP-tested.
--
-- Claims are a cache, never the authority: every RPC re-reads tenant_users
-- live (is_tenant_member / assert_tenant_role).
--
--   tenant_ids        every ACTIVE membership
--   active_tenant_id  the ACTIVE primary membership (set by set_active_tenant),
--                     else the only ACTIVE membership, else null
--   tenant_role       the role in the active tenant
--   platform_role     PLATFORM_SUPER_ADMIN or null
create or replace function public.access_token_claims(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with active as (
    select tu.tenant_id, tu.role, tu.is_primary
    from public.tenant_users tu
    where tu.profile_id = p_user_id
      and tu.status = 'ACTIVE'
  ),
  chosen as (
    select a.tenant_id, a.role
    from active a
    where a.is_primary or (select count(*) from active) = 1
    order by a.is_primary desc
    limit 1
  )
  select jsonb_build_object(
    'tenant_ids',       coalesce((select jsonb_agg(a.tenant_id order by a.tenant_id) from active a), '[]'::jsonb),
    'active_tenant_id', (select c.tenant_id from chosen c),
    'tenant_role',      (select c.role from chosen c),
    'platform_role',    (select p.platform_role from public.profiles p where p.id = p_user_id)
  );
$$;

-- system-flavoured (§3.4): the hook calls it with the service-role key
revoke execute on function public.access_token_claims(uuid) from public, anon, authenticated;
grant execute on function public.access_token_claims(uuid) to service_role;
