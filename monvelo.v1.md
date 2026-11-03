<!--
Received from the user 2026-10-29 as a proposal. Under review; NOT adopted.
Nothing in the repository has been changed to match it. The governing
documents remain Spec A and Addendum A6 (docs/superpowers/specs/).
Review: Downloads/Teafair-Monvelo-Spec-Review-2026-10-29.pdf
Text below is the user's paste with its Markdown structure restored; content unchanged.
-->

# MONVELO B2B FINANCING & SUPPLY CHAIN SPECIFICATION

## System Architecture Overview

Monvelo is a B2B trade micro-lending and stock liquidity engine built on top of PostgreSQL / Supabase. It operates strictly within B2B manufacturing and distribution contexts, enabling independent brand manufacturers (Tenants) to auto-subsidize trade micro-loans for retail shopkeepers (Shops) through localized fintech capital collection networks (Fintech Agents).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       TENANT CORE LAYER (Brand Owner)                        │
│   - Cost-of-Sales Ledger Balance (Append-Only Interest Subsidy Pool)        │
│   - Custom Subsidy Thresholds & Brand Terms (Default: 10% Interest Subsidy)  │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CUSTOMER & SHOP DATABASE (Retailer)                    │
│   - Verified PostGIS Shop Coordinates                                       │
│   - Tenant-Isolated Credit Ratings (`tenant_shop_registrations`)            │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SUPPLY & FULFILLMENT OVERLAY (RTM Depots)                │
│   - Monvelo Opt-In Flag (`is_monvelo_enabled`) on Orders                    │
│   - Linked Teafair Warehouses & Stockist Depots                             │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     SERVICE & FINTECH LENDING ENGINE                        │
│   - Principal Collection (Fintech Agent -> Retailer @ 0% Shop Interest)     │
│   - Auto-Settlement of 10% Interest via Tenant Ledger Debit                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Personas & User Roles

| Persona / Role | Domain Context | Platform Responsibilities & Permissions |
|---|---|---|
| MONVELO_OPERATOR | Platform Level | Global administrative control, vetting fintech agents, approving agent-tenant links, and platform-wide risk overrides. |
| TENANT_ADMIN | Tenant Core | Brand owner or brand manager; manages cost-of-sales subsidy ledgers, product catalogs, and custom brand financing terms. |
| LOGISTICS_MANAGER | Fulfillment | Manages warehouse stock dispatch, verifies delivery receipts, and updates stock movement status. |
| SALES_REP / FIELD_ZSM | Field Operations | Registers retail shops, proposes tenant-agent links (subject to Operator approval), and toggles Monvelo financing on qualifying orders. |
| FINTECH_AGENT | Localized Lending | POS liquidity business providing physical cash/capital collection, earning settlement fees, and executing localized repayments. |
| RETAILER / SHOP_OWNER | Retail Operations | Neighborhood shop owner receiving 0%-interest inventory financing; repays principal over a 30-day interest-free window. |

## Approved Enums

```sql
-- Subscription Status for Tenant Brand Owners
CREATE TYPE public.monvelo_subscription_status AS ENUM (
  'TRIAL',
  'ACTIVE',
  'SUSPENDED',
  'TERMINATED'
);

-- User Roles inside Tenant Scope
CREATE TYPE public.monvelo_tenant_role AS ENUM (
  'TENANT_ADMIN',
  'LOGISTICS_MANAGER',
  'SALES_REP'
);

-- Payment & Financing Lifecycle Statuses
CREATE TYPE public.monvelo_order_payment_status AS ENUM (
  'PENDING',
  'CASH',
  'FINANCED_PENDING_DISBURSAL',
  'FINANCED_AWAITING_DELIVERY',
  'REPAID_IN_FULL',
  'DEFAULTED'
);

-- Fulfillment & Delivery Lifecycle Statuses
CREATE TYPE public.monvelo_delivery_status AS ENUM (
  'PACKING',
  'IN_TRANSIT',
  'DELIVERED',
  'FAILED'
);

-- Loan Status Lifecycle
CREATE TYPE public.monvelo_loan_status AS ENUM (
  'REQUESTED',
  'APPROVED',
  'DISBURSED',
  'PAID_IN_FULL',
  'DEFAULTED'
);

-- Interest Subsidy Statuses
CREATE TYPE public.monvelo_subsidy_status AS ENUM (
  'PENDING',
  'SETTLED',
  'OVERDUE',
  'REJECTED_INSUFFICIENT_FUNDS'
);

-- Append-Only Ledger Transaction Types
CREATE TYPE public.monvelo_ledger_transaction_type AS ENUM (
  'DEPOSIT_FUNDING',
  'INTEREST_SUBSIDY_DEBIT',
  'SUBSIDY_REFUND_CREDIT'
);
```

