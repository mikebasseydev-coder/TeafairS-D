# Web chat and ticketing — Addendum A3

**Date:** 2026-10-21
**Status:** written spec approved 2026-10-21; plan `docs/superpowers/plans/2026-10-21-addendum-a3-chat-and-ticketing.md`
**Addendum A3 to Spec A** ("Spec E" stays reserved for the AI moat).
**Builds on:** Spec A (`2026-10-05-multi-tenant-rtm-foundation-design.md`),
addenda A1 (web storefront) and A2 (buyer contact privacy), Spec D1 (web money
loop). Where this document touches D1's settlement functions (§9) it amends
them.

## 1. Purpose

A buyer on `teafairweb.com` who has a problem with an order, or a question
before buying, has no way to reach Teafair today. Staff have no queue, and the
payment exceptions D1 detects (`PAID_AFTER_CANCEL`, `SPLIT_MISMATCH`, …) only
produce notification rows that nobody works as cases.

A3 adds a native support module, backend only:

1. a buyer opens a ticket from the website — linked to their order, or a
   pre-purchase question tied to a delivery area — and chats with the
   accountable staff member;
2. staff (ZSM, TM) work a tenant- and territory-scoped queue with live
   updates;
3. the payment system raises its own urgent tickets when money and order
   state disagree.

No third-party help desk (Zendesk, Intercom). No client code: the website and
the app stay on hold. Attachments are out of scope (§12).

## 2. Decisions

These were decided in conversation on 2026-10-21.

1. **Buyers poll, staff get Realtime.** The buyer's page polls a public
   gateway every 3–5 s. No Supabase Realtime, publication or database access
   is exposed to anonymous visitors. Signed-in staff subscribe to Realtime on
   the support tables; RLS filters what they receive.
2. **A ticket secret, not a phone number, proves ownership.** Opening a
   ticket returns a reference `TK-XXXXXX` and a high-entropy secret. The
   database stores only `sha256(secret)`. Every buyer read and post needs
   both; any mismatch returns the same `404 NOT_FOUND` as a missing ticket.
3. **No personal data on the ticket header.** `support_tickets` holds
   structure only. Buyer contact details live in `support_ticket_contacts`.
4. **Contacts and message bodies are restricted** to the ticket's handlers:
   the tenant's ZSMs, the TM of the ticket's territory (the A2 rule for
   `order_contacts`), **and the ticket's `accountable_id` and `assigned_to`**.
   The last two let a fallback handler — `web_default_agent_id` on an
   unrouted pre-purchase ticket, who may not be a TM — read and answer the
   ticket they are notified about. Buyers type phone numbers and addresses
   into chat, so message bodies get the same protection as contacts. Other
   tenant members can see that a ticket exists, its status and its order,
   not what was said.
   ORDER tickets follow A2: handler access via accountable/assigned applies
   to PRE_PURCHASE and SYSTEM tickets only (user decision 2026-10-21).
5. **Redaction on request.** A ZSM-only RPC blanks a ticket's contact record
   **and replaces every buyer (`CUSTOMER`) message body with `[redacted]`**,
   keeping staff replies, SYSTEM messages and the ticket's structure. It
   audits a redacted summary (`TICKET_DATA_REDACTED`). Audit rows are never
   edited.
6. **Routing comes from trusted rows.** An order-linked ticket takes its
   tenant, territory and accountable person from the `orders` row. A
   pre-purchase ticket takes State/LGA, goes to `web_codeless_tenant()`
   (TEAFAIR), and routes through D1's routing (§5). Nothing the buyer sends
   picks a tenant (Spec A decision 4).
7. **Staff write only through RPCs.** `authenticated` keeps `SELECT` only.
   Claim, reply, status and priority changes, and redaction are `SECURITY
   DEFINER` RPCs with an idempotency key and an audit row (source `USER`).
8. **Project schema rules apply** (Spec A §9): workflow statuses are `text` +
   `CHECK`, not enums; foreign keys `ON DELETE RESTRICT`; tenant rows
   reference each other through composite `(tenant_id, x)` keys; people are
   `profiles(id)`.
