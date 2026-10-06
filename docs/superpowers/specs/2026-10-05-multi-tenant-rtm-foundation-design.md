# Multi-tenant RTM foundation — design

**Date:** 2026-10-05 (open questions closed 2026-10-06)
**Status:** approved design — the governing authority for implementation
**Scope:** Spec A of four (see §12); implementation phases in §14

## Executive summary

Teafair is a multi-tenant Route-to-Market (RTM) and embedded-liquidity platform
for African FMCG supply chains. Several brand owners run their own distribution
networks on one Supabase deployment, over a shared registry of retail shops.
Teafair is itself one of those tenants, selling its own house brands alongside
the client networks it serves (§4.7).

**The liquidity engine.** Shop owners in the informal market restock on
high-interest street credit. Teafair replaces that with third-party POS agents —
`FINTECH_AGENT` members operating Moniepoint, OPay and PalmPay terminals,
registered as `fintech_partners` — who act as local liquidity nodes: the shop
owner settles an order at a nearby agent, the brand owner is paid immediately,
and the agent earns a negotiated commission (`fintech_partners.commission_bps`).
**Paystack is the exclusive collection engine**, and Paystack Subaccounts
perform the commission split natively during collection, so the cost of
collection is locked at the moment the money moves and no human approves a
payout.

**The invariants that make it safe:**

- **No direct client writes.** The Android app never issues DML against a
  business table. A Deno Edge Function gateway validates the JWT, the Zod
  payload, PINs and Paystack, then makes exactly one call to a `SECURITY
  DEFINER` Postgres RPC that performs the whole transaction (§3).
- **Tenant isolation from verified claims.** `tenant_id` is never accepted from
  a client. It comes from the JWT and is re-verified live against
  `tenant_users`, so a revoked membership loses access immediately rather than
  when its token expires (§4.4, §8).
- **Dual-validation handshake.** A POS-backed settlement needs a
  server-verified Paystack reference *and* a shop-owner OTP before a commission
  row is written (§6.11).
- **Teafair agent accountability.** Every order, payment and commission names
  the Teafair staff member accountable for that trade cluster (§6.10).
- **Brand-tier approvals.** A requisition's approval level is set by the brands
  on it, not by its cash value (§5.4).
- **Offline-first field work.** A pickup logged without signal lands as
  `PENDING_CONFIRMATION` and escalates to the DSM after 24 hours unconfirmed
  (§7.4).
- **Hardened money edges.** Paystack webhooks are signature-verified, held to a
  5-minute replay window, and processed at most once (§3.6); BVN/NIN hashes are
  versioned for pepper rotation and readable only by their owner (§4.5).

## 1. Purpose and standing

This spec defines the foundation of the TEAFAIR Route-to-Market platform as a
**multi-tenant** system: several client companies (Nestlé, Unilever, …) each
running their own distribution network on one deployment, over a shared
retail-shop registry.

It **supersedes** the two previous governing specs in full:

| Superseded | Why |
|---|---|
| `2026-09-03-serverless-rtm-platform-design.md` | single-tenant; write path was ~50 bare Postgres RPCs; HQ-centric 9-role taxonomy; no shared network |
| `2026-09-04-architecture-and-scaffold-design.md` | `apps/` + `packages/` pnpm monorepo with a `react-native-windows` HQ app; Expo-first build sequence |

Both are retained as history. The 15 references in `docs/features/` remain
useful for **behavioural** detail (verification signals, cash-audit variance,
financing lifecycle) but every one is superseded on architecture, roles and
tenancy, and must be re-read against this document before use.

This spec covers tenancy, the write contract, roles, the data model and offline
reliability. It does **not** specify screens or feature workflows — those belong
to Specs B–D (§12).

## 2. Decisions locked

Each of these was contested during design and is settled. Reversing one
invalidates parts of this spec.

1. **No direct client writes.** The React Native app and the deferred Windows
   client never issue `INSERT`/`UPDATE`/`DELETE` against business tables.
2. **Edge Function = gateway, Postgres RPC = transaction.** The function handles
   HTTP, validation, PIN checks and external IO; one `SECURITY DEFINER` RPC call
   performs the atomic database work.
3. **The gateway forwards the caller's JWT** to the RPC. It does not use the
   service-role key for user-initiated work.
4. **`tenantId` is never accepted from the client.** The active tenant is read
   from JWT claims and re-verified against `tenant_users` server-side.
5. **Shared schema, `tenant_id` discriminator.** One database, one `public`
   schema. No schema-per-tenant, no database-per-tenant.
6. **Tenants are never deleted.** `ON DELETE RESTRICT` throughout;
   `status = 'INACTIVE'` is the offboarding path.
7. **Supabase CLI owns all DDL.** Prisma is retired from the architecture.
8. **Two role axes.** `platform_role_enum` (TEAFAIR staff) is separate from
   `tenant_role_enum` (client-company operations). `profiles.user_role` does not
   exist.
9. **No HQ approval tier.** The operational chain is DSA → DSM → ASM → TM → ZSM
   and ends there.
10. **No inventory movement ledger.** `inventory_batches.quantity` is
    authoritative, protected by `SELECT … FOR UPDATE`; `audit_logs` carries
    history.
11. **Android only at launch.** The Windows HQ client is deferred; its CI
    workflow and stub remain so the target is not lost.
12. **Supabase is the only backend.** Supabase Auth, the Custom Access Token
    Hook, Vault, Deno Edge Functions and the Supabase CLI. Azure is not a
    deployment option — §3 and §8 depend on Supabase primitives that have no
    equivalent there.
13. **Paystack is the exclusive collection engine, and performs the split
    itself.** Paystack Subaccounts route the partner's share natively during
    collection, so `commission_records` *reconciles* a split that already
    happened and never instructs a payout.
14. **Commission is fully automated.** There is no human approval gate. The
    controls are partner onboarding and the §6.11 dual-validation handshake.
15. **`retail_shops` is a global shared registry**, mapped per tenant through
    `tenant_shop_coverage`.
16. **Two permanent security overrides.** Claim helpers live only in `public`,
    never in the Supabase-managed `auth` schema. `bvn_nin_hash` lives only in
    `user_secure_profiles` under owner-only RLS, never on the peer-readable
    `profiles` row.
17. **BVN/NIN hashes are versioned.** `user_secure_profiles` carries
    `bvn_hash_version`; a pepper rotation stores the new hash alongside the old,
    matches against either, and migrates rows in the background (§4.5).
18. **Requisition approval is set by brand tier, not cash value.** Each tenant
    maps brands to the tier that must sign off; a requisition needs the highest
    tier among its brands, regardless of total value (§5.4).
19. **Unconfirmed pickups escalate after 24 hours.** A `PENDING_CONFIRMATION`
    pickup unconfirmed for 24 hours is flagged and escalated to the supervising
    DSM by a `pg_cron` job (§7.4).
20. **Paystack webhooks have a 5-minute replay window** (±300 s), on top of
    signature verification and at-most-once processing (§3.6).

## 3. Architecture

### 3.1 The write path

