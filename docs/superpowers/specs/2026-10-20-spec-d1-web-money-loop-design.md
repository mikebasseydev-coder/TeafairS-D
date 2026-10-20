# Web money loop — Spec D1

**Date:** 2026-10-20
**Status:** design approved in conversation 2026-10-20; written spec awaiting review
**Amends:** Spec A (`2026-10-05-multi-tenant-rtm-foundation-design.md`) §3.4,
§3.6 and §12; addendum A1 (`2026-10-15-web-storefront-agent-attribution-design.md`)
§4.2, §5.2, §5.3, §6 and §8. Where this document disagrees with them on the
subjects below, this document governs.

## 1. Purpose and standing

`teafairweb.com` is the public storefront. It has no backend of its own: it
uses the Teafair Supabase project, Paystack, and the public gateways A1 built.
A1 and A2 take an order and initialise a Paystack transaction, and
`process-payment` moves the **payment** to `SUCCESS`. Everything after that is
missing:

1. the **order** never leaves `PENDING`;
2. no `commission_records` row is written for a terminal partner's split;
3. the `reconcile-funds` Verify-API sweep that Spec A §3.6 relies on does not
   exist, so a lost webhook leaves a payment `INITIATED` forever;
4. `commission_records` never move `SPLIT → SETTLED`;
5. refunds and reversals are ignored;
6. a visitor with no agent code cannot buy at all — both public gateways
   resolve the tenant through the code;
7. web orders carry no fulfilment warehouse.

D1 closes all seven, backend only. No client code is written; the website
(`teafair-web`) and the app (Spec B) stay on hold.

### 1.1 Spec D is split in four

Spec A §12 lists Spec D as one spec, "Money and integrations", depending on
A, B and C. Its subjects are independent subsystems, and most need an app
screen that does not exist. D is split:

| # | Covers | Depends on |
|---|---|---|
| **D1** | **this document** — web settlement, `reconcile-funds`, commission release, refunds, codeless storefront, fulfilment routing, public order status | A, A1, A2 |
| D2 | POS settlement: `initiate_checkout`, `complete-pos-backed-order` (§6.11), OTP to `customer_phone` for web `POS_AGENT` orders, `POS_AGENT` status lookup | A, B |
| D3 | Liquidity and identity: fintech advances, KYC/BVN provider, partner and subaccount onboarding, commission dispute resolution and recovery, staff-initiated refunds | A, B |
| D4 | Cash: EOD cash reconciliation (`cash_audit_batches`), `reconcile-discounts-eod` | A, B, C |

**Amendment to Spec A §12:** D1 depends on A only (with addenda A1 and A2) and
may be built before B and C. D2–D4 keep Spec A's dependencies. Order
transitions after `PAID` (`IN_TRANSIT`, `DELIVERED`), stock picking and
cancelling abandoned `PENDING` orders remain Spec C.

## 2. Decisions

1. **Codeless traffic belongs to the TEAFAIR tenant.** A visitor without an
   agent code buys Teafair's house brands. `web_codeless_tenant()` returns the
   `ACTIVE` tenant whose `code = 'TEAFAIR'`; the tenant is never read from the
   client or from configuration (Spec A decision 4). Partner brands are reached
   only through their own agents' codes. A multi-tenant marketplace cart is out
   of scope.
2. **Location is an LGA, chosen from a list.** Buyers pick State → LGA from a
   seeded reference of Nigeria's 37 states (FCT included) and 774 LGAs. No
   geocoding: Nigerian addresses geocode poorly and no territory has a drawn
   boundary yet. Point-in-polygon routing is a possible Spec C upgrade.
3. **Coverage is explicit per tenant.** `territory_coverage` maps an LGA to a
   territory; a row with no LGA is the state's fallback territory. ZSMs
   maintain it.
4. **Every web order is routed when it is placed**, not when it is paid. The
   delivery LGA, credited territory, fulfilment warehouse and accountable
   person are stamped by `place_web_order`. Nothing that arrives with a
   payment can change attribution or routing.
