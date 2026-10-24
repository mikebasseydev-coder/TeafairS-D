# Food Refund Policy, Support Photos, Web Fulfilment & WhatsApp-First Messaging (Addendum A5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The web storefront sells food and tea only, under a versioned refund policy. Each buyer:
- proves their number is on WhatsApp;
- consents to the policy before paying;
- can attach damage photos in support chat.

Web orders move PAID → IN_TRANSIT → DELIVERED. Delivery is proven by a WhatsApp-delivered PIN. ZSMs can pull a dispute evidence bundle.

**Architecture:** Postgres holds:
- the policy;
- the phone verifications;
- one `upload_slots` table for both photo kinds;
- `order_fulfilments`;
- a `notification_logs` table.

Each write is a SECURITY DEFINER RPC. Deno gateways handle Turnstile, PIN and OTP generation, signed Storage URLs, and outbound messages. Outbound messages go through one shared router: WhatsApp Cloud API first, KudiSMS on error or after 15 s, WhatsApp-only for checkout verification. Photos live in two private Storage buckets. Staff read them through `storage.objects` SELECT policies; buyers read them through gateway-signed URLs.

**Tech Stack:** Postgres 15 (Supabase local), pgTAP, Supabase Storage, pg_cron, Deno Edge Functions, Zod, Meta WhatsApp Cloud API, KudiSMS, Cloudflare Turnstile.

**Spec:** `docs/superpowers/specs/2026-10-23-addendum-a5-refund-fulfillment-design.md` (Addendum A5, approved 2026-10-23). Read §2 and §9 before any task. Spec A §9, A2 and A3, plus `supabase/CLAUDE.md` ("Writing a migration / an RPC / an Edge Function"), apply to every task.

## Global Constraints

- **Scope.**
  - Backend only. No client code.
  - Leave the untracked `FIGMA.md` alone.
  - Branch: `docs/addendum-a5-refund-fulfillment` (cut from local `main` at `541fc1e`).
- **Remote.**
  - Never push to GitHub.
  - Never run `supabase db push`, `functions deploy` or `config push`.
  - Never set remote secrets. Nothing touches `vwmjyfjdwrohfizljxrq`.
- **Grants and RLS.**
  - `authenticated` gets table `SELECT` only.
  - RLS policies are `FOR SELECT` only, in the form `x in (select public.f())`.
  - Storage gets SELECT policies only. No client insert, update or delete on `storage.objects`.
- **Functions.**
  - Every `SECURITY DEFINER` function sets `search_path = public, pg_temp`.
  - Every new function runs `revoke all … from public, anon, authenticated, service_role`, then gets only the grants the spec names.
  - Internal helpers get no grant.
- **Write contract.**
  - Staff RPCs take `p_idempotency_key uuid` first, then call `assert_tenant_role`, then `idempotency_begin`, then the writes, then `write_audit` (source `USER`), then `idempotency_complete`.
  - Public (service_role) RPCs use source `WEB`.
  - No `p_tenant_id` anywhere.
- **Schema.**
  - Statuses are `text` + `CHECK`.
  - FKs are `ON DELETE RESTRICT`. Tenant rows use composite `(tenant_id, x)` FKs.
- **Secrets and privacy.**
  - No PIN, OTP, verification code, token, full phone number, IP, Storage path or signed URL ever appears in an audit row, a notification payload, `notification_logs`, or a console log.
  - Consent IP and phone-verification facts live in `order_contacts` (A2).
- **Exact copy.**
  - `This product is not available to order yet.`
  - `The refund policy has changed. Please review it and try again.`
  - `You must accept the refund policy to place an order.`
  - `Please verify your WhatsApp number again.`
  - `We couldn't reach WhatsApp. Please try again in a few minutes.`
  - `Too many wrong codes. Ask the buyer to request a new code or try again later.`
  - FOOD refund note: `Opened food items can't be refunded. Report transit damage within 24 hours of delivery with photos.`
- **Photo limits.**
  - JPEG, PNG or WebP only.
  - At most 5,242,880 bytes each.
  - At most 3 photos per message.
  - Signed URLs live for 10 minutes.
- **Files.**
  - Migrations: `supabase/migrations/20261023<hhmmss>_a5_<topic>.sql`.
  - pgTAP: `supabase/tests/database/0NN_a5_<topic>.test.sql`, numbered from 027.
  - Shared Deno code: `supabase/functions/_shared/messaging/` and `_shared/storage/`.
- **Testing.**
  - Run `supabase test db` only after `supabase db reset`. If the first run sees an empty DB, wait and rerun.
  - Stop any `functions serve` you start.
- **Commits.** Every commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Decisions this plan makes where the spec is silent

1. **Ten tasks, in three layers:**
   - checkout (T1–T4);
   - attachments (T5–T6);
   - fulfilment and evidence (T7–T9).

   Integration and docs come last (T10).
2. **`place_web_order` is redefined once, in T2.** That redefinition adds `p_accepted_refund_policy boolean`, `p_policy_version_tag text`, `p_client_ip inet` and `p_phone_verification_token text`. The category refusal (T1) is added to the same body. T1 adds the column and the sellability helper `public.web_category_sellable(text) returns boolean` (internal).
3. **A3 RPC signatures change, so each one is dropped and recreated.** The functions are `open_support_ticket`, `add_ticket_message` and `reply_ticket`, which gain a trailing `p_attachment_ids uuid[] default '{}'`. The support gateways are updated in the same task (T6), and 020/021 keep passing.
4. **Signed Storage URLs** are created in `_shared/storage/signed.ts` with the service-role key, calling the Storage REST endpoints:
   - `POST /storage/v1/object/upload/sign/{bucket}/{path}` for uploads;
   - `POST /storage/v1/object/sign/{bucket}/{path}` for downloads, with `expiresIn: 600`.

   This is the only service-role use in user gateways. It is allowed because it is a Storage call, not an RPC call. Every authorisation decision has already been made by the caller's RPC.
5. **The PIN** is generated in the gateway with `crypto.getRandomValues`, as 4 digits zero-padded. It is hashed in the RPC with `extensions.crypt(p_pin, extensions.gen_salt('bf'))`, the same way `issue_otp` hashes. The checkout verification code is generated the same way, with 6 digits.

## Review Focus

1. **A verification token used for a different phone number** than the one on the order must be refused (T2 test).
2. **Brute-forcing the delivery PIN.** The 10th lifetime wrong code locks until a ZSM resends. A resend by the TM does not reset that (T7 test).
3. **A warehouse manager entering a code on a courier order in another tenant**, or on an order whose warehouse isn't theirs, gets 42501 (T7 test).
4. **A buyer attaching an object that was never uploaded**, or a fourth photo, or another ticket's slot, gets P0001 (T5 test).
5. **WhatsApp returning 200 after 16 s.** The router must already have fallen back to SMS at 15 s and must log `SMS` (T3 test, with a fake clock).