```
Client (React Native, Android)
  │  POST /functions/v1/<name>      Authorization: Bearer <user JWT>
  ▼
Edge Function (Deno)  ── the HTTP gateway
  1. verify JWT; reject anonymous
  2. read claims → active_tenant_id, tenant_role, platform_role
  3. Zod-validate the body   (any client-supplied tenantId is stripped)
  4. bcrypt-verify the 4-digit PIN, if this operation requires one
  5. external IO — Paystack / KudiSMS / BVN provider / PostGIS preparation
  6. exactly one call ──►  db.rpc('<rpc_name>', { p_idempotency_key, … })
  7. map Postgres error codes to HTTP status (§3.5)
  ▼
Postgres SECURITY DEFINER RPC  ── the transaction
  · the function body IS the BEGIN … COMMIT
  · actor  = (select auth.uid())
  · tenant = (select auth.jwt()) -> 'app_metadata' ->> 'active_tenant_id'
  · re-verify ACTIVE membership and role against tenant_users
  · idempotency insert, ON CONFLICT DO NOTHING
  · SELECT … FOR UPDATE on contended rows, locked in primary-key order
  · multi-table writes + audit_logs
  · RETURN jsonb
```

### 3.2 Why the gateway forwards the JWT

If the gateway called the RPC with the service-role key, `auth.uid()` inside the
RPC would be `NULL`. The function would have to be *told* the actor and tenant,
and would have no way to verify either — leaving the isolation guarantee resting
on thirteen Edge Functions each getting it right.

Forwarding the caller's own `Authorization` header instead:

```ts
const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  global: { headers: { Authorization: req.headers.get("Authorization")! } },
})
await db.rpc("place_requisition", { p_idempotency_key, p_items })
```

The RPC now runs as `authenticated` with real claims, so it derives actor and
tenant itself. **There is no tenant or actor parameter to forge.** It can still
write to locked-down tables because it is `SECURITY DEFINER`.

Consequence worth having: the service-role key is absent from every user-facing
function, and present only in the system-initiated set (§3.4).

### 3.3 Function requirements

Every write RPC:

- is `SECURITY DEFINER` with `SET search_path = public, pg_temp`;
- is `GRANT EXECUTE … TO authenticated`, `REVOKE … FROM anon, public`;
- takes `p_idempotency_key uuid` as its first parameter;
- derives actor and tenant from claims — never from parameters;
- re-asserts role before writing;
- writes one `audit_logs` row per business effect;
- returns `jsonb`.

Every RLS helper:

- lives in `public`, never in the Supabase-managed `auth` schema, which the
  platform may reset on upgrade;
- wraps the accessor as `(select auth.uid())` so Postgres can cache it as an
  initPlan rather than re-evaluating per row;
- is `SECURITY DEFINER STABLE` with `SET search_path = public, pg_temp`.

### 3.4 Gateway inventory

| Function | Flavour | DB identity | Purpose |
|---|---|---|---|
| `auth-verify-claims` | **auth hook** | — | Custom Access Token Hook; injects tenant claims. Not an HTTP gateway |
| `onboarding-kyc-verify` | user | `authenticated` | BVN/NIN provider call, bank binding |
| `warehouse-order-workflow` | user | `authenticated` | requisition approval transitions |
| `stockist-allocation-process` | user | `authenticated` | atomic allocation from a source warehouse |
| `territory-route-geosync` | user | `authenticated` | PostGIS route and geofence validation |
| `fintech-advance-payout` | user | `authenticated` | advance risk evaluation and disbursement |
| `dsa-commission-calculate` | user | `authenticated` | partner-bps commission computation |
| `complete-pos-backed-order` | user | `authenticated` | dual-validation POS settlement (§6.11) |
| `process-payment` | **system** | `service_role` | Paystack webhook; signature, ±300 s replay window, Verify API, at-most-once (§3.6) |
| `fintech-commission-release` | **system** | `service_role` | matches `commission_records` against Paystack settlement reports; `SPLIT` → `SETTLED` |
| `reconcile-funds` | **system** | `service_role` | physical cash deposits against Paystack settlements; sweeps unconfirmed payments through the Verify API (§3.6) |
| `reconcile-discounts-eod` | **system** | `service_role` | end-of-day discounting |
| `zonal-performance-aggregate` | **system** | `service_role` | scheduled zonal rollups |
| `inventory-sync` | **system** | `service_role` | cross-node catalogue and batch sync |

System-initiated functions have no user context, so they authenticate by gateway
signature or cron secret, run under `service_role`, and record
`audit_logs.source = 'WEBHOOK'` or `'CRON'` with a system actor.

### 3.5 Error contract

The offline queue must distinguish retry from stop, so this mapping is part of
the contract rather than per-function improvisation.

| Postgres condition | HTTP | Queue behaviour |
|---|---|---|
| `P0001` business-rule violation | 422 | terminal — surface to the user |
| `42501` not authenticated, not a member, or role not permitted | 403 | terminal |
| `23505` unique violation | 409 | terminal |
| `TF001` insufficient stock | 409 + structured detail | terminal |
| `TF002` idempotency key reused with a different payload, actor or operation | 409 | terminal |
| `40001` serialization failure, or the same key still in flight | 503 | retry with backoff |
| `55P03` lock timeout | 503 | retry with backoff |
| network failure, 5xx | — | retry with backoff |

Client-facing shape: `{ error: { code, message, details } }`.

Teafair's own conditions use the `TF` SQLSTATE class. An earlier draft
assigned insufficient stock to `P0002`, but that is PL/pgSQL's built-in
`no_data_found`, raised by any `SELECT … INTO STRICT` that finds nothing — a
lookup bug would have reached the user as "out of stock". `TF001`/`TF002`
cannot collide with a built-in code.

### 3.6 Paystack webhook verification

`process-payment` applies four checks, in order, before it calls an RPC:

1. **Signature.** `x-paystack-signature` must equal the hex HMAC-SHA512 of the
   **raw** request body keyed with the Paystack secret key, compared in constant
   time. Parsing the body before hashing it breaks the check.
2. **Replay window — ±300 seconds.** Paystack's signature covers the body only
   and carries no timestamp, so the window is measured against the event's own
   time: `data.paid_at`, falling back to `data.created_at`. An event outside
   `now() ± 300 s` is not processed. The gateway answers `200` so Paystack stops
   retrying, and writes an `audit_logs` row with operation `WEBHOOK_STALE`.
3. **Source confirmation.** The reference is re-verified against the Paystack
   Verify Transaction API; amount, currency and status come from that response,
   never from the webhook body.
4. **At most once.** `(event, data.reference)` is the idempotency key, so a
   replay that slips inside the window is a no-op.

**Late confirmations are not lost.** Paystack retries a failed delivery for up
to 72 hours, so the window will drop some legitimate retries. `reconcile-funds`
therefore sweeps every payment still `INITIATED` or `PROCESSING` more than five
minutes after creation and settles it through the Verify API. Payments are
confirmed by the sweep as well as by the webhook; the webhook is the fast path
only.

## 4. Tenancy and isolation

### 4.1 Strategy

Single database, single `public` schema, `tenant_id UUID NOT NULL REFERENCES
tenants(id) ON DELETE RESTRICT` as the discriminator on tenant-scoped tables.

Schema-per-tenant and database-per-tenant are both rejected for one decisive
reason: the shared retail-shop registry is a core product requirement, and
physical separation makes a shop visible to many tenants either impossible or a
federation problem.

### 4.2 Three data classes

Treating every table as tenant-scoped is what produced the original
`retail_shops` incoherence. There are three classes, each with a different
policy shape.