5. **An order nobody can ship is refused.** When the buyer's LGA and state
   have no coverage, or the territory has no regional warehouse and the
   tenant has no `CENTRAL` default, checkout fails with "We don't deliver to
   this area yet." The refusal comes from the quote, before Paystack is
   called, so no money is taken.
6. **Commission is the split Paystack made, never a recomputation.** The split
   terms are snapshotted on `payments` at checkout. The commission row copies
   the snapshot and is checked against Paystack's verified split. There is no
   default rate anywhere; `fintech_partners.commission_bps` (Spec A §11) stays
   the single source, read once at quote time.
7. **Only terminal-bound codes carry commission.** A code bound to a terminal
   of an `ACTIVE` partner splits to that partner's subaccount (A1 decision 9).
   A staff (DSA, DSM, ASM, TM, ZSM) code without a terminal records
   attribution only. A codeless order is 100 % company revenue. Territory
   volume — for every order — is credited through `orders.territory_id` and
   rolls up TM → ASM/DSM teams → ZSM by zone.
8. **Settlement is server-to-server only.** Two callers settle a collection:
   the Paystack webhook and the `reconcile-funds` sweep. Both pass data from
   Paystack's Verify API, never from a request body. Browsers only read status.
9. **One writer per state machine.** `settle_paystack_payment` is the only
   writer for collections (payment status, `PENDING → PAID`, the commission
   row). `apply_paystack_refund` is the only writer for refunds and
   reversals. `release_commission` is the only writer for `SPLIT → SETTLED`.
10. **Real money wins.** A verified `success` is recorded whatever the order's
    state. If the order cannot become `PAID`, that is audited and escalated,
    not dropped.
11. **`PAID` does not touch stock.** It is the warehouse's to-ship signal.
    Stock is picked from `fulfilment_warehouse_id` at dispatch (Spec C).
12. **Notifications are rows.** Alerts are `notifications` rows written in the
    same transaction as the change they describe.

## 3. Schema

### 3.1 Global reference tables

Shared by all tenants, like `retail_shops` (Spec A §4.2). `SELECT` to
`authenticated`; no write grants. The website reads them through
`storefront-locations` (§8.3).

```
ng_states(code text PK CHECK (code ~ '^[A-Z]{2}$'),   -- 'LA', 'FC', …
          name text NOT NULL UNIQUE)

ng_lgas(id uuid PK, state_code → ng_states,
        name text NOT NULL,
        UNIQUE(state_code, name))
```

Seeded in the migration from the INEC list of 774 LGAs. The migration asserts
37 and 774 rows after the insert and fails otherwise.

### 3.2 `territory_coverage` (tenant-owned)

```
territory_coverage(id uuid PK, tenant_id → tenants,
                   state_code → ng_states, lga_id? → ng_lgas,
                   territory_id, created_at, updated_at,
                   UNIQUE NULLS NOT DISTINCT (tenant_id, state_code, lga_id),
                   FK (tenant_id, territory_id) → territories)
```

A trigger checks that `lga_id`, when present, belongs to `state_code`. RLS:
`FOR SELECT` to `ACTIVE` members of the tenant (it reveals no personal data).
Written only by `set_territory_coverage` (§5.1).

### 3.3 New columns

| Column | Meaning | Guard |
|---|---|---|
| `territories.web_fulfilment_warehouse_id?` | the warehouse that ships this territory's web orders | trigger: same tenant, `kind = 'REGIONAL'`, `warehouses.territory_id` = this territory |
| `tenant_settings.web_default_warehouse_id?` | the fallback warehouse | trigger: same tenant, `kind = 'CENTRAL'` |
| `tenant_settings.web_default_agent_id?` | last-resort accountable person for codeless orders | checked `ACTIVE` member of the tenant when set and again when used |
| `orders.delivery_lga_id?` → `ng_lgas` | where the buyer wants delivery | — |
| `orders.territory_id?` | the territory credited with the sale | FK `(tenant_id, territory_id)` |
| `orders.fulfilment_warehouse_id?` | the warehouse that ships it | FK `(tenant_id, fulfilment_warehouse_id)` |
| `payments.split_subaccount_code?` | partner subaccount at checkout | `^ACCT_[A-Za-z0-9]+$` |
| `payments.split_bps?` | `commission_bps` at checkout | `0..10000` |
| `payments.split_amount?` | partner share at checkout | `NUMERIC(15,2) > 0` |
| `commission_records.paystack_settlement_id?` | the Paystack settlement that paid it | set with `SETTLED` |

