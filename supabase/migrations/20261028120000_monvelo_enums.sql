-- Addendum A6 §3 — Monvelo roles and the neutral channel name.
--
--   tenant_role_enum    + ZSA, ASA          street agents (zone / area)
--   platform_role_enum  + MONVELO_OPERATOR, MONVELO_FINANCE
--   order_channel_enum  FIELD_DSA → FIELD_SALES
--
-- The new labels are only used by the next migration: Postgres refuses to use
-- an enum value added in the same transaction. Function bodies compare the
-- channel by value, so the rename needs no body change.
alter type public.order_channel_enum rename value 'FIELD_DSA' to 'FIELD_SALES';

alter type public.tenant_role_enum add value if not exists 'ZSA';
alter type public.tenant_role_enum add value if not exists 'ASA';

alter type public.platform_role_enum add value if not exists 'MONVELO_OPERATOR';
alter type public.platform_role_enum add value if not exists 'MONVELO_FINANCE';