| Class | Tables | `tenant_id` | Read policy |
|---|---|---|---|
| **A — tenant-scoped** | `central_products`, `brand_approval_policies`, `inventory_batches`, `warehouses`, `requisitions`, `orders`, `retail_stock_pickups`, `payments`, `commission_records`, `cash_audit_batches`, `zones`, `territories`, `routes`, `route_waypoints`, `field_check_ins`, `fintech_advances`, `fintech_terminals`, `fintech_partners`, `tenant_shop_coverage` | `NOT NULL` | `public.is_tenant_member(tenant_id)` |
| **B — platform-global** | `retail_shops` | none | active membership in any tenant, gated by `allow_shared_network` |
| **C — identity** | `profiles`, `user_secure_profiles`, `tenant_users`, `devices` | none — a person serves multiple tenants | per-row owner, or shared membership |
| **D — plumbing** | `audit_logs`, `idempotency_logs`, `notifications`, `otp_challenges` | nullable — platform-level rows carry `NULL` | per-row actor or recipient; see §8 |

Child tables (`requisition_items`, `order_items`, `retail_stock_pickup_items`)
carry a denormalised `tenant_id NOT NULL` alongside their parent FK. It is
redundant by derivation and deliberate: it lets the RLS predicate hit a local
index instead of joining to the parent on every row.

### 4.3 The shared retail network

A shop is global; each tenant maps it into **its own** territory structure:

```
retail_shops          -- global registry, no tenant_id
tenant_shop_coverage  -- (tenant_id, retail_shop_id, territory_id)
```

Nestlé and Unilever can both cover shop X, each through their own TM. This is
also what makes `tenant_settings.allow_shared_network` enforceable:

- `true` — the tenant can discover and claim any shop in the global registry;
- `false` — the tenant sees only shops in its own `tenant_shop_coverage`.

A shop owner is a `tenant_users` member of *some* tenant, so the peer-profile
policy would otherwise expose their identity to unrelated tenants. `retail_shops`
therefore carries its own operational contact fields (`shop_name`,
`contact_phone`); the owner's `profiles` row stays behind shared membership.

### 4.4 Active tenant: claims propose, the database decides

`auth-verify-claims` is a Custom Access Token Hook. It injects:

```
tenant_ids[]        all ACTIVE memberships
active_tenant_id    the tenant selected in tenant-selector
tenant_role         the role within the active tenant
platform_role       PLATFORM_SUPER_ADMIN, or null
```

Switching tenant re-mints the token: `tenant-selector` calls a gateway that
records the selection, then the client refreshes the session so the hook re-runs.

**Claims are a cache, never the authority.** A revoked membership leaves a valid
JWT in the field until it expires, so `is_tenant_member()` reads `tenant_users`
live. This is also what resolves the two-sources-of-truth problem:
`tenant_users.role` is authoritative and the claim is a routing convenience.

### 4.5 PII

```
user_secure_profiles(user_id PK → profiles,
                     bvn_nin_hash UNIQUE, bvn_hash_version,
                     bvn_nin_hash_prev?, bvn_hash_prev_version?,
                     bank_name, bank_account_number, bank_code, verified_at)
```

RLS: `FOR SELECT USING ((select auth.uid()) = user_id)` — owner only, no peer
access of any kind.

BVN uniqueness is required (one BVN, one person) but the raw value must not be
stored in a readable, indexable column. So the column holds
`bvn_nin_hash` — HMAC-SHA256 with a pepper held in Supabase Vault — under a
unique index. Duplicate detection works; harvesting does not. Compliance reads
go through a gateway that writes `audit_logs` on every access. The hash is
computed inside the RPC from the Vault secret, so the pepper never leaves the
database.

**Pepper rotation.** The raw BVN is never stored, so a background job cannot
recompute a hash from it. Each version therefore wraps the previous one:

```
h1 = HMAC(pepper_1, bvn)
h2 = HMAC(pepper_2, h1)          -- computable from h1 alone
```

A rotation to version *n*:

1. adds `pepper_n` to Vault; new submissions are written at version *n*;
2. a background job moves each row: `bvn_nin_hash_prev ← bvn_nin_hash`,
   `bvn_nin_hash ← HMAC(pepper_n, bvn_nin_hash)`, `bvn_hash_version ← n`;
3. while it runs, a lookup computes the incoming BVN at both versions and matches
   either, under an advisory lock on the hash so two registrations cannot race
   past each other;
4. once no row remains below *n*, `bvn_nin_hash_prev` is cleared.

There is no downtime and no re-collection of BVNs. The cost is that every
pepper in the chain must stay in Vault. A leaked older pepper alone is useless
against stored values, because each stored hash also needs every later pepper.

### 4.6 Audit

Because `service_role` bypasses RLS, and because there is no inventory movement
ledger, `audit_logs` is the only forensic record of who changed what. It is
therefore load-bearing:

- append-only: `REVOKE UPDATE, DELETE FROM PUBLIC`, with a trigger as backstop;
- never pruned;
- `before` / `after` JSONB on every `inventory_batches` write, so stock history
  is reconstructable;
- indexed on `(tenant_id, created_at DESC)`, `(tenant_id, entity_type,
  entity_id)` and `(idempotency_key)`.

### 4.7 Teafair as a tenant

Teafair sells its own house brands, so Teafair is also a tenant: `TEAFAIR`,
seeded by migration with the fixed id `7eaf0000-0000-4000-8000-000000000001`
so it exists in every environment. It is an ordinary tenant — its own
catalogue, brand-tier policies, staff, POS partners, Paystack collections and
audit trail — and is isolated from client tenants exactly as they are from
each other.

Membership of `TEAFAIR` confers **no** platform power. A Teafair ZSM is a ZSM
of the Teafair tenant only; cross-tenant work remains `PLATFORM_SUPER_ADMIN`,
which lives on `profiles.platform_role`, not on any membership (§5.1). Staff
who work client brands and house brands hold one `tenant_users` row per
tenant, with a role in each, and switch between them with `set_active_tenant`.

## 5. Roles and access

### 5.1 Enums

```sql
CREATE TYPE platform_role_enum AS ENUM ('PLATFORM_SUPER_ADMIN');

CREATE TYPE tenant_role_enum AS ENUM (
  'ZSM', 'TM', 'ASM', 'DSM', 'DSA', 'FINTECH_AGENT', 'RETAIL_SHOP_OWNER'
);
```

Two axes rather than one nine-value enum, so invalid states are unrepresentable:
`PLATFORM_SUPER_ADMIN` in `tenant_users.role` and `DSA` in a platform column are
both impossible by construction.

`PLATFORM_SUPER_ADMIN` is TEAFAIR staff: tenant provisioning, global tenant
management, KYC approval. It operates through the Supabase dashboard and admin
tooling, not the mobile app. All daily business logic lives in
`tenant_role_enum`.

### 5.2 Scope model

Four management tiers sit over two geographic levels, so the tiers cannot all be
geographic. `tenant_users` carries optional `zone_id` and `territory_id` plus
`reports_to_id`.

| Role | Geographic anchor | Scope |
|---|---|---|
| `PLATFORM_SUPER_ADMIN` | none | cross-tenant, out-of-app |
| `ZSM` | `zone_id` | all territories in the zone; top of the in-app chain |
| `TM` | `territory_id` | one territory |
| `ASM` | `territory_id` + `reports_to_id` | team tier within a territory |
| `DSM` | `territory_id` + `reports_to_id` | team tier; supervises DSAs |
| `DSA` | `territory_id` + `reports_to_id` | own records only |
| `FINTECH_AGENT` | `territory_id` | own terminals, advances, deposits |
| `RETAIL_SHOP_OWNER` | none | own shop only |