`orders.territory_id` carries the same value A2 stamps on
`order_contacts.territory_id`, written in the same statement: the `orders`
copy feeds volume reporting, the contacts copy feeds that table's privacy
policy.

### 3.4 Constraints

On `orders`:

- `orders_online_routed`: `channel <> 'ONLINE' or status = 'CANCELLED' or
  num_nulls(delivery_lga_id, territory_id, fulfilment_warehouse_id) = 0`.
- `orders_codeless_pays_online`: `channel <> 'ONLINE' or agent_code_id is not
  null or payment_route = 'PAYSTACK_WEB'` — a codeless order has no agent to
  pay at a terminal.

Web orders placed before D1 (test orders only; the remote has taken no real
traffic) have no routing. Postgres checks a `CHECK` constraint against every
row written after it is added, so such an order could never be settled. The
migration therefore first sets every `ONLINE` order that is still `PENDING`
with `delivery_lga_id` null to `CANCELLED`, writing an audit row
(`D1_LEGACY_CANCEL`, source `SYSTEM`) for each. It then adds both constraints
fully validated. If one of those orders is later paid, §6.2 step 3 records it
as `PAID_AFTER_CANCEL`.

On `payments`:

- `payments_split_snapshot_complete`: `num_nulls(split_subaccount_code,
  split_bps, split_amount) in (0, 3)`.
- `payments_split_within_amount`: `split_amount is null or split_amount <
  amount`.

New indexes: `orders (tenant_id, territory_id, status)`,
`orders (tenant_id, fulfilment_warehouse_id, status)`,
`commission_records (created_at) where status = 'SPLIT'`.

## 4. Routing

`web_route_order(p_tenant_id, p_code agent_codes?, p_lga_id)` — internal,
`STABLE`, not granted to any client role. Called by `quote_web_order` (so the
website learns about an undeliverable LGA before Paystack is touched) and by
`place_web_order` (which stamps the result). Returns territory, warehouse and
accountable person, or raises `P0001` "We don't deliver to this area yet."

1. **Territory.**
   - Coded: the bound terminal's `territory_id`, else the code holder's
     `tenant_users.territory_id`.
   - Codeless, or coded with both null: the `territory_coverage` row for
     `(tenant, state of p_lga_id, p_lga_id)`, else the state row
     `(tenant, state, null)`.
2. **Warehouse.** The territory's `web_fulfilment_warehouse_id`, else
   `tenant_settings.web_default_warehouse_id`. Neither → refuse.
3. **Accountable person** (`teafair_agent_id`, Spec A §6.10).
   - Coded: A1's rule, unchanged — a staff code holder (DSA, DSM, ASM, TM,
     ZSM) is accountable for their own sales; for a `FINTECH_AGENT`'s code it
     is the TM of the territory from step 1. None → "This link is not active
     yet" (A1).
   - Codeless: the territory's `tm_id`, else its zone's `zsm_id`, else
     `web_default_agent_id`. Each candidate must be an `ACTIVE` member of the
     tenant. None → refuse.

The territory may be null only when step 1 finds nothing but the `CENTRAL`
default still resolves a warehouse. That order would violate
`orders_online_routed`, so it is refused as well: **coverage is required for
every web order.** `web_default_warehouse_id` is the fallback for a territory
that has no regional warehouse, not for an unmapped location.

## 5. RPCs

