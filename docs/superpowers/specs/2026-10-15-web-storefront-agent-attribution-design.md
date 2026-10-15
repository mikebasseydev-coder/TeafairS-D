# Web storefront and agent attribution — Spec A addendum A1

**Date:** 2026-10-15
**Status:** draft — awaiting review
**Amends:** Spec A (`2026-10-05-multi-tenant-rtm-foundation-design.md`) §2,
§3.4, §6.2, §6.6, §6.7 and §8. Where this document and Spec A disagree on the
subjects below, this document governs; everything else in Spec A stands.

## 1. Purpose

`teafairweb.com` is a public storefront hosted on Vercel in its own repository
(`teafair-web`), sharing this Supabase project. POS agents are distribution
nodes: each shares a link carrying an **agent code** among the people at their
venue — a church, a mosque, a hospital, an office complex. A buyer who opens
the link sees that tenant's catalogue and places an order, and the order is
credited to the agent and the venue.

Buyers have no account and never use the mobile app. Agents use the app only to
complete payments taken at their terminal (§6, Spec D).

This addendum covers the backend only: schema, RPCs and two public gateways.
The website itself lives in `teafair-web` and is out of scope here. The mobile
app stays frozen until Spec B.

## 2. Decisions

1. **A third gateway flavour: `public`.** Spec A has `user` (forwards the
   caller's JWT) and `system` (signature or cron secret). A web buyer has
   neither. Public gateways accept unauthenticated callers, call RPCs granted
   **only to `service_role`**, and are hardened as in §5. Spec A's rule "never
   call an RPC from a user-facing function with the service-role key" still
   holds for `user` gateways; a public gateway has no user JWT to forward.
2. **The agent code resolves the tenant.** The browser never sends a tenant id.
   The RPC looks the code up and takes the tenant from that row, so decision 4
   ("`tenantId` is never accepted from the client") is kept.
3. **One revenue ledger.** Web sales are `orders` rows with
   `channel = 'ONLINE'` plus `payments` rows, confirmed by the existing
   `process-payment` webhook and Verify-API sweep (§3.6). There is no separate
   web-purchase table.
4. **Venue belongs to the terminal, not the agent.** An agent running two
   terminals at two venues has two venues. Venue fields go on
   `fintech_terminals`; an agent code may be bound to one terminal.
5. **Venue type is a separate axis from `orders.channel`.** `order_channel_enum`
   says how a sale was made; `venue_channel_enum` says where a terminal sits.
   No venue values are added to `order_channel_enum`.
6. **One code per link.** The agent code *is* the referral link and the
   optional promo code. There is no separate promo-code table, and redemptions
   are orders that reference the code.
7. **Payment route is chosen at checkout (option C).** `PAYSTACK_WEB` — the
   buyer pays on the website through Paystack. `POS_AGENT` — the buyer pays at
   the agent's terminal, and the agent completes it in the app.
8. **Attribution is stored on the order, not as visitor logs.** Agent code,
   attributed agent, attributed terminal and `utm_source/medium/campaign` are
   order columns. Page views and sessions stay in GA4 and the ad pixels; the
   database stores no visitor sessions, device data or IP addresses.
9. **Web-route commission is a referral split.** On `PAYSTACK_WEB` orders whose
   code is bound to a terminal, the partner's Paystack subaccount takes
   `commission_bps` of the charged amount at collection (decision 13). §6.11's
   dual validation governs POS settlement, where an agent handles money and
   stock; on the web route the buyer pays Paystack directly and the agent
   handles neither, so it does not apply.

## 3. Schema

### 3.1 New enum values

```sql
create type public.venue_channel_enum as enum (
  'CHURCH', 'MOSQUE', 'HOSPITAL', 'OFFICE_COMPLEX', 'RESIDENTIAL_ESTATE',
  'EDUCATIONAL_INSTITUTION', 'EVENT_CENTER', 'TRANSIT_HUB', 'OPEN_MARKET', 'OTHER'
);

alter type public.audit_source_enum add value 'WEB';   -- own migration file
```

`audit_source_enum` gains `WEB` for rows written through a public gateway:
no actor, like `WEBHOOK`.

### 3.2 `fintech_terminals` — venue columns

| Column | Type | Notes |
|---|---|---|
| `venue_channel` | `venue_channel_enum` | nullable until the venue is set |
| `venue_name` | `text` | e.g. "RCCG Grace Parish"; `btrim` non-empty when set |
| `address_text` | `text` | street address |
| `state` | `text` | Nigerian state |
| `lga` | `text` | Local Government Area |
| `location` | `extensions.geometry(Point, 4326)` | GIST index |
| `operating_hours` | `jsonb` | object; keys `mon`…`sun`, values `"HH:MM-HH:MM"` or `"closed"` |

A check keeps the venue all-or-nothing: `venue_channel`, `venue_name`,
`address_text`, `state` and `location` are either all null or all set.
Read access is unchanged: Class A, members of the tenant.

### 3.3 `agent_codes` — new table (Class A)

```
agent_codes(id, tenant_id → tenants RESTRICT,
            code text UNIQUE,                 -- ^[A-Z0-9][A-Z0-9-]{3,31}$, stored upper-case
            agent_id → profiles,
            terminal_id? → fintech_terminals  (composite tenant FK),
            discount_type? text CHECK IN ('PERCENT','FIXED'),
            discount_value? NUMERIC(15,2),
            max_redemptions? INT CHECK (> 0),
            expires_at? timestamptz,
            is_active boolean DEFAULT true,
            created_by → profiles,
            created_at, updated_at)
            UNIQUE (tenant_id, id)
```

- `code` is unique across **all** tenants, because the link alone must resolve
  the tenant.
- Discount: both columns null, or both set. `PERCENT` is `> 0 AND <= 100`;
  `FIXED` is `> 0`.
- The agent must hold an ACTIVE `tenant_users` row in the same tenant. A code
  for a staff member (DSA, DSM, …) works as a **house code** for organic and
  social traffic.
- If `terminal_id` is set, that terminal's `agent_id` must equal the code's
  `agent_id`.
- RLS: `FOR SELECT` to tenant members, like every Class A table.

### 3.4 `orders` — attribution and web columns

| Column | Type | Notes |
|---|---|---|
| `agent_code_id` | `uuid` | composite FK `(tenant_id, agent_code_id)` → `agent_codes` |
| `attributed_agent_id` | `uuid → profiles` | snapshot at checkout |
| `attributed_terminal_id` | `uuid` | composite FK → `fintech_terminals`; snapshot at checkout |
| `utm_source`, `utm_medium`, `utm_campaign` | `text` | each ≤ 100 chars |
| `payment_route` | `text` CHECK IN (`'PAYSTACK_WEB'`, `'POS_AGENT'`) | null for non-web orders |
| `discount_amount` | `NUMERIC(15,2) NOT NULL DEFAULT 0` | `>= 0` |
| `customer_email` | `text` | lower-case, optional |
| `delivery_address` | `text` | required on web orders |
| `public_reference` | `text UNIQUE` | `TF-` + 6 Crockford base-32 characters (no I, L, O, U), shown to the agent, e.g. `TF-7K3Q9X` |

A check ties them together: when `channel = 'ONLINE'` and `agent_code_id` is
set, `payment_route`, `attributed_agent_id`, `delivery_address` and
`public_reference` are all set. `total_amount` is the sum of line totals minus
`discount_amount`. Snapshots keep historical attribution correct if the code is
later rebound.

Indexes: `(tenant_id, agent_code_id)`, `(attributed_agent_id)`,
`(tenant_id, attributed_terminal_id)`, and the unique `public_reference`.

The model grows from 33 to 34 tables.

## 4. RPCs

All follow the write contract (`p_idempotency_key` first, audit row per
effect, `SET search_path = public, pg_temp`).

### 4.1 Management — `authenticated`, called through PostgREST

| RPC | Roles | Scope |
|---|---|---|
| `set_terminal_venue(key, terminal_id, venue_channel, venue_name, address_text, state, lga, lat, lng, operating_hours)` | `ZSM`; `TM`; `FINTECH_AGENT` | ZSM tenant-wide; TM terminals in their own territory; agent only terminals where `agent_id` is themselves |
| `upsert_agent_code(key, code, agent_id, terminal_id, discount_type, discount_value, max_redemptions, expires_at, is_active)` | `ZSM`; `TM` | ZSM tenant-wide; TM only for agents in their territory |

- `set_terminal_venue` rejects (`P0001`) a location outside the territory's
  `boundary` when the territory has one.
- `upsert_agent_code` creates or updates by `code`. A code's `tenant_id` and
  `agent_id` never change; to move a code, deactivate it and issue another.
  Agents cannot issue their own codes, because codes carry discounts.

### 4.2 Public — `service_role` only

| RPC | Kind | Does |
|---|---|---|
| `storefront_catalogue(p_code)` | read, `STABLE` | resolves the code; returns tenant name, logo and currency; the discount; venue name and channel; active products (`sku_code`, `product_name`, `brand`, `category`, `unit_price`, `description`). Never agent PII |
| `quote_web_order(p_code, p_items)` | read, `STABLE` | prices the cart: subtotal, discount, total, currency, and, when a split applies, the subaccount code and partner share. A split applies when the code is bound to a terminal whose partner has `status = 'ACTIVE'` (every partner carries a `paystack_subaccount_code`); the share is `round(total × commission_bps / 10000, 2)` |
| `place_web_order(key, p_code, p_items, p_customer, p_utm, p_payment_route, p_expected_total, p_checkout)` | write | creates the order, items and, on `PAYSTACK_WEB`, an `INITIATED` payment |

`EXECUTE` is revoked from `public`, `anon` and `authenticated`, and granted to
`service_role` only.

**Code validity** (all three): the code exists and is active; it has not
expired; the tenant is `ACTIVE`; the agent's membership is `ACTIVE`; a bound
terminal is active; and, if `max_redemptions` is set, the count of the code's
orders in `PAID`, `IN_TRANSIT` or `DELIVERED` is below it. An invalid code is
`P0001` with one message, "This link is no longer valid", whatever the reason.

**`place_web_order`**:

1. `idempotency_begin` — actor null, request hash over everything except
   `p_checkout`.
2. Validate items: 1–50 lines, distinct active SKUs of the code's tenant,
   integer `qty` from 1 to 1000. Price at `central_products.unit_price`.
3. Discount: `PERCENT` → `round(subtotal × value / 100, 2)`; `FIXED` →
   `value`; capped at the subtotal. The total must be `> 0` and must equal
   `p_expected_total`; otherwise `P0001` "Prices changed — refresh and try
   again".
4. Throttle: at most 5 `PENDING` web orders per `customer_phone` in the
   trailing hour, else `P0001`.
5. `teafair_agent_id` (§6.10): the attributed agent when their role is a staff
   tier (`DSA`, `DSM`, `ASM`, `TM`, `ZSM`); otherwise the `tm_id` of the
   bound terminal's territory, falling back to the agent's membership
   territory. If neither resolves, `P0001` "This link is not active yet".
6. Insert `orders` (`ONLINE`, `PENDING`, attribution snapshots,
   `public_reference`) and `order_items`.
7. On `PAYSTACK_WEB`: insert `payments` (`INITIATED`, `amount = total`,
   `paystack_reference` and `{access_code, authorization_url}` from
   `p_checkout`, `fintech_partner_id` and `fintech_terminal_id` from the bound
   terminal).
8. Audit with source `WEB`. Return `order_id`, `public_reference`, `total` and,
   on `PAYSTACK_WEB`, the reference and authorization URL.

## 5. Public gateways

### 5.1 Kernel — `_shared/core/public-gateway.ts`

- Allows only the origins in `WEB_ALLOWED_ORIGINS` (comma-separated env var)
  and answers CORS preflight. A request from any other `Origin` is 403. A
  request with no `Origin` (server-side rendering on Vercel) is served: CORS
  only governs browsers, so it is not an access control, and Turnstile is the
  gate on checkout.
- Strips any tenant key from the body, Zod-validates it, maps errors per §3.5.
- Uses `serviceRpc()`; imports nothing from the user-gateway path.
- `verify_jwt = false` in `config.toml`, as for every function.

### 5.2 `storefront-catalogue`

`GET ?code=…` → `storefront_catalogue`. The response carries
`Cache-Control: public, max-age=60, s-maxage=300`, so the Vercel CDN absorbs
traffic and the function sees roughly one call per code every five minutes.

### 5.3 `web-checkout`

`POST { idempotency_key, code, items, customer, utm?, payment_route,
turnstile_token }`. The browser generates `idempotency_key` once per checkout
attempt and reuses it on retry.

1. **Turnstile.** Verify `turnstile_token` with Cloudflare
   (`TURNSTILE_SECRET_KEY`). On failure → 403. The token is single-use and is
   not part of the idempotency hash.
2. **Normalise the phone.** `0803…` → `+234803…`; must match the E.164 check
   on `orders.customer_phone`.
3. `quote_web_order` → total and split.
4. **On `PAYSTACK_WEB`:** Paystack *Initialize Transaction* with a fresh
   reference (`TFW-<uuid>`), the quoted amount in kobo, the buyer's email or
   `order-<reference>@pay.teafairweb.com`, a `callback_url` on
   `teafairweb.com` and, when a split applies, `subaccount` with
   `transaction_charge` = total − partner share and `bearer = account`.
5. `place_web_order` with `p_expected_total` = the quoted total and
   `p_checkout` = the Paystack reference, access code and authorization URL.
6. Return `{ order_id, public_reference, total, payment_route,
   authorization_url? }`.

**Why initialize happens before the write.** A retry whose earlier attempt
committed gets the original order and the original authorization URL back from
`place_web_order` (idempotency replay). The new Paystack transaction that retry
initialized is never shown to the buyer and expires unpaid. Initializing after
the write would leave a committed order with no checkout URL whenever Paystack
fails, and re-initializing the same reference is rejected by Paystack as a
duplicate.

Amount, subaccount and charge are computed on the server, so a tampered browser
can change none of them. A tampered Paystack amount would still be caught by
`settle_paystack_payment`'s existing amount check (`PAYSTACK_MISMATCH`).

### 5.4 Secrets

| Secret | Used by |
|---|---|
| `PAYSTACK_SECRET_KEY` | `web-checkout` (already set for `process-payment`) |
| `TURNSTILE_SECRET_KEY` | `web-checkout`; locally Cloudflare's always-pass test key |
| `WEB_ALLOWED_ORIGINS` | both public gateways |
| `WEB_CHECKOUT_CALLBACK_URL` | `web-checkout`: Paystack's return URL on `teafairweb.com` |
| `TURNSTILE_VERIFY_URL` | optional; local tests point it at a fake |

## 6. Payment flows

**`PAYSTACK_WEB`.** The buyer pays on Paystack's page. `process-payment` (or
the `reconcile-funds` sweep) moves the payment to `SUCCESS`. Moving the order
to `PAID` and writing `commission_records` stay where Spec A already put them:
Spec C/D, not yet built.