ASM and DSM are **team tiers, not a third geographic level** — a deliberate
choice against an `areas` table. Visibility resolves by zone or territory, which
is index-friendly, rather than by walking `reports_to_id` per row.

### 5.3 Operation matrix

PIN = bcrypt-verified 4-digit PIN required at the gateway.

| Operation | Roles | Scope | PIN |
|---|---|---|---|
| `submit_kyc` | any | self | — |
| `approve_kyc` | `PLATFORM_SUPER_ADMIN` | global | — |
| `register_device` | any | self | — |
| `invite_tenant_user` | `ZSM`; `PLATFORM_SUPER_ADMIN` for the first ZSM | zone | — |
| `set_active_tenant` | any | self | — |
| `upsert_zone` | `PLATFORM_SUPER_ADMIN`, `ZSM` | tenant | — |
| `upsert_territory` | `ZSM` | zone | — |
| `pin_retail_shop` | `DSA`, `DSM`, `ASM`, `TM`, `ZSM` | global insert + auto-coverage | — |
| `claim_shop_coverage` | `TM`, `ZSM` | territory; needs `allow_shared_network` | — |
| `plan_route` | `TM`, `ZSM` | territory | — |
| `field_check_in` | `DSA`, `DSM`, `ASM`, `TM` | own; geofence validated | — |
| `upsert_product` | `ZSM` | tenant | — |
| `set_brand_approval_policy` | `ZSM` | tenant | **yes** |
| `receive_inventory_batch` | `ASM`, `TM`, `ZSM` | warehouse | — |
| `adjust_inventory` | `ZSM` | tenant | **yes** |
| `submit_requisition` | `DSM`, `ASM` | territory | — |
| `approve_requisition` | `DSM` → `ASM` → `TM` → `ZSM` by level | own tier | **yes** when the required level is `TM` or `ZSM` |
| `fulfil_requisition` | `ASM`, `TM` | source warehouse | — |
| `log_retail_pickup` | `DSA` | own | **yes**, deferrable (§7.4) |
| `record_dsa_stock_issue` | `RETAIL_SHOP_OWNER` | own shop | **yes** |
| `create_order` | `DSA`, `RETAIL_SHOP_OWNER` | own | — |
| `fulfil_online_sale` | `DSM`, `ASM` | territory | — |
| `initiate_checkout` | `DSA`, `RETAIL_SHOP_OWNER`, `FINTECH_AGENT` | own | — |
| `request_advance` | `FINTECH_AGENT` | own | — |
| `approve_advance` | system risk rules; `ZSM` override | tenant | **yes** (override) |
| `log_cash_deposit` | `FINTECH_AGENT`, `DSA` | own | — |
| `process_payment`, `release_commission`, `reconcile_funds`, `aggregate_zonal` | system only | — | — |

### 5.4 The approval ladder is data, not an enum

`requisitions.current_approval_level` and `required_approval_level` hold
`tenant_role_enum` values. Adding or removing a tier is a data change, not
`ALTER TYPE`. The approval trail itself goes to `audit_logs`.

**Brand tiers set the required level, not cash value.** High-value or
restricted brands need a senior sign-off however small the requisition;
fast-moving staples clear at a supervisory tier however large it is. Each
tenant keeps its policy in `brand_approval_policies (tenant_id, brand,
required_approval_level)`:

- the ladder ranks `DSM < ASM < TM < ZSM`; a policy level must be one of those
  four;
- a requisition's `required_approval_level` is the **highest** level among the
  brands of its line items, fixed when it is submitted;
- a brand with no policy row clears at `DSM`;
- `total_value` is still recorded, for reporting only — it plays no part in
  approval.

`public.requisition_required_level(tenant_id, sku_codes[])` computes the level,
so `submit_requisition` and any later re-check use one definition. Changing a
policy (`set_brand_approval_policy`) is PIN-gated, because it decides who may
release restricted stock. It affects requisitions submitted afterwards, never
those already in flight.

### 5.5 PIN storage

Previously absent entirely:

```
tenant_users.pin_hash           text        -- bcrypt
tenant_users.pin_failed_attempts int
tenant_users.pin_locked_until   timestamptz
```

Five attempts, then a 15-minute lockout. A 4-digit PIN is a 10,000-key space;
lockout is the only thing that makes it viable as a transaction control.

## 6. Data model — 33 tables

### 6.1 Count accounting

The 16 tables in the input artifacts become 33: **+11 genuinely missing**
(`warehouses`, `requisitions`, `requisition_items`, `orders`, `order_items`,
`routes`, `route_waypoints`, `field_check_ins`, `devices`, `audit_logs`,
`notifications`), **+3 platform** (`user_secure_profiles`,
`tenant_shop_coverage`, `idempotency_logs`), **+2 for the liquidity engine**
(`fintech_partners`, `otp_challenges`), and **+1 for brand-tier approvals**
(`brand_approval_policies`, decision 18).

Four candidates were dropped to keep the count down:

| Dropped | Instead |
|---|---|
| `sales` | merged into `orders` behind a `channel` discriminator — one revenue ledger, not two |
| `bank_accounts` | settlement snapshot on `fintech_advances` at disbursement, which is also better for audit |
| `alerts` | deferred post-launch; `notifications` carries what launch needs |
| `inventory_movements` | struck by decision 10; `audit_logs` carries stock history |

### 6.2 Enums and workflow statuses

Stable sets are enums. Workflow statuses are `text` + `CHECK`, so they evolve
without `ALTER TYPE`.

```sql
-- enums
platform_role_enum      PLATFORM_SUPER_ADMIN
tenant_role_enum        ZSM TM ASM DSM DSA FINTECH_AGENT RETAIL_SHOP_OWNER
tenant_status_enum      ACTIVE SUSPENDED INACTIVE
tenant_user_status_enum ACTIVE INVITED DISABLED
kyc_status_enum         UNVERIFIED PENDING VERIFIED REJECTED
density_category_enum   HIGH_DENSITY MARKET_SQUARE EVENT_CENTER SUBURBAN
gateway_provider_enum   PAYSTACK
pos_network_enum        MONIEPOINT OPAY PALMPAY
payment_status_enum     INITIATED PROCESSING SUCCESS FAILED REFUNDED
commission_status_enum  SPLIT SETTLED DISPUTED
warehouse_kind_enum     CENTRAL REGIONAL STOCKIST
order_channel_enum      ONLINE FIELD_DSA RETAIL
audit_source_enum       USER SYSTEM WEBHOOK CRON
otp_purpose_enum        PICKUP_CONFIRM POS_SETTLEMENT

-- text + CHECK
requisitions.status          DRAFT PENDING_APPROVAL APPROVED REJECTED FULFILLED CANCELLED
orders.status                PENDING PAID IN_TRANSIT DELIVERED CANCELLED REFUNDED
retail_stock_pickups.status  PENDING_CONFIRMATION CONFIRMED DISPUTED
fintech_advances.status      PENDING APPROVED DISBURSED REPAID DEFAULTED REJECTED
routes.status                PLANNED IN_PROGRESS COMPLETED CANCELLED
idempotency_logs.status      IN_PROGRESS COMPLETED FAILED
```

`order_status_enum` from the input artifact carried `TM_APPROVED` and
`HQ_APPROVED`. Those belonged to the approval ladder, not to revenue, and the HQ
tier no longer exists; they move to `requisitions` as approval *levels*.

