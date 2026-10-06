-- Spec A §6.2 — stable sets are enums. Workflow statuses are text + CHECK on
-- their tables, so they evolve without ALTER TYPE.

-- §5.1: two role axes, so a platform role in a tenant column (or the reverse)
-- is unrepresentable.
create type public.platform_role_enum as enum ('PLATFORM_SUPER_ADMIN');

create type public.tenant_role_enum as enum (
  'ZSM', 'TM', 'ASM', 'DSM', 'DSA', 'FINTECH_AGENT', 'RETAIL_SHOP_OWNER'
);

create type public.tenant_status_enum      as enum ('ACTIVE', 'SUSPENDED', 'INACTIVE');
create type public.tenant_user_status_enum as enum ('ACTIVE', 'INVITED', 'DISABLED');
create type public.kyc_status_enum         as enum ('UNVERIFIED', 'PENDING', 'VERIFIED', 'REJECTED');
create type public.density_category_enum   as enum ('HIGH_DENSITY', 'MARKET_SQUARE', 'EVENT_CENTER', 'SUBURBAN');

-- Gateway and POS network are separate axes (§6.2): Paystack is the only
-- collection engine; Moniepoint/OPay/PalmPay are POS agent networks.
create type public.gateway_provider_enum   as enum ('PAYSTACK');
create type public.pos_network_enum        as enum ('MONIEPOINT', 'OPAY', 'PALMPAY');

create type public.payment_status_enum     as enum ('INITIATED', 'PROCESSING', 'SUCCESS', 'FAILED', 'REFUNDED');
-- Decision 14: no approval state; nothing human gates a commission.
create type public.commission_status_enum  as enum ('SPLIT', 'SETTLED', 'DISPUTED');
create type public.warehouse_kind_enum     as enum ('CENTRAL', 'REGIONAL', 'STOCKIST');
create type public.order_channel_enum      as enum ('ONLINE', 'FIELD_DSA', 'RETAIL');
create type public.audit_source_enum       as enum ('USER', 'SYSTEM', 'WEBHOOK', 'CRON');
create type public.otp_purpose_enum        as enum ('PICKUP_CONFIRM', 'POS_SETTLEMENT');
