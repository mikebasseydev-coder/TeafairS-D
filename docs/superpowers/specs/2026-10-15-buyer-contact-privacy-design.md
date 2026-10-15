# Buyer contact privacy — Spec A addendum A2

**Date:** 2026-10-15
**Status:** draft for review
**Amends:** Spec A (`2026-10-05-multi-tenant-rtm-foundation-design.md`) §6.6
and §8, and addendum A1 (`2026-10-15-web-storefront-agent-attribution-design.md`)
§3.4 and §4.2. Where this document disagrees with them on the subjects below,
this document governs.

## 1. Purpose

A1's final review left one go-live blocker: buyer contact details are readable
by every member of a tenant. Three places hold them.

| Where | What leaks | Who can read it today |
|---|---|---|
| `orders.customer_name`, `customer_phone`, `customer_email`, `delivery_address` | full contact details of every web and field buyer | every ACTIVE tenant member, including third-party `FINTECH_AGENT`s |
| `audit_logs.after` of `place_web_order` | the whole order row, contact details included | every ZSM and TM in the tenant, whatever their territory |
| `payments.gateway_response_payload` | Paystack's verified transaction: customer email, phone and name, card BIN and last 4 | every ACTIVE tenant member |

This addendum closes all three. Buyer contact details become visible only to
the staff who are accountable for fulfilling the order.

## 2. Decisions

1. **Contact details move to their own table, `order_contacts`.** One row per
   order. `orders` keeps no personal data. This follows the precedent of
   `user_secure_profiles` (Spec A decision 16): sensitive fields live in a
   separate table with a narrower policy, not behind column grants on a
   shared one.
2. **Who reads `order_contacts`:** a ZSM, every row in their tenant; a TM, rows
   whose `territory_id` is a territory they manage. Nobody else: not ASM, DSM,
   DSA, `FINTECH_AGENT` or `RETAIL_SHOP_OWNER`. Delivery staff get access when
   Spec C defines fulfilment.
3. **The POS agent gets a masked till lookup, not the row.** For a
   `POS_AGENT`-route order, the order's attributed agent can call
   `pos_order_lookup(public_reference)`. It returns the reference, the buyer's
   first name, the last four digits of the phone, the total and the status:
   enough to match the buyer at the terminal, nothing more. (Approved
   2026-10-15.)
4. **Field-sales orders move too.** Existing `customer_name` and
   `customer_phone` values on every order, whatever its channel, move into
   `order_contacts`. (Approved 2026-10-15.)
5. **The territory is stamped on the contact row at checkout.** It is the
   territory `place_web_order` already uses to find the accountable TM (the
   terminal's, else the code holder's). A staff code holder has their own
   territory; a ZSM has none, so a ZSM code gives a null territory and only
   ZSMs see that row. Migrated rows have a null territory until Spec C stamps
   field orders.
6. **Audit rows carry no contact details.** `place_web_order` audits the order
   row, which no longer holds them, plus a redacted summary:
   `{"phone_last4", "has_email", "has_address"}`. `audit_logs` is append-only,
   so existing rows cannot be scrubbed; this is safe because A1 never reached a
   live database. **A1 and A2 deploy together, or A2 first; never A1 alone.**
7. **Paystack's raw payload is withheld from `authenticated`.** Column grants
   exclude `payments.gateway_response_payload`, the same mechanism Spec A uses
   for `tenant_users.pin_hash` and `otp_challenges.code_hash`. The payload
   stays for `service_role` and the reconciliation jobs. The status, amount and
   reference columns stay readable.

## 3. Schema

### 3.1 `order_contacts` — new table (Class A, narrowed policy)

| Column | Type | Rule |
|---|---|---|
| `order_id` | `uuid` primary key | composite FK `(tenant_id, order_id)` → `orders`, `on delete restrict` |
| `tenant_id` | `uuid not null` | → `tenants`, `on delete restrict` |
| `territory_id` | `uuid` | composite FK `(tenant_id, territory_id)` → `territories`, `on delete restrict` |
| `customer_name` | `text` | non-blank when present |
| `customer_phone` | `text` | E.164: `^\+[1-9][0-9]{7,14}$` |
| `customer_email` | `text` | stored lower-case |
| `delivery_address` | `text` | non-blank when present |
| `created_at` | `timestamptz not null default now()` | |
| `updated_at` | `timestamptz not null default now()` | `set_updated_at()` trigger |