**Gateway and POS network are two different axes.** The input artifacts
conflated them in a single `gateway_provider_enum` of
`PAYSTACK OPAY MONIEPOINT`. They are unrelated: **Paystack is the exclusive
collection engine** — every digital payment, webhook and split settlement routes
through it — while Moniepoint, OPay and PalmPay are *POS agent networks* acting
as local liquidity nodes. A shop owner settles an order at a nearby POS agent
whose terminal belongs to one of those networks, and the money reaches Teafair
through Paystack. So `gateway_provider_enum` holds one value and
`pos_network_enum` is a separate dimension on `fintech_partners`.

### 6.3 Tenancy and identity (6)

```
tenants(id, name, code UNIQUE, status, logo_url, created_at, updated_at)
        -- no commission_rate: the rate is per-partner, in
        -- fintech_partners.commission_bps (§6.7)

tenant_settings(tenant_id PK → tenants, currency DEFAULT 'NGN',
                timezone DEFAULT 'Africa/Lagos',
                allow_shared_network BOOLEAN DEFAULT TRUE,
                custom_fields JSONB)

tenant_users(id, tenant_id, profile_id → profiles, role tenant_role_enum,
             zone_id?, territory_id?, reports_to_id? → tenant_users,
             is_primary, status, pin_hash?, pin_failed_attempts,
             pin_locked_until?, created_at, updated_at)
             UNIQUE(tenant_id, profile_id)

profiles(id PK → auth.users, full_name, phone_number UNIQUE, email UNIQUE?,
         platform_role platform_role_enum NULL, kyc_status,
         created_at, updated_at)

user_secure_profiles(user_id PK → profiles,
                     bvn_nin_hash UNIQUE, bvn_hash_version SMALLINT,
                     bvn_nin_hash_prev?, bvn_hash_prev_version?,
                     bank_name, bank_account_number, bank_code, verified_at?)
                     -- versioning and rotation: §4.5

devices(id, user_id → profiles, hardware_id, device_model, push_token?,
        last_seen_at)  UNIQUE(user_id, hardware_id)
```

`profiles.user_role` does not exist — role is per-tenant and cannot live on a
global row.

### 6.4 Geography and shared network (7)

```
zones(id, tenant_id, zone_name, zsm_id? → profiles,
      boundary GEOMETRY(MultiPolygon, 4326), created_at)

territories(id, tenant_id, zone_id → zones, territory_name,
            tm_id? → profiles,
            boundary GEOMETRY(MultiPolygon, 4326), created_at)

retail_shops(id, shop_name, contact_phone, owner_id? → profiles,
             density_category, location GEOMETRY(Point,4326),
             address_text, created_at, updated_at)        -- GLOBAL

tenant_shop_coverage(tenant_id, retail_shop_id → retail_shops,
                     territory_id → territories, assigned_by, assigned_at)
                     PRIMARY KEY (tenant_id, retail_shop_id)

routes(id, tenant_id, territory_id, assigned_staff_id, route_date, status)

route_waypoints(id, tenant_id, route_id → routes, seq, landmark_name,
                location GEOMETRY(Point,4326), geofence_radius_m)

field_check_ins(id, tenant_id, route_id?, waypoint_id?, user_id,
                location GEOMETRY(Point,4326), captured_at,
                within_geofence BOOLEAN)
```

GIST indexes on all three geometry columns, since `territory-route-geosync`
queries all of them:

```sql
CREATE INDEX idx_retail_shops_geo    ON retail_shops    USING GIST (location);
CREATE INDEX idx_route_waypoints_geo ON route_waypoints USING GIST (location);
CREATE INDEX idx_field_checkins_geo  ON field_check_ins USING GIST (location);
CREATE INDEX idx_zones_boundary      ON zones           USING GIST (boundary);
CREATE INDEX idx_territories_boundary ON territories    USING GIST (boundary);
```

The first corrects a syntax error in the input artifact, which was missing its
table name and would have failed to apply.

### 6.5 Catalogue and inventory (4)

```
warehouses(id, tenant_id, name, kind warehouse_kind_enum,
           territory_id?, location?, manager_id? → profiles)

brand_approval_policies(tenant_id, brand,
                        required_approval_level tenant_role_enum
                          CHECK (IN ('DSM','ASM','TM','ZSM')),
                        updated_by → profiles, updated_at)
                        PRIMARY KEY (tenant_id, brand)       -- §5.4

central_products(id, tenant_id, sku_code, product_name, brand, category,
                 unit_price NUMERIC(15,2), wholesale_price NUMERIC(15,2),
                 description?, is_active, created_at)
                 UNIQUE(tenant_id, sku_code)

inventory_batches(id, tenant_id, warehouse_id → warehouses, sku_code,
                  batch_number, quantity NUMERIC(14,3) CHECK (quantity >= 0),
                  expires_at?, created_at)
                  FOREIGN KEY (tenant_id, sku_code)
                    REFERENCES central_products(tenant_id, sku_code)
```

Three corrections folded in: `warehouse_destination_id` now has a real FK target;
money widens to `NUMERIC(15,2)` and quantities to `NUMERIC(14,3)` so that
cartons-and-units and weighed goods survive; `stockistOrgId` resolves to
`warehouses` where `kind = 'STOCKIST'`, operated internally by an ASM or DSM —
stockists have no independent login role at launch.

### 6.6 Commerce (6)

```
requisitions(id, tenant_id, source_warehouse_id → warehouses,
             dest_warehouse_id → warehouses, requested_by,
             status, current_approval_level?, required_approval_level,
             total_value NUMERIC(15,2), created_at, updated_at)

requisition_items(id, tenant_id, requisition_id → requisitions, sku_code,
                  requested_qty NUMERIC(14,3), approved_qty?, fulfilled_qty?)

orders(id, tenant_id, channel order_channel_enum, retail_shop_id?,
       agent_id? → profiles, customer_name?, customer_phone?,
       total_amount NUMERIC(15,2), status, tracking_reference?,
       created_at, updated_at)

order_items(id, tenant_id, order_id → orders, sku_code,
            qty NUMERIC(14,3), unit_price NUMERIC(15,2),
            line_total NUMERIC(15,2))

retail_stock_pickups(id, tenant_id, retail_shop_id → retail_shops,
                     dsa_agent_id → profiles, dsm_supervisor_id?,
                     event_tag?, status, confirmed_by?, confirmed_at?,
                     escalated_at?, created_at)      -- escalation: §7.4

retail_stock_pickup_items(id, tenant_id, pickup_id → retail_stock_pickups,
                          sku_code, quantity_picked NUMERIC(14,3))
```

`payments.order_id` and `commission_records.sale_id` both now resolve to
`orders(id)` with real foreign keys; in the input artifact both were
`NOT NULL` columns pointing at nothing.

**One event, two entry points.** `log_retail_pickup` (DSA-initiated) and
`record_dsa_stock_issue` (shop-owner-initiated) are not two tables. They are two
ways into the same `retail_stock_pickups` row: whichever party acts first creates
it, and the other party's action is the confirmation that moves it from
`PENDING_CONFIRMATION` to `CONFIRMED` (§7.4). A DSA with signal and a shop owner
with signal therefore converge on one record rather than producing a duplicate
pair that has to be reconciled later.