## Database Schema Design (Pure Supabase SQL)

```sql
-- Enable PostGIS for Spatial Proximity Engine
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

-- ============================================================================
-- 1. TENANT CORE LAYER
-- ============================================================================

-- Subscribing Brand Owners / Manufacturers
CREATE TABLE IF NOT EXISTS public.tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_name TEXT NOT NULL,
  subscription_status public.monvelo_subscription_status NOT NULL DEFAULT 'TRIAL',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tenant Staff & Role Mapping
CREATE TABLE IF NOT EXISTS public.tenant_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.monvelo_tenant_role NOT NULL DEFAULT 'SALES_REP',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(tenant_id, user_id)
);

-- Append-Only Tenant Cost-of-Sales Financial Ledger
CREATE TABLE IF NOT EXISTS public.tenant_ledger_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  transaction_type public.monvelo_ledger_transaction_type NOT NULL,
  amount NUMERIC(12, 2) NOT NULL CHECK (amount <> 0),
  reference_id UUID, -- Links to inventory_loans.id or payment gateway reference
  description TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 2. CUSTOMER & SHOP DATABASE
-- ============================================================================

-- Retailer Storefront Registry
CREATE TABLE IF NOT EXISTS public.shops (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  phone_number TEXT NOT NULL,
  location extensions.geometry(Point, 4326),
  is_monvelo_enabled BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tenant-Isolated Credit Ratings & Credit Limits
CREATE TABLE IF NOT EXISTS public.tenant_shop_registrations (
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  shop_id UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  credit_rating_score INT NOT NULL DEFAULT 500 CHECK (credit_rating_score BETWEEN 300 AND 850),
  credit_limit_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (credit_limit_amount >= 0),
  registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, shop_id)
);

-- ============================================================================
-- 3. LOGISTICS & FULFILLMENT OVERLAY
-- ============================================================================

-- Master Products Catalog
CREATE TABLE IF NOT EXISTS public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  sku TEXT NOT NULL,
  name TEXT NOT NULL,
  unit_cost NUMERIC(12, 2) NOT NULL CHECK (unit_cost >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(tenant_id, sku)
);

-- Shared / Tenant Warehouses
CREATE TABLE IF NOT EXISTS public.warehouses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE, -- NULL indicates shared public hub
  name TEXT NOT NULL,
  location extensions.geometry(Point, 4326),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Warehouse Inventory Stock Levels
CREATE TABLE IF NOT EXISTS public.warehouse_stock (
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  quantity_available INT NOT NULL DEFAULT 0 CHECK (quantity_available >= 0),
  PRIMARY KEY (warehouse_id, product_id)
);

-- Orders Database (Overlaid with Monvelo Credit Financing Flags)
CREATE TABLE IF NOT EXISTS public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  shop_id UUID NOT NULL REFERENCES public.shops(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  total_value NUMERIC(12, 2) NOT NULL CHECK (total_value > 0),
  payment_status public.monvelo_order_payment_status NOT NULL DEFAULT 'PENDING',
  is_monvelo_financed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Order Items Breakdown
CREATE TABLE IF NOT EXISTS public.order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity INT NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(12, 2) NOT NULL CHECK (unit_price >= 0)
);

-- Order Physical Deliveries
CREATE TABLE IF NOT EXISTS public.deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  driver_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  status public.monvelo_delivery_status NOT NULL DEFAULT 'PACKING',
  dispatched_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- 4. SERVICE DATABASE (FINTECH LENDING & PROXIMITY ENGINE)
-- ============================================================================

-- Fintech Institutional Partners
CREATE TABLE IF NOT EXISTS public.fintech_partners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Monvelo Field Agents (Physical Proximity Capital Collection)
CREATE TABLE IF NOT EXISTS public.monvelo_agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fintech_id UUID NOT NULL REFERENCES public.fintech_partners(id) ON DELETE CASCADE,
  agent_name TEXT NOT NULL,
  phone_number TEXT NOT NULL UNIQUE,
  current_location extensions.geometry(Point, 4326),
  is_active BOOLEAN NOT NULL DEFAULT true,
  paystack_subaccount_code TEXT, -- Hidden from public reads
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Agent-Tenant Links (Requires Operator Approval)
CREATE TABLE IF NOT EXISTS public.monvelo_agent_tenants (
  monvelo_agent_id UUID NOT NULL REFERENCES public.monvelo_agents(id) ON DELETE CASCADE,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  assigned_territory TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'SUSPENDED')),
  approved_at TIMESTAMPTZ,
  approved_by_operator_id UUID REFERENCES auth.users(id),
  PRIMARY KEY (monvelo_agent_id, tenant_id)
);

-- Inventory Loans Master Engine
CREATE TABLE IF NOT EXISTS public.inventory_loans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  order_id UUID NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  shop_id UUID NOT NULL REFERENCES public.shops(id) ON DELETE RESTRICT,
  fintech_id UUID NOT NULL REFERENCES public.fintech_partners(id) ON DELETE RESTRICT,
  monvelo_agent_id UUID NOT NULL REFERENCES public.monvelo_agents(id) ON DELETE RESTRICT,

  principal_amount NUMERIC(12, 2) NOT NULL CHECK (principal_amount > 0), -- Paid by shop owner (0% shop interest)
  total_interest_amount NUMERIC(12, 2) NOT NULL CHECK (total_interest_amount >= 0), -- 10% subsidized by Tenant
  due_date TIMESTAMPTZ NOT NULL,
  status public.monvelo_loan_status NOT NULL DEFAULT 'REQUESTED',

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Interest Subsidies Tracker (Debits Tenant Cost-of-Sales)
CREATE TABLE IF NOT EXISTS public.interest_subsidies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id UUID NOT NULL UNIQUE REFERENCES public.inventory_loans(id) ON DELETE CASCADE,
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  subsidy_amount NUMERIC(12, 2) NOT NULL CHECK (subsidy_amount >= 0),
  status public.monvelo_subsidy_status NOT NULL DEFAULT 'PENDING',
  settled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- INDEXES FOR PERFORMANCE & PROXIMITY SEARCHES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_shops_location ON public.shops USING GIST(location);
CREATE INDEX IF NOT EXISTS idx_agents_location ON public.monvelo_agents USING GIST(current_location);
CREATE INDEX IF NOT EXISTS idx_orders_tenant_payment ON public.orders(tenant_id, payment_status);
CREATE INDEX IF NOT EXISTS idx_ledger_tenant ON public.tenant_ledger_transactions(tenant_id);
```