### 5.1 Management — `authenticated`, through PostgREST

Standard write contract (Spec A §9): `p_idempotency_key` first, live
membership and role check, audit with source `USER`.

| RPC | Who | Does |
|---|---|---|
| `set_territory_coverage(p_idempotency_key, p_state_code, p_lga_id?, p_territory_id?)` | ZSM | upsert the row; `p_territory_id` null deletes it |
| `set_territory_web_warehouse(p_idempotency_key, p_territory_id, p_warehouse_id?)` | ZSM | set or clear the pointer |
| `set_web_defaults(p_idempotency_key, p_warehouse_id?, p_agent_id?)` | ZSM | set `tenant_settings` defaults |

### 5.2 Public — `service_role` only, called by public gateways

| RPC | Change |
|---|---|
| `storefront_catalogue(p_code?)` | code optional; null → `web_codeless_tenant()` |
| `quote_web_order(p_code?, p_items, p_lga_id)` | routes the order (§4); returns the split only when the code is terminal-bound |
| `place_web_order(p_idempotency_key, p_code?, p_items, p_customer, p_utm, p_payment_route, p_expected_total, p_checkout, p_lga_id)` | stamps routing columns and the split snapshot; `p_lga_id` is part of the idempotency hash; codeless requires `PAYSTACK_WEB` |
| `storefront_locations(p_code?)` | new; §8.3 |
| `web_order_status(p_public_reference, p_paystack_reference)` | new; §8.4 |

The old signatures are dropped, not overloaded. A1's per-phone throttle
applies to codeless orders unchanged.

### 5.3 System — `service_role` only, called by system gateways

| RPC | Caller |
|---|---|
| `settle_paystack_payment(…)` | `process-payment`, `reconcile-funds` (§6) |
| `record_stale_paystack_webhook(…)` | `process-payment` (unchanged) |
| `list_unconfirmed_payments(p_limit)` | `reconcile-funds` (§7) |
| `apply_paystack_refund(…)` | `process-payment`, `reconcile-funds` (§9) |
| `list_unsettled_subaccounts()` | `fintech-commission-release` (§8) |
| `release_commission(…)`, `expire_unsettled_commissions()` | `fintech-commission-release` (§8) |

## 6. Collection settlement

`settle_paystack_payment` keeps its role and its at-most-once key
`(event, reference)`. Its signature gains the verified Paystack transaction id
and split, parsed by the gateway from the Verify response:

```
settle_paystack_payment(p_event, p_reference, p_status, p_amount_minor,
                        p_currency, p_verified jsonb,
                        p_transaction_id text,
                        p_split_subaccount text?, p_split_share_minor bigint?)
```

`p_event` is the webhook event (`charge.success`) or `'sweep'`.

### 6.1 Status mapping

| Verified status | Payment younger than 2 h | 2 h – 72 h | Older than 72 h |
|---|---|---|---|
| `success` | `SUCCESS` | `SUCCESS` | `SUCCESS` |
| `failed` | `FAILED` | `FAILED` | `FAILED` |
| `abandoned` | not final | `FAILED` | `FAILED` |
| `ongoing`, `pending`, `processing`, `queued` | not final | not final | `FAILED`, audit `SWEEP_EXPIRED` |
| `reversed` | the gateway calls `apply_paystack_refund` as a full reversal instead (§9) | | |

Paystack reports an initialised-but-unpaid transaction as `abandoned`; the
current code makes that `FAILED` at once, which would fail a buyer still on
the payment page when the sweep runs. The two-hour hold fixes it. A non-final
result returns before the idempotency key is taken, so the next sweep retries.

### 6.2 On `SUCCESS`, in one transaction

Payment row `FOR UPDATE`, then order row `FOR UPDATE`.

1. Amount and currency must match the payment (existing check). Mismatch →
   audit `PAYSTACK_MISMATCH`; payment and order unchanged.
2. Payment → `SUCCESS`, `gateway_response_payload = p_verified` (existing).
   From `FAILED`, also audit `LATE_SUCCESS`.