**Shop-level stock balances are deferred** (§10). The pickup and issue events
record quantities, so a shop's position is derivable from
`retail_stock_pickup_items` plus the orders fulfilled from that shop. Whether
that derivation gets cached into a balance table is a Spec C decision, taken
when the `retail-shop-owner` screens define what they actually need to display.
Until then `inventory_batches` tracks warehouse and stockist stock only, and
nothing in this spec decrements a shop.

### 6.7 Money and the liquidity engine (6)

```
fintech_partners(id, tenant_id, business_name, pos_network pos_network_enum,
                 commission_bps INT CHECK (commission_bps BETWEEN 0 AND 10000),
                 territory_id? → territories, contact_phone,
                 paystack_subaccount_code, status, approved_by,
                 approved_at, created_at)
                 UNIQUE(tenant_id, pos_network, business_name)

payments(id, tenant_id, order_id → orders, customer_id? → profiles,
         teafair_agent_id → profiles, fintech_partner_id? → fintech_partners,
         fintech_terminal_id? → fintech_terminals,
         amount NUMERIC(15,2) CHECK (amount > 0),
         gateway_provider gateway_provider_enum DEFAULT 'PAYSTACK',
         payment_status, paystack_reference, otp_challenge_id? → otp_challenges,
         gateway_response_payload JSONB, created_at, updated_at)
         UNIQUE(tenant_id, paystack_reference)

commission_records(id, tenant_id, order_id → orders, payment_id → payments,
                   fintech_partner_id → fintech_partners,
                   teafair_agent_id → profiles,
                   amount NUMERIC(15,2), bps_applied INT,
                   paystack_split_reference, paystack_subaccount_code,
                   status commission_status_enum, settled_at?,
                   dispute_reason?, created_at)
                   -- SPLIT at collection, SETTLED once matched against
                   -- Paystack's settlement report, DISPUTED on mismatch.
                   -- There is no approval state: nothing human gates this.

fintech_terminals(id, tenant_id, partner_id → fintech_partners,
                  agent_id? → profiles, terminal_id, territory_id?,
                  is_active, created_at)
                  UNIQUE(tenant_id, terminal_id)

fintech_advances(id, tenant_id, partner_id? → fintech_partners,
                 agent_id → profiles,
                 requested_amount NUMERIC(15,2) CHECK (> 0),
                 repayment_duration_days INT CHECK (BETWEEN 1 AND 30),
                 status, disbursed_to_bank_code?,
                 disbursed_to_account_last4?, disbursed_at?, repaid_at?,
                 created_at)

cash_audit_batches(id, tenant_id, agent_id → profiles,
                   teller_receipt_number,
                   declared_cash_amount NUMERIC(15,2) CHECK (>= 0),
                   digital_collection_total NUMERIC(15,2) CHECK (>= 0),
                   variance_reason?, is_reconciled, created_at)
                   UNIQUE(tenant_id, teller_receipt_number)
```

### 6.8 Platform (4)

```
otp_challenges(id, tenant_id, subject_id → profiles,
               purpose otp_purpose_enum, code_hash, destination_phone,
               issued_by → profiles, expires_at, consumed_at?,
               failed_attempts, locked_until?, created_at)

idempotency_logs(key UUID PK, tenant_id?, actor_id, operation,
                 request_hash, response JSONB, status, created_at)

audit_logs(id, tenant_id?, actor_id?, actor_role TEXT,
           teafair_agent_id?, operation,
           entity_type, entity_id, before JSONB, after JSONB,
           idempotency_key?, source audit_source_enum, created_at)

notifications(id, tenant_id?, user_id → profiles, kind, title, body,
              payload JSONB, read_at?, created_at)
```

### 6.9 Conventions across the model

- Money is `NUMERIC(15,2)`; quantities are `NUMERIC(14,3)`; all timestamps are
  `timestamptz`.
- Every FK out of `tenants` is `ON DELETE RESTRICT`. The input artifact used
  `CASCADE`, which would have erased a client's payments, commissions and cash
  audits on offboarding, making any later audit impossible to answer.
- `updated_at` is maintained by a shared `set_updated_at()` trigger. In the
  input artifact these columns defaulted to `NOW()` and never advanced.
- `zones.zsm_id` and `territories.tm_id` are constrained by trigger to a profile
  holding an ACTIVE `tenant_users` row in the same tenant with the matching role.
- `zones` and `territories` carry `boundary GEOMETRY(MultiPolygon, 4326)` with
  GIST indexes, so territory assignment and geofence checks are spatial rather
  than by lookup table.

### 6.10 Agent accountability

`actor_id` and `teafair_agent_id` are different things and both are recorded.

The actor is whoever made the call — which on a POS-backed settlement is a
`RETAIL_SHOP_OWNER` or a partner's agent, neither of whom works for Teafair. The
`teafair_agent_id` is the Teafair staff member (`DSA`, `DSM`, `TM`) accountable
for that trade cluster. Without the second column, a disputed settlement traces
back only to a shop owner, and nobody inside the business owns it.

It is therefore `NOT NULL` on `orders`, `payments` and `commission_records`, and
nullable on `audit_logs` only because platform-level and cron rows have no
supervising agent. The RPC derives it from the order's cluster rather than
accepting it as a parameter.

### 6.11 The dual-validation handshake

A POS-backed settlement needs two independent proofs before it is believed, and
`complete_pos_backed_order` will not write a commission row without both:

| Proof | What it establishes | Source |
|---|---|---|
| **Paystack reference** | the funds actually moved | verified server-side against the Paystack API inside the gateway, never trusted from the client |
| **Shop-owner OTP** | the physical stock actually changed hands | `otp_challenges` row, SMS-delivered, hash-compared in the RPC |

Either one alone is forgeable by a single party: a POS agent with a reference
but no OTP may have collected cash without releasing stock; an OTP with no
reference means stock moved on credit, which is the exact street-credit trap the
product exists to remove. Requiring both is what lets commission be split
automatically without a human approving each one.

`otp_challenges` carries the controls the input artifacts had no home for:
single use via `consumed_at`, a short `expires_at`, `failed_attempts` with
`locked_until`, and issuance rate limiting per `subject_id`. The code is stored
hashed, never in plaintext.

## 7. Offline queue and idempotency

### 7.1 Storage

MMKV, via `src/store/mmkvStorage.ts`. Appropriate for a bounded write queue plus
a read cache of a few thousand rows.

> The resolution document said "SQLite/AsyncStorage" while the target tree
> specifies MMKV. MMKV is adopted. Revisit only if the agent read cache grows
> past roughly ten thousand rows, where a queryable store starts to earn its
> cost.

### 7.2 Queue entry

```ts
type QueuedMutation = {
  id: string            // UUIDv4 — IS the idempotency_key, generated at enqueue
  operation: string     // gateway function name
  payload: unknown      // Zod-validated at enqueue, before it ever leaves
  dependsOn?: string    // ordering within a causal chain
  attempts: number
  nextAttemptAt: number
  lastError?: { code: string; message: string; terminal: boolean }
  status: "PENDING" | "IN_FLIGHT" | "TERMINAL" | "DONE"
}
```

The key is generated **at enqueue, not at send**. That is what makes a retry
after an ambiguous timeout safe: the retry carries the same key, so the RPC
recognises it. Validating with Zod at enqueue means a malformed mutation fails
in the user's hands rather than rotting silently in the queue.

### 7.3 Drain

Strict FIFO within a `dependsOn` chain — a sale from picked-up stock cannot land
before the pickup — and parallel across chains. Exponential backoff from 2s to
5m. Retry on 503 and network failure; stop immediately on 409 and 422 per §3.5
and move the entry to a visible "Needs attention" list. The alternative is an
invisible infinite retry against a business rule that will never pass.