9. **Text only in v1.** No attachments.

## 3. Schema

New domain `support`: migrations `…_support_*.sql`, pgTAP
`019_support_tickets.test.sql` onward, Edge Function code in
`_shared/support/` when shared.

### 3.1 `support_tickets` (tenant-owned, no personal data)

```
support_tickets(
  id uuid PK, tenant_id → tenants,
  public_reference text UNIQUE CHECK (~ '^TK-[0-9A-HJKMNP-TV-Z]{6}$'),
  kind text CHECK in ('ORDER','PRE_PURCHASE','SYSTEM'),
  category text CHECK in ('PAYMENT','DELIVERY','ORDER_CHANGE','PRODUCT','OTHER','SYSTEM'),
  order_id uuid?, territory_id uuid?, accountable_id → profiles?,
  assigned_to → profiles?,
  status text CHECK in ('OPEN','IN_PROGRESS','RESOLVED','CLOSED') default 'OPEN',
  priority text CHECK in ('LOW','MEDIUM','HIGH','URGENT') default 'MEDIUM',
  system_key text? UNIQUE,           -- at-most-once key for SYSTEM tickets
  last_message_at timestamptz, resolved_at timestamptz?,
  created_at, updated_at,
  UNIQUE (tenant_id, id),
  FK (tenant_id, order_id) → orders, FK (tenant_id, territory_id) → territories,
  CHECK (kind <> 'ORDER' or order_id is not null),
  CHECK ((kind = 'SYSTEM') = (system_key is not null)),
  CHECK (status <> 'RESOLVED' or resolved_at is not null)
)
```

`public_reference` uses the same generator as `TF-` order references (6
Crockford base-32 characters, retry on collision); the builder extracts it into
a shared internal function. It is not a secret; the secret is.