---

## File structure

```
supabase/migrations/
  20261023120000_a5_policy_categories.sql   refund_policies + seed, sale_category, web_category_sellable, web_active_refund_policy, catalogue refund_note (T1)
  20261023120100_a5_checkout_consent.sql    web_phone_verifications, start/confirm RPCs, order consent columns, order_contacts columns, place_web_order redefinition (T2)
  20261023120200_a5_notification_logs.sql   notification_logs + log_message_delivery (T3)
  20261023120300_a5_upload_slots.sql        buckets, upload_slots, my_support_message_ticket_ids, storage policies, request_* RPCs, claim helper, A3 RPC re-creates, cleanup cron (T5)
  20261023120400_a5_fulfilment.sql          order_fulfilments, dispatch/resend/deliver, request_delivery_photo, within_damage_window (T7)
  20261023120500_a5_dispute_evidence.sql    get_order_dispute_evidence (T9)
supabase/tests/database/
  027_a5_policy_checkout.test.sql (T1+T2)  028_a5_notification_logs.test.sql (T3)
  029_a5_upload_slots.test.sql (T5)        030_a5_fulfilment.test.sql (T7)  031_a5_evidence_grants.test.sql (T9)
supabase/functions/
  _shared/messaging/{router,whatsapp,router.test}.ts                       (T3)
  otp-issue/* (switch to router)                                            (T3)
  checkout-phone-verify-start/*, checkout-phone-verify-confirm/*, storefront-refund-policy/*, web-checkout/* (T4)
  _shared/storage/{signed,signed.test}.ts, support-ticket-attachment/*, support-staff-attachment/*, support-ticket-{open,message,read}/* (T6)
  order-dispatch/*, order-delivery-pin/*, order-delivery-photo/*            (T8)
  order-dispute-evidence/*                                                  (T9)
  _tests/gateway.integration.ts                                             (T10)
supabase/config.toml, supabase/functions/.env.example, supabase/CLAUDE.md, CLAUDE.md
```

Test conventions:
- pgTAP follows `019`–`026`.
- Deno handler tests follow `support-ticket-open/handler.test.ts`, which fakes the RPC client and dependencies.
- The public gateways use `publicGateway` and the staff gateways use `userGateway`. Both live in `_shared/core/`.

---

### Task 1: Refund policy table, product categories, catalogue notes

**Files:**
- Create `supabase/migrations/20261023120000_a5_policy_categories.sql`.
- Create `supabase/tests/database/027_a5_policy_checkout.test.sql` (the T1 section).
- Modify `001_schema_shape.test.sql`: 45 → 46 tables.

**Interfaces:**
- **Produces `public.refund_policies`**, as in spec §3.1:
  - a `version_tag` CHECK;
  - a partial unique index `(is_active) where is_active`.
- **Seeds `v2.0-food-cosmetics`**: active, `categories = '{FOOD}'`, `published_at = now()`.
  - The placeholder Markdown covers the general terms (§3.1), the food terms (§3.1) and the WhatsApp clause (§3.5).
  - The first line reads `<!-- PLACEHOLDER: requires legal review before go-live -->`.
- **Access to `refund_policies`:** RLS is on, with no policy and no grant.
- **Adds `central_products.sale_category`**, as in spec §3.2.
- **Internal function `public.web_category_sellable(p_category text) returns boolean`** (STABLE). It is true when the active policy's `categories` contains the category.
- **`public.web_active_refund_policy() returns jsonb`**, granted to service_role only. It returns `{version_tag, title, content, categories, published_at}`, or null when no policy is active.
- **`storefront_catalogue(text)` is re-created by `create or replace`, with the same signature.** It:
  - excludes products whose `sale_category` is not sellable;
  - adds a top-level `refund_policy: {version_tag}`;
  - adds `refund_notes: {FOOD: '<FOOD note>'}`.

  The FOOD note copy is fixed in plan Global Constraints, and the note map lives in the function as a CASE. The existing catalogue keys stay byte-identical, so `014`/`018` stay green.

- [ ] **Step 1: Write the failing tests.**

  ```sql
  select is((select count(*) from refund_policies where is_active), 1::bigint, 'one active policy');
  select is(public.web_active_refund_policy() ->> 'version_tag', 'v2.0-food-cosmetics', 'v2.0-food-cosmetics is active');
  select throws_ok(<insert second active policy>, '23505', null, 'only one active policy');
  select throws_ok(<insert version_tag 'food'>, '23514', null, 'version tag format');
  select ok(public.web_category_sellable('FOOD') and not public.web_category_sellable('ELECTRONICS') and not public.web_category_sellable('TELECOM'), 'only FOOD sellable');
  select throws_ok(<update a product sale_category = 'TOYS'>, '23514', null, 'category set is fixed');
  select ok(<storefront_catalogue(null) excludes a product set to ELECTRONICS>, 'unsellable products hidden');
  select is(<storefront_catalogue(null) -> 'refund_notes' ->> 'FOOD'>, 'Opened food items can''t be refunded. Report transit damage within 24 hours of delivery with photos.', 'food note');
  select ok(not has_table_privilege('anon', 'public.refund_policies', 'select') and not has_table_privilege('authenticated', 'public.refund_policies', 'select'), 'policy table not client-readable');
  select ok(position('PLACEHOLDER' in (select content from refund_policies where version_tag='v2.0-food-cosmetics')) > 0, 'seed marked for legal review');
  ```
- [ ] **Step 2: Run it** with `docker exec -i supabase_db_teafair psql -U postgres -qAt < supabase/tests/database/027_a5_policy_checkout.test.sql`. Expected: FAIL, because the relation does not exist.
- [ ] **Step 3: Write the migration** and update 001.
- [ ] **Step 4: Run** `supabase migration up`, then 027, then `supabase db reset && supabase test db`. Expected: PASS. Baseline: 26 files, 1065 tests.
- [ ] **Step 5: Commit** with `feat(db): refund policy v2.0-food-cosmetics, sellable product categories (A5 §3.1–3.2)`.

---

### Task 2: WhatsApp phone verification and consent on web orders (DB)

**Files:**
- Create `supabase/migrations/20261023120100_a5_checkout_consent.sql`.
- Modify `027_a5_policy_checkout.test.sql` (T2 section), `001_schema_shape` (46 → 47), and any existing pgTAP calling `place_web_order` (`008`/`013`/`014`/`018`, whichever do) so they pass the new arguments.