### 7.4 PIN-gated operations and the pickup path

The gateway bcrypt-verifies PINs against `tenant_users.pin_hash`, which is
server-side by design. Caching any verifier on the device would defeat the
control. So PIN-gated operations normally require connectivity at the moment of
action: `record_dsa_stock_issue`, `approve_requisition` at the `TM` or `ZSM`
level, `set_brand_approval_policy`, `adjust_inventory`.

`log_retail_pickup` is the exception, because it is a core field action in
exactly the places where signal is worst. It uses a deferred-confirmation path:

1. The DSA logs the pickup offline. It enqueues and lands as
   `status = 'PENDING_CONFIRMATION'`, with no PIN.
2. The shop owner confirms from their own app when either device reconnects,
   which sets `CONFIRMED`, `confirmed_by` and `confirmed_at`.
3. A pickup still `PENDING_CONFIRMATION` **24 hours** after it landed is
   escalated. The shop owner can instead mark the pickup `DISPUTED` at any
   time.

**The escalation job.** `public.escalate_stale_pickups()` runs from `pg_cron`
every 15 minutes, so an escalation fires between 24 hours and 24 hours 15
minutes after landing. For each pickup that is `PENDING_CONFIRMATION`, has
`created_at < now() - interval '24 hours'` and has `escalated_at IS NULL`, it:

- sets `escalated_at = now()` — this is the flag, and it stops a second
  escalation;
- sends a `notifications` row to `dsm_supervisor_id`, or, when that is null, to
  the DSA's `reports_to_id` holding the `DSM` role;
- writes an `audit_logs` row with `source = 'CRON'`.

The status stays `PENDING_CONFIRMATION`, so the shop owner can still confirm or
dispute; the DSM intervenes manually. The 24 hours run from `created_at`, the
server time the pickup landed. A pickup logged offline for two days therefore
gets its full 24 hours once it arrives, because the shop owner could not
confirm it before then.

This keeps the control and the offline path. The pickup is an event record, not
a balance mutation — no shop stock is decremented (§6.6) — so step 1 committing
before confirmation cannot corrupt an inventory figure. The confirmation is the
accountability record, not the gate.

### 7.5 Read cache

supabase-js reads persist to MMKV with a per-class TTL:

| Class | TTL | Refresh |
|---|---|---|
| master data — products, territories, shops | long | on app foreground |
| operational lists — own pickups, own orders | short | on screen focus |
| money — balances, commissions | never served stale | spinner, or an explicitly stale-marked value |

Server timestamps are authoritative throughout. The client's `captured_at` is
recorded alongside and never substituted, because field device clocks drift.

## 8. RLS policy inventory

Grants, before any policy:

```sql
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM authenticated, anon;
```

Helpers, in `public`:

```sql
-- active tenant from the verified JWT. Actor comes from auth.uid() directly;
-- a jwt_user_id() wrapper would only reimplement it.
CREATE OR REPLACE FUNCTION public.jwt_tenant_id()
RETURNS uuid LANGUAGE sql STABLE
SET search_path = public, pg_temp AS $$
  SELECT NULLIF(
    (select auth.jwt()) -> 'app_metadata' ->> 'active_tenant_id', ''
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION public.is_tenant_member(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM tenant_users tu
    WHERE tu.tenant_id = p_tenant_id
      AND tu.profile_id = (select auth.uid())
      AND tu.status = 'ACTIVE'
  );
$$;

CREATE OR REPLACE FUNCTION public.tenant_role(p_tenant_id uuid)
RETURNS tenant_role_enum LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public, pg_temp AS $$
  SELECT tu.role FROM tenant_users tu
  WHERE tu.tenant_id = p_tenant_id
    AND tu.profile_id = (select auth.uid())
    AND tu.status = 'ACTIVE'
  LIMIT 1;
$$;
```

> **Do not read claims through `current_setting('request.jwt.claim.<name>')`.**
> PostgREST removed those per-claim GUCs in favour of a single
> `request.jwt.claims` JSON setting, so the per-claim form returns `NULL` on
> current Supabase and a predicate built on it fails open or closed silently
> depending on how it is written. Use `auth.jwt()`, as above.

**Implementation notes (Phase 2).**

- Policies express the live membership check set-wise —
  `tenant_id in (select public.my_tenant_ids())` — rather than calling
  `public.is_tenant_member(tenant_id)` per row. Both read `tenant_users` live
  with the same predicate; the set form is evaluated once per statement and
  hashed. `is_tenant_member()` and `tenant_role()` remain for RPC bodies.
- Secrets are excluded by **column** grant as well as by policy:
  `tenant_users.pin_hash` and `otp_challenges.code_hash` are never selectable
  by `authenticated`, even on rows the caller may otherwise read.
- Postgres grants `EXECUTE` to `PUBLIC` on every new function through a
  global default that a per-schema default cannot remove. The grants
  migration revokes it globally for functions `postgres` creates; every
  function the API may call is granted explicitly.

Policies are **`FOR SELECT` only**. There are no `INSERT`, `UPDATE` or `DELETE`
policies on business tables, because the grants above make them unreachable;
writes arrive through `SECURITY DEFINER` RPCs.

| Table group | `FOR SELECT USING` |
|---|---|
| Class A (all tenant-scoped) | `public.is_tenant_member(tenant_id)` |
| `retail_shops` | member of any ACTIVE tenant; narrowed to `tenant_shop_coverage` when that tenant has `allow_shared_network = false` |
| `tenant_shop_coverage` | `public.is_tenant_member(tenant_id)` |
| `tenants` | `public.is_tenant_member(id)` |
| `tenant_settings` | `public.is_tenant_member(tenant_id)` |
| `tenant_users` | `profile_id = (select auth.uid())` OR `public.is_tenant_member(tenant_id)` |
| `profiles` | `id = (select auth.uid())` OR shares an ACTIVE tenant membership |
| `user_secure_profiles` | `user_id = (select auth.uid())` — owner only |
| `devices` | `user_id = (select auth.uid())` |
| `notifications` | `user_id = (select auth.uid())` |
| `audit_logs` | `public.is_tenant_member(tenant_id)` AND `public.tenant_role(tenant_id) IN ('ZSM','TM')` |
| `idempotency_logs` | `actor_id = (select auth.uid())` |
| `otp_challenges` | `subject_id = (select auth.uid())` — code_hash column never selectable by the client |
| `fintech_partners` | `public.is_tenant_member(tenant_id)` |

The input artifact used `FOR ALL USING (is_tenant_member(tenant_id))` on
thirteen tables. Because `FOR ALL` covers writes, and Postgres reuses `USING` as
the `WITH CHECK` when none is given, any ACTIVE member of a tenant could rewrite
product prices, insert themselves a `PAID` commission, flip a payment to
`SUCCESS`, zero out a cash audit, or delete pickup records. Tenant isolation
held; authorisation within a tenant did not exist. Restricting policies to
`SELECT` and routing writes through RPCs is what closes that.

## 9. Conventions that hold from here

- **Never** grant `INSERT`, `UPDATE` or `DELETE` on a business table to
  `authenticated`. Every mutation is a `SECURITY DEFINER` RPC.
- **Never** accept `tenantId` from a client payload. Read the claim, verify the
  membership.
- **Never** call an RPC from a user-facing Edge Function with the service-role
  key. Forward the caller's `Authorization` header.