3. Order `PENDING → PAID`, audited. If the order is not `PENDING` (Spec C
   will cancel abandoned orders), the order is left as it is, audit
   `PAID_AFTER_CANCEL`, and every ZSM of the tenant is notified to refund or
   reinstate it.
4. **Commission row** — only when the payment carries a split snapshot:
   `commission_records(order_id, payment_id, fintech_partner_id and
   teafair_agent_id from the payment, amount = split_amount,
   bps_applied = split_bps, paystack_subaccount_code = split_subaccount_code,
   paystack_split_reference = p_transaction_id)`.
   Status `SPLIT` when `p_split_subaccount = split_subaccount_code` and
   `p_split_share_minor = split_amount × 100`; otherwise `DISPUTED` with
   `dispute_reason = 'SPLIT_MISMATCH'` and both values in the audit row.
   `UNIQUE(tenant_id, payment_id)` keeps it to one.
5. `notifications` for the fulfilment warehouse's `manager_id` and the
   territory's `tm_id` (when set, deduplicated): kind `WEB_ORDER_PAID`,
   payload `{order_id, public_reference}` — no contact details.
6. Audit rows carry source `WEBHOOK` or `CRON` and the payment's
   `teafair_agent_id`.

`max_redemptions` counts `PAID`, `IN_TRANSIT` and `DELIVERED` orders, so the
`PAID` transition activates it. It is enforced at checkout; when several
pending orders on a code's last redemption are all paid, all are honoured.

On `FAILED` the order stays `PENDING`; cancelling it is Spec C.

## 7. `reconcile-funds`

A system gateway (Spec A §3.4), run by `pg_cron`.

**Every 5 minutes — the confirmation sweep.**
`list_unconfirmed_payments(50)` returns `INITIATED`/`PROCESSING` payments
older than 5 minutes, oldest first (the existing `idx_payments_unconfirmed`
serves it). For each: Verify, then `settle_paystack_payment(p_event =>
'sweep', …)`. One payment's error is logged and does not stop the batch. A
webhook and a sweep racing on one reference serialise on the payment row; the
second sees `unchanged`.

**Daily at 06:00 Africa/Lagos — the refund pass.** Paystack *List Refunds* for
the last 3 days, each fed to `apply_paystack_refund` (§9). Duplicates are
no-ops. This recovers refund webhooks that were lost or arrived stale.

The two runs are one function with a `mode` in the body (`sweep` | `refunds`).

## 8. Commission release and public gateways

### 8.1 `fintech-commission-release`

A system gateway, daily at 07:00 Africa/Lagos.

1. `list_unsettled_subaccounts()` — distinct `paystack_subaccount_code` with
   `SPLIT` rows older than 24 hours, with the oldest such date.
2. Per subaccount: Paystack *List Settlements* from that date, then *Settlement
   Transactions* for each settlement, following pagination.
3. Each transaction whose reference matches a `SPLIT` row →
   `release_commission(p_settlement_id, p_settled_at, p_reference,
   p_subaccount_share_minor)`:
   - share = `amount × 100` → `SETTLED`, `settled_at`,
     `paystack_settlement_id`;
   - otherwise → `DISPUTED`, `SETTLEMENT_MISMATCH`, both values audited.
   At most once per `(settlement_id, payment_id)`.
4. `expire_unsettled_commissions()` — `SPLIT` rows older than 7 days →
   `DISPUTED`, `NOT_SETTLED`.

Every move to `DISPUTED` notifies the tenant's ZSMs (kind
`COMMISSION_DISPUTED`). Resolving a dispute is D3. No human acts on the normal
path (Spec A decision 14).

### 8.2 Changes to A1's public gateways

