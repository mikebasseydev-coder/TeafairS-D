-- Spec A §4.7 — Teafair is itself a tenant, selling its own house brands.
--
-- It is an ordinary tenant: its own catalogue, brand-tier policies, staff,
-- partners, payments and audit trail, isolated exactly like any client
-- company. Membership of TEAFAIR grants no platform power; cross-tenant work
-- is PLATFORM_SUPER_ADMIN only, on profiles.platform_role (§5.1).
--
-- Seeded here, not in seed.sql, because it is a real business entity that
-- must exist in every environment. The id is fixed so tooling can address it.

insert into public.tenants (id, name, code, status)
values ('7eaf0000-0000-4000-8000-000000000001', 'Teafair', 'TEAFAIR', 'ACTIVE')
on conflict (id) do nothing;

insert into public.tenant_settings (tenant_id)
values ('7eaf0000-0000-4000-8000-000000000001')
on conflict (tenant_id) do nothing;