**Interfaces:**
- **Consumes from T1:** `refund_policies`, `web_category_sellable`.
- **Produces `public.web_phone_verifications`**, as in spec §3.5, with RLS on and no policy or grant.
- **`public.start_web_phone_verification(p_phone text, p_code text, p_client_ip inet) returns jsonb`** returns `{verification_id, expires_at}`. Service_role only.
  - The phone must be E.164.
  - The code must be 6 digits and is stored hashed with bf.
  - Throttles:
    - more than 3 starts for the phone in the last hour raises P0001 `Too many messages. Please wait a few minutes.`;
    - more than 10 per IP per hour raises the same error. The IP is stored as `client_ip inet`, which is added to the table for this purpose and is not returned.
- **`public.confirm_web_phone_verification(p_verification_id uuid, p_code text, p_token_hash text) returns jsonb`** returns `{verified: true}`. Service_role only.
  - These cases raise P0001 `Please verify your WhatsApp number again.`:
    - the row is expired, consumed or verified;
    - `failed_attempts >= 5`.
  - A wrong code increments `failed_attempts` and raises P0001 `That code is not right.`
  - On success it sets `verified_at`, stores `token_hash` (the gateway sends the sha256 hex of the token) and sets `token_expires_at` to `verified_at` plus 30 minutes.
- **`orders` gains columns.** `policy_version_tag` (FK to `refund_policies.version_tag`) and `policy_accepted_at`, plus the CHECK `channel <> 'ONLINE' or created_at < timestamptz '2026-10-23 00:00:00+00' or (policy_version_tag is not null and policy_accepted_at is not null)`.
- **`order_contacts` gains columns.** `consent_ip inet`, `phone_verified_at timestamptz` and `phone_verified_channel text check (phone_verified_channel = 'WHATSAPP')`.
- **`place_web_order` is redefined with four new parameters.** Drop the 9-arg signature and create one that appends `p_accepted_refund_policy boolean, p_policy_version_tag text, p_client_ip inet, p_phone_verification_token text`. Then:
  - Replay is checked first and returns the original reply.
  - `p_accepted_refund_policy is distinct from true` raises P0001 `You must accept the refund policy to place an order.`
  - A tag that is not the active `version_tag` raises P0001 with the policy-changed copy.
  - Any line whose product's `sale_category` is not sellable raises P0001 with the not-available copy.
  - The token check: `encode(extensions.digest(p_phone_verification_token,'sha256'),'hex')` must match a row that is verified, unconsumed, unexpired and has the same phone as the normalised customer phone. Otherwise it raises P0001 with the verify-again copy. The row is locked `for update` and marked consumed.
  - It writes the consent columns, `consent_ip`, `phone_verified_at` and `channel = 'WHATSAPP'`.
  - The audit after-image gains `{policy_version_tag, policy_accepted_at, phone_verified: true}` and never the IP.
  - Grants carry over: service_role only.
  - The idempotency request excludes the token and the IP, in the same way A3 excludes the secret.

- [ ] **Step 1: Write the failing tests** (the T2 section of 027).

  ```sql
  select is(<start_web_phone_verification('+2348011111111','123456','10.0.0.1')> ? 'verification_id', true, 'verification started');
  select throws_ok(<4th start for that phone within an hour>, 'P0001', 'Too many messages. Please wait a few minutes.', 'phone throttle');
  select throws_ok(<confirm with '000000'>, 'P0001', 'That code is not right.', 'wrong code');
  select throws_ok(<confirm after 5 wrong codes, with the right code>, 'P0001', 'Please verify your WhatsApp number again.', 'verification exhausted');
  select is(<confirm right code on a fresh start> ->> 'verified', 'true', 'verified');
  select is(<place_web_order with accepted, tag, ip, token> ->> 'public_reference' is not null, true, 'verified, consenting order placed');
  select is(<order_contacts row: (consent_ip, phone_verified_channel)>, <('10.0.0.9', 'WHATSAPP')>, 'consent IP and verification stored A2-side');
  select ok(<audit after-image of that order has policy_version_tag and no consent_ip / no ip text>, 'audit has consent, not IP');
  select throws_ok(<same token again on a new key>, 'P0001', 'Please verify your WhatsApp number again.', 'token is single use');
  select throws_ok(<token verified for +2348011111111 used with customer phone +2348022222222>, 'P0001', 'Please verify your WhatsApp number again.', 'token bound to phone');
  select throws_ok(<token older than 30 minutes>, 'P0001', 'Please verify your WhatsApp number again.', 'token expires');
  select throws_ok(<p_accepted_refund_policy false>, 'P0001', 'You must accept the refund policy to place an order.', 'consent required');
  select throws_ok(<tag 'v1.0-old'>, 'P0001', 'The refund policy has changed. Please review it and try again.', 'stale policy refused');
  select throws_ok(<line with an ELECTRONICS product>, 'P0001', 'This product is not available to order yet.', 'unsellable refused');
  select is(<replay of the first order's key after activating a new policy> ->> 'order_id', <first order_id>, 'replay keeps original consent');
  select throws_ok(<insert ONLINE order with created_at now() and null policy_version_tag as postgres>, '23514', null, 'new web orders must carry consent');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.** Update the older pgTAP files that call `place_web_order` so they create a verified token and pass the new arguments. Name each one in the report.
- [ ] **Step 4: Run** 027, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(db): WhatsApp-verified, consenting web checkout (A5 §3.3–3.6)`.

---

### Task 3: WhatsApp-first messaging router and delivery log

**Files:**
- Create `supabase/migrations/20261023120200_a5_notification_logs.sql` and `supabase/tests/database/028_a5_notification_logs.test.sql`.
- Create `supabase/functions/_shared/messaging/whatsapp.ts`, `router.ts` and `router.test.ts`.
- Modify `supabase/functions/otp-issue/{handler,index,handler.test}.ts` and `supabase/functions/.env.example`.

**Interfaces:**
- **DB: `public.notification_logs`**, as in spec §7, with `purpose` CHECK `OTP | DELIVERY_CODE | DELIVERY_CODE_RESEND | PHONE_VERIFY`.
  - RLS SELECT goes to `tenant_id in (select my_tenant_ids_with_role(array['ZSM']::tenant_role_enum[]))`.
  - The table is granted to authenticated for SELECT.
