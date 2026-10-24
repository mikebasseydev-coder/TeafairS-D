# Addendum A5 to Spec A — Food refund policy, support photos, web-order fulfilment, WhatsApp-first messaging

**Status:** approved 2026-10-23; plan `docs/superpowers/plans/2026-10-23-addendum-a5-refund-fulfillment.md`.
**Authority:** this addendum amends Spec A. Spec A §9 applies in full, and so do A2 (buyer contact privacy) and A3 (support tickets).
**Builds on:** D1, A3 and A4. All of them are merged into local `main`, and A5's branch `docs/addendum-a5-refund-fulfillment` is cut from there.
**Scope:** backend only, meaning migrations, RPCs, Edge Functions and tests. The policy page and the checkout checkbox UI wait for Spec B, because frontend work is on hold.

## 1. Intent

Teafair sells **only food and tea** today. Electronics, GSM and airtime are switched off; Teafair holds an NCC licence through one of its companies, which matters for airtime later. A5 does four things:
1. It gives the web storefront a refund policy that Paystack chargebacks can be defended against.
2. It lets buyers prove transit damage with photos inside the support chat.
3. It records when a web order left the warehouse and when it reached the buyer.
4. It sends buyer messages over WhatsApp first and falls back to SMS.

**Goals**
- A refund policy stored in the database with versions. The first version is `v2.0-food`.
- Consent is required on every web order and recorded, with the buyer's IP kept A2-private.
- A product category on every product. Only categories covered by an active policy can be sold.
- Photo attachments on support-ticket messages, from buyers and staff.
- `PAID → IN_TRANSIT → DELIVERED` for web orders. Delivery is proven by a 4-digit PIN, with an optional photo at the door.
- A ZSM-only dispute evidence bundle per order.
- One messaging router for every buyer-facing message: WhatsApp first, KudiSMS on failure or after 15 seconds.

**Non-goals**
- Electronics and telecom terms: serial or IMEI capture, RMA inspection, POS de-registration. They are written when those categories launch, as a new policy version.
- Digital airtime top-up. That is Spec D2.
- Refund execution. Refunds still happen in Paystack and arrive through D1's `apply_paystack_refund`.
- Field-order fulfilment (Spec C).
- Photo attachments in staff chat (A4).
- Image processing, virus scanning and thumbnails.
- WhatsApp for staff in-app notifications.

**Anti-goals.** Any of these would make A5 a failure even if everything else worked:
- A buyer's IP, phone or photo readable by someone A2 or A3 would not allow.
- A public Storage URL.
- A delivery PIN that can be guessed by retrying.
- An OTP or PIN that appears in a log.
- A public "send a message to any number" endpoint.

## 2. Decisions locked by the user (2026-10-23)

1. **Categories.** Only food and tea are on sale. `FOOD` is live, while `ELECTRONICS` and `TELECOM` are defined but not sellable.
2. **The policy lives in Postgres.** The first version is `v2.0-food`. The web checkout requires consent, and the consent record must satisfy Paystack's chargeback evidence standard.
3. **Photos.** Buyers and staff may attach photos inside the support chat: up to 3 per message, JPEG, PNG or WebP, at most 5 MB each. They live in a private Storage bucket and follow the existing ticket access rules.
4. **Fulfilment.** Every web order goes `PAID → IN_TRANSIT → DELIVERED`.
   - Dispatch generates a 4-digit delivery PIN and sends it to the buyer.
   - Delivery requires the PIN and accepts an optional photo at the door.
   - Delivery starts a 24-hour damage-claim window.
5. **Messaging.** WhatsApp is the primary channel, and KudiSMS is the fallback when WhatsApp fails or takes longer than 15 seconds. The channel used is logged.
6. **WhatsApp verification at checkout** (decided 2026-10-23, "better sure than being shut down"). Before any web order can be placed, the buyer proves that their phone number is on WhatsApp and is theirs by entering a code sent to it over WhatsApp. The refund policy makes a WhatsApp number a condition of purchase (§3.5).
7. **Two kinds of delivery** (decided 2026-10-23). Field staff deliver in some places and outside couriers in others. Field staff enter the buyer's code in the app. For a courier delivery, the courier reports the code and the fulfilment warehouse's manager enters it (§5.2).