- `storefront-catalogue`: `code` optional.
- `web-checkout`: `code` optional; **`lga_id` required on every request**;
  codeless requires `payment_route = 'PAYSTACK_WEB'`. Everything else in A1
  §5.3 — Turnstile, phone normalisation, quote, initialise-then-place, replay
  returning the original URL — is unchanged. The split passed to Paystack
  *Initialize* and the snapshot passed to `place_web_order` come from the
  same quote.

This changes A1's request contract. No client consumes it yet.

### 8.3 `storefront-locations` (new, public)

`POST { code? }`. Returns the 37 states, each with its LGAs, and for each LGA
`deliverable: boolean` — true when §4 would route it for the resolved tenant.
No territory, warehouse or person is named. `Cache-Control: public,
max-age=3600`. The website greys out undeliverable LGAs.

### 8.4 `web-order-status` (new, public)

`POST { public_reference, paystack_reference }`. Paystack appends
`reference` to the `callback_url`, so the page has both.

- The pair must match one order and its payment. Any mismatch returns the
  same `404 NOT_FOUND` as a missing order: `TF-XXXXXX` alone has about 10⁹
  values and could be enumerated; the `TFW-<uuid>` reference cannot.
- Returns `{ public_reference, order_status, payment_status, total, currency,
  lines: [{ name, qty, unit_price }] }`. No contact details, agent, territory
  or warehouse.
- Read-only. It never calls Verify and never settles (decision 8).

The callback page polls every 3 s for up to 60 s while `PENDING`, then shows
"Your payment is being confirmed — keep your reference TF-XXXXXX." The
5-minute sweep completes the rest.

## 9. Refunds and reversals

Refunds are started by finance in the Paystack dashboard. Starting one from
Teafair needs a staff gateway with a PIN — D3, after Spec B.

**Inputs.** `process-payment` accepts `refund.processed` in addition to
`charge.success`, with the same signature check and replay window. It
re-fetches the refund with Paystack *Fetch Refund*; amount, currency, status
and the linked transaction reference come from that response. The daily
refund pass (§7) and a Verify result of `reversed` (§6.1) feed the same
writer.

**`apply_paystack_refund(p_source, p_refund_id, p_transaction_reference,
p_amount_minor, p_currency, p_reason, p_verified)`** — at most once per
`p_refund_id` (a reversal uses `'reversal:' || reference`).

| Case | Effect |
|---|---|
| refunded amount = payment amount, payment `SUCCESS` | payment → `REFUNDED`; order → `REFUNDED` from `PAID`, `IN_TRANSIT` or `DELIVERED`; audit reason `REFUND` or `REVERSAL` |
| refunded amount < payment amount | no status change; audit `PARTIAL_REFUND` with the amount; ZSMs notified |
| payment not `SUCCESS`, unknown reference, currency mismatch | audit `REFUND_CONFLICT`; nothing changes |

A commission row in `SPLIT` or `SETTLED` on a fully refunded payment →
`DISPUTED`, `ORDER_REFUNDED`; ZSMs notified. Paystack does not claw the share
back from the subaccount, so recovery is recorded work for D3.

## 10. Scheduling and secrets

`pg_net` is added (`create extension pg_net`). Each cron job reads the
project's functions URL and the cron secret from **Vault**
(`vault.decrypted_secrets`) and posts with `net.http_post`:

| Job | Schedule (UTC) | Calls |
|---|---|---|
| `reconcile-funds-sweep` | `*/5 * * * *` | `reconcile-funds` `{mode:"sweep"}` |
| `reconcile-funds-refunds` | `0 5 * * *` (06:00 Lagos) | `reconcile-funds` `{mode:"refunds"}` |
| `fintech-commission-release` | `0 6 * * *` (07:00 Lagos) | `fintech-commission-release` |

The migration schedules the jobs; it contains no secret values. Vault entries
`functions_base_url` and `cron_secret` are created per environment (locally by
the integration setup; on the remote by the user at deploy time). If they are
missing the job logs and posts nothing.