- **DB: `public.log_message_delivery(p_tenant_id uuid, p_purpose text, p_channel text, p_status text, p_phone text, p_related_id uuid, p_whatsapp_error text) returns void`.** Service_role only. It stores `right(p_phone, 4)` and never the full number.
- **Deno, `whatsapp.ts`:**
  - `type WhatsAppConfig = { token: string; phoneNumberId: string; apiVersion: string; apiUrl?: string }`.
  - `whatsAppConfigFromEnv(): WhatsAppConfig | null` reads `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_API_VERSION` and `WHATSAPP_API_URL`. It returns null if any of the first three is missing.
  - `sendWhatsAppTemplate(cfg, to, template: {name: string; language: string; params: string[]}, signal: AbortSignal): Promise<void>` throws on a non-2xx response, including the Meta `error.code` in the message.
- **Deno, `router.ts`:**
  - `type OutboundMessage = { purpose: 'OTP'|'DELIVERY_CODE'|'DELIVERY_CODE_RESEND'|'PHONE_VERIFY'; template: {name; language; params}; smsText: string; tenantId?: string; relatedId?: string; whatsappOnly?: boolean }`.
  - `type DeliveryResult = { channel: 'WHATSAPP'|'SMS'; sent: true }`.
  - `type MessageSender = (to: string, msg: OutboundMessage) => Promise<DeliveryResult>`.
  - `createMessageRouter(deps: { whatsapp: WhatsAppConfig | null; sendWhatsApp?: typeof sendWhatsAppTemplate; sms: SmsSender; log: (entry) => Promise<void>; timeoutMs?: number /* default 15000 */ }): MessageSender`. It works as follows:
    - It tries WhatsApp under `AbortSignal.timeout(timeoutMs)`.
    - On any failure, or when no configuration is present, and unless `whatsappOnly` is set, it sends the SMS.
    - It logs each attempt that ends a send: WHATSAPP/SENT, or WHATSAPP/FAILED followed by SMS/SENT or SMS/FAILED.
    - It throws `MessageDeliveryError` when the message ends unsent.
    - It never puts the code or the full phone number in any log entry.
  - `messageRouterFromEnv(serviceRpc)` wires `log` to `log_message_delivery`.
  - Template names come from env: `WHATSAPP_TEMPLATE_OTP` (default `teafair_otp`) and `WHATSAPP_TEMPLATE_DELIVERY_CODE` (default `teafair_delivery_code`).
- **`otp-issue` moves to the router.** It replaces `sendSms` with `sendMessage: MessageSender`, using purpose `OTP` and the existing SMS text. The error becomes `GatewayError(502, "MESSAGE_DELIVERY_FAILED", "The code could not be sent. Request a new one.")`, and the response gains `channel`.

- [ ] **Step 1: Write the failing tests.**
  - `router.test.ts`:
    - "WhatsApp success sends no SMS and logs WHATSAPP/SENT";
    - "WhatsApp non-2xx falls back to SMS and logs both";
    - "WhatsApp slower than the timeout falls back to SMS". Use `timeoutMs: 50` and a fake WhatsApp that resolves after 200 ms. Assert that the SMS was sent and that the result channel is `SMS`;
    - "no WhatsApp config goes straight to SMS";
    - "whatsappOnly never sends SMS and throws when WhatsApp fails";
    - "both channels failing throws MessageDeliveryError";
    - "log entries never contain the code or the full phone".
  - `otp-issue/handler.test.ts`: update the existing tests to use the router fake, and add "reports the channel used".
  - pgTAP 028:
    - `log_message_delivery` stores the last 4 digits only;
    - the purpose and channel CHECKs;
    - a ZSM reads their tenant's rows;
    - a TM reads none;
    - anon and authenticated cannot execute `log_message_delivery`.
- [ ] **Step 2: Run** `deno test --allow-env supabase/functions/` and 028. Expected: FAIL.
- [ ] **Step 3: Implement.** Add the WhatsApp variables to `.env.example` with empty values.
- [ ] **Step 4: Run** `deno test --allow-env supabase/functions/` (baseline 197 passing), `deno check supabase/functions/*/index.ts`, and `supabase db reset && supabase test db`. Expected: all PASS.
- [ ] **Step 5: Commit** with `feat: WhatsApp-first message router with SMS fallback and delivery log (A5 §7)`.

---

### Task 4: Checkout gateways

**Files:**
- Create:
  - `supabase/functions/checkout-phone-verify-start/{index,handler,handler.test}.ts`;
  - `checkout-phone-verify-confirm/*`;
  - `storefront-refund-policy/*`.
- Modify `supabase/functions/web-checkout/{handler,handler.test}.ts` and `supabase/config.toml` (three `verify_jwt = false` blocks).

**Interfaces:**
- **Consumes:**
  - the T2 RPCs;
  - T1 `web_active_refund_policy`;
  - the T3 router (`whatsappOnly: true`, purpose `PHONE_VERIFY`, template `WHATSAPP_TEMPLATE_OTP`);
  - `turnstileVerifier` and `normalizePhone`, with the client-IP helper as used in `web-checkout`.
- **`checkout-phone-verify-start`** (POST) takes `{turnstile_token, phone}`.
  - Turnstile and phone handling follow web-checkout.
  - It generates the 6-digit code and calls the start RPC.
  - It sends the code WhatsApp-only. On `MessageDeliveryError` it returns `GatewayError(503, "WHATSAPP_UNAVAILABLE", "We couldn't reach WhatsApp. Please try again in a few minutes.")`.
  - It replies `{verification_id, expires_at}` with no-store caching.