Indexes: `(tenant_id, territory_id)` for the policy, and
`(customer_phone, created_at)` for the checkout throttle (§4.1).

Policy, `FOR SELECT` only:

```sql
using (tenant_id in (select public.my_tenant_ids_with_role(array['ZSM']::public.tenant_role_enum[]))
       or territory_id in (select public.my_tm_territory_ids()))
```

`public.my_tm_territory_ids()` is a new helper in the style of the existing
ones: `security definer`, `stable`, returns the `territory_id` of the caller's
ACTIVE `TM` memberships.

### 3.2 `orders`

- Copy `customer_name`, `customer_phone`, `customer_email` and
  `delivery_address` into `order_contacts` for every order where any of them is
  set, then drop the four columns and `idx_orders_web_pending_phone`.
- `orders_web_attribution_complete` no longer lists `delivery_address`;
  `place_web_order` still requires an address and writes it to the contact row.

### 3.3 `payments`

Revoke table-level `SELECT` on `payments` from `authenticated` and grant it
back on every column except `gateway_response_payload`.

## 4. RPCs

### 4.1 `place_web_order` — changed

Same signature, grants and idempotency behaviour. Changes:

- Insert the `orders` row without contact columns, then the `order_contacts`
  row with the stamped `territory_id` (§2.5).
- The throttle counts `order_contacts` joined to `orders`
  (`channel = 'ONLINE'`, `status = 'PENDING'`, last hour, same phone). The
  limit stays 5.
- The audit `after` is `to_jsonb(order) || {"contact": {phone_last4,
  has_email, has_address}}`.

### 4.2 `pos_order_lookup(p_public_reference text) returns jsonb` — new

- `authenticated`, `security definer`, pinned `search_path`. A read, so it takes
  no idempotency key and writes no audit row (as `verify_pin`).
- Tenant from the JWT, re-verified live: the caller must be an ACTIVE member of
  the JWT tenant.
- Returns
  `{public_reference, first_name, phone_last4, total, currency, status}` only
  when the order is in that tenant, `payment_route = 'POS_AGENT'` and
  `attributed_agent_id` is the caller.
- Any other case — unknown reference, another agent's order, a Paystack-route
  order, another tenant — raises one message, `P0001 'Order not found'`, so the
  lookup cannot be used to probe which references exist.
- A caller who is not an ACTIVE member of the JWT tenant is refused with
  `42501` (403) by `assert_tenant_role`, as every other RPC.
- The reference is matched case-insensitively and trimmed, as agent codes are.

## 5. Not changed

- Edge Functions. Public checkout responses never contained contact details,
  and the `web-checkout` request shape is unchanged. Only a comment in
  `_shared/commerce/phone.ts` that names `orders.customer_phone` is updated.
- The `teafair-web` contract.
- The idempotency log: `place_web_order`'s response holds no contact details,
  and its request is stored only as a hash.

## 6. Testing

Test-first, local stack only.

- **New `013_commerce_buyer_privacy.test.sql`:**
  - `orders` has none of the four contact columns; `order_contacts` exists with
    RLS on.
  - Reads as each role: ZSM sees every contact row in the tenant; a TM sees
    their territory's rows and not another territory's; `FINTECH_AGENT`, DSA,
    ASM and shop owner see none; a ZSM of another tenant sees none.
  - `place_web_order` writes the contact row with the expected territory, and
    its audit row contains no full phone, email or address.
  - The throttle still refuses the sixth pending order from one phone within
    the hour.
  - `pos_order_lookup` returns the masked fields to the order's agent, and
    raises `Order not found` for another agent, the tenant's ZSM, a
    Paystack-route order, an unknown reference and another tenant; a disabled
    member gets `42501`.
  - The data move: an order row carrying contact details before the migration
    has a matching `order_contacts` row after it (checked once on the local
    stack with `supabase migration up`, since pgTAP runs after migrations).
  - `authenticated` cannot select `payments.gateway_response_payload`, but can
    select `payments.payment_status`.
- **Updated:** `001` (35 tables), `010` and `012` fixtures that insert contact
  columns into `orders`.
- **Then:** the full pgTAP suite, the Deno unit tests and the gateway
  integration test, all green.

## 7. Not in this addendum

- Delivery-staff access to contact details (Spec C).
- Retention and deletion of buyer contact details (a data-protection policy
  decision for before launch, not a schema change).
- Encrypting contact details at rest beyond Supabase's disk encryption.