## Row-Level Security (RLS) & Data Isolation Policies

All Monvelo multi-tenant tables enforce strict Row-Level Security. RLS policies leverage JWT metadata (`app_metadata ->> 'tenant_id'`) to eliminate inefficient subquery joins during reads and writes.

```sql
-- Enable RLS across all multi-tenant tables
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_ledger_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_shop_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_loans ENABLE ROW LEVEL SECURITY;

-- 1. Orders Tenant Isolation Policy
CREATE POLICY tenant_isolation_orders_policy ON public.orders
AS RESTRICTIVE
USING (
  tenant_id = (NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'tenant_id', ''))::uuid
);

-- 2. Ledger Transactions Tenant Isolation Policy
CREATE POLICY tenant_isolation_ledger_policy ON public.tenant_ledger_transactions
AS RESTRICTIVE
USING (
  tenant_id = (NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'tenant_id', ''))::uuid
);

-- 3. Products Tenant Isolation Policy
CREATE POLICY tenant_isolation_products_policy ON public.products
AS RESTRICTIVE
USING (
  tenant_id = (NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'tenant_id', ''))::uuid
);

-- 4. Tenant Shop Registrations Isolation Policy
CREATE POLICY tenant_isolation_shop_reg_policy ON public.tenant_shop_registrations
AS RESTRICTIVE
USING (
  tenant_id = (NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'tenant_id', ''))::uuid
);
```

## Helper Views & Functions

### Ledger Balance View (Derived Balance)

```sql
CREATE OR REPLACE VIEW public.tenant_ledger_balances AS
SELECT
  tenant_id,
  COALESCE(SUM(amount), 0.00) AS current_balance
FROM public.tenant_ledger_transactions
GROUP BY tenant_id;
```

### Proximity Agent Search (PostGIS)

```sql
CREATE OR REPLACE FUNCTION public.get_nearby_monvelo_agents(
  shop_lat NUMERIC,
  shop_lng NUMERIC,
  radius_meters INT DEFAULT 5000
)
RETURNS TABLE (
  agent_id UUID,
  agent_name TEXT,
  phone_number TEXT,
  distance_meters DOUBLE PRECISION
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    id AS agent_id,
    agent_name,
    phone_number,
    ST_Distance(
      current_location,
      ST_SetSRID(ST_MakePoint(shop_lng, shop_lat), 4326)::geography
    ) AS distance_meters
  FROM public.monvelo_agents
  WHERE is_active = true
    AND ST_DWithin(
      current_location,
      ST_SetSRID(ST_MakePoint(shop_lng, shop_lat), 4326)::geography,
      radius_meters
    )
  ORDER BY distance_meters ASC;
$$;
```