- **`checkout-phone-verify-confirm`** (POST) takes `{verification_id: uuid, code: /^\d{6}$/}`.
  - It generates a 32-byte base64url token (reuse `_shared/support/secret.ts`'s base64url helper, or add `randomToken()` there) and calls confirm with the token's sha256 hex.
  - It replies `{verification_token}` with no-store caching.
  - P0001 responses keep the 422 mapping and carry the database copy.
- **`storefront-refund-policy`** (GET) calls `web_active_refund_policy`. A null result maps to 404 `NOT_FOUND`. The response header is `cache-control: public, max-age=300`.
- **`web-checkout` schema gains three fields:** `accept_refund_policy: z.literal(true)`, `policy_version_tag: string` and `phone_verification_token: string(43)`.
  - A missing or false `accept_refund_policy` returns 400 with `You must accept the refund policy to place an order.`
  - It passes `p_accepted_refund_policy: true`, `p_policy_version_tag`, `p_client_ip` (from the same header logic as Turnstile) and `p_phone_verification_token`.

- [ ] **Step 1: Write the failing tests.**
  - start: "bot check failure is 403 and sends nothing"; "WhatsApp failure is 503 WHATSAPP_UNAVAILABLE and never falls back to SMS"; "sends the code only to WhatsApp and never returns it".
  - confirm: "malformed code is 400"; "returns a 43-char token and sends only its hash to the RPC".
  - policy: "null is 404"; "cached for 5 minutes".
  - web-checkout: "missing accept_refund_policy is 400 with the consent copy"; "passes consent, tag, client IP and token to place_web_order". Update existing web-checkout tests for the new required fields.
- [ ] **Step 2: Run** `deno test`. Expected: FAIL.
- [ ] **Step 3: Implement** the gateways and the config.toml blocks.
- [ ] **Step 4: Run** `deno test` and `deno check`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(functions): WhatsApp checkout verification, policy endpoint, consenting checkout (A5 §3)`.

---

### Task 5: Upload slots, Storage buckets and policies, support attachments (DB)

**Files:**
- Create `supabase/migrations/20261023120300_a5_upload_slots.sql` and `supabase/tests/database/029_a5_upload_slots.test.sql`.
- Modify `001_schema_shape` (47 → 48), plus `020`/`021`/`022` if their calls to the re-created A3 RPCs need named arguments.

**Interfaces:**
- **Buckets.** Insert `storage.buckets` rows for `support-attachments` and `delivery-proofs`, as in spec §4.1, using `on conflict (id) do nothing`.
- **`public.upload_slots`**, as in spec §4.2/§5.4:
  - `purpose` CHECK `SUPPORT_TICKET | DELIVERY_PROOF`;
  - `ticket_id`/`order_id` set according to `purpose`;
  - `bucket` derived from purpose;
  - `storage_path text unique`;
  - `mime_type` CHECK in the three types;
  - `size_bytes` between 1 and 5242880;
  - `uploaded_by_type` CHECK `CUSTOMER | STAFF`;
  - `uploaded_by uuid`;
  - `message_id uuid`;
  - `claimed_at`.

  Composite FKs point to tickets, orders and messages.
- **`public.my_support_message_ticket_ids() returns setof uuid`** (SECURITY DEFINER, STABLE, granted to authenticated). It returns exactly the ticket ids the caller can read under the `support_messages` policy: ZSM tenants, TM territories, or the history helper. Reuse the existing helpers.
- **RLS on `upload_slots`** is SELECT only: `ticket_id in (select my_support_message_ticket_ids())` for SUPPORT_TICKET rows. DELIVERY_PROOF rows are added in T7.
- **Storage policy** `support_attachments_select` on `storage.objects` FOR SELECT TO authenticated, using `bucket_id = 'support-attachments' and (storage.foldername(name))[2]::uuid in (select public.my_support_message_ticket_ids())`.
- **`public.request_ticket_attachment(p_idempotency_key uuid, p_public_reference text, p_secret text, p_mime_type text, p_size_bytes bigint) returns jsonb`** returns `{attachment_id, storage_path}`. Service_role only.
  - It checks the secret the same way `add_ticket_message` does.
  - It refuses CLOSED tickets with the A3 closed copy.
  - It refuses a mime type outside the set, or a size outside 1..5242880, with P0001 `Photos must be JPEG, PNG or WebP and at most 5 MB.`
  - More than 10 pending slots per ticket per hour raises the A3 throttle copy.
  - The path is `tickets/<ticket_id>/<slot_id>.<jpg|png|webp>`.
- **`public.request_staff_ticket_attachment(p_idempotency_key uuid, p_ticket_id uuid, p_mime_type text, p_size_bytes bigint) returns jsonb`** (authenticated, staff contract). It applies `support_lock_ticket(…, false)` with A3's permission rules, and the same limits.
- **Internal `public.claim_support_attachments(p_ticket_id uuid, p_message_id uuid, p_ids uuid[], p_uploader_type text) returns integer`.**
  - It raises P0001 `You can attach up to 3 photos.` for more than 3 ids.
  - It checks that every id is a pending slot of that ticket and uploader type. Otherwise it raises P0001 `That photo isn't available.`
  - It checks that a matching `storage.objects` row exists with the same `name`, a `metadata->>'size'` equal to `size_bytes`, and a `metadata->>'mimetype'` equal to `mime_type`. Otherwise it raises P0001 `That photo hasn't finished uploading.`
  - It sets `message_id` and `claimed_at`.
- **A3 RPCs are re-created** (drop and create) with a trailing `p_attachment_ids uuid[] default '{}'`: `open_support_ticket` (CUSTOMER), `add_ticket_message` (CUSTOMER) and `reply_ticket` (STAFF).
  - Each claims after inserting its message.
  - The idempotency request includes the ids.
  - The audit after-image adds `attachment_count`.
- **`read_support_ticket`** adds `attachments: [{attachment_id, mime_type, storage_path}]` per message. The gateway turns the paths into signed URLs and strips the paths (T6).
- **`redact_ticket_customer_data`** also deletes the ticket's CUSTOMER slots, both from `storage.objects` (where the bucket and name match) and from the table. The audit after-image adds `attachments_deleted`.
- **Cron `cleanup-upload-slots` at `45 0 * * *`** calls the internal `public.cleanup_pending_upload_slots() returns integer`. It deletes pending slots older than 24 hours, together with their objects.

- [ ] **Step 1: Write the failing tests** in 029. Use the A3 fixtures and insert `storage.objects` rows as postgres to simulate uploads.

  ```sql
  select is(<request_ticket_attachment right secret, image/jpeg, 1000> ->> 'storage_path' like 'tickets/%.jpg', true, 'slot granted');
  select throws_ok(<wrong secret>, 'P0001', 'NOT_FOUND', 'secret checked');
  select throws_ok(<image/gif>, 'P0001', 'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'type limit');
  select throws_ok(<5242881 bytes>, 'P0001', 'Photos must be JPEG, PNG or WebP and at most 5 MB.', 'size limit');
  select throws_ok(<add_ticket_message with a slot whose object is not in storage.objects>, 'P0001', 'That photo hasn''t finished uploading.', 'object must exist');
  select throws_ok(<object exists but metadata size differs>, 'P0001', 'That photo hasn''t finished uploading.', 'size must match');
  select throws_ok(<four ids>, 'P0001', 'You can attach up to 3 photos.', 'max 3');
  select throws_ok(<a slot from another ticket>, 'P0001', 'That photo isn''t available.', 'slot bound to ticket');
  select lives_ok(<add_ticket_message with one uploaded slot>, 'buyer attaches a photo');
  select is(<read_support_ticket messages -> attachments length for that message>, 1, 'buyer reads attachment metadata');
  select is(<storage.objects for that path visible as the territory TM>, 1, 'handler TM can download');
  select is(<same as a DSA / other-territory TM / Z2>, 0, 'others cannot');
  select is(<same as the selling DSA on an ORDER ticket>, 0, 'A2-strict: seller cannot');
  select lives_ok(<reply_ticket as TM with a staff slot>, 'staff attaches a photo');
  select ok(not exists(<audit rows whose text contains 'tickets/'>), 'no paths in audit');
  select is(<redact as ZSM: customer slots and objects left for the ticket>, 0, 'redaction deletes buyer photos');
  select is(public.cleanup_pending_upload_slots(), <n older than 24h>, 'stale pending slots cleaned');
  select ok(exists(select 1 from cron.job where jobname = 'cleanup-upload-slots'), 'cleanup scheduled');
  select ok(not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and cmd <> 'SELECT' and policyname like '%attachment%' ), 'no client write policies on storage');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** 029, then `supabase db reset && supabase test db`. Expected: PASS, with `019`–`022` still green.
- [ ] **Step 5: Commit** with `feat(db): support photo upload slots, private storage, A3 attachments (A5 §4)`.

---

### Task 6: Attachment gateways and signed URLs

**Files:**
- Create `supabase/functions/_shared/storage/{signed,signed.test}.ts`.
- Create `support-ticket-attachment/*` (public) and `support-staff-attachment/*` (user gateway).
- Modify `support-ticket-open`, `support-ticket-message` and `support-ticket-read` (handler, test and index), and `config.toml` (one `verify_jwt = false` block, for the public one).

**Interfaces:**
- **`signed.ts`:**
  - `createSignedUploadUrl(cfg: {url, serviceKey}, bucket, path): Promise<string>`;
  - `createSignedDownloadUrl(cfg, bucket, path, expiresIn = 600): Promise<string>`.

  Both use the Storage REST endpoints in plan Decision 4 and throw on a non-2xx response. `storageConfigFromEnv()` reads `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
- **`support-ticket-attachment`** (POST) takes `{idempotency_key, public_reference, secret, mime_type, size_bytes}`. It calls `request_ticket_attachment` and replies `{attachment_id, upload_url}`. It never returns `storage_path` and never logs anything.
- **`support-staff-attachment`** (POST, JWT) takes `{idempotency_key, ticket_id, mime_type, size_bytes}`. It calls `request_staff_ticket_attachment` with the caller's JWT and replies `{attachment_id, upload_url}`.
- **The open and message gateways** accept `attachment_ids?: uuid[] (max 3)` and pass `p_attachment_ids`.
- **`support-ticket-read`** replaces each attachment's `storage_path` with a 10-minute `url`, so the response never contains a path.

- [ ] **Step 1: Write the failing tests:**
  - "signed upload URL uses the upload/sign endpoint with the service key";
  - "download URL expires in 600 seconds";
  - "public attachment gateway never returns the storage path";
  - "staff attachment gateway forwards the caller's JWT";
  - "read gateway swaps paths for signed URLs";
  - "message gateway passes attachment_ids";
  - "more than 3 attachment_ids is 400".
- [ ] **Step 2: Run** `deno test`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `deno test` and `deno check`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(functions): support photo upload and signed download gateways (A5 §4.3)`.

---

### Task 7: Web-order fulfilment (DB)

**Files:**
- Create `supabase/migrations/20261023120400_a5_fulfilment.sql` and `supabase/tests/database/030_a5_fulfilment.test.sql`.
- Modify `001_schema_shape` (48 → 49).

**Interfaces:**
- **Consumes:** T5 `upload_slots` and the `delivery-proofs` bucket; T2 `order_contacts` for the phone.
- **Produces `public.order_fulfilments`**, as in spec §5.1, plus:
  - `delivered_via text check (delivered_via in ('FIELD_STAFF','COURIER'))`;
  - `pin_lifetime_failures int not null default 0`;
  - `pin_resends_today int` / `pin_resend_day date`;
  - `pin_zsm_lock boolean not null default false`.

  RLS SELECT goes to the ZSM tenants, `territory_id in my_tm_territory_ids()` via the order, and the fulfilment warehouse's `manager_id = auth.uid()`. It is exposed through a helper `my_fulfilment_order_ids()` (SECURITY DEFINER, STABLE). Revoke column SELECT on `delivery_pin_hash` from authenticated.
- **Internal `public.fulfilment_can_dispatch(p_me tenant_users, p_order orders) returns boolean`.** True for a ZSM of the tenant, or for the ACTIVE manager of `p_order.fulfilment_warehouse_id`.
- **Internal `public.fulfilment_delivery_path(p_me tenant_users, p_order orders) returns text`.** It returns:
  - `'FIELD_STAFF'` for a TM, DSM or DSA whose territory is the order's territory, or for a ZSM;
  - `'COURIER'` for the warehouse manager;
  - otherwise null.
- **`public.mark_order_dispatched(p_idempotency_key uuid, p_order_id uuid, p_tracking_reference text, p_pin text) returns jsonb`** returns `{order_id, status, buyer_phone, public_reference}`.
  - The caller passes `assert_tenant_role(array['ZSM','TM','ASM','DSM','DSA'])` or is the warehouse manager. A warehouse manager is a profile who may hold any role, so use `assert_tenant_role(null)` and then `fulfilment_can_dispatch`. Otherwise 42501.
  - It requires an ONLINE order in PAID status. Otherwise it raises P0001 `only paid web orders can be dispatched`.
  - The PIN must match `^\d{4}$`. Otherwise P0001.
  - It sets IN_TRANSIT and inserts the fulfilment row with the hashed PIN and `pin_sent_at = null`.
  - `buyer_phone` is returned for the gateway only.
  - The audit after-image is `{order_id, status, has_tracking}`.
- **`public.mark_delivery_pin_sent(p_idempotency_key uuid, p_order_id uuid, p_channel text) returns jsonb`.** It is called by the gateway after a successful send. It sets `pin_sent_at` and counts a resend toward the day's limit only for resends. The same caller rules apply.
- **`public.resend_delivery_pin(p_idempotency_key uuid, p_order_id uuid, p_pin text) returns jsonb`** returns `{order_id, buyer_phone, public_reference}`.
  - It requires IN_TRANSIT and the dispatch or delivery permission.
  - It refuses when 3 resends have already been sent today: P0001 `Too many codes sent today. Ask a ZSM.`, except for a ZSM.
  - It sets a new hash.
  - Only a ZSM caller resets `pin_failed_attempts`, `pin_locked_until`, `pin_lifetime_failures` and `pin_zsm_lock`. A non-ZSM resend leaves all locks as they are.
- **`public.mark_order_delivered(p_idempotency_key uuid, p_order_id uuid, p_pin text, p_photo_attachment_id uuid default null) returns jsonb`** returns `{order_id, status, delivered_at, damage_claim_deadline, delivered_via}`.
  - `fulfilment_delivery_path` must be non-null. Otherwise 42501.
  - It requires IN_TRANSIT.
  - If `pin_zsm_lock` is set or `pin_locked_until > now()`, it raises P0001 with the too-many copy.
  - On a wrong PIN it increments `pin_failed_attempts` and `pin_lifetime_failures`. At 5 failures it sets `pin_locked_until` to now plus 30 minutes. At 10 lifetime failures it sets `pin_zsm_lock`. It then raises P0001 with the too-many copy if a lock was just reached, else P0001 `That delivery code is not right.`
    - **The failure counters must survive the raise.** Record each failure in a separate committed step before raising. The approach: the function returns `{ok:false, error}` instead of raising on a wrong PIN, and the gateway or client maps it. A function exception would roll back the counter increment.
    - So the contract for a wrong PIN is: return `{order_id, status:'IN_TRANSIT', error:'WRONG_PIN'|'LOCKED'}`, and run `idempotency_complete` with that reply.
  - A correct PIN:
    - sets DELIVERED, `delivered_at`, the deadline, `delivered_by` and `delivered_via`;
    - claims the photo slot if one is given (it must be DELIVERY_PROOF for this order, uploaded by the caller, with a matching object);
    - audits `{order_id, status, pin_verified:true, has_photo, delivered_via}`.
- **`public.request_delivery_photo(p_idempotency_key uuid, p_order_id uuid, p_mime_type text, p_size_bytes bigint) returns jsonb`.** The caller must have a delivery path. The path is `orders/<order_id>/<slot_id>.<ext>`. It applies the same limits as T5.
- **DELIVERY_PROOF read access.**
  - `upload_slots` RLS adds DELIVERY_PROOF rows where `order_id in (select my_fulfilment_order_ids())`, or where `uploaded_by = auth.uid()`.
  - The Storage policy `delivery_proofs_select` uses the same rule on `(storage.foldername(name))[2]::uuid`.
- **`open_support_ticket`** sets `support_tickets.within_damage_window` (a new column, boolean, null when not applicable) for ORDER tickets with category `DELIVERY` or `PRODUCT`, as `now() <= damage_claim_deadline`. Use `create or replace`, since the signature is the same as T5's.

- [ ] **Step 1: Write the failing tests** in 030. Fixtures: TEAFAIR with an Ikeja TM, DSA and ZSM; warehouse W managed by profile M (an ACTIVE member); a PAID ONLINE order O with `fulfilment_warehouse_id = W` and territory Ikeja; a second tenant's warehouse manager M2.

  ```sql
  select is(<mark_order_dispatched as M with pin '1234'> ->> 'status', 'IN_TRANSIT', 'warehouse manager dispatches');
  select ok(<buyer_phone in that reply equals order_contacts phone>, 'gateway gets the buyer phone');
  select throws_ok(<dispatch as the DSA>, '42501', null, 'DSA cannot dispatch');
  select throws_ok(<dispatch as M2>, '42501', null, 'other tenant manager refused');
  select throws_ok(<dispatch a PENDING order>, 'P0001', 'only paid web orders can be dispatched', 'must be paid');
  select ok(not has_column_privilege('authenticated', 'public.order_fulfilments', 'delivery_pin_hash', 'select'), 'PIN hash unreadable');
  select is(<mark_order_delivered as DSA wrong pin> ->> 'error', 'WRONG_PIN', 'wrong pin reported');
  select is(<pin_failed_attempts after that>, 1, 'failure recorded');
  select is(<5th wrong pin> ->> 'error', 'LOCKED', 'locks after 5');
  select is(<right pin while locked> ->> 'error', 'LOCKED', 'locked refuses right pin');
  select is(<after lock expiry (update pin_locked_until as postgres), wrong pins to 10 lifetime> ->> 'error', 'LOCKED', 'lifetime lock');
  select is(<resend as TM, then right pin> ->> 'error', 'LOCKED', 'non-ZSM resend does not clear the lifetime lock');
  select is(<resend as ZSM with '5678', then deliver '5678' as DSA> ->> 'status', 'DELIVERED', 'ZSM resend unlocks; delivery succeeds');
  select ok(<damage_claim_deadline = delivered_at + 24h and delivered_via = 'FIELD_STAFF'>, 'window started');
  select is(<courier path: order O2 delivered by M> ->> 'delivered_via', 'COURIER', 'courier delivery by warehouse manager');
  select throws_ok(<deliver as an Epe DSA>, '42501', null, 'other territory refused');
  select lives_ok(<deliver with an uploaded DELIVERY_PROOF slot>, 'photo claimed on delivery');
  select is(<that object visible as the TM / as M / as the uploader>, 1, 'photo readers');
  select is(<that object visible as an Epe TM>, 0, 'others cannot see the photo');
  select is(<open ORDER ticket category DELIVERY within 24h: within_damage_window>, true, 'inside window');
  select is(<same after deadline (update as postgres)>, false, 'outside window');
  select throws_ok(<4th non-ZSM resend in a day>, 'P0001', 'Too many codes sent today. Ask a ZSM.', 'resend limit');
  select ok(not exists(<audit rows containing '1234' or '5678'>), 'no PIN in audit');
  ```
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** 030, then `supabase db reset && supabase test db`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(db): web-order dispatch and PIN-verified delivery, field and courier paths (A5 §5)`.

---

### Task 8: Fulfilment gateways

**Files:**
- Create `supabase/functions/order-dispatch/*`, `order-delivery-pin/*`, `order-delivery-photo/*` and `order-delivery-confirm/*`. All are user gateways (JWT).

**Interfaces:**
- **Consumes:** the T7 RPCs, the T3 router (purposes `DELIVERY_CODE` and `DELIVERY_CODE_RESEND`, template `WHATSAPP_TEMPLATE_DELIVERY_CODE` with params `[public_reference, pin]`, SMS fallback on) and T6 `signed.ts`.
- **`order-dispatch`** (POST) takes `{idempotency_key, order_id, tracking_reference?}`.
  - It generates the PIN and calls `mark_order_dispatched`.
  - If the call is not a replay, it sends `Your Teafair order <ref> is on its way. Give this delivery code to the rider: <PIN>.` and calls `mark_delivery_pin_sent` with the channel.
  - It replies `{order_id, status, delivery_code_sent, channel}`, where `delivery_code_sent` is false on `MessageDeliveryError`.
  - It never returns the phone or the PIN.
- **`order-delivery-pin`** (POST) takes `{idempotency_key, order_id}`. It calls resend, then sends, then calls `mark_delivery_pin_sent`, and replies in the same shape.
- **`order-delivery-photo`** (POST) takes `{idempotency_key, order_id, mime_type, size_bytes}`. It calls `request_delivery_photo` and replies `{attachment_id, upload_url}`.
- **`order-delivery-confirm`** (POST) takes `{idempotency_key, order_id, pin: /^\d{4}$/, photo_attachment_id?}`.
  - It calls `mark_order_delivered`.
  - `error: 'WRONG_PIN'` maps to 422 `That delivery code is not right.`
  - `error: 'LOCKED'` maps to 422 with the too-many copy.
  - Otherwise it passes the reply through. This gateway exists because the RPC returns errors as data (T7).

- [ ] **Step 1: Write the failing tests:**
  - "dispatch sends the PIN through the router and never returns it or the phone";
  - "replay sends nothing";
  - "send failure keeps IN_TRANSIT and reports delivery_code_sent false";
  - "resend uses DELIVERY_CODE_RESEND";
  - "confirm maps WRONG_PIN and LOCKED to 422 with the copy";
  - "photo gateway returns only an upload URL";
  - "PIN never appears in console output". Spy on console.
- [ ] **Step 2: Run** `deno test`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `deno test` and `deno check`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat(functions): order dispatch, delivery code, delivery photo and confirm gateways (A5 §5.3)`.

---

### Task 9: Dispute evidence bundle and A5 grants sweep

**Files:**
- Create `supabase/migrations/20261023120500_a5_dispute_evidence.sql` and `supabase/tests/database/031_a5_evidence_grants.test.sql`.
- Create `supabase/functions/order-dispute-evidence/*`, a user gateway.

**Interfaces:**
- **`public.get_order_dispute_evidence(p_order_id uuid) returns jsonb`.**
  - SECURITY DEFINER and volatile (it writes an audit row).
  - Granted to authenticated.
  - The caller must be a ZSM of the order's tenant, via `assert_tenant_role(['ZSM'])` and a tenant match. Otherwise 42501.
  - It returns the blocks listed in spec §6 (order, lines with `sale_category`, payments, refunds, consent including the accepted policy `content`, contact including `consent_ip` and phone verification, fulfilment including `pin_verified` and photo `storage_path`, tickets with messages and attachment metadata including `within_damage_window`).
  - It audits `DISPUTE_EVIDENCE_VIEWED` with `{order_id}`, without idempotency, because it is a read.
- **The gateway** forwards the caller's JWT and signs every `storage_path` (in the delivery photo and the ticket attachments) as a 10-minute URL. The response contains no paths.
- **Grants sweep in 031.** Write one `ok()` per A5 function × (anon, authenticated, service_role), guarded with `to_regprocedure`, matching the spec's grants:
  - service_role only: `web_active_refund_policy`, `start_web_phone_verification`, `confirm_web_phone_verification`, `place_web_order`, `log_message_delivery` and `request_ticket_attachment`;
  - authenticated: `request_staff_ticket_attachment`, `mark_order_dispatched`, `mark_delivery_pin_sent`, `resend_delivery_pin`, `mark_order_delivered`, `request_delivery_photo` and `get_order_dispute_evidence`, plus the helpers `my_support_message_ticket_ids` and `my_fulfilment_order_ids`;
  - none: `web_category_sellable`, `claim_support_attachments`, `cleanup_pending_upload_slots`, `fulfilment_can_dispatch` and `fulfilment_delivery_path`.

- [ ] **Step 1: Write the failing tests.**
  - pgTAP:
    - ZSM receives every block, and the consent block holds the policy text;
    - TM, DSA and warehouse manager get 42501;
    - another tenant's ZSM gets 42501;
    - one `DISPUTE_EVIDENCE_VIEWED` audit row per call, with an after-image of `{order_id}` only;
    - the grants sweep.
  - Deno: "evidence gateway signs every storage path and returns none".
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** 031, `supabase db reset && supabase test db`, `deno test` and `deno check`. Expected: PASS.
- [ ] **Step 5: Commit** with `feat: ZSM dispute evidence bundle; A5 grants sweep (A5 §6)`.

---

### Task 10: Integration flow and docs

**Files:**
- Modify `supabase/functions/_tests/gateway.integration.ts`, `supabase/functions/.env.example`, `supabase/CLAUDE.md` and `CLAUDE.md`.

- [ ] **Step 1: Add a fake WhatsApp Cloud API to the integration test.** It records template sends, alongside the existing fake Paystack, and is reached through `WHATSAPP_API_URL`. Then write the failing test `"A5: verified checkout → dispatch → delivery code via WhatsApp → delivery → damage ticket with photo → evidence"`:
  1. Start phone verification. Read the code from the fake WhatsApp, confirm it, and get the token.
  2. Fetch `storefront-refund-policy` and check out with consent, the tag and the token. Pay through the fake Paystack, as the D1 tests do.
  3. As the warehouse manager, call `order-dispatch` and read the PIN from the fake WhatsApp.
  4. As the territory DSA, upload a delivery photo to the signed URL and call `order-delivery-confirm` with the PIN and the photo.
  5. Open a DELIVERY ticket on the order, request an attachment, upload it and post with it. Assert that `within_damage_window` is true through the ZSM read.
  6. As the ZSM, call `order-dispute-evidence` and assert that it holds consent, verification, delivery and the ticket photo URL.
  7. Fake WhatsApp returning 500 for one dispatch: the code arrives by SMS and `notification_logs` shows `SMS`.

  Use per-run keys and phones.
- [ ] **Step 2: Run it** with `supabase functions serve --env-file supabase/functions/.env` and the command in `supabase/CLAUDE.md`. Expected: FAIL until served. Then all ok. Stop serve afterwards.
- [ ] **Step 3: Update the docs.**
  - `supabase/CLAUDE.md`:
    - an A5 status row;
    - the gateways and RPCs;
    - the new secrets (`WHATSAPP_*`), with a note that Meta must approve the templates `teafair_otp` and `teafair_delivery_code` before deploy;
    - the Storage buckets, with the deploy note "dry-run the storage policies against staging first; fallback is gateway-signed URLs for staff";
    - the placeholder policy text that needs legal review;
    - "deploy after A3/A4";
    - the new required checkout fields for the client (Spec B).
  - Root `CLAUDE.md`: counts from real commands, plus the A5 spec row.
- [ ] **Step 4: Full verification.** Run `supabase db reset && supabase test db` (expect PASS), `deno test --allow-env supabase/functions/` (0 failed), `deno check` and the integration command (all ok).
- [ ] **Step 5: Commit** with `test(functions): A5 end-to-end flow; docs: A5 status, secrets, deploy notes`.