| Secret | Used by |
|---|---|
| `CRON_SECRET` (function env) = Vault `cron_secret` | `reconcile-funds`, `fintech-commission-release`; compared in constant time; mismatch → 401 |
| `PAYSTACK_SECRET_KEY` | the two new functions (already set) |
| `PAYSTACK_BASE_URL` | optional; local tests point it at a fake |

## 11. Testing

All on the local stack. Nothing is pushed to the remote project until
explicitly asked.

**pgTAP** — new files `014_web_locations_routing`, `015_web_settlement`,
`016_commission_release`, `017_refunds`, `018_d1_security`:

- seeds: exactly 37 states and 774 LGAs; LGA–state trigger; a second state
  fallback row rejected by `NULLS NOT DISTINCT`;
- routing: LGA hit, state fallback, `CENTRAL` fallback for a territory with
  no regional warehouse, refusal when uncovered, coded order whose terminal
  and agent lack a territory, accountable chains (staff holder; TM through a
  `FINTECH_AGENT` terminal; TM → ZSM → default; inactive candidates skipped);
- constraints: codeless ⇒ `PAYSTACK_WEB`; split snapshot all-or-none and
  below amount; `orders_online_routed`; warehouse-pointer triggers;
- settlement: `PENDING → PAID`; `SPLIT`; `SPLIT_MISMATCH`; no row without a
  snapshot; `abandoned` under and over 2 h; `SWEEP_EXPIRED` after 72 h;
  `LATE_SUCCESS`; `PAID_AFTER_CANCEL`; notifications; webhook and sweep on
  one reference (`unchanged`); `max_redemptions` reached by `PAID` orders;
- release: `SETTLED`; `SETTLEMENT_MISMATCH`; `NOT_SETTLED` after 7 days;
  replay of one settlement;
- refunds: full, partial, reversal, conflict; commission → `ORDER_REFUNDED`;
  replay of one refund id;
- security: `anon` and `authenticated` cannot execute any §5.2 or §5.3 RPC;
  §5.1 RPCs reject non-ZSMs; `territory_coverage` RLS; the three
  `cron.job` rows exist.

**Deno unit tests** beside each handler, with injected fakes and Paystack
fixtures taken from Paystack's documented responses: the `refund.processed`
branch of `process-payment`; `reconcile-funds` (secret, batch continues past
an error, both modes); `fintech-commission-release` (pagination, matching);
`web-order-status` (mismatch → 404, no personal data); `storefront-locations`;
the codeless path and `lga_id` validation in `web-checkout`.

**Integration** (`_tests/gateway.integration.ts`, a fake Paystack server):
codeless checkout → signed `charge.success` → `PAID` → status read;
terminal-bound checkout → `SPLIT` → release run → `SETTLED`; dropped webhook
recovered by the sweep; signed `refund.processed` → `REFUNDED`.

A live Paystack test-mode run against the remote project is a manual check at
deploy time.

## 12. Facts to confirm while writing the plan

These are Paystack response shapes, not design choices. Each is checked
against Paystack's API reference before the task that uses it, and the
fixtures in §11 are built from that reference:

- the Verify Transaction fields carrying the transaction id, the subaccount
  code and the subaccount's share of a split transaction;
- the *List Settlements* subaccount filter and the per-transaction subaccount
  amount in *Settlement Transactions*;
- the `refund.processed` payload's transaction reference and timestamp (for
  the replay window), and the *Fetch Refund* / *List Refunds* response.

If a field does not exist as assumed, the check that depends on it is
narrowed (for example, `SPLIT_MISMATCH` compares the subaccount code only) and
the change is recorded in the plan.

## 13. Not in D1

- The `teafair-web` website and every app screen (Spec B hold).
- Everything listed for D2, D3 and D4 in §1.1.
- Order transitions after `PAID`, stock picking, cancelling abandoned
  `PENDING` orders (Spec C).
- Partial-refund accounting.
- Multi-tenant carts.
- Geocoded or boundary-based routing.
- Open A1 follow-ups not listed here (Turnstile hostname/action check,
  `expected_total` in the idempotency hash) stay where A1 recorded them.