- **Never** create a function or helper in the `auth` schema. Use `public`.
- Every `SECURITY DEFINER` function pins `SET search_path = public, pg_temp`.
- RLS predicates use `(select auth.uid())` and `public.*` helpers, never a
  per-row correlated subquery.
- Workflow statuses are `text` + `CHECK`; stable sets are enums.
- Money `NUMERIC(15,2)`, quantities `NUMERIC(14,3)`, timestamps `timestamptz`.
- Every mutation carries a client-generated `p_idempotency_key`, checked inside
  the transaction.
- `.env` and `.env*.local` are gitignored. Supabase URLs and keys are never
  hardcoded; the Vault holds the BVN pepper and gateway secrets.

## 10. Deferred

Out of scope for this spec and for launch, recorded so they are not rediscovered
as gaps:

- `alerts` as a first-class table with acknowledge/resolve — `notifications`
  covers launch.
- `bank_accounts` as a table, enabling multiple settlement accounts per agent.
- `inventory_movements` as an append-only ledger, with nightly
  `pg_cron` reconciliation against `inventory_batches.quantity`.
- A cached shop-level stock balance. Shop position is derivable from pickup and
  order events at launch (§6.6); caching it is a Spec C decision.
- An independent `STOCKIST` login role; stockists are internally operated
  warehouses at launch.
- An `areas` table between territory and field, if ASM scope ever becomes
  geographic rather than a team tier.
- The Windows HQ desktop client, and with it the full master-data, finance and
  audit-browser surfaces. `windows-hq-ci.yml` and the stub remain in the tree.
- Push notifications beyond `devices.push_token` capture.
- FIRS e-invoicing and QuickBooks connectors.

## 11. Open questions

None. Every question raised during design is settled; the rulings are recorded
below for provenance.

> *Commission rate precedence* is **closed**:
> `fintech_partners.commission_bps` is the single source, negotiated per
> partner and stored in basis points. `tenants.commission_rate` and
> `commission_records.rate_applied` are removed.

### 11.1 Resolved rulings

The four questions raised by the liquidity blueprint are settled and have been
folded into §2 as locked decisions 12–16. Recorded here for provenance:

| Question | Ruling |
|---|---|
| Deployment target | **Supabase only.** Azure dropped entirely |
| Commission approval | **Fully automated.** No human gate |
| Who performs the split | **Paystack Subaccounts**, natively during collection |
| Shared network | **`retail_shops` stays global**, mapped via `tenant_shop_coverage` |

Two overrides this spec made against the blueprint were also confirmed as
permanent: claim helpers live only in `public` and never in `auth`, and
`bvn_nin_hash` lives only in `user_secure_profiles` and never on `profiles`.

The four open questions this spec carried were closed on 2026-10-06 and folded
into §2 as locked decisions 17–20:

| Question | Ruling |
|---|---|
| BVN pepper rotation | **Versioned hash column.** New hash stored alongside the old, lookups match either, rows migrate in the background (§4.5) |
| Requisition approval thresholds | **Brand-tier policies**, not cash value bands (§5.4) |
| Pickup confirmation threshold | **24 hours**, then escalation to the supervising DSM (§7.4) |
| Paystack webhook replay window | **±300 seconds**, measured against the event time, because the signature carries none (§3.6) |

A blueprint draft circulated on 2026-10-06 reintroduced five positions this
spec had already overruled. They were rejected and this document stands:
Azure as a target (decision 12); `bvn_nin_hash` on `profiles` (decision 16);
claim extractors in the `auth` schema reading
`current_setting('request.jwt.claim.*')`, which returns `NULL` on current
PostgREST (§8); RLS trusting claims without a live `tenant_users` check
(§4.4); and a non-null `teafair_agent_id` on cron and webhook audit rows
(§6.10).

## 12. Spec decomposition

This is Spec A of four. Each gets its own spec, plan and implementation cycle.

| # | Spec | Covers | Depends on |
|---|---|---|---|
| **A** | **this document** | tenancy, write contract, roles, data model, offline | — |
| B | App shell and structure | flat `src/`, navigation, phone/tablet topology, zustand slices, `tenant-selector`, auth/onboarding/splash, `windows/` stub, both CI workflows | A |
| C | RTM core | central-store, products-catalogue, stockist-distributors, retail-shop-owner, direct-sales, retail-footprint, zonal/territory/area oversight | A, B |
| D | Money and integrations | fintech-advance, payments, sales-funds-return, EOD reconciliation, KudiSMS, KYC provider, gateways | A, B, C |

## 13. Migration from the current repository

1. `supabase/` — ordered, hand-written migrations: the 33 tables, enums,
   helpers, RLS, grants, RPCs, cron jobs, seeds, type generation. Supabase CLI
   owns all DDL. Declarative schemas (`supabase/schemas/` + `db diff`) are not
   used: grants and revokes, comments, column privileges and DML — including
   `cron.schedule` — are on the diff engine's documented caveat list, and
   grants are the security core of §8.
2. `src/` — the flat app structure per the target tree, replacing the
   `apps/` + `packages/` layout from the superseded architecture spec.
3. Delete `frontend/` — 824 lines across 55 files, mostly placeholder modules
   from the single-tenant Expo scaffold. Nothing is ported; the patterns worth
   keeping (injectable Supabase client, result unwrapping, storage adapter,
   auth-store shape) are re-created fresh against this spec.
4. `prisma/` is not created. Prisma is retired.
5. `CLAUDE.md`, `apps/CLAUDE.md` and `supabase/CLAUDE.md` describe the
   superseded architecture and must be rewritten against this spec as part of
   the Spec B scaffold plan.
6. The 15 docs in `docs/features/` are marked superseded-in-part: behavioural
   reference retained, architecture and roles replaced by this document.

## 14. Implementation roadmap

Spec A ships in four phases. Each phase gets its own plan, and each phase ends
with tests passing against a local Supabase stack (`supabase start`,
`supabase db reset`, `supabase test db`).

| Phase | Delivers | Spec sections |
|---|---|---|
| **1. Database schema and migration core** | Supabase CLI project; extensions (`pgcrypto`, `postgis`, `pg_cron`); every enum; the 33 tables with keys, checks, indexes and `updated_at` triggers; `audit_logs` append-only backstop | §4.2, §6 |
| **2. Security, RLS and atomic RPCs** | grants and revokes; the `public.*` claim and membership helpers; every `FOR SELECT` policy; the write-RPC skeleton (idempotency, audit, error codes); foundation RPCs; `requisition_required_level()`; `escalate_stale_pickups()` and its cron job | §3.3, §3.5, §4.4, §5, §8 |
| **3. Edge Function gateway layer** | shared gateway module (JWT, Zod, PIN, error mapping); `auth-verify-claims` access-token hook; `process-payment` with the §3.6 checks; OTP issue and verify | §3.1–3.6, §6.11 |
| **4. Client-side foundation** | React Native (Expo) + TypeScript; MMKV write queue with enqueue-time keys, `dependsOn` FIFO and 2 s–5 min exponential backoff; `PENDING_CONFIRMATION` offline pickup; read cache | §7 |

**Status (2026-10-06):** phases 1 and 2 are implemented in
`supabase/migrations/` and verified by 200 pgTAP assertions in
`supabase/tests/database/`.

Phase 4 is built inside the Spec B app shell. Feature RPCs and gateways beyond
the foundation set belong to Specs C and D.

