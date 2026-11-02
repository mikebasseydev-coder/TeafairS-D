# CLAUDE.md (supabase)

The entire backend. Spec A
(`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`) is
the authority; this file is the working summary.

## Status

| Phase (Spec A §14) | State |
|---|---|
| 1. Schema — extensions, enums, 33 tables | done |
| 2. Grants, RLS, write contract, foundation RPCs, brand tiers, escalation cron | done |
| 3. Edge Function gateway (`supabase/functions/`) | done |
| A1. Web storefront — agent codes, venues, public gateways | done |
| A2. Buyer contact privacy — `order_contacts`, till lookup | done |
| D1. Web money loop — routing, settlement, sweeps, refunds, commission release | done (local) |
| A3. Web chat & ticketing — support tables, buyer gateways, staff RPCs, system tickets | done (local) |
| A4. Internal staff messaging — chat channels, direct chats, team/zone rooms, announcements | done (local) |
| A5. Refund policy, WhatsApp-verified checkout, fulfilment and delivery code, support photos, dispute evidence | done (local) |
| Tenant sale categories (NCC licence) and NAFDAC numbers | done (local) |
| Cartons and break-bulk wholesale packs | done (local) |
| Web transport fare | done (local) |
| Sentry observability (Edge Functions) | done (local) |
| Auth hardening (audit H1, H2, M1, L1) and the Send SMS / Send Email hooks | done (local) |
| Domain separation and renames (A6 §15) | done (local) |
| Monvelo (A6) Step 1 | done (local) |
| Monvelo (A6) Step 1c: tenant representation | done (local) |
| Monvelo (A6) Step 2: financing ledger and allocation | done (local) |
| Monvelo (A6) Step 3: funding, delivery, repayment, the money sweep | done (local) |
| 4. Client offline queue | needs Spec B |

Linked to remote project `vwmjyfjdwrohfizljxrq`. Per the 2026-10-15 push
(GitHub `main` at `42dd15b`), the remote has the 29 migrations up to
`20261015130200` (Spec A plus addenda A1 and A2) and six Edge Functions:
`auth-verify-claims`, `otp-issue`, `otp-verify`, `process-payment`,
`storefront-catalogue` and `web-checkout`. Remote secrets must use the names
the code reads (see `functions/.env.example`): `otp-issue` needs
`SMS_PROVIDER` (+ `KUDISMS_TOKEN`, `KUDISMS_SENDER_ID` for `kudisms`) and
`auth-verify-claims` needs `AUTH_HOOK_SECRET`, or they fail at boot. Never
`supabase config push`: the hook URI in `config.toml` is local-only. **A1
never deploys without A2**: A1 alone exposes buyer contact details to every
tenant member, and audit rows cannot be scrubbed afterwards.

### Deploying Spec D1

The eight Spec D1 migrations (`20261020120000`–`20261020130300`) and the
functions `reconcile-funds`, `web-commission-release`,
`storefront-locations` and `web-order-status` (plus the changed
`process-payment`, `storefront-catalogue` and `web-checkout`) are local only.
**D1 never deploys without A1 and A2.** Nothing is pushed until explicitly
asked.

**Pre-push checks** (run on the remote first):

1. ONLINE orders that are not PENDING. The legacy cancel only covers PENDING,
   and before D1 the routing columns do not exist, so every such order lacks
   routing and any count above zero makes the `orders_online_routed`
   constraint fail the push:
   `select count(*) from public.orders where channel = 'ONLINE' and status not in ('PENDING', 'CANCELLED');`
2. Web orders already paid under A1 (v1) but still PENDING. The legacy cancel
   will cancel them even though the money was taken, so each needs a decision
   (ship, or refund in Paystack) before the push:
   `select count(*) from public.payments p join public.orders o on o.tenant_id = p.tenant_id and o.id = p.order_id where p.payment_status = 'SUCCESS' and o.channel = 'ONLINE' and o.status = 'PENDING';`

**Order.** Push the D1 migrations, then deploy the D1 functions immediately.
The D1 settlement and storefront migrations drop RPC signatures that the
deployed `process-payment` and `web-checkout` call, so checkout and webhooks
fail in between. Paystack retries webhooks, so a gap of a few minutes is
acceptable; a long one is not. Then create the Vault secrets (Cron jobs,
below).

**Post-deploy setup.** D1 routes every web order (§4). A coded link that works
under A1 refuses with "We don't deliver to this area yet." until its territory
has a `web_fulfilment_warehouse_id` (its own REGIONAL warehouse) or the tenant
has a CENTRAL `web_default_warehouse_id`. Codeless sales go to TEAFAIR and
need its coverage (state or LGA → territory), a warehouse, and an accountable
person: the territory's TM (else the zone's ZSM, else `web_default_agent_id`).
A ZSM of each tenant sets these with:

- `set_territory_web_warehouse(p_idempotency_key, p_territory_id, p_warehouse_id)`
- `set_web_defaults(p_idempotency_key, p_warehouse_id, p_agent_id)` (CENTRAL warehouse)
- `set_territory_coverage(p_idempotency_key, p_state_code, p_lga_id, p_territory_id)`
  (`p_lga_id` null covers the whole state)

Until Spec B exists there is no client: call them through PostgREST
(`POST /rest/v1/rpc/<name>`) with a ZSM's JWT whose active tenant is the one
being set up.

### Addendum A3 (web chat and ticketing)

Four migrations (`20261021120000`–`20261021120300`) and the functions
`support-ticket-open`, `support-ticket-read` and `support-ticket-message` are
local only. **A3 deploys after D1**: it depends on D1's routing (a ticket goes
to the territory's TM, else the zone's ZSM, else `web_default_agent_id`), and
its triggers watch D1's tables to raise system tickets from payment exceptions.