## 3. Refund policy and consent

### 3.1 `refund_policies` (platform table, not tenant-owned)

The columns are:
- `id uuid pk`;
- `version_tag text unique`, checked against `^v[0-9]+\.[0-9]+-[a-z0-9-]+$`;
- `title text not null`;
- `content text not null`, holding the policy as Markdown;
- `categories text[] not null`, the product categories the version covers, for example `{FOOD}`;
- `is_active boolean not null default false`;
- `published_at timestamptz`;
- `created_at`.

Rules:
- Exactly one row may be active. A partial unique index on `(is_active) where is_active` enforces it.
- Versions are written by migration or seed only. There is no RPC for them, because the platform has no policy-editing role.
- The migration seeds `v2.0-food` as active with `{FOOD}`. It covers the general terms (Paystack refunds to the original source within 5–7 business days of approval, and contacting support before opening a bank dispute) and the food terms (opened items are non-refundable, and transit damage must be reported within 24 hours of delivery with photos).
- **The seeded wording is a placeholder that must be reviewed by counsel before go-live** *(builder's call)*.
- Reads: there is no `anon` grant. The storefront reads the active policy through the public gateway `storefront-refund-policy`, a GET whose response has `cache-control: public, max-age=300`. It calls the service-role RPC `web_active_refund_policy()`, which returns `{version_tag, title, content, categories, published_at}`.

### 3.2 Product categories

- Add `central_products.sale_category text not null default 'FOOD' check (sale_category in ('FOOD','ELECTRONICS','TELECOM'))`.
- The existing free-text `category` stays as the merchandising label.
- A category is **sellable** when the active policy's `categories` contains it.
- `place_web_order` refuses any line whose product is not sellable, with P0001 `This product is not available to order yet.`
- The storefront catalogue hides unsellable products.

### 3.3 Consent on web orders

- `orders` gains:
  - `policy_version_tag text references refund_policies (version_tag) on delete restrict`;
  - `policy_accepted_at timestamptz`.
- A CHECK requires both on ONLINE orders created after A5. Older ONLINE rows are grandfathered by a `created_at` cut-off constant.
- `order_contacts` gains `consent_ip inet`. Like the rest of the contact data, it is readable only by the ZSM and the order's TM.
- `place_web_order` gains `p_policy_version_tag text` and `p_client_ip inet`.
  - A tag that does not match the active policy gives P0001 `The refund policy has changed. Please review it and try again.`
  - The function writes the consent columns and `consent_ip`.
  - The audit after-image carries the tag and the time, but **not** the IP.
- **The function is redefined, not overloaded.** The old signature is dropped and `web-checkout` is updated in the same change *(builder's call: the function is large, but an overload would leave a consent-free path)*.
- `web-checkout` requires the body fields `policy_version_tag` and `accept_refund_policy: true`, the literal value. A missing or false value gives 400 `You must accept the refund policy to place an order.` The client IP comes from the same header logic used for Turnstile.

### 3.5 WhatsApp phone verification at checkout

**Policy clause.** `v2.0-food` states that the buyer must give a WhatsApp number they control. Order updates and the delivery code are sent there. An order that cannot be completed because the number given was not reachable on WhatsApp is not grounds for a refund dispute.

**Table.** `web_phone_verifications` is a platform table with RLS on, no policy and no grant. Its columns are:
- `id`;
- `phone` (E.164);
- `code_hash` (bcrypt);
- `expires_at`, set to now plus 10 minutes;
- `failed_attempts`;
- `verified_at`;
- `token_hash` (the sha256 hex of a 32-byte token);
- `token_expires_at`, set to `verified_at` plus 30 minutes;
- `consumed_at`;
- `created_at`.

**Gateways and RPCs.** Both gateways are public, and every RPC below is service_role only.
- **`checkout-phone-verify-start`** (POST) takes `{turnstile_token, phone}`.
  - It checks Turnstile and normalises the phone.
  - It calls `start_web_phone_verification(p_phone, p_code)`. The limits are 3 starts per phone per hour and 10 per IP per hour.
  - It sends the code through the WhatsApp authentication template, using **WhatsApp only, with no SMS fallback**. An SMS would prove nothing about WhatsApp.
  - If WhatsApp fails, it returns 503 `We couldn't reach WhatsApp. Please try again in a few minutes.` *(builder's call: during a WhatsApp outage, checkout waits rather than taking an unverified number)*.
  - On success it returns `{verification_id, expires_at}`.
- **`checkout-phone-verify-confirm`** (POST) takes `{verification_id, code}`.
  - It calls `confirm_web_phone_verification(p_id, p_code)`.
  - Five wrong codes end that verification, and the buyer starts again.
  - On success it returns `{verification_token}`. The token is shown once and only its hash is stored.
- **Checkout.** `web-checkout` requires `phone_verification_token`, and `place_web_order` gains `p_phone_verification_token text`.
  - The token's hash must match an unconsumed, unexpired row whose `phone` equals the order's customer phone. Otherwise the call fails with P0001 `Please verify your WhatsApp number again.`
  - The order consumes the token.
  - `order_contacts` gains `phone_verified_at timestamptz` and `phone_verified_channel text check (… = 'WHATSAPP')`.
- **Evidence.** The dispute evidence bundle (§6) includes `phone_verified_at` and the channel.

### 3.6 Consent assertion and replay

- `place_web_order` also takes `p_accepted_refund_policy boolean`. A value other than true raises P0001. The database therefore records that the buyer asserted consent; it does not just infer it from the gateway.
- A replay with the same idempotency key returns the original order and its original consent, even if the active policy has changed since. The consent was valid when it was given.

### 3.4 Category disclaimers

The catalogue response carries `refund_note` per sellable category, taken from the active policy. For FOOD it reads: `Opened food items can't be refunded. Report transit damage within 24 hours of delivery with photos.` Telecom and electronics notes arrive with their policy versions. The client shows them in the checkout summary.

## 4. Support photo attachments (A3 extension)

### 4.1 Storage

- A private bucket named `support-attachments` is created in the migration with `public = false`, `file_size_limit = 5242880` and allowed MIME types `image/jpeg`, `image/png` and `image/webp`.
- Paths take the form `tickets/<ticket_id>/<attachment_id>.<ext>`.
- **Nobody uploads with a raw client write** *(builder's call, keeping Spec A §9 "no direct client writes")*. Instead:
  1. An RPC authorises the upload and registers a pending attachment.
  2. The gateway creates a **signed upload URL** valid for 2 hours (Storage fixes the lifetime of upload URLs; each allows a single upload because there is no upsert, and the DB slot decides what is accepted). Download URLs last 10 minutes.
  3. The client uploads the file.
  4. Posting the message claims the attachment.
- `storage.objects` gets one FOR SELECT policy, for authenticated staff downloads. It applies when the bucket is `support-attachments` and the ticket id parsed from the path is in `my_support_message_ticket_ids()`. That new helper returns exactly the tickets whose messages the caller may read, mirroring the `support_messages` policy, including A2-strict ORDER tickets and linked history. There is no insert, update or delete policy for clients.

### 4.2 Data

Attachments live in `upload_slots` (§5.4), which is shared with delivery photos. For support tickets (`purpose = 'SUPPORT_TICKET'`) the columns are:
- `id`, `tenant_id`, `purpose`, `ticket_id`;
- `message_id`, which is null while pending;
- `storage_path text unique`;
- `mime_type`;
- `size_bytes`;
- `uploaded_by_type` (CUSTOMER or STAFF);
- `uploaded_by uuid`, which is null for a customer;
- `created_at`;
- `claimed_at`.

Composite FKs link it to the ticket and the message. RLS has SELECT only, `ticket_id in (select my_support_message_ticket_ids())`. Pending attachments older than 24 hours are deleted, together with their objects, by a nightly cron job *(builder's call)*.

### 4.3 Flows

- **Buyer:**
  - `support-ticket-attachment` (public, POST) takes `{public_reference, secret, file_name, mime_type, size_bytes}`.
  - The RPC `request_ticket_attachment(p_idempotency_key, p_public_reference, p_secret, p_mime_type, p_size_bytes)` checks the secret and the limits, refuses CLOSED tickets, and rate-limits to 10 pending attachments per ticket per hour.
  - It returns `{attachment_id, storage_path}`, and the gateway adds `upload_url`.
  - `add_ticket_message` and `open_support_ticket` gain `p_attachment_ids uuid[] default '{}'`. Attaching more than 3 IDs, an ID from another ticket, or an object not yet uploaded raises P0001.
  - The RPC checks that the object exists in `storage.objects` and that its stored size and MIME type match the request.
- **Staff:**
  - `support-staff-attachment` (user gateway, JWT) calls `request_staff_ticket_attachment(p_idempotency_key, p_ticket_id, p_mime_type, p_size_bytes)` with the caller's JWT. It passes the same `support_lock_ticket` permission check as replying.
  - `reply_ticket` gains `p_attachment_ids uuid[] default '{}'`.
- **Reading:**
  - `read_support_ticket` returns `attachments: [{attachment_id, mime_type, url}]` per message. The `support-ticket-read` gateway signs those URLs for 10 minutes.
  - Staff read through Storage RLS.
  - Redaction (A3 §6) deletes a ticket's CUSTOMER attachments, both the rows and the objects.
- **Audit:** the after-images carry the attachment count only, never paths or URLs.

## 5. Web-order fulfilment

### 5.1 Data

`order_fulfilments` has these columns:
- `order_id pk`, plus `tenant_id`, with a composite FK to `orders`;
- `dispatched_at`, `dispatched_by`, and `tracking_reference text` (optional courier reference);
- `delivery_pin_hash text`, a bcrypt hash made with `extensions.crypt`;
- `pin_failed_attempts int default 0`, `pin_locked_until timestamptz`, `pin_sent_at`;
- `delivered_at`, `delivered_by`;
- `delivery_photo_path text`;
- `damage_claim_deadline timestamptz`, set to `delivered_at + interval '24 hours'`;
- `created_at`, `updated_at`.

RLS is SELECT only, granted to the ZSM, the order's TM and the fulfilment warehouse's manager. `delivery_pin_hash` is never exposed: a column-level revoke ensures authenticated callers cannot select it.

### 5.2 Who acts *(builder's call: there is no WAREHOUSE_MANAGER role, and warehouses carry `manager_id`)*

- **Dispatch:** the ACTIVE member who is the `manager_id` of the order's `fulfilment_warehouse_id`, or any ZSM of the tenant.
- **Delivery by field staff:** an ACTIVE TM, DSM or DSA whose `territory_id` is the order's `territory_id`, or any ZSM of the tenant.
- **Delivery by courier (user decision 7):** the fulfilment warehouse's manager enters the code the courier reports. `mark_order_delivered` records `delivered_via` as `FIELD_STAFF` or `COURIER`, according to the caller's path.
- **Orders with no territory** can be delivered only through the courier path or by a ZSM.
- **Photo read access:** the ZSM, the order's TM, the warehouse manager, and whoever uploaded the photo.

**PIN protection (builder's call, answering the reviewer):**
- Five wrong codes lock the PIN for 30 minutes.
- Ten wrong codes over the order's lifetime lock it until a ZSM resends a new code. A resend by anyone else neither clears a lock nor resets the lifetime count.
- A resend counts toward the 3-per-day limit only when the message was sent.
- If dispatch commits but both channels fail to send, the order stays IN_TRANSIT with `delivery_code_sent: false`, and a resend is the recovery.
- `mark_order_delivered` claims the photo's upload slot only on a correct PIN, after checking that the object exists and that its size and type match. After a wrong PIN, the slot stays pending and reusable.

### 5.3 RPCs and gateways

- **`mark_order_dispatched(p_idempotency_key, p_order_id, p_tracking_reference text, p_pin text) returns jsonb`**
  - It requires an ONLINE order in PAID status, a 4-digit PIN, and the dispatch rule.
  - It sets the order to IN_TRANSIT, writes `order_fulfilments`, and stores the PIN as a hash.
  - It returns `{order_id, status, buyer_phone}` to the **gateway only**. The phone comes from `order_contacts` and is used to send the PIN; it is never returned to the client.
  - It is called through the `order-dispatch` user gateway. That gateway generates the PIN, which, like OTPs, is never logged. It sends `Your Teafair order <public_reference> is on its way. Give this delivery code to the rider: <PIN>.` through the router, and returns `{order_id, status, delivery_code_sent: true|false, channel}`.
  - A replay sends nothing.
- **`resend_delivery_pin(p_idempotency_key, p_order_id, p_pin)`**
  - It follows the same rules as dispatch, for IN_TRANSIT orders only.
  - It sets a new hash and resets the failed-attempt count.
  - It is limited to 3 resends per order per day, through the `order-delivery-pin` gateway.
- **`mark_order_delivered(p_idempotency_key, p_order_id, p_pin text, p_photo_attachment_id uuid default null) returns jsonb`**
  - It requires an IN_TRANSIT order and the delivery rule.
  - A wrong PIN increments `pin_failed_attempts`. At 5 failures, `pin_locked_until` is set to now plus 30 minutes and the call raises P0001 `Too many wrong codes. Ask the buyer to request a new code or try again later.`
  - While locked, every attempt is refused.
  - A correct PIN sets DELIVERED, `delivered_at` and the deadline. The photo, if given, must be a claimed attachment in the `delivery-proofs` bucket.
  - The audit records `{order_id, status, pin_verified: true, has_photo}`.
  - Staff call it directly, because it has no outside IO.
- **Delivery photos** go in a second private bucket, `delivery-proofs`, using the same signed-upload pattern. The upload is authorised by `request_delivery_photo(p_idempotency_key, p_order_id, p_mime_type, p_size_bytes)` through the `order-delivery-photo` gateway, and only for callers allowed to deliver the order. Storage SELECT is allowed for the ZSM and the order's TM. The shared table `upload_slots` (§5.4) holds these slots.
- **Damage window.** Delivery does not change ticket rules; buyers can always open a ticket. An ORDER ticket opened with category `DELIVERY` or `PRODUCT` records `within_damage_window boolean`, which is true when `now() <= damage_claim_deadline`. ZSMs see the flag.
- **Refund interaction.** D1 `apply_paystack_refund` already accepts PAID, IN_TRANSIT and DELIVERED orders, so nothing changes. A refunded order cannot be dispatched or delivered: the status checks enforce this.

### 5.4 Upload slots

The two buckets share one pattern, so there is one table, `upload_slots`. It has a `purpose` column (`SUPPORT_TICKET` or `DELIVERY_PROOF`), a nullable `ticket_id` / `order_id` pair, and a CHECK tying each purpose to its columns *(builder's call: one table, one claim function, one cleanup job)*. For DELIVERY_PROOF rows, RLS SELECT goes to the ZSM and to the order's TM.

## 6. Dispute evidence bundle

**`get_order_dispute_evidence(p_order_id uuid) returns jsonb`** is SECURITY DEFINER, STABLE and read-only. It is for ZSMs of the order's tenant only; anyone else gets 42501. It returns:
- the order header and lines, each with its `sale_category`;
- the Paystack payments, with references, amounts, status and settlement;
- refunds;
- consent: `policy_version_tag`, `policy_accepted_at`, `consent_ip`, and the policy `content` as accepted;
- the contact block (the ZSM may read it under A2);
- fulfilment: dispatched and delivered times, the tracking reference, `pin_verified`, and the delivery photo path;
- every support ticket on the order with its messages, attachment metadata and `within_damage_window`.

Each call is audited as `DISPUTE_EVIDENCE_VIEWED` with `{order_id}`, because the bundle collects personal data *(builder's call)*. It is exposed through the `order-dispute-evidence` user gateway, which signs the photo URLs for 10 minutes.

## 7. WhatsApp-first messaging

- **A shared router, not a public endpoint** *(builder's call: a public `send-otp` would let anyone send messages to any number).* `_shared/core/messaging.ts` exports `MessageSender = (to, message: OutboundMessage) => Promise<DeliveryResult>`. Every gateway that sends a buyer or shop-owner message uses it: `otp-issue`, `order-dispatch` and `order-delivery-pin`. `SmsSender` stays as the fallback transport.
- **Routing.**
  - The router first tries the Meta WhatsApp Cloud API with an approved template, `POST https://graph.facebook.com/v{N}/{phone_number_id}/messages`, under a 15-second `AbortSignal.timeout`.
  - On a timeout, a network error, a non-2xx response, or a missing configuration, it sends through KudiSMS.
  - If both fail, the gateway's existing error applies (`SMS_DELIVERY_FAILED`, renamed `MESSAGE_DELIVERY_FAILED`).
  - The OutboundMessage carries a template name and parameters for WhatsApp, plus the plain SMS text.
- **Templates.**
  - `teafair_otp`, an authentication template with the code parameter.
  - `teafair_delivery_code`, a utility template with the reference and the code.

  Both template names come from env and must be approved in Meta Business Manager before use.
- **Secrets.** `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_API_VERSION`, plus the existing KudiSMS secrets. With no WhatsApp secrets the router goes straight to SMS, so local development and tests need no Meta account. An optional `WHATSAPP_API_URL` lets the integration fake stand in for the real API.
- **Log.** `notification_logs` is a platform table with these columns:
  - `id`, `tenant_id?`, `purpose`, one of `OTP`, `DELIVERY_CODE`, `DELIVERY_CODE_RESEND` or `PHONE_VERIFY`. `PHONE_VERIFY` messages are sent with the router in WhatsApp-only mode (§3.5).
  - `channel` (`WHATSAPP` or `SMS`);
  - `status` (`SENT` or `FAILED`);
  - `whatsapp_error text?`, holding the provider error code only;
  - `phone_last4`;
  - `related_id uuid?`, the challenge or order;
  - `created_at`.

  It never stores the message, the code or the full phone number. Writes go through the internal RPC `log_message_delivery(...)`, which is service_role only and called by the router. RLS gives the ZSMs of the tenant SELECT.

## 8. Tests

pgTAP files start at 027 and are split by area. They cover:
- policy and categories;
- consent, including the A2 placement of the IP;
- upload slots, Storage policies and attachment claims;
- fulfilment, including PIN lockout, the roles and the damage flag;
- the evidence bundle;
- the grants sweep.

Deno unit tests cover:
- the router: WhatsApp success, timeout fallback at 15 seconds using a fake clock, non-2xx fallback, no configuration, both channels failing, and the log never containing the code;
- each new gateway.

The integration test covers a web order from consent through dispatch, a delivery PIN sent through the fake WhatsApp, delivery, a damage ticket with a photo, and the evidence bundle.

## 9. Clarifications and left to the builder

- **No WhatsApp status webhook** *(builder's call)*. WhatsApp often accepts a message and then fails later. Because every web buyer's number is verified on WhatsApp at checkout (§3.5), such later failures should be rare. The router therefore falls back to SMS only when the send call fails or times out. Resend remains the recovery path.
- **Storage policies by migration.** The `storage.objects` SELECT policies and the bucket rows are created in migrations, which is Supabase's documented approach. Hosted projects can refuse them, so the deploy notes add a dry-run check against staging first. If a policy is refused, the fallback is to have gateways sign URLs for staff as well.
- **File layout.** The user's directive named a single migration and a single test file. The plan splits them by task (`20261023<hhmmss>_a5_<topic>.sql`, tests 027 onward) so that each task is reviewed on its own. This follows the repo's convention *(builder's call; the user may override it)*.
- **Revoke sweeps** also cover `service_role` for internal helpers, as in A3 and A4.
- **Left to the builder:** fixture shapes, index details, and the exact wording of the placeholder policy text, which needs counsel review.