**`POS_AGENT`.** `place_web_order` creates the order with no payment row and
returns the `public_reference`. The buyer shows it to the agent, who completes
payment in the app through `initiate_checkout` and `complete-pos-backed-order`
(Spec D). That settlement is a real POS settlement, so §6.11 applies. Spec D
must send its OTP to the order's `customer_phone`: web buyers have no
`profiles` row, so `otp_challenges.subject_id` must accept that case.

## 7. Testing

- **pgTAP:** `010`–`012_commerce_web_*.test.sql` cover schema shape; RLS
  (members read `agent_codes`, `anon`/`authenticated` cannot execute the public
  RPCs); `set_terminal_venue` and `upsert_agent_code` role scoping;
  code-validity rejections; pricing, the discount cap and `p_expected_total`;
  the throttle; `teafair_agent_id` resolution; idempotent replay; audit rows
  with source `WEB`.
- **Deno unit tests** beside each handler, with injected Paystack, Turnstile
  and RPC fakes: CORS, Turnstile failure, phone normalisation, the
  initialize-then-place order, replay returning the original URL, error
  mapping.
- **Integration:** extend `_tests/gateway.integration.ts` with a catalogue read
  and a `POS_AGENT` checkout against the local stack. Paystack is not called
  live.

Everything runs on the local stack. Nothing is pushed to the remote project
until explicitly asked.

## 8. Not in this addendum

- The `teafair-web` website itself.
- Order `PAID` transitions, `commission_records`, `initiate_checkout` and
  `complete-pos-backed-order` (Spec C/D).
- Cancelling abandoned `PENDING` web orders (a `pg_cron` job, Spec C).
- A buyer-facing order-status lookup.
- Collection from the agent's venue instead of delivery.
- Visitor/session logging, an ad-spend table and direct BI database access.
  If BI needs database access later, it gets a dedicated read-only role
  restricted to per-tenant reporting views, never a connection that bypasses
  RLS.