- **Public gateways** (`publicGateway`, service-role RPCs):
  `support-ticket-open` (Turnstile, then `open_support_ticket`; only the
  secret's hash is stored), `support-ticket-read` (`read_support_ticket`) and
  `support-ticket-message` (`add_ticket_message`). The pair
  `(public_reference, secret)` is the buyer's capability; any miss is 404.
  A closed conversation or a throttled buyer gets 422 with the database copy.
  All three need `verify_jwt = false`, already set in `config.toml`.
- **The ticket secret** is HMAC-SHA256(`SUPPORT_TICKET_SECRET_KEY`,
  idempotency key), base64url, so a retried open returns the same secret as
  the lost first reply. `support-ticket-open` needs `SUPPORT_TICKET_SECRET_KEY`
  (32+ random bytes, base64url), `TURNSTILE_SECRET_KEY` (the same secret as
  `web-checkout`; locally with `TURNSTILE_VERIFY_URL` pointing at the fake)
  and `WEB_ALLOWED_ORIGINS`. Without a usable key every open is 503. **Set
  `SUPPORT_TICKET_SECRET_KEY` as a remote Edge Function secret before
  deploying the open gateway.** Rotating it only breaks replays of opens
  still in flight; existing tickets keep their stored hashes.
- **Staff RPCs** (through PostgREST, `authenticated`): `claim_ticket`,
  `reply_ticket`, `update_ticket_status`, `set_ticket_priority`, and the
  ZSM-only `assign_ticket` (pre-purchase tickets that are not CLOSED; an
  IN_PROGRESS ticket goes back to OPEN) and `redact_ticket_customer_data`
  (repeating it with nothing new to redact writes no audit row).
  `close_resolved_support_tickets` is the cron sweep: pure SQL, so it needs
  no Vault secret. System tickets come from `raise_system_ticket`, called by
  triggers on D1's disputed commissions and payment exceptions; they do not
  count toward a buyer's three open tickets per order.
- **Ticket headers are visible to every tenant member**, and so are their
  Realtime events. They carry structure only, no personal data.
- **Handler RLS rule.** The tables are `SELECT`-only. Contacts and messages
  are readable by a ZSM of the tenant, the TM of the ticket's territory, and,
  on PRE_PURCHASE and SYSTEM tickets only, the ticket's accountable or
  assigned person (`my_support_ticket_ids()` for contacts; messages use the
  history helper below). Buyer contact details stay with each ticket's own
  handlers.
- **ORDER tickets follow A2** (user decision 2026-10-21): only the ZSM and the
  territory TM read or act on them. The order's selling agent stays
  `accountable_id` and gets the notification (`{ticket_id,
  public_reference}` only), but cannot read contacts or messages, claim,
  reply, or change status or priority.
- **Claimed tickets are locked.** Once `assigned_to` is set, only the assignee
  or a ZSM can claim, reply, change status or change priority. Everyone else
  gets 42501. Any permitted replier claims an unassigned ticket. The hold
  lapses when the assignee is no longer an ACTIVE member: the ticket is then
  treated as unassigned, and a permitted claim takes it (audited with
  `before.assigned_to`). Notifications likewise skip an inactive assignee or
  accountable person and fall back to every ZSM.
- **Repeat system facts.** A repeat on a RESOLVED system ticket reopens it. A
  repeat on a CLOSED one opens a new SYSTEM ticket whose `previous_ticket_id`
  points at the closed one. `system_key` is unique only among non-CLOSED
  tickets (partial index `support_tickets_open_system_key`).
- **Linked buyer tickets.** A buyer ORDER ticket links to the most recent
  CLOSED ORDER ticket on the same order.
- **Linked history.** Handlers read linked history through
  `my_support_history_ticket_ids()`, which covers the whole chain and gives
  messages only. Contacts stay with each ticket's own handlers through
  `my_support_ticket_ids()`.

### Addendum A4 (internal staff messaging)

Four migrations (`20261022120000`–`20261022120300`), local only. No Edge
Functions and no secrets: staff talk through PostgREST.

- **RPCs** (`authenticated`): `get_or_create_direct_channel`,
  `post_chat_message`, `mark_chat_read`, `hide_chat_message` (ZSM only), and
  the read-only inbox `list_my_chat_channels()`. The tables are `SELECT`-only.
  Team (territory), zone and announcement channels are created by trigger.
- **Access is live-derived.** `my_chat_channel_ids()` computes the caller's
  channels from `tenant_users` on every call; there is no member table, so a
  role or territory change takes effect at once. The internal helpers
  `chat_is_available`, `chat_staff_zone` and `chat_create_group_channel` have
  no grants.
- **Direct chats are private.** Only the two people can read them, and
  `hide_chat_message` refuses them (42501). Rooms are moderated by a ZSM of
  the room's zone; any ZSM of the tenant moderates announcements. A hidden
  message keeps its row with body `[removed]`, `hidden_at` and `hidden_by`;
  the `CHAT_MESSAGE_HIDDEN` audit holds ids and the reason, never the body.
  Hiding twice writes no second audit row.
- **Notifications** use fixed copy and ids only; rooms never notify.
- **Chat writes no audit rows except moderation (user decision).** Posting,
  opening a direct chat and marking read write no `audit_logs` row, because
  ZSMs and TMs read `audit_logs` tenant-wide and it would reveal who messages
  whom. They still use `idempotency_logs`, which only the actor can read.
- **Once a territory or zone has a chat channel it cannot be deleted
  (RESTRICT); clear its channel first in any future admin cleanup.**
- **Realtime.** The publication includes `chat_messages` and `chat_channels`;
  RLS decides who receives each event.
- **For Spec B.** Subscribe to Realtime with `channel_id=eq.` and
  `tenant_id=eq.` filters, because every post updates `chat_channels`. Move
  the announcement fan-out (one `notifications` row per staff member) to a
  queue past roughly 10k staff per tenant.

### Addendum A5 (refund policy, verified checkout, fulfilment, support photos)

Seven migrations (`20261023120000`–`20261023120500`, plus `120310`) and the
functions below are local only. **A5 deploys after A3 and A4** (it changes A3's
`open_support_ticket`, `add_ticket_message` and `reply_ticket`).

- **Refund policy.** `refund_policies` holds `v2.0-food-cosmetics` (FOOD and COSMETICS sellable; the
  category is `central_products.sale_category`). `storefront-refund-policy`
  (GET, cached 5 min) returns the active policy. **The policy text is a
  placeholder and needs legal review before go-live.** Food copy: "Opened food
  items can't be refunded. Report transit damage within 24 hours of delivery
  with photos." Cosmetics copy: "Opened or used cosmetics can't be refunded.
  Patch-test before first use. Report damage or leaks within 24 hours of
  delivery with photos." **Versions are immutable (R20):** a trigger refuses DELETE,
  TRUNCATE and any UPDATE except `is_active` (and `published_at` when
  activating). New wording ships as a new version (`v2.1-food`, and so on),
  inserted inactive and then activated while the old one is deactivated.
  Orders keep pointing at the version their buyer accepted.
- **Verified, consenting checkout.** `web-checkout` now requires
  `accept_refund_policy: true`, `policy_version_tag` and
  `phone_verification_token` (43 chars). The token comes from
  `checkout-phone-verify-start` (Turnstile, then a WhatsApp-only code; throttles
  3 per phone and 10 per IP per hour) and `checkout-phone-verify-confirm` (a
  wrong code is 422, not a raise, so the attempt counter commits). Consent IP
  and verification facts live in `order_contacts`. The cut-off constant for
  ONLINE orders is 2026-10-23. `web_phone_verifications` rows go after 7
  days (`cleanup_web_phone_verifications`, cron
  `cleanup-web-phone-verifications`, 00:50 UTC; no grant).
- **Client IP (R19).** `_shared/commerce/client-ip.ts` is the only reader:
  `cf-connecting-ip`, else the first `x-forwarded-for` hop, and only if it
  parses as an IPv4 or IPv6 literal; anything else is null. Every public
  gateway uses it (checkout, phone verification, ticket open).
- **Message router.** `_shared/messaging/router.ts` tries the Meta WhatsApp
  Cloud API first and falls back to SMS (not for PHONE_VERIFY). Each attempt is
  logged in `notification_logs` (last four digits only). `otp-issue` now uses
  it. The entry carries the caller's active tenant (R18) for DELIVERY_CODE,
  DELIVERY_CODE_RESEND and OTP, so the tenant's ZSMs read it under RLS;
  PHONE_VERIFY is platform-level and logs a null tenant (readable by no API
  role).
- **Support photos.** Private buckets `support-attachments` and
  `delivery-proofs` (JPEG/PNG/WebP, 5 MiB, 3 per message). A photo needs an
  `upload_slots` row first: `support-ticket-attachment` (buyer),
  `support-staff-attachment` (staff), `order-delivery-photo` (delivery). A
  buyer **opens the ticket, requests an attachment, uploads, then posts a
  message with `attachment_ids`** (`support-ticket-message`); a ticket cannot be
  opened with photos. `support-ticket-read` signs download URLs for 600 s.
  **Signed upload URLs live 2 hours** (Storage fixes this; each allows one
  upload because there is no upsert; the DB slot checks size and mime at claim
  and cleanup runs at 24 h). Storage has SELECT policies only. **Staff hold
  long-lived read access:** because staff read through the Storage SELECT
  policies, a staff member can mint a signed download URL of any lifetime with
  their own JWT, and it works until the object is purged (slot redaction or
  cleanup). The spec §9 fallback, gateway-signed staff URLs with no staff
  SELECT policy, would remove this. Deleting is
  asynchronous: slot deletion enqueues paths in `storage_purge_queue`, and the
  cron-invoked `storage-purge` function (every 15 min, `x-cron-secret`) drains
  it through the Storage API.
- **Fulfilment.** `order-dispatch` (WM or ZSM; PIN generated in the gateway,
  hashed by `mark_order_dispatched`, sent through the router),
  `order-delivery-pin` (resend), `order-delivery-photo`,
  `order-delivery-confirm` (RPC `mark_order_delivered`) and
  `order-dispute-evidence` (ZSM; `get_order_dispute_evidence`, audited as
  `DISPUTE_EVIDENCE_VIEWED`, signs photo URLs for 600 s). Web orders only.
  Delivery opens a 24 h damage window; `within_damage_window` is stamped on
  ORDER DELIVERY/PRODUCT tickets.
- **Gateway proof (R16).** `mark_order_dispatched`, `resend_delivery_pin` and
  `mark_delivery_pin_sent` demand the Vault secret `gateway_secret`, equal to
  the functions env `GATEWAY_SECRET`. Create it **once per environment and
  after every `db reset`**, next to `cron_secret`:
  `select vault.create_secret('<value>', 'gateway_secret');`. Missing or
  different, dispatch fails closed (42501). `storage-purge` also needs the
  existing `functions_base_url` and `cron_secret` Vault secrets and `CRON_SECRET`.
- **New secrets (functions env).** `WHATSAPP_ACCESS_TOKEN`,
  `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_API_VERSION`, optional
  `WHATSAPP_API_URL` (tests only), `WHATSAPP_TEMPLATE_OTP`,
  `WHATSAPP_TEMPLATE_DELIVERY_CODE`, `GATEWAY_SECRET`. With the first three
  empty the router sends SMS only (and phone verification returns 503).

**Deploy notes.**

1. **Meta must approve the templates `teafair_otp` (authentication, with the
   copy-code button) and `teafair_delivery_code` before deploy.**
2. Storage buckets and policies: **dry-run the storage policies against staging
   first; the fallback is gateway-signed URLs for staff.**
3. Pre-push check on the remote; it must return 0 before pushing
   `20261023120100`: `select count(*) from orders where channel = 'ONLINE' and created_at >= '2026-10-23' and policy_version_tag is null;`
   If not, move the cut-off constant to the push date in a new migration.
4. **Pre-push catalogue check (R21).** `sale_category` defaults to `FOOD`, so
   every existing product becomes sellable under `v2.0-food-cosmetics` on push. List the
   active catalogue per tenant first:
   `select t.code, p.sku_code, p.product_name, p.category from central_products p join tenants t on t.id = p.tenant_id where p.is_active order by t.code, p.category, p.sku_code;`
   Every SKU that is not food or tea gets reclassified to `COSMETICS`,
   `ELECTRONICS` or `TELECOM`, or deactivated, in the same release window. A
   product's category follows its NAFDAC registration and label, not every
   use buyers find for it (user decision 2026-10-23: the coconut oil is
   registered and branded for skin, hair and body, so it is **`COSMETICS`**,
   not `FOOD`). **Post-push:** rerun
   it with `p.sale_category` added and confirm that only food is `FOOD` and
   the coconut oil is `COSMETICS`. Every
   later catalogue load must set `sale_category` explicitly; never rely on the
   default.
5. **Pre-deploy staging check on the client IP (R19).** On staging, call a
   public gateway with forged `cf-connecting-ip` and `x-forwarded-for` headers
   and log which value reaches `clientIp`. Establish which header hosted
   Supabase sets and overwrites, and change `_shared/commerce/client-ip.ts` to
   trust only that header (or that hop of `x-forwarded-for`). Until then the
   per-IP throttle and the consent IP are spoofable; Turnstile and the
   per-phone throttle are the backstop.
6. Create `gateway_secret` in Vault and set `GATEWAY_SECRET` and the
   `WHATSAPP_*` secrets as function secrets; then deploy the functions.
7. Legal review of the placeholder policy text. Versions are immutable (R20),
   so counsel's text ships as a **new version**, e.g. `v2.1-food`, in a new
   migration that inserts it inactive, deactivates `v2.0-food-cosmetics` and activates
   the new one in the same transaction.

**For Spec B (client).** Checkout must send the consent fields and run the
verification flow first (start, then confirm, then checkout with the token;
tokens are single use and expire in 30 min). Use a fresh idempotency key for
every delivery-PIN entry (the stored request omits the PIN, so a reused key
replays the first answer). Open a ticket, then request an attachment, then post
with it. Confirm delivery through `order-delivery-confirm`, not the RPC, to get
the 422 for a wrong or locked code.

**A5 builder rulings.**

- R1: `start_web_phone_verification` takes `p_client_ip inet` for the per-IP limit.
- R2: the router lives at `_shared/messaging/router.ts`, not `_shared/core/messaging.ts`.
- R3: the D1/A1 integration flows send the new checkout fields.
- R4: `support-ticket-attachment` takes no `file_name`.
- R5: `mark_order_delivered` returns `WRONG_PIN`/`LOCKED` as data; the gateway maps them to 422 so counters commit.
- R6: only a ZSM resend resets PIN failure counters and locks; 5 wrong codes lock 30 min, 10 lifetime lock to ZSM.
- R7: extra tests for other-tenant and other-warehouse WMs delivering (42501).
- R8: `get_order_dispute_evidence` is VOLATILE because it writes an audit row.
- R9: a wrong verification code returns `verified:false` data (gateway 422), not a raise.
- R10: pre-push count check for ONLINE orders without a policy tag (above).
- R11: `accept_refund_policy` is checked in the handler for the exact 400 copy.
- R12: Storage deletes go through `storage_purge_queue` and the `storage-purge` cron function; Storage SELECT policies require a live slot.
- R13: `open_support_ticket` keeps its A3 signature; photos attach after opening.
- R14: the bucket migration also enforces bucket settings on a pre-existing bucket.
- R15: the 2-hour signed upload URL lifetime is accepted (Storage-fixed).
- R16: gateway-only proof through Vault `gateway_secret` for dispatch, resend and mark-sent.
- R17: `add_ticket_message` stays service_role-only; `reply_ticket` and `redact_ticket_customer_data` keep their A3 grants. Flagged for final review.
- R18: `notification_logs` gets the tenant from `caller.activeTenantId` for DELIVERY_CODE/_RESEND/OTP, after the RPC succeeded (which proved it is the order's tenant); PHONE_VERIFY stays null; the integration test reads the log as the ZSM through PostgREST.
- R19: the client IP must parse as an IPv4/IPv6 literal, else null; one shared helper everywhere; the trusted header is a pre-deploy staging check (deploy note 5); Turnstile and the per-phone throttle are the backstop.
- R20: `refund_policies` rows are immutable except `is_active` (and `published_at` when activating); a trigger refuses other updates and deletes; counsel's text ships as a new version.
- R21: `sale_category` keeps its `FOOD` default; the deploy notes carry a pre-push and post-push catalogue classification check (deploy note 4).
- R22: user gateways use the service role only for Storage signing and removal and for the `log_message_delivery` write (spec §7, plan Decision 4); see the exception note under "Writing an Edge Function".

**Follow-up outside A5 (Spec A scope), now closed.** Spec A's `issue_otp`
took the code as `p_code`, so a DSA or fintech agent could choose it over
PostgREST. Fixed by the auth hardening below (H2).

### Tenant sale categories and NAFDAC numbers

One migration (`20261024120000_tenant_categories_nafdac`), local only. It
deploys with or after A5, which it extends.

- **`tenant_allowed_categories`** `(tenant_id, category, enabled)` decides
  which categories each tenant may sell. Every tenant starts with `FOOD` and
  `COSMETICS` (trigger on `tenants`). Rows are written by migration only, with
  no RPC, like `refund_policies`; members read their own tenant's rows.
- **TELECOM is Sureach's alone.** Sureach Nigeria Limited holds the NCC
  licence. It is seeded as tenant `SUREACH` with fixed id
  `5eac0000-0000-4000-8000-000000000001`, allowed all four categories. A
  trigger refuses TELECOM for any other tenant: "Only Sureach Nigeria Limited
  holds the NCC licence to sell TELECOM products." TELECOM still needs a
  policy version that covers it before it is sellable on the web.
- **Product guard.** A trigger on `central_products` checks the category on
  insert, on a category or tenant change, and on activation: P0001 "Tenant is
  not authorized to sell products in category <C>." A category cannot be
  withdrawn (disabled or deleted) while the tenant has active products in it;
  deactivate them first.
- **NAFDAC numbers.** `central_products.nafdac_number`: upper-case letters and
  digits in 2 to 6 hyphenated groups, at most 32 characters (`A7-0123`,
  `LG-IKJ-02-2134`). An active `FOOD` or `COSMETICS` product must have one
  (CHECK `central_products_nafdac_required`, 23514). The dispute evidence
  bundle shows `nafdac_number` and `nafdac_regulated` on each line (the
  product's current values; the function now lives in `20261024140000`).
- **Purerigin Coconut Oil** (Teafair's own brand, tenant TEAFAIR) is seeded
  active as two SKUs, both `COSMETICS` with NAFDAC `LG-IKJ-02-2134`:
  `PURERIGIN-COCONUT-OIL-200ML` (retail 5,000, wholesale 4,000 a bottle) and
  `PURERIGIN-COCONUT-OIL-100ML` (retail 3,000, wholesale 2,500 a bottle).
- **The NAFDAC requirement is `NOT VALID` on push.** Products that already
  exist are not checked, so the push cannot fail on them, but any update to
  such a row fails until it has a number. **Pre-push:** confirm that no remote
  tenant uses the code `SUREACH` (`select id from tenants where code = 'SUREACH';`
  must return 0 rows). **Post-push**, list the products still missing a number:
  `select t.code, p.sku_code, p.product_name from central_products p join tenants t on t.id = p.tenant_id where p.is_active and p.sale_category in ('FOOD','COSMETICS') and p.nafdac_number is null;`
  Load their numbers (or deactivate them; until then they stay on sale). When
  the list is empty, close the gap in a new migration:
  `alter table public.central_products validate constraint central_products_nafdac_required;`

### Cartons and break-bulk packs

Two migrations (`20261024130000_break_bulk`, `20261024130100_app_wholesale_price`),
local only, after the one above.

- Prices stay **per unit**: `unit_price` is retail, `wholesale_price` is
  wholesale. `central_products.carton_units` is the number of units in a
  carton. `break_bulk_units` is the smallest pack the trade may buy, and must
  divide the carton. The generated columns `carton_wholesale_price` and
  `break_bulk_wholesale_price` give the pack prices.
- **Trade sales come in whole packs.** Order lines on any channel except
  `ONLINE`, and retail stock pickup lines, must be a multiple of the
  break-bulk pack (else a full carton; with neither, any quantity): P0001
  "<product> sells to the trade in packs of N units; Q is not a whole number of
  packs." Web buyers still buy single units. The rule sits on the tables
  (triggers) because no RPC writes these lines yet; Spec C inherits it.
  **User decision 2026-10-24: web sales (`ONLINE`, the Teafair storefront) are
  retail; every app sale (`FIELD_SALES`, `RETAIL`, pickups) is wholesale.**
  App order lines must also be priced at the product's per-unit
  `wholesale_price` (`20261024130100`): P0001 "App sales are at the wholesale
  price: <product> is W a unit, not P." Web lines keep the retail price.
  Requisitions (warehouse to warehouse) are not restricted.
- **Purerigin break-bulk (user, 2026-10-24): a quarter carton.** 200ml:
  carton of 12 at 48,000, quarter carton of 3 at 12,000. 100ml: carton of 24
  at 60,000, quarter carton of 6 at 15,000.

### Teafairweb retail pricing

One migration (`20261024140000_web_retail_pricing`), local only. User
decisions 2026-10-24: the web is for consumers, at full retail price.

- **No web discounts.** Existing link discounts are cleared on push, and a
  trigger on `web_referral_codes` refuses new ones: P0001 "Web discounts are switched
  off: Teafairweb sells at full retail price." (`upsert_web_referral_code` keeps its
  signature; pass null.) Web lines are billed at `unit_price`; the cart's
  `discount` is always 0 and the catalogue has no `discount` key. CHECK
  `orders_web_no_discount` (NOT VALID, so A1-era orders keep theirs).
- **Transport fare:** a flat fare per web order from
  `tenant_settings.web_transport_fare` (TEAFAIR 750, others 0). The cart
  returns `subtotal`, `discount`, `goods_total`, `transport_fare` and `total`
  (goods plus fare). `orders.transport_fare` records it; only `ONLINE` orders
  carry one, never above the total. Refunded only if the order is cancelled
  before dispatch or never delivered (policy text; staff refund in Paystack).
- **POS agent commission (A6 §15.5, replaces the flat ₦500 bounty).**
  `tenant_settings.web_agent_commission_bps` (integer 0-10000, default 0,
  written by migration only) is 0 for every tenant, TEAFAIR included, until
  the user agrees rates, so no order splits yet. The share is
  `round(goods_total * bps / 10000, 2)`, on goods only and never on the fare,
  paid through the Paystack split (`commission_bps` is the tenant rate,
  `partner_share` the share). It applies only when the order's referral code
  is tied to a POS venue whose partner is ACTIVE. Codeless orders, DSA/DSM
  links, a SUSPENDED partner, a rate of 0 and a share that rounds to 0 all
  get `split` null, no `payments.split_*` and no `web_commissions` row.
  `web_pos_partners.commission_bps` and `web_agent_bounty` are dropped.
  `web-checkout` needed no change: it charges the quote total and splits
  `partner_share`.
- **Evidence bundle:** the order header shows `goods_total`,
  `discount_amount`, `transport_fare`, `total_amount` and `referral_code_id`;
  each payment shows `agent_commission`.
- Ruling: the commission rate is a per-tenant setting, like the fare, written
  by migration only.

### Sentry observability

`@sentry/deno@10.76.2` (pinned in `_shared/core/deps.ts`), local only. **Off
unless `SENTRY_DSN` is set**, so tests and plain local runs send nothing.

- **`observe(name, handler)`** (`_shared/core/observability.ts`) wraps every
  function's `Deno.serve` handler. It continues the caller's trace from the
  `sentry-trace` and `baggage` headers, opens one `http.server` transaction
  per request (`POST /<function>`), tags `function`, `region` and
  `execution_id`, and flushes after the response through
  `EdgeRuntime.waitUntil`. Default integrations are off; the edge runtime has
  no `Deno.serve` instrumentation.
- **Spans:** every RPC is a `db.rpc` child span (`rpc <function>`, with
  `db.sqlstate` on a refusal; never the arguments). The message router adds
  `message.send` spans per WhatsApp and SMS attempt (channel and purpose
  only). Spans inside Postgres are not possible from here.
- **Tags:** user gateways tag `gateway=user`, `tenant_id`, `tenant_role` and
  `platform_role` from the verified JWT, plus `user.id`; public gateways tag
  `gateway=public`.
- **What becomes an event** (`reportError`, called from `errorResponse` and
  for anything thrown past the handler): every 5xx and every unexpected throw
  at level `error`; database refusals (P0001, 42501, 23505, 23514, TF001,
  TF002) at level `warning`, fingerprinted by RPC + SQLSTATE + message shape
  (digits folded) so each rule is one issue. Bad input, auth failures and 404s
  send nothing. Tagged `db.sqlstate`, `rpc.function`, `error_code`,
  `http.status_code`.
- **Scrubbing** (`_shared/core/scrub.ts`, `beforeSend`,
  `beforeSendTransaction`, `beforeBreadcrumb`; `sendDefaultPii: false`):
  requests keep only method and path (no query, headers or body); the user
  keeps only its id; values under sensitive keys (pin, otp, code, token,
  secret, proof, phone, email, address, ip, hash, signature, path, url; `p_`
  RPC parameters too) are dropped; every string is scrubbed of JWTs, bearer
  tokens, Paystack keys, signed URLs, emails, Nigerian and E.164 phone
  numbers, IPs, and digits next to "pin", "code" or "otp". Stack frames lose
  local variables.
- **Env** (`functions/.env.example`): `SENTRY_DSN`, `SENTRY_ENVIRONMENT`
  (local, staging, production), optional `SENTRY_RELEASE` (git SHA),
  `SENTRY_TRACES_SAMPLE_RATE` (default 1; lower it as traffic grows).
- **Tests:** `scrub.test.ts` and `observability.test.ts` (a recording
  transport) prove scrubbing, trace continuation, tags, the RPC span and the
  capture policy. The integration run's fake ingest on port 54399 receives
  real envelopes from the edge runtime when `functions/.env` has
  `SENTRY_DSN=http://public@host.docker.internal:54399/1` and
  `SENTRY_ENVIRONMENT=local-integration`; the Sentry test is skipped without
  a DSN.

**Proving it against real Sentry (local, under 3 minutes):**

1. In Sentry, create a project for the backend (platform Deno) and copy its
   DSN. Choose the data region (EU or US) deliberately: events leave Nigeria.
2. In `supabase/functions/.env`, set `SENTRY_DSN=<that DSN>` and
   `SENTRY_ENVIRONMENT=local`; then `supabase functions serve --env-file supabase/functions/.env`.
3. Sign in as a staff user and send a request the database refuses, with a
   trace of your own:
   `curl -X POST http://127.0.0.1:54321/functions/v1/order-dispatch -H "Authorization: Bearer <jwt>" -H "content-type: application/json" -H "sentry-trace: 4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1" -d '{"idempotency_key":"<uuid>","order_id":"<random uuid>"}'`
4. In Sentry: **Issues** shows a warning on `mark_order_dispatched` tagged
   `tenant_id`, `tenant_role`, `db.sqlstate`; **Performance** (or the trace
   view for `4bf92f3577b34da6a3ce929d0e0e4736`) shows `POST /order-dispatch`
   with its `rpc mark_order_dispatched` span. Check the event JSON holds no
   phone, token or PIN.
5. Put `SENTRY_DSN` back to the fake (or empty) before running the
   integration tests.

**Deploy:** set `SENTRY_DSN`, `SENTRY_ENVIRONMENT` and `SENTRY_RELEASE` as
remote function secrets; nothing else changes.

### Auth hardening and the Supabase Auth hooks

Three migrations (`20261024150000_auth_verified_phone`,
`20261024160000_secure_otp_generation`, `20261024170000_auth_hooks`) and the
functions `send-auth-sms` and `send-auth-email`, local only. From the
2026-10-24 auth audit.

- **H1, verified phones only.** `handle_new_user` takes the phone from
  `auth.users.phone` only, never `raw_user_meta_data` (client-written at
  sign-up). `invite_tenant_user` only finds an account whose phone Supabase
  Auth confirmed (`phone_confirmed_at`). Self-serve sign-up is off
  (`[auth] enable_signup = false`): accounts come from the Admin API with
  `phone` and `phone_confirm: true`. **Gotcha:** in `config.toml`,
  `[auth.email] enable_signup` and `[auth.sms] enable_signup` are the email and
  phone *provider* switches; turning them off disables those logins
  entirely. Keep both on; the global switch blocks new accounts.
- **H2, the database draws the shop-owner OTP.** `issue_otp(p_idempotency_key,
  p_subject_id, p_purpose, p_gateway_proof)` checks `assert_gateway_proof` (the
  Vault `gateway_secret`, as R16), draws 6 digits from `gen_random_bytes`
  (rejection-sampled), stores the bcrypt hash, and returns `code` to the
  gateway on the first call only. The code is never in `idempotency_logs`, so
  a replay carries none and sends nothing. The audit row no longer holds
  `destination_phone`. `otp-issue` now needs `GATEWAY_SECRET`.
- **M1, phone sign-in codes (`send-auth-sms`).** Supabase Auth's Send SMS hook
  (Standard Webhooks, `SEND_SMS_HOOK_SECRET`). It sends a code only when
  `auth_sms_allowed(user, phone)` holds: the account's own profile phone, and
  a platform role or an ACTIVE or INVITED membership. It refuses phone
  changes, because the profile would not follow them. It sends through the A5
  router, purpose `AUTH_OTP` (platform-level log, no tenant). **User decision
  2026-10-24: WhatsApp only** (trusted; Nigerian SMS delivery is poor; Twilio
  is too expensive). `AUTH_OTP_SMS_FALLBACK=true` adds the KudiSMS fallback.
  **Twilio is never used.** Locally `[auth.sms.twilio]` is enabled with inert
  `local-unused` values only because the CLI turns the phone provider on only
  with a built-in provider; with the hook on, Auth never calls it.
- **Email (`send-auth-email`, Resend).** Supabase Auth's Send Email hook
  (`SEND_EMAIL_HOOK_SECRET`) handles `recovery`, `signup`, `invite` and
  `email_change` (both addresses under secure change; Supabase's
  `token_hash_new` goes to the *current* address). Magic links, email OTPs
  and reauthentication are refused (not a Teafair sign-in route). Links go
  to `<AUTH_EMAIL_LINK_BASE or SUPABASE_URL>/auth/v1/verify?token=<token_hash>&type=...&redirect_to=...`.
  `redirect_to` is kept only when its origin and path exactly match
  `AUTH_SITE_URL`, `<AUTH_SITE_URL>/reset-password` or
  `AUTH_EMAIL_REDIRECT_URLS` (query and fragment dropped); otherwise the reset
  page (recovery) or the site URL is used. Resend gets an `Idempotency-Key`
  from the hook's `webhook-id`, so a retried hook never sends twice. Copy is
  fixed text: nothing a user typed is rendered.
- **Hook errors travel as HTTP 200** with `{error:{http_code,message}}`
  (`_shared/auth/hook.ts`). Supabase Auth turns any other status into a bare
  500 ("Unexpected status code returned from hook") and drops the message.
- **L1.** `SMS_PROVIDER=log` refuses to start unless `SUPABASE_URL` is the
  local stack (`assertSafeSmsProvider`). Optional `KUDISMS_GATEWAY` is sent as
  KudiSMS's `gateway` field. Its value for the corporate (DND) route is
  unconfirmed: ask KudiSMS before setting it.
- **Config (local):** passwords at least 12 characters, email confirmations
  on, one email per 60 s per user, and exact redirect URLs including
  `/reset-password`.
- **Sentry:** both hooks tag `gateway=auth-hook` and `user.id` only.
  Delivery failures are `error` events with fixed text, never an address,
  number or code.
- **Tests:** pgTAP 002, 004, 008 and 035. Unit tests for both hooks, `sms.ts`
  and `otp-issue`. Integration covers:
  - anonymous sign-up refused;
  - phone sign-in end to end (WhatsApp code, `verifyOtp`, tenant claims);
  - a non-member refused with the hook's own 403;
  - the recovery email via the fake Resend, with a one-time link landing on
    `/reset-password`;
  - a hostile `redirectTo` kept out of the email;
  - the DSA's direct `issue_otp` call refused (42501);
  - the shop-owner code verifying.

  The Sentry integration test runs only when `SENTRY_DSN` points at the fake
  (`host.docker.internal:54399`); with a real DSN, events go to real Sentry.

**Deploy (after A5 and the pricing migrations; deploy `otp-issue` straight after the push).**

1. Pre-push on the remote: find profiles whose phone Supabase Auth never
   confirmed (they came through the old metadata path and can no longer be
   invited), and decide on each before the push:
   `select p.id from public.profiles p join auth.users u on u.id = p.id where u.phone is null or u.phone_confirmed_at is null;`
2. Push the three migrations, then deploy `otp-issue` immediately: the old
   `otp-issue` sends `p_code`, which the new `issue_otp` no longer accepts.
3. Function secrets:
   - `SEND_SMS_HOOK_SECRET`, `SEND_EMAIL_HOOK_SECRET`;
   - `RESEND_API_KEY`, `AUTH_EMAIL_FROM` (a Resend-verified domain);
   - `AUTH_SITE_URL`, optional `AUTH_EMAIL_REDIRECT_URLS`;
   - `AUTH_OTP_SMS_FALLBACK`.

   Leave `AUTH_EMAIL_LINK_BASE` unset. `GATEWAY_SECRET` is now also needed by
   `otp-issue`.
4. Deploy `send-auth-sms` and `send-auth-email` (`--no-verify-jwt`, as every
   function here).
5. Dashboard (never `config push`):
   - Authentication > Sign In / Providers: "Allow new users to sign up" off,
     Email on with "Confirm email" on, Phone on;
   - Auth Hooks: Send SMS -> `https://<ref>.supabase.co/functions/v1/send-auth-sms`
     and Send Email -> `.../send-auth-email`, each with its secret (generate
     there, then copy to the function secret);
   - URL Configuration: the site URL and the exact redirect URLs, including
     `/reset-password`, no wildcards;
   - minimum password length 12;
   - a short SMS OTP expiry (the local default is 6000 s).

   If the dashboard insists on an SMS provider before Phone can be switched
   on, check Supabase's current guidance: the hook replaces the provider, and
   Twilio must not be bought for this.
6. Meta: the `teafair_otp` authentication template is now also the sign-in
   code. With no SMS fallback, a number not on WhatsApp cannot sign in.

### Domain separation (A6 §15)

Migrations `20261028130000`-`20261028130500`, pgTAP 042-045, local only.
User ruling 2026-10-28: Monvelo is strictly B2B trade financing; web sales
never move to Monvelo. The `fintech_*` names are gone.

| Domain | Owns | Never |
|---|---|---|
| Web | `web_pos_partners`, `web_pos_venues`, `web_referral_codes`, `web_commissions`; `tenant_settings.web_*`; storefront and checkout RPCs; `web-checkout`, `web-commission-release`, `web-order-status`, `storefront-*` | reads or writes a `monvelo_` table; has an FK onto one |
| Monvelo | every `monvelo_` table, `areas`, the ZSA/ASA anchors, `MONVELO_*` platform roles; `monvelo-*` gateways | reads or writes a `web_` table; has an FK onto one; pays through the web commission path |
| Shared | `payments` and the Paystack webhook (`process-payment`, `settle_paystack_payment`, `apply_paystack_refund`); `reconcile-funds`; `_shared/payments/`; OTP; the message router; `retail_shops`, `profiles`, `tenants`, `orders` | - |

Renames: `fintech_partners` -> `web_pos_partners`, `fintech_terminals` ->
`web_pos_venues`, `agent_codes` -> `web_referral_codes`, `commission_records`
-> `web_commissions`, `FINTECH_AGENT` -> `POS_AGENT`,
`monvelo_fintech_agents`/`_members` -> `monvelo_agents`/`monvelo_agent_members`,
`upsert_agent_code` -> `upsert_web_referral_code`, `set_terminal_venue` ->
`set_web_pos_venue`, `request_settlement_change`/`approve_settlement_change` ->
`request_monvelo_settlement_change`/`approve_monvelo_settlement_change`,
`fintech-commission-release` -> `web-commission-release`,
`_shared/fintech-liquidity/` -> `_shared/payments/`. `fintech_advances` is
dropped (Monvelo financing replaces it). The full mapping is A6 §15.4. The two
staff RPC results changed: `upsert_web_referral_code` returns
`referral_code_id`, `set_web_pos_venue` returns `venue_id`; and
`order-dispute-evidence` shows `order.referral_code_id`. Public (teafairweb)
responses and the wire keys `subaccount_code`, `commission_bps`,
`partner_share` and the Paystack metadata `agent_code` are unchanged.

**Naming note.** The `fintech_liquidity_*` migration files keep their
historical names; they hold OTP, the Paystack webhook and D1 money; the domains
are `web_*` and `monvelo_*`.

**The commission rule** is under "Teafairweb retail pricing" above: only POS
referral-link orders earn, at `tenant_settings.web_agent_commission_bps`
(0 for every tenant for now).

**The guard** is `042_domain_separation_guard.test.sql`: no function body
names an old identifier (case-sensitive patterns, `terminal_id` tested after
stripping `network_terminal_id`, `commission_bps` banned only as a column
access), no constraint, index, policy or trigger carries an old name, the old
objects are absent, and no cron job names `fintech-commission-release`. `045`
proves the boundary: no body names both a `public.web_` and a `public.monvelo_`
table, and no FK joins the two domains.

**Deploy notes (A6 §15.8; user actions, later; nothing is pushed).** The
remote has the 29 migrations to `20261015130200` and still holds the old
names.

- Pre-push checks (any non-zero result needs a decision):
  1. `select count(*) from public.fintech_advances;` must be 0 (its rows are lost).
  2. `select count(*) from public.fintech_partners where commission_bps > 0;`
     those per-partner rates are dropped; every tenant's rate is 0 afterwards.
  3. `select count(*) from public.tenant_users where role = 'FINTECH_AGENT';`
     informational; those memberships become `POS_AGENT`.
- Redeploy every importer of `_shared/payments/`: `process-payment`,
  `reconcile-funds`, `web-checkout`, `web-commission-release` and
  `monvelo-agent-register`.
- Deploy `web-commission-release` in the same window as the migration push,
  outside the 06:00 UTC run. If the push and the deploy straddle 06:00, the job
  logs one 404 and runs again the next day.
- Idempotency keys logged under the old op names (`upsert_agent_code`,
  `set_terminal_venue`, `request_settlement_change`,
  `approve_settlement_change`) raise TF002 if replayed after the push; no client
  exists, so no action.
- `supabase functions delete fintech-commission-release` only if it was
  deployed by then (the 2026-10-15 record lists six functions, so it was not).
- Never run `supabase config push`.

### Monvelo (A6), Step 1

Migrations `20261028120000`-`20261028120600` (plus the §15 renames above),
pgTAP 036-041 and 045, local only. A6 §16 (Step 1c) and Step 2 are under
"Monvelo (A6) Step 1c and Step 2" below.

- **Tables:** `areas`; `monvelo_agents` and `monvelo_agent_members`;
  `monvelo_shop_enrolments` and `monvelo_consent_challenges` (enrolments and
  challenges); `monvelo_agent_nominations`; `monvelo_tenant_settings`;
  `monvelo_brand_terms`; `monvelo_tenant_fee_terms`.
- **RPCs:** `upsert_area`, `set_monvelo_tenant_settings`,
  `propose_monvelo_brand_terms`, `approve_monvelo_brand_terms`,
  `withdraw_monvelo_brand_terms`, `record_monvelo_fee_terms`,
  `register_monvelo_agent`, `approve_monvelo_agent`, `suspend_monvelo_agent`,
  `set_monvelo_agent_caps`, `add_monvelo_member`,
  `request_monvelo_settlement_change`, `approve_monvelo_settlement_change`,
  `start_monvelo_consent`, `enrol_monvelo_shop`,
  `withdraw_monvelo_shop_consent`, `nominate_monvelo_agent`,
  `close_monvelo_nomination`.
- **Gateways:** `monvelo-agent-register` (Paystack account resolution, then
  `register_monvelo_agent`) and `monvelo-shop-consent` (the owner consent
  code). No new secrets: both need `GATEWAY_SECRET`, and
  `monvelo-agent-register` also needs the Paystack key (`PAYSTACK_SECRET_KEY`).
- **Roles:** `ZSA` (zone) and `ASA` (area) are the street-agent anchors on
  `tenant_role_enum`; `order_channel_enum` `FIELD_DSA` is renamed
  `FIELD_SALES`.

### Monvelo consent MV-SHARE-2026-10

Migration `20261028120600_monvelo_shop_enrolment`, function `monvelo-shop-consent`
(A6 §4.1, NDPA 2023, ruling 10), local only.

- **The consent text.** The owner agrees that Teafair may share the shop's
  name, shop code, location and area with registered Monvelo agents for
  stock financing, and may withdraw at any time. The words are shown in the
  app (Spec B); the WhatsApp message is the authentication OTP template, which
  carries no custom text. Every enrolment records `consent_version`
  (`MV-SHARE-2026-10`) and `consent_at`. New wording is a new version string.
- **Withdrawal.** `withdraw_monvelo_shop_consent` (the shop's owner only) sets
  every ACTIVE or SUSPENDED enrolment of the shop to WITHDRAWN. Re-enrolment
  needs a fresh code and returns the row to ACTIVE with a new consent time.
  Withdrawal leaves `retail_shops.preferred_agent_id` in place, so Step 2+
  readers must require an ACTIVE enrolment before showing a shop to an agent.
- **Destination.** The code goes to the owner's verified profile phone
  (`auth.users.phone_confirmed_at` set), never the shop's contact number.
- **Area guard.** The area must be in the caller's tenant (42501). A ZSA's
  area must lie in a territory of the ZSA's zone; an ASA's area must be the
  ASA's own `tenant_users.area_id` (the stricter reading).
- **Nominations** keep the last four digits of the phone only; the full number
  is dropped in the RPC and reaches the street agent through a notification
  (Step 6).

### Teafair field structure (A6 §17)

Migrations `20261029125000_teafair_field_structure` and
`20261029125100_zone_management`, pgTAP 056 and 057, local only.
User rulings 2026-10-29: the ZSM is a Teafair official overseeing several
tenants; zones are states; one ZSM can cover several zones.

- **Zones are states.** `zones.state_code` (NOT NULL, FK `ng_states`,
  `unique (tenant_id, state_code)`); `zone_name` is a display name. The
  migration backfills by exact state name (case-insensitive) through the
  internal `zone_state_backfill()` and **fails, naming each zone, on any zone
  it cannot match** (or two zones of one tenant on one state); it never
  guesses. **Pre-push:** on the remote, rename every zone to its state's
  `ng_states.name` first:
  `select z.tenant_id, z.id, z.zone_name from zones z left join ng_states s on lower(s.name) = lower(btrim(z.zone_name)) where s.code is null;`
  must return 0 rows.
- **Zones and ZSMs belong to the platform (`20261029125100`).** Three audited
  `PLATFORM_SUPER_ADMIN` RPCs (`authenticated`; `appoint_zone_manager` and
  `create_zone` take `p_tenant_id`, the platform-role exception, as
  `appoint_client_service_manager`):
  - `appoint_zone_manager(key, tenant, phone)`: a confirmed phone becomes an
    INVITED ZSM with no zone, notified (`TENANT_INVITE`); an existing member
    is 23505, a non-ACTIVE tenant P0001.
  - `create_zone(key, tenant, state_code)`: the zone is named after its state;
    a second zone for a state is 23505 "this tenant already has a zone for
    that state".
  - `set_zone_zsm(key, zone, profile)`: the tenant comes from the zone; null
    clears coverage; otherwise the profile must be an ACTIVE ZSM of that
    tenant (P0001); audited with `zsm_id` before and after.

  `upsert_zone` keeps its signature but no longer creates zones (42501 "zones
  are created by a platform administrator"); a ZSM edits only a zone in their
  `zsm_zone_ids` (42501 "this zone is not yours"), only its boundary, and a
  name other than the state's is P0001 "a zone is named after its state".
  `invite_tenant_user` still refuses a ZSM invite.
- **Coverage is `zones.zsm_id`.** A ZSM covers every zone where they are
  `zsm_id`, in each tenant where they hold an ACTIVE ZSM membership. A ZSM's
  `tenant_users` row carries no zone (CHECK `tenant_users_zsm_no_zone`, which
  replaces `tenant_users_zsm_has_zone`). The backfill made each ACTIVE ZSM
  the `zsm_id` of their old zone where it had none (earliest membership
  first; others are listed in a NOTICE), then cleared `zone_id`. A platform
  administrator sets `zones.zsm_id` with `set_zone_zsm` (the
  `zones_check_manager` trigger still requires an ACTIVE ZSM of the tenant).
  **Pre-push:** list the ZSMs who will lose their old zone's coverage (an
  INVITED or DISABLED ZSM, one whose zone already has another `zsm_id`, one
  sharing a zone with an earlier ACTIVE ZSM, or one with no zone), and plan a
  `set_zone_zsm` for each after the push:
  `with pick as (select distinct on (tenant_id, zone_id) tenant_id, zone_id, profile_id from public.tenant_users where role = 'ZSM' and status = 'ACTIVE' and zone_id is not null order by tenant_id, zone_id, created_at, id) select tu.tenant_id, tu.profile_id, tu.status, tu.zone_id from public.tenant_users tu left join public.zones z on z.tenant_id = tu.tenant_id and z.id = tu.zone_id left join pick p on p.tenant_id = tu.tenant_id and p.zone_id = tu.zone_id where tu.role = 'ZSM' and (tu.status <> 'ACTIVE' or coalesce(z.zsm_id, p.profile_id) is distinct from tu.profile_id);`
- **Helpers.** `zsm_zone_ids(tenant, profile)` (internal, SECURITY DEFINER)
  and `my_zsm_zone_ids()` (the caller's zones in the active tenant,
  `authenticated`, for policies). `chat_staff_zone_ids(tenant, profile)`
  (internal) gives a staff member's zones; `chat_staff_zone` now returns a
  ZSM's zone only while they cover exactly one.
- **Recreated (signatures and grants unchanged):** `invite_tenant_user` (the
  territory must be in one of my zones; a ZSA takes the zone of the territory
  named in the invite, or the ZSM's only zone; a ZSM covering several zones
  must name a territory, P0001; the ZSA's manager must cover that zone),
  `upsert_territory`, `upsert_area`, `hide_chat_message`,
  `my_chat_channel_ids` (a multi-zone ZSM is in every ZONE channel and
  territory room of their zones) and `get_or_create_direct_channel` (zone
  rules compare zone sets). `assign_ticket` and `web_route_try` already route
  by the object's zone through `zones.zsm_id` and are unchanged.
  `start_monvelo_consent` checks the ZSA's own `zone_id` and is unchanged.
- **The field force is Teafair staff** (§17.2): only a platform administrator
  appoints a ZSM (`appoint_zone_manager`); ZSMs invite TM, ASM, ZSA and ASA
  within their zones.

### Monvelo (A6) Step 1c and Step 2

Migrations `20261029120000`-`20261029130600`, pgTAP 046-060 (`051`-`054` and
`058` are Step 2), the function `contact-report-upload`, local only. The plan
is `docs/superpowers/plans/2026-10-29-monvelo-step1c-step2.md`; its ledger of
rulings is in `.superpowers/sdd/` (git-ignored).

**Step 1c: tenant representation (A6 §16).**

- **Roles.** `CLIENT_SERVICE_MANAGER` (Teafair staff representing a tenant in
  house; appointed by a `PLATFORM_SUPER_ADMIN` with
  `appoint_client_service_manager`, one membership per tenant served),
  `TENANT_ADMIN` (the tenant's read-only login; every write RPC refuses it with
  42501), `LOGISTICS_MANAGER` (Teafair staff under the CSM; dispatches and
  reads FUNDED financings).
- **Contact reports are the source of truth.** The CSM files an insert-only
  report (`file_contact_report`) with attendees, decisions and recipients;
  corrections supersede it. A ZSM reviews it (`review_contact_report`; a
  `MONVELO_OPERATOR` only while the tenant has no ACTIVE ZSM), then the CSM
  uploads the signed hard copy (`request_contact_report_hard_copy`, the
  `contact-report-upload` gateway, `attach_contact_report_hard_copy`; bucket
  `contact-reports`, PDF/JPEG/PNG up to 10 MB). Only then is a decision
  citable (`assert_citable_decision`).
- **Decision subjects:** `BRAND_TERMS`, `MONVELO_SETTINGS`, `FEES`,
  `CATALOGUE`, `STOCK`, `DISTRIBUTION`, `OTHER`. A citation must match its
  subject and cite the current report of a correction chain.
- **Every tenant agreement cites a decision (zero backdoors):** brand terms
  approval and withdrawal, `set_monvelo_tenant_settings`,
  `record_monvelo_fee_terms`, `upsert_catalogue_product`, the stock RPCs
  (`record_stock_receipt`, `record_stock_transfer`, `record_stock_adjustment`)
  and `set_tenant_operational_state`. `049` scans every function body for
  writes to the guarded tables and fails on any writer that does not cite the
  right subject, unless it is on a named allowlist with a reason.
- **The bridging rule.** The CSM approves brand terms and settings. While a
  tenant has no CSM, a ZSM other than the proposer approves, still citing a
  ZSM-approved, hard-copied decision.
- **Sending is deferred.** Each recipient gets a PENDING
  `contact_report_deliveries` row (the send log); nothing is sent until Step 6
  adds a Meta-approved utility template and a drain through the router.

**Operations (A6 §18).**

- **ZSM scope (§18.3).** ZSM admin and approval powers, and their reads, are
  limited to the zones they cover; an uncovered zone stays open to every
  ACTIVE ZSM of the tenant until one is assigned. Tenant-wide objects (terms,
  settings, contact-report review, web defaults) stay with any ZSM. ZSM-to-ZSM
  direct chat is open.
- **Operational states (§18.4).** `set_state_operational` (platform admin,
  with a reason) switches a state on for the app and the web separately; a
  brand opts in with `set_tenant_operational_state` citing a `DISTRIBUTION`
  decision. New work (web orders, trade orders, enrolment, supply days,
  pledges, financing requests) needs both; placed orders, dispatch, delivery,
  refunds and winding down never do. Opt-ins persist across platform toggles.
- **Stock (§18.1).** Orders reserve stock at placement, first expiry first out
  (`stock_reservations`; `inventory_batches.quantity_reserved` is the stored
  sum, TF001 `insufficient stock` with `{sku_code, available, requested}`);
  dispatch consumes it into `SALE_DISPATCH` movements; a cancel or a refund
  before dispatch releases it; `record_order_return` (LM or CSM) restores goods
  after dispatch, citing the order. Cron `stock-reservation-sweep` (every 15
  min) cancels unpaid web orders after `tenant_settings.web_reservation_hours`
  (24) and cash trade orders still PENDING at the end of their Lagos supply day.

**Step 2: the financing ledger and allocation.**

- **Tables:** `monvelo_platform_settings` (radius 1000 m, preferred window 10
  min, claim 15 min; migration only), `monvelo_supply_days`, `monvelo_pledges`,
  `monvelo_financings` (every §4.4 column; status machine enforced by trigger),
  `monvelo_financing_lines` (one per brand; terms locked once at funding),
  `monvelo_shop_limits` and `monvelo_shop_limit_events` (per-brand limit and
  its insert-only history), `monvelo_financing_claims`,
  `monvelo_tenant_ledger_entries` (insert-only; FUNDED_GROSS positive, every
  other entry negative; no writer until Steps 3 and 5). Monvelo records are
  never deleted, and `service_role` holds no write on the Step 2 tables.
  Tenants never see lenders (§16.2.2): claims are read only by the agent's own
  members and Monvelo staff.
- **RPCs:** `set_monvelo_supply_day`, `pledge_monvelo_funds`,
  `monvelo_supply_days_near`, `monvelo_agents_near`, `place_trade_order` (ZSA,
  ASA or TM; wholesale, whole packs, the territory's oldest REGIONAL
  warehouse), `request_monvelo_financing`, `approve_monvelo_financing` (the
  territory's TM, above the limit), `cancel_monvelo_financing` (the raiser or
  the TM; cancels the trade order and releases its stock),
  `claim_monvelo_financing`, `monvelo_open_offers` (never the owner),
  `monvelo_order_financing_status` (at most 200 orders).
- **Cron `monvelo-offer-sweep`** (every minute, pure SQL): lapsed claims go back
  to OFFERED with no new window; then a request still OFFERED or
  AWAITING_APPROVAL at the end of its Lagos supply day, or whose trade order is
  no longer PENDING (the stock sweep cancels unpaid trade orders), is EXPIRED
  and its trade order cancelled. Rows are audited as `CRON` on the raiser.
- **Allocation (§7.1).** The shop's preferred agent alone may claim during its
  window (only when its pledge covers the request); then any ACTIVE agent
  within the radius (the preferred agent is exempt) whose pledge, less its
  other open claims, covers the principal, within its per-financing and daily
  caps. One open claim per financing; an agent whose claim lapsed cannot claim
  that request again.
- **Credit is the tenant's (§7.2, user 2026-10-30).** Teafair imposes no
  cash-order or trading-history threshold. A shop's per-brand limit opens at
  the tenant's `opening_limit`; above it the TM approves. The tenant sets
  `limit_growth_bps`, `max_limit`, `default_cure_days` and
  `post_default_limit_bps` through `set_monvelo_tenant_settings`, citing a
  `MONVELO_SETTINGS` decision. The platform keeps only integrity checks:
  consent, a verified owner phone, approved terms for every brand of the order
  (all or nothing), a supply day, the operational state.
- **The hybrid default freeze (§18.2).** A shop with an unresolved default
  with any tenant gets no new request or claim for any brand; the message names
  no tenant or brand. After it is cleared, each tenant waits its
  `default_cure_days` ("<Brand> credit resumes on <date>"), and the shop's limit
  for each of its brands restarts once at `post_default_limit_bps` of the
  opening limit.
- **The raiser's overdue share (§7.3).** A ZSA, ASA or TM whose PAR30 (outstanding
  more than 30 days past due, over the outstanding of what they raised that was
  delivered, with every tenant) passes 10% cannot request until it drops.
- **For Step 3:** funding must require a PENDING trade order and debit the
  pledge once; the tenant ledger's writers arrive with funding and payouts.

### Monvelo (A6) Step 3: funding, delivery, repayment, the money sweep

Migrations `20261031120000`-`20261031120400`, pgTAP 061-064, the functions
`monvelo-fund`, `monvelo-confirm-delivery` and `monvelo-confirm-repayment`,
local only. The plan is
`docs/superpowers/plans/2026-10-31-monvelo-step3-funding-repayment.md`. Its
calls, as amended, and the material rulings are recorded in A6 §19.

- **Tables:** `monvelo_flags` (PAYER_MISMATCH, LATE_PAYMENT, AMOUNT_MISMATCH,
  REPAYMENT_REJECTED, REPAYMENT_UNCONFIRMED, FUNDING_REFUNDED; Monvelo staff
  only; reviewed once with `review_monvelo_flag`), `monvelo_rebate_payables`
  and `monvelo_rebate_payable_lines` (what Teafair owes the agent within 24
  hours; the agent's members and Monvelo staff), `monvelo_owner_challenges`
  (the shop owner's DELIVERY and REPAYMENT codes; no reader at all),
  `monvelo_repayments` (the funder's members, the shop owner and Monvelo
  staff). `payments` gains `monvelo_financing_id`, `monvelo_agent_id` and
  `monvelo_started_by`, none granted to `authenticated`.
- **RPCs:** `start_monvelo_funding` (the claimant's member; the reference is
  `MV-<financing>-<n>`), `settle_monvelo_funding` (service_role; the webhook
  and the sweep), `dispatch_monvelo_financing` (whoever passes
  `fulfilment_can_dispatch`; consumes the order's reservations),
  `start_monvelo_delivery` / `confirm_monvelo_delivery` (a holder of a
  `fulfilment_delivery_path`; delivery starts the clock and books FUNDED_GROSS
  and the FEE in the tenant ledger), `record_monvelo_repayment` /
  `confirm_monvelo_repayment` (the funder's member who recorded it),
  `reject_monvelo_repayment` (the shop owner; a flag and a HIGH ticket),
  `apply_monvelo_refund` (service_role). Internal: `monvelo_apply_late_charge`,
  `monvelo_delivery_cutoff`, `monvelo_fee_bps_at`, `monvelo_payer_matches`.
  The code RPCs take the gateway proof (`gateway_secret`), like A5's PIN RPCs.
- **Gateways.** `monvelo-fund` starts a Paystack bank transfer to Teafair's
  main account (no split, no callback URL, `channels: ["bank_transfer"]`).
  `monvelo-confirm-delivery` and `monvelo-confirm-repayment` send the owner's
  6-digit code over WhatsApp only, to the owner's verified profile phone, and
  never return it. The deliverer or recorder types in the code the owner reads
  out. A wrong, expired or locked code is a 422.
- **`MV-` routing.** `process-payment` and `reconcile-funds` share
  `_shared/payments/settle.ts`: a reference matching `MV-[A-Z2-7]{8}-n` settles
  through `settle_monvelo_funding`, and its refunds and reversals through
  `apply_monvelo_refund`. `settle_paystack_payment` and
  `apply_paystack_refund` refuse an MV- payment (outcome `monvelo_reference`),
  and `stock-reservation-sweep` ignores it.
- **The payer binding (F1).** A funding counts only if Paystack's Verify shows
  a bank transfer whose masked sender account ends in the agent's
  `settlement_account_last4`, and whose sender name matches the holder's name
  (at least two name tokens of two or more letters, either name inside the
  other). Anything else is flagged and refunded by staff in the Paystack
  dashboard, as D1 does. **Gap:** two accounts with the same holder name and
  the same last four digits cannot be told apart.
- **Cron `monvelo-money-sweep`** (every 5 min, pure SQL, `monvelo_sweep_money`):
  1. FUNDED at or after `funded_at` + 23 h → REFUND_DUE: the order is
     cancelled, its reservations released, the payable cancelled, and a HIGH
     ticket asks staff to refund.
  2. DELIVERED past `due_at` → the one late charge (DEFAULTED_WITH_LATE_CHARGE).
  3. Repayments PENDING for 24 h → EXPIRED, with a flag and a HIGH ticket.
- **Calls and rulings (cost if wrong):**
  - `payments` gains `monvelo_agent_id` and `monvelo_started_by` as well as
    `monvelo_financing_id`, all ungranted. Plan call 12 said one column; the
    late route needs the paying agent (R7, R12). If wrong: two columns to drop.
  - The delivery cutoff is 23 h after `funded_at` (user, 2026-11-01). It
    replaces 23:59 Lagos on the funding day. Delivery stops, and the refund
    falls due, at the same instant (`monvelo_delivery_cutoff`).
  - R9: the lender columns of `monvelo_financings` are out of the tenant's
    column grant. If wrong: tenants would see the lender.
  - R15/R19: every audit row naming an agent, a pledge, a payer, a Monvelo
    payment, a payable or a repayment is written with `tenant_id` null,
    including the four recruitment rows. If wrong: ZSMs lose those rows.
  - R20: only a `fulfilment_delivery_path` holder confirms a delivery; a code
    alone never does. If wrong: a field user without the order in scope
    cannot confirm.
  - R29: at most one FUNDED_GROSS and one FEE per financing (a unique index).
    If wrong: drop the index.
  - R30: an EXPIRED or LOCKED repayment code ends its repayment in the same
    call. If wrong: two PENDING records for a moment; confirmation still caps.
  - R32: only the recording member confirms a repayment. If wrong: a
    colleague cannot finish a hand-over.
  - R34: a suspended funder may still record and confirm repayments. If
    wrong: one status check.
  - R48 (D1–D6): the refund ticket names `MV-…-N`, never the agent; a
    dispatched order's ticket asks for the return; `FUNDING_REFUNDED` flags a
    live financing whose funding was refunded; a funding already refunded
    closes at once with no ticket; unconfirmed-repayment tickets are HIGH; a
    repayment expires at 24 h. If wrong: a line each.
- **Open for later:**
  - The `monvelo-refund:<financing>` ticket stays open after the refund closes
    the financing, so staff could refund twice by hand.
  - REFUND_DUE does not restore the agent's pledge `remaining` or its
    daily-cap headroom. Whether pledges recycle is a business question.
- **Integration.** `gateway.integration.ts` continues the Step 2 test's
  CLAIMED financing: funding, a lapsed claim that still funds, a payer
  mismatch, dispatch, the delivery code, a part repayment, the late charge and
  REPAID_LATE, and the TENANT_ADMIN's reads. It moves time as postgres through
  `DB_URL`.

## Layout

```
supabase/
├── config.toml
├── migrations/        hand-written, ordered — Supabase CLI owns all DDL
├── tests/database/    pgTAP, run by `supabase test db`
└── functions/         Edge Functions — one flat directory per function
    └── _shared/       core/ (gateway kernel, public-gateway, phone) · auth/ · commerce/ · payments/ · monvelo/ · messaging/ · storage/ · support/ · fulfilment/
```

Code is grouped by domain: `auth`, `rtm-core`, `commerce` (the web
storefront; its tables are `web_*`), `payments` (shared Paystack code),
`monvelo` and the supporting `messaging`, `storage`, `support`, `fulfilment`.
Migration and pgTAP file names carry the domain
(`…_auth_pin_verification.sql`, `008_fintech_liquidity_otp.test.sql`). A
domain gets a `_shared/<domain>/` folder once it has code. The
`fintech_liquidity_*` migration and test files keep their historical names;
they hold OTP, the Paystack webhook and D1 money; the domains are `web_*`
and `monvelo_*`.

Migrations are **hand-written**, not generated from declarative schemas: grants,
column privileges, comments and `cron.schedule` are outside what `db diff`
tracks, and grants are the security core (Spec A §13).

## Writing a migration

- Every new table: `enable row level security` in the same migration, a
  `FOR SELECT` policy, and nothing else. Never an INSERT/UPDATE/DELETE policy.
- Tenant-scoped tables carry `tenant_id uuid not null references
  tenants(id) on delete restrict`, a `unique (tenant_id, id)`, and reference
  other tenant rows through **composite** `(tenant_id, x)` foreign keys so a
  row can never point into another tenant.
- Index every foreign key and every column a policy filters on.
- Mutable tables get the `set_updated_at()` trigger.
- PostGIS lives in the `extensions` schema: write `extensions.geometry(...)`
  and `extensions.st_*` — function search paths do not include it.
- New functions get **no** EXECUTE for PUBLIC/anon/authenticated by default
  (grants migration). Grant explicitly, and only what the API may call.
- Buyer contact details live only in `order_contacts` (addendum A2), readable
  by the ZSM and the order's TM. Never put personal data on `orders` or in an
  audit payload; audit a redacted summary.
- `payments` and `tenant_users` are granted column by column. A new column on
  either is invisible to the app until added to the grant, and the app must
  name columns rather than `select *`.

## Writing an RPC

Follow the skeleton in `20261006130300_write_contract.sql`:

```sql
create or replace function public.<op>(p_idempotency_key uuid, ...)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me    public.tenant_users := public.assert_tenant_role(array['ZSM']::public.tenant_role_enum[]);
  v_prior jsonb;
begin
  v_prior := public.idempotency_begin(p_idempotency_key, '<op>', <request jsonb>);
  if v_prior is not null then return v_prior; end if;
  -- validate (P0001), lock contended rows in primary-key order, write
  perform public.write_audit(v_me.tenant_id, '<op>', '<table>', <id>, <before>, <after>, p_idempotency_key);
  return public.idempotency_complete(p_idempotency_key, <response jsonb>);
end; $$;
grant execute on function public.<op>(...) to authenticated;
```

- No `p_tenant_id` parameter, ever (the only exception is `set_active_tenant`,
  which proposes a tenant and is checked against membership).
- Error codes (Spec A §3.5): `P0001` business 422 · `42501` forbidden 403 ·
  `23505` 409 · `TF001` insufficient stock 409 · `TF002` idempotency mismatch
  409 · `40001`/`55P03` retry 503. Do not use `P0002`: it is PL/pgSQL's
  `no_data_found`.
- Pure DB work is an RPC; scheduled pure-SQL work is a `pg_cron` job. Edge
  Functions are for HTTP, PINs and external IO only.
- **PIN-gated RPCs** call `public.consume_pin_pass()` right after
  `idempotency_begin`. The gateway's `requirePin` leaves a single-use pass
  that lasts 60 s, so a call that skips the gateway and goes straight through
  PostgREST still needs the PIN.
- **The one idempotency exception** is `verify_pin`. It returns a
  `pin_check` composite and takes no key: it is a guard, not a queued write,
  and a replayed key must never re-grant a pass.

## Writing an Edge Function

Each function is a self-contained directory. `index.ts` only wires live
dependencies, `handler.ts` exports `create…Handler(deps)`, and tests sit
beside it. Code used by two or more functions goes in `_shared/<domain>/`,
one responsibility per file. Third-party versions appear only in
`_shared/core/deps.ts`.

- **User gateways** use `userGateway(schema, handle, liveUserGatewayDeps())`.
  The pipeline: POST only → JWT (`auth.getClaims`) → tenant keys stripped →
  Zod → handler → §3.5 error mapping. The handler's `rpc` forwards the
  caller's JWT. Never import `serviceRpc` into a user gateway. **The one
  exception (A5, R22):** user gateways use the service role only to sign and
  remove Storage objects (`_shared/storage/`) and for the message router's
  `log_message_delivery` write. Every RPC that does the user's work still runs
  on the caller's JWT.
- **PIN-gated operations** call `requirePin(rpc, body.pin)` (from
  `_shared/auth/pin.ts`) before their RPC.
- **System functions** use `serviceRpc()` and authenticate the caller
  themselves: the Auth hooks `auth-verify-claims`, `send-auth-sms` and `send-auth-email`, and `process-payment` (`charge.success`,
  `refund.processed`) by signature; the cron-invoked `reconcile-funds`
  (`{mode: "sweep" | "refunds"}`) and `web-commission-release` (`{}`;
  Spec D1) by the `x-cron-secret` header, compared in constant time against
  `CRON_SECRET` (`_shared/core/cron.ts`). The sweep takes its batch from
  `claim_unconfirmed_payments(50)`, which stamps `last_swept_at` on every row
  it hands out, so a row whose Verify fails still moves to the back. Paystack
  GETs time out after 15 s; `pg_net` waits up to 120 s for a cron call.
- **Public gateways** (`storefront-catalogue`, `web-checkout`; addendum A1;
  `support-ticket-open`, `support-ticket-read`, `support-ticket-message`;
  addendum A3; `storefront-locations`, `web-order-status`; Spec D1) use
  `publicGateway(route, handle, deps)` from `_shared/core/public-gateway.ts`.
  Callers are anonymous, so their RPCs are granted to `service_role` only and
  resolve the tenant from the agent code, or TEAFAIR when there is none
  (codeless). CORS is limited to `WEB_ALLOWED_ORIGINS`; checkout is gated by
  Turnstile. `web-order-status` answers only for a matching
  `(public_reference, paystack_reference)` pair; any miss is 404.
- **`verify_jwt = false`** is set for every function in `config.toml`; each
  one verifies its caller itself.

```bash
supabase functions serve --env-file supabase/functions/.env     # serve locally
deno test --allow-env supabase/functions/                       # unit tests
supabase status -o env > supabase/.env.test.local               # then:
deno test --allow-net --allow-env --env-file=supabase/.env.test.local \
  --env-file=supabase/functions/.env supabase/functions/_tests/gateway.integration.ts
```

Before the integration run: `supabase db reset` wipes Vault, so run
`select vault.create_secret('<GATEWAY_SECRET>', 'gateway_secret');` (A5, R16),
and put `GATEWAY_SECRET` and the `WHATSAPP_*` test values in
`supabase/functions/.env` (gitignored; see `.env.example`). The SMS-fallback
test reads `notification_logs` as the TEAFAIR ZSM through PostgREST, so RLS is
exercised (R18).

**Secrets:** copy `supabase/.env.example` and
`supabase/functions/.env.example`; `AUTH_HOOK_SECRET` must match in both. Set
`SMS_PROVIDER=log` locally, and `kudisms` (with `KUDISMS_TOKEN` and
`KUDISMS_SENDER_ID`) anywhere real. `web-checkout` also needs
`TURNSTILE_SECRET_KEY`, `WEB_ALLOWED_ORIGINS` and `WEB_CHECKOUT_CALLBACK_URL`
(see `functions/.env.example`). `reconcile-funds` and
`web-commission-release` need `CRON_SECRET` or they fail at boot.
`support-ticket-open` needs `SUPPORT_TICKET_SECRET_KEY` (addendum A3, above).

The integration test runs its own fake Paystack (Initialize, Verify, List
Refunds, Fetch Subaccount, List Settlements, Settlement Transactions) and
Turnstile on host port 54399, reached from the edge runtime at
`host.docker.internal:54399` (`PAYSTACK_API_BASE`, `TURNSTILE_VERIFY_URL`),
plus a fake WhatsApp Cloud API on the same port (`WHATSAPP_API_URL`, with
`WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` and `WHATSAPP_API_VERSION`
set to any values) that records template sends so the test can read codes.
Verification starts use a random `cf-connecting-ip` each, to stay under the
10-per-IP-per-hour limit. If the fake cannot bind (`os error 10013`), Windows has
reserved the port (`netsh interface ipv4 show excludedportrange protocol=tcp`;
on 2026-10-25 the range was 54325-54524): set `INTEGRATION_FAKE_PORT` to a free
port and use that port in every `host.docker.internal:54399` URL of the functions env. The only Vault secret it needs is `gateway_secret`;
it calls the cron functions directly.

### Cron jobs (Spec D1 §10)

`pg_cron` calls `reconcile-funds` (sweep every 5 min, refunds 05:00 UTC) and
`web-commission-release` (06:00 UTC) through `pg_net`
(`public.invoke_system_function`). It reads the base URL and the shared secret
from Vault; the migrations hold no secret values. Create both once **per
environment** (SQL editor or `psql`):

```sql
select vault.create_secret('<functions base url>', 'functions_base_url');
select vault.create_secret('<secret>', 'cron_secret');
```

Locally the URL is `http://host.docker.internal:54321/functions/v1`, and the
secret is the `CRON_SECRET` in `functions/.env`. On the remote it is
`https://<project-ref>.supabase.co/functions/v1`, and the secret must equal the
function secret `CRON_SECRET`. Without them each job logs
`functions_base_url or cron_secret is missing from Vault` and posts nothing.
`supabase db reset` wipes Vault, so recreate them after a reset if you want
the jobs to run locally.

A5 adds the `storage-purge` job (every 15 min, same two secrets), the
pure-SQL jobs `cleanup-upload-slots` (00:45) and
`cleanup-web-phone-verifications` (00:50), and the Vault
secret `gateway_secret` (see Addendum A5); create `gateway_secret` the same way,
once per environment and after every `db reset`.

**Paystack test mode (D1 plan, fact F6).** The Paystack account is in test
mode. Transactions, Verify and refunds behave as they do live, but test mode
is not expected to produce real subaccount settlements. The commission release
path (List Settlements, Settlement Transactions) has therefore been proven only
against the integration fake. Its first real check comes after go-live:
watch the first `web-commission-release` runs and the `release_commission`
audit rows (`share_verified`).

## Testing

```bash
supabase test db                 # all files; look for "Result: PASS"
psql -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
     -qAt -f supabase/tests/database/003_rls.test.sql   # one file, every assertion
```

Act as a user the way PostgREST does: `set_config('role','authenticated',true)`
plus `request.jwt.claims` JSON with `sub` and `app_metadata.active_tenant_id`.
Test helpers created with `create function pg_temp.*` need an explicit
`grant execute … to authenticated`. Write the test first and watch it fail.

If `supabase start` / `db reset` fails with `LegacyDbSetupError` and a realtime
`nxdomain` message, Docker's internal DNS hiccuped; restart Docker Desktop and
retry. `supabase migration up` applies new migrations without a full reset.

If it fails with `HealthCheckTimeoutError … unhealthy`, the host is CPU-starved:
the CLI's 2s probes are not configurable. `[analytics]` is off in
`config.toml` for this reason; keep it off, and stop other heavy containers
before starting.
