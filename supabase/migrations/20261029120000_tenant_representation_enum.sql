-- Addendum A6 §16.3 (Monvelo Step 1c) — the three tenant-representation roles.
-- A new enum value cannot be used in the transaction that adds it, so the
-- statements stand alone; 20261029120100 uses them.
alter type public.tenant_role_enum add value if not exists 'CLIENT_SERVICE_MANAGER';
alter type public.tenant_role_enum add value if not exists 'TENANT_ADMIN';
alter type public.tenant_role_enum add value if not exists 'LOGISTICS_MANAGER';