The secret hash lives in its own table, `support_ticket_secrets(ticket_id PK,
tenant_id, secret_hash text NOT NULL)`, with RLS on, no policy and no grant to
any API role. That keeps it out of `support_tickets` entirely, so the header
can be granted whole and published to Realtime without column-grant caveats.
Every non-SYSTEM ticket has exactly one secrets row, written in the opening
transaction. *(Builder's call, recorded.)*

There is no `subject` column: a subject is buyer text, so the first message
carries it. `category` is a fixed list the buyer picks.

RLS `FOR SELECT`: ACTIVE members of the tenant (`my_tenant_ids()`).

### 3.2 `support_ticket_contacts` (restricted)

```
support_ticket_contacts(
  ticket_id uuid PK, tenant_id, territory_id uuid?,
  customer_name text?, customer_phone text? CHECK E.164,
  customer_email text? CHECK lower,
  redacted_at timestamptz?,
  created_at, updated_at,
  FK (tenant_id, ticket_id) → support_tickets,
  FK (tenant_id, territory_id) → territories
)
```

RLS `FOR SELECT` (the handler rule, decision 4): the tenant's ZSMs, or a TM
whose territory is `territory_id` (`my_tm_territory_ids()`), or the ticket's
`accountable_id` or `assigned_to` — through a `SECURITY DEFINER` helper
`my_support_ticket_ids()` that returns the ids of tickets where the caller is
either, used as `ticket_id in (select public.my_support_ticket_ids())`, never
a per-row subquery (Spec A §9). `territory_id` is a copy of the
ticket's, written in the same statement (the A2 pattern). SYSTEM tickets have
no contact row.

### 3.3 `support_messages` (restricted)

```
support_messages(
  id uuid PK, tenant_id, ticket_id,
  sender_type text CHECK in ('CUSTOMER','STAFF','SYSTEM'),
  sender_id → profiles?,             -- set for STAFF only
  territory_id uuid?,                -- copy of the ticket's, for RLS
  body text NOT NULL CHECK (length(btrim(body)) between 1 and 2000),
  created_at,
  FK (tenant_id, ticket_id) → support_tickets,
  CHECK ((sender_type = 'STAFF') = (sender_id is not null))
)
```

Append-only, with one exception: redaction (§6) overwrites `CUSTOMER`
bodies with `[redacted]` and sets `redacted_at timestamptz?`. RLS as for
contacts. Index
`(ticket_id, created_at)`.

If a ticket's territory changes (re-routing, §6), the RPC that changes it
updates the copies on contacts and messages in the same transaction.

### 3.4 Realtime

`support_tickets` and `support_messages` are added to the
`supabase_realtime` publication. Realtime applies the `FOR SELECT` policies
per subscriber, so a TM receives only their territory's messages and anon
receives nothing. No `anon` grant is added to either table.

## 4. Buyer flows (public gateways)

All use `publicGateway` (A1 §5.1): CORS to `WEB_ALLOWED_ORIGINS`, Zod,
service-role RPCs, tenant keys stripped.

### 4.1 `support-ticket-open` — `POST`

Body: `{ idempotency_key, turnstile_token, category, message,
customer: { name, phone, email? }, order?: { public_reference,
paystack_reference }, location?: { lga_id } }`.

- Turnstile and phone normalisation exactly as `web-checkout`.
- Exactly one of `order` or `location`.
- **`order`** must be the same pair `web-order-status` accepts (D1 §8.4); a
  mismatch is `404 NOT_FOUND`. The pair lookup is extracted from
  `web_order_status` into an internal function
  `web_find_order_by_pair(p_public_reference, p_paystack_reference) returns
  orders` (case-insensitive on the Paystack reference, any order status), and
  `web_order_status` is rewritten to call it. D1 has not been deployed, so
  this changes no live contract. *(Builder's call.)* This keeps a stranger who knows a `TF-`
  reference from opening a ticket on someone else's order and being told
  about it. Kind `ORDER`.
- **`location`** is a pre-purchase ticket. Kind `PRE_PURCHASE`, tenant
  `web_codeless_tenant()`.
- The gateway derives the secret as HMAC-SHA256(`SUPPORT_TICKET_SECRET_KEY`,
  idempotency key), base64url (43 characters), and passes only its sha256 to
  the RPC. The reply is
  `{ public_reference, secret, status }`; the secret is shown once and never
  stored in plain text.
- Throttle: at most 3 tickets per phone per hour, and at most 3 open
  (`OPEN` or `IN_PROGRESS`) buyer (`ORDER`) tickets per order; SYSTEM tickets
  do not count. Throttles count existing rows
  (contacts by phone and `created_at`, tickets by order and status), checked
  after the idempotency replay so a replay never counts. A redacted ticket no
  longer counts toward its phone's limit; that is accepted.
  *(Builder's call.)*

RPC `open_support_ticket(p_idempotency_key, p_kind, p_category, p_message,
p_customer, p_order_public_reference?, p_order_paystack_reference?, p_lga_id?,
p_secret_hash)` — `service_role` only. The secret is deterministic per
idempotency key, so a retry (say, after a lost reply) re-derives the same
secret and the replayed reply still pairs with the stored hash.

### 4.2 `support-ticket-read` — `POST`

Body `{ public_reference, secret }` → works in every status, `CLOSED`
included → `{ public_reference, status, category,
order_public_reference?, messages: [{ sender: 'you'|'teafair', body,
created_at }] }`. Staff names and ids are not exposed. `Cache-Control:
no-store`. Polled every 3–5 s by the page. RPC `read_support_ticket` compares
`sha256(secret)` in the database with a constant-time check.

### 4.3 `support-ticket-message` — `POST`

Body `{ idempotency_key, public_reference, secret, message }`. No Turnstile
on every message; instead at most 30 buyer messages per ticket per hour. Throttle counts `CUSTOMER` messages of the ticket in the last hour.
Order of checks: the pair first (any miss is 404), then closed, then the
throttle. A `CLOSED` ticket refuses with `This conversation is closed. Open a new ticket
if you still need help.`; a `RESOLVED` ticket reopens to `OPEN` and clears `resolved_at`. RPC
`add_ticket_message` (`service_role`).

## 5. Routing

At open time, stamped on the ticket and copied to contacts:

- **ORDER:** `tenant_id`, `territory_id` and `accountable_id` are the order's
  `tenant_id`, `territory_id` and `teafair_agent_id`.
- **PRE_PURCHASE:** `web_route_try(web_codeless_tenant(), null, p_lga_id)`.
  When it yields a territory and an accountable person, use them. Otherwise
  `territory_id` is null and `accountable_id` is
  `tenant_settings.web_default_agent_id` (if an ACTIVE member) else null —
  the ticket sits in the ZSM queue. A pre-purchase ticket is never refused
  for coverage: a question about delivering to an uncovered area is exactly
  what support should see.

Notification on open and on every buyer message: kind
`SUPPORT_TICKET_ACTIVITY`, to `assigned_to`, else `accountable_id`, else every
ZSM. Payload `{ ticket_id, public_reference }` — no message text.

## 6. Staff RPCs (`authenticated`)

Standard write contract. Who may act: the tenant's ZSMs on any ticket; a TM
on tickets whose `territory_id` is theirs; and the ticket's `accountable_id`
or `assigned_to` (decision 4; PRE_PURCHASE and SYSTEM tickets only) for
claim, reply, status and priority. Assign
and redact stay ZSM-only. Anyone else is `42501`.

| RPC | Does |
|---|---|
| `claim_ticket(p_idempotency_key, p_ticket_id)` | `assigned_to = caller`; `OPEN → IN_PROGRESS`. A TM cannot take a ticket another person holds; a ZSM can (takeover, audited) |
| `reply_ticket(p_idempotency_key, p_ticket_id, p_body)` | STAFF message; claims if unassigned; `OPEN → IN_PROGRESS`; `RESOLVED → IN_PROGRESS` (clears `resolved_at`) |
| `update_ticket_status(p_idempotency_key, p_ticket_id, p_status)` | `IN_PROGRESS → RESOLVED`, `RESOLVED → CLOSED`, any non-closed → `CLOSED`; `CLOSED` is final |
| `set_ticket_priority(p_idempotency_key, p_ticket_id, p_priority)` | |
| `assign_ticket(p_idempotency_key, p_ticket_id, p_territory_id)` | ZSM only, **PRE_PURCHASE tickets only**: re-route to a territory (sets `territory_id`; `accountable_id` = the territory's TM, else the zone's ZSM, else `web_default_agent_id`, each only if ACTIVE — D1's chain; clears `assigned_to`; updates the copies). ORDER and SYSTEM tickets follow their order's territory and cannot be re-routed, so ticket visibility never diverges from the order's contact visibility. *(Builder's call.)* |
| `redact_ticket_customer_data(p_idempotency_key, p_ticket_id)` | ZSM only: nulls name, phone, email and sets `redacted_at` on the contact row; replaces every `CUSTOMER` message body with `[redacted]` and sets its `redacted_at`; audit `TICKET_DATA_REDACTED` with `{ticket_id, had_email, messages_redacted}` only. Repeating it is a no-op beyond the idempotency replay |

Audit rows never carry message bodies or contact details.

`RESOLVED` tickets close automatically after 7 days (a `pg_cron` pure-SQL
job, audit source `CRON`).

## 7. Staff reads

Through PostgREST under RLS: the queue (`support_tickets`), a ticket's
messages and contact (restricted tables), and Realtime on both. No extra RPC
is needed for reads.

## 8. Message delivery rules

- Messages are ordered by `created_at`, then `id`.
- The 2000 limit counts characters, after trimming, in both Zod and the
  CHECK.
- Every message write updates `support_tickets.last_message_at` (queue
  order) in the same transaction.
- The buyer read returns all messages of the ticket; v1 tickets are short
  enough not to page. (Builder may add `since` paging if a test shows a need.)

## 9. System tickets (amends D1)

`raise_system_ticket(p_tenant_id, p_kind_key text, p_order_id?, p_body
text, p_priority)` — internal, not granted to any role. Called **inside** the
D1 transaction that detects the case, next to its existing notification:

| D1 event | Where | Priority |
|---|---|---|
| `PAID_AFTER_CANCEL` | `settle_paystack_payment` | URGENT |
| `LATE_SUCCESS` | `settle_paystack_payment` | HIGH |
| commission → `DISPUTED` (any reason) | settle, refund, release, expire | HIGH |

- Every D1 case has an order (`commission_records.order_id` is NOT NULL), so
  `p_order_id` is required; tenant and `territory_id` come from that order
  and `order_id` is set on the SYSTEM ticket.
- `system_key` makes it at most once: `PAID_AFTER_CANCEL:<payment_id>`,
  `LATE_SUCCESS:<payment_id>`, `COMMISSION_DISPUTED:<commission_id>` (one
  ticket per commission, whatever the first reason; a later dispute reason on
  the same commission adds a SYSTEM message to that ticket instead).
  *(Builder's call.)*
- `kind = 'SYSTEM'`, no secret, no contact row, `accountable_id` null — the
  ZSM queue.
- The body is a SYSTEM message built from ids, amounts and the audit
  operation — never from `p_verified` or contact data.
- D1's existing notifications stay; the ticket is the case that gets worked.

## 10. Errors and limits

| Case | Response |
|---|---|
| wrong reference/secret pair, wrong order pair | `404 NOT_FOUND` |
| throttle exceeded | `422` `Too many messages. Please wait a few minutes.` |
| closed ticket | `422` (copy in §4.3) |
| message empty or over 2000 characters | `400 VALIDATION_FAILED` |
| bot check failed | `403 BOT_CHECK_FAILED` (as checkout) |

## 11. Testing

**pgTAP** `019_support_tickets.test.sql` (and further files if it grows):

- schema: CHECKs, the SYSTEM/secret/system_key pairing, composite FKs,
  `secret_hash` not readable by `authenticated`;
- RLS isolation: other tenant sees nothing; a tenant DSA sees the header but
  no contacts or messages; the territory TM sees their tickets' messages and
  not another territory's; ZSM sees all; a non-TM `web_default_agent_id`
  sees and can reply to the unrouted ticket routed to them and nothing
  else; anon sees nothing;
- open: ORDER from a valid pair, refused on a mismatched pair; PRE_PURCHASE
  routed, and unroutable to default agent / ZSM queue; throttles; idempotent
  replay ignores a new secret hash;
- delivery: buyer message with the right secret, refused with a wrong one;
  `last_message_at` bumped; RESOLVED reopens; CLOSED refuses; notifications
  carry no text;
- staff RPCs: claim, reply (auto-claim), status transitions, priority,
  assign (copies updated), redact (contacts blanked, buyer bodies become
  `[redacted]`, staff replies untouched, audit summary only);
  role refusals;
- system tickets: each D1 event raises one ticket; replay raises none;
- grants: `anon` and `authenticated` cannot execute any `service_role` RPC.

**Deno unit tests** for the three gateways (Turnstile, pair mismatch → 404,
secret never echoed after open, throttle mapping).

**Integration:** open → staff reply via PostgREST → buyer read shows it →
buyer message → resolve → close.

## 12. Not in A3

- Attachments and file storage.
- The website chat widget and the staff app screens (Spec B hold).
- Email or SMS notifications to buyers (they poll; no outbound channel).
  *Email lifted by addendum A7 (2026-11-05): buyers get an email with the
  reference and a pre-filled ticket link, never the secret. SMS stays out.*
- Support for POS (`POS_AGENT`) orders, which have no Paystack reference to
  pair with — the buyer uses a pre-purchase ticket until D2.
- SLAs, auto-assignment rotas, canned replies, satisfaction ratings.
- Retention schedules; redaction is on request only.
