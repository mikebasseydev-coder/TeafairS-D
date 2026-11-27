# Spec B — The Client (Teafair RTM app shell)

**Status:** approved by the user, 2026-11-27. `src/` is unfrozen for slices
B1–B4 (§11). **Authority:** Spec A
(`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`)
and its addenda A1–A8 still govern the backend. Where this spec and Spec A
disagree about the client, this spec wins. It replaces Spec A §3.4 (gateway
inventory), §7.1 (`src/store/`) and the flat `src/` of §12, and amends §2
item 11 ("Android only") to iOS and Android.

Spec B is the app shell: scaffold, auth, tenancy, the PIN, navigation, the
offline queue and the realtime client. Spec C (RTM core) and Spec D (money
and integrations) build their screens on it. §6 maps every callable RPC and
every user gateway to the feature that will own it, so C and D add screens,
not plumbing.

## 1. Ground truth (from the migrations, 2026-11-27)

| Thing | Values |
|---|---|
| `tenant_role_enum` | `ZSM`, `TM`, `ASM`, `DSM`, `DSA`, `ZSA`, `ASA`, `POS_AGENT`, `RETAIL_SHOP_OWNER`, `CLIENT_SERVICE_MANAGER`, `TENANT_ADMIN`, `LOGISTICS_MANAGER` |
| `platform_role_enum` (on `profiles`, never a membership) | `PLATFORM_SUPER_ADMIN`, `MONVELO_OPERATOR`, `MONVELO_FINANCE` |
| Monvelo agent people | rows in `monvelo_agent_members`, not a role; they may have no tenant at all |
| Seeded tenants | `TEAFAIR` (`7eaf0000-…0001`), `SUREACH` (`5eac0000-…0001`); others come from `provision_tenant` |
| Tenant code | `^[A-Z0-9_]{2,16}$` (no hyphen; collisions get `_02`, `_03`, …) |
| SKU code (batch loads) | `^[A-Z0-9_-]{3,40}$`, e.g. `OIL-COC-15ML-SACHET` |
| JWT claims (`app_metadata`) | `tenant_ids`, `active_tenant_id`, `tenant_role`, `platform_role` |

`MONVELO_OPERATOR` is a platform role, not a tenant role. `ZSA` is the
zone's street agent and `ASA` the area's (A6). Nothing in the client may
name a role outside these two enums.

## 2. Two surfaces

| | **TeafairWeb** (its own repository) | **Teafair RTM** (this repository, `src/`) |
|---|---|---|
| Who | platform administrators, CSMs, logistics managers, tenant admins; anonymous buyers on the storefront | field force (ZSM, TM, ASM, DSM, DSA, ZSA, ASA), logistics managers at dispatch, shop owners, POS agents, Monvelo agent members |
| Owns | **tenant provisioning** (`provision_tenant`); first staff (`appoint_client_service_manager`, `appoint_zone_manager`, `create_zone`, `set_zone_zsm`); **invitations, roles and territories** (`invite_tenant_user`, `upsert_territory`, `upsert_area`, `upsert_zone`); contact reports and their hard copies (the citations every catalogue and stock write needs); **the SKU builder and CSV upload** (`upsert_catalogue_product`, `upsert_tenant_skus`); **opening stock** (`post_opening_stock`) and later receipts, transfers and adjustments; brand terms, Monvelo settings and fees; tenant support tickets; the storefront and its checkout | reading the active tenant's catalogue and stock balances under RLS; field, POS, fulfilment and Monvelo workflows; invitations accepted, PINs set, tenants switched; staff chat and staff ticket replies |
| Never | Monvelo tables from the storefront code (A6 §15) | provisioning, catalogue or stock writes; the storefront's public gateways |

The admin RPCs are `authenticated` and carry their own role checks, so
TeafairWeb calls them with the admin's JWT exactly as §7 describes. The batch
RPCs are what a CSV upload calls: parse the file in the browser, validate it
with the same Zod schema, send it as one `p_items` array (1–500 rows), and
show the reply `{created, updated, skipped}`. A refused batch writes nothing;
the error names the row (`item 7: …`).

**Batch contracts** (migration `20261127120000`, pgTAP 084):

- `provision_tenant(p_idempotency_key, p_name, p_preferred_code default null)`
  → `{tenant_id, code, name, status}`. PLATFORM_SUPER_ADMIN only.
- `upsert_tenant_skus(p_idempotency_key, p_decision_id, p_items)` →
  `{created, updated, skipped}`. The CSM, citing a CATALOGUE decision. Each item
  has the `upsert_catalogue_product` fields. A new SKU needs `product_name`,
  `brand`, `category`, `sale_category`, `unit_price` and `wholesale_price`.
  Pack factors must be positive whole numbers.
- `post_opening_stock(p_idempotency_key, p_decision_id, p_warehouse_id, p_items, p_reference default null)`
  → `{warehouse_id, lines, total_quantity}`. The CSM or the LM, citing a STOCK
  decision. Items are `{sku_code, batch_number, quantity, expires_at?}`. It
  works only on a warehouse with no movements yet; later stock goes through
  `record_stock_receipt`.

**Deviation from the brief, on purpose.** The brief put catalogue and stock
loads with ZSM/ASM and left out the decision. A6 §16.4 gives the catalogue to
the CSM and stock to the CSM or LM, always citing a decision ("zero
backdoors"), and pgTAP 049 fails any writer that does not. The batch RPCs
follow the spec, not the brief.

## 3. Stack, targets and layout

- React Native, Expo and TypeScript (`strict`). NativeWind, Zustand,
  `react-native-mmkv`, `expo-secure-store`, `@supabase/supabase-js`, Zod.
  Expo Router does the navigation. Versions are pinned exactly at B1, to the
  then-current Expo SDK.
- **`pnpm` only**, `node-linker=hoisted` (Expo); `pnpm exec`, never `npx`.
  B1 makes the root `package.json` the app's package (the existing tooling
  scripts stay), and the app's code is `src/`. Deno is unaffected: it already
  runs with `--node-modules-dir=none`.
- Targets: iOS and Android. Phones in portrait (~390–430 px); tablets and
  foldables in portrait and landscape, with multi-column layouts through
  NativeWind `sm:`/`md:`/`lg:`. `react-native-safe-area-context` for notches,
  the dynamic island and navigation bars. Expo web exists only as the
  Playwright test target (§11).

```
src/
├── app/                      Expo Router routes: thin, they render feature screens
├── shared/
│   ├── tokens/               FIGMA.md values + the NativeWind preset (the only hex values)
│   ├── ui/                   primitives: Button, Field, PinPad, OtpInput, Card, Banner, Sheet, ListRow, EmptyState
│   ├── storage/              secure.ts (Tier 1), mmkv.ts (Tier 2, namespaced), reset-registry.ts
│   ├── network/              supabase.ts, rpc.ts, gateway.ts, errors.ts (§3.5), queue/, realtime.ts, database.types.ts
│   ├── observability/        log.ts + scrub.ts (Ruling 46)
│   └── index.ts
└── features/
    ├── auth/                 email OTP, session, claims decoder
    ├── tenant/               memberships, invitations, set_active_tenant, PIN gate
    ├── shell/                role navigation shells
    ├── catalogue/  stock/    reads (Spec C)
    ├── field/                trade orders, shops, territories (Spec C)
    ├── fulfilment/           dispatch, delivery code, delivery photo (A5)
    ├── support/  chat/       staff tickets (A3/A5), staff messaging (A4)
    ├── notifications/        notifications, register_device
    └── monvelo/              everything A6/A8, alone
```

Each feature has `components/ screens/ hooks/ services/ store/ index.ts`. The
barrel `index.ts` is its only public surface.

**Dependency graph (acyclic, enforced by ESLint `import/no-restricted-paths`
and `import/no-cycle`):**

```
shared  ←  auth  ←  tenant  ←  shell  ←  { catalogue, stock, field, fulfilment, support, chat, notifications, monvelo }
```

`shared` imports no feature. A domain feature may import the barrels of
`auth`, `tenant` and `shell`, never another domain feature. `monvelo` shares
no store or service with anything outside `shared`, `auth` and `tenant`
(A6 §15).

## 4. Design system and security

- **Tokens.** `src/shared/tokens/` is the single source of the `FIGMA.md`
  `teafair-*` values (emerald, lime, forest, black, white, surface,
  darkSurfaceEnd, the three gradients). It exports the NativeWind preset
  that `tailwind.config.js` consumes. **No raw hex value and no stock palette
  class (`emerald-500`, `slate-900`, …) outside `src/shared/tokens/`.** An
  ESLint rule and a unit test (`tokens.guard.test.ts`, a scan of `src/` for
  `#[0-9a-fA-F]{3,8}\b` and for stock palette class names) enforce it.
- **Design workflow.** Every screen follows `.claude/awards-mobile-workflow.md`.
- **Ruling 46 in the client.**
  - The app holds only `EXPO_PUBLIC_SUPABASE_URL` and
    `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (the `sb_publishable_` key, or the
    anon key until it is retired). No secret, ever. The existing
    `secret-scoping` test already scans `src/`.
  - `log.ts` is the only logger. It runs every message and context object
    through `scrub.ts`, which follows `_shared/core/scrub.ts`. Values under
    sensitive keys are dropped (pin, otp, code, token, secret, phone,
    email, address, hash, `p_` parameters). Strings are scrubbed of JWTs,
    emails and phone numbers. It never logs a queued payload.
  - No PIN, OTP, owner code, token or checkout URL is ever written to MMKV,
    to a Zustand `persist` store, to a log or to an error report. §5 says
    where each one lives.

## 5. State: feature stores and the three tiers

Every store is a Zustand store in `src/features/<feature>/store/`, exported
through the feature barrel. There is no global store.

| Tier | Where | Holds | Never |
|---|---|---|---|
| **1** | `expo-secure-store`, only through `shared/storage/secure.ts` (supabase-js `auth.storage` adapter; values chunked, because SecureStore values must stay small) | the Supabase session: `access_token`, `refresh_token`; the MMKV encryption key | anything in Zustand or MMKV |
| **2** | Zustand `persist` + MMKV, one MMKV instance per `${userId}:${tenantId}` (encrypted with the Tier 1 key); a user-level instance `${userId}` for things above tenants | the offline queue and its `dependsOn` chains (keys made at enqueue); the §3.5 "Needs attention" list; the read cache (Spec A §7.5); filters, tabs and layout choices; the last active tenant (a hint) | tokens, PINs, OTPs, codes, checkout URLs, buyer contacts, financial balances |
| **3** | Zustand without `persist` | the email OTP input; the 4-digit PIN entry and confirm buffers; the current PIN for a change; the shop owner's delivery and repayment code entry; the Monvelo funding checkout (`authorization_url`, `access_code`) | any storage |

Tier 3 is wiped on submit (success or failure), on `MONVELO_CHECKOUT_LOST`,
on tenant switch, on sign-out and when the app goes to the background.

**Financial figures are never cached.** Exposure, pledges, ledger,
repayments, payment states and reconciliation summaries are network-only. If
the app is offline, it shows "Unavailable offline", not the last value.
Server timestamps are authoritative. A queued entry shows "queued at"
(device time) until it lands, then the server's `created_at`.

**The reset registry** (`shared/storage/reset-registry.ts`):

```ts
type ResetScope = "tenant" | "session";
registerReset(scope: ResetScope, name: string, reset: () => void | Promise<void>): void;
runResets(scope: ResetScope): Promise<void>; // "session" runs "tenant" first
```

Every feature store registers at module load: tenant-scoped stores (catalogue,
stock, field, fulfilment, support, chat, notifications, monvelo, tenant's PIN
status) under `tenant`; auth and the user-level instance under `session`. The
realtime client registers too, so it unsubscribes every channel. A unit test
imports every barrel and asserts that each store with state has registered.

- **Tenant switch:** refused while the current tenant's queue holds PENDING
  or IN_FLIGHT entries ("Send or discard N queued changes first"); then
  `set_active_tenant` → `refreshSession()` → `runResets("tenant")` → open the
  new tenant's MMKV namespace.
- **Sign-out:** the same queue check, then `runResets("session")`,
  `auth.signOut()`, the Tier 1 entries removed. The MMKV namespaces of that
  user are kept, encrypted and unreadable without Tier 1, and are cleared at
  the next sign-in of a different user.

**Store inventory (B1–B4):**

| Store | Feature | Tier | State |
|---|---|---|---|
| `useSessionStore` | auth | 1 (via supabase-js) + memory | status, `userId`, decoded claims (hints) |
| `useOtpStore` | auth | 3 | email, code buffer, resend cooldown |
| `useTenantStore` | tenant | 2 (user-level) | memberships from `tenant_ids` and reads, last active tenant |
| `useInvitationStore` | tenant | memory | `list_my_invitations()` result |
| `usePinStore` | tenant | 3 + memory | `pin_set`, `locked_until`, entry buffers |
| `useQueueStore` | shared/network | 2 | entries, drain state |
| `useAttentionStore` | shared/network | 2 | terminal entries with their error |
| `usePrefsStore` | shell | 2 | theme, list density, tabs |
| `useMonveloCheckoutStore` | monvelo | 3 | the funding checkout of the open financing |

## 6. RPC and gateway map

**Surfaces:** App = Teafair RTM; Web = TeafairWeb; GW = only through the
named gateway (never call the RPC directly); Sys = cron, webhook or service
role, never a client.

### 6.1 User gateways (all 15), the app's or the admin portal's

| Gateway | RPCs behind it | Feature | Surface | Notes |
|---|---|---|---|---|
| `otp-issue` | `issue_otp` | field | App | shop-owner OTP (pickup, POS settlement) |
| `otp-verify` | `verify_otp` | field | App | |
| `order-dispatch` | `mark_order_dispatched`, `mark_delivery_pin_sent` | fulfilment | App | LM or ZSM |
| `order-delivery-pin` | `resend_delivery_pin`, `mark_delivery_pin_sent` | fulfilment | App | |
| `order-delivery-photo` | `request_delivery_photo` | fulfilment | App | slot → upload → confirm |
| `order-delivery-confirm` | `mark_order_delivered` | fulfilment | App | fresh key per code entry; 422 `WRONG_PIN`/`LOCKED` |
| `order-dispute-evidence` | `get_order_dispute_evidence` | support | Web | ZSM; audited view |
| `support-staff-attachment` | `request_staff_ticket_attachment` | support | App, Web | slot, upload, then `reply_ticket` |
| `contact-report-upload` | `request_contact_report_hard_copy` | (admin) | Web | |
| `monvelo-agent-register` | `monvelo_agent_register_preflight`, `register_monvelo_agent`, `request_monvelo_settlement_change` | monvelo | App | Paystack account check |
| `monvelo-shop-consent` | `start_monvelo_consent`, `enrol_monvelo_shop`, `start_monvelo_policy_consent`, `submit_monvelo_shop_policy` | monvelo | App | owner's WhatsApp code |
| `monvelo-fund` | `start_monvelo_funding`, `record_monvelo_checkout` | monvelo | App | 409 `MONVELO_CHECKOUT_LOST` → new key, start again |
| `monvelo-confirm-delivery` | `start_monvelo_delivery`, `confirm_monvelo_delivery` | monvelo | App | owner's code; fresh key per entry |
| `monvelo-confirm-repayment` | `record_monvelo_repayment`, `confirm_monvelo_repayment` | monvelo | App | owner's code; fresh key per entry |
| `monvelo-cover-upload` | `can_upload_monvelo_cover` | monvelo | App, Web | policy and claim evidence uploads |

`_shared/auth/pin.ts` (`requirePin`) exists but no RPC calls
`consume_pin_pass()` yet, so no gateway is PIN-gated today. The first one
(Spec A §7.4: requisition approvals, brand policy, stock issue) arrives with
Spec C, through a gateway, online only.

Public gateways (anonymous, TeafairWeb storefront only, never the app):
`storefront-catalogue`, `storefront-locations`, `storefront-refund-policy`,
`checkout-phone-verify-start`, `checkout-phone-verify-confirm`,
`web-checkout`, `web-order-status`, `support-ticket-open`,
`support-ticket-read`, `support-ticket-attachment`, `support-ticket-message`.
System functions (never a client): `auth-verify-claims`, `send-auth-email`,
`send-auth-sms`, `process-payment`, `reconcile-funds`,
`web-commission-release`, `storage-purge`, `email-outbox-send`,
`monvelo-insurance-declare`, `monvelo-insurance-webhook`.

### 6.2 RPCs called directly (`supabase.rpc`, the caller's JWT)

| Feature | RPCs | Surface |
|---|---|---|
| auth / tenant (B2–B3) | `list_my_invitations`, `accept_tenant_invitation`, `decline_tenant_invitation`, `set_active_tenant`, `get_my_pin_status`, `set_tenant_pin`, `change_tenant_pin`, `verify_pin` (guard, no key) | App, Web |
| notifications | `register_device` | App |
| platform admin | `provision_tenant`, `appoint_client_service_manager`, `appoint_zone_manager`, `create_zone`, `set_zone_zsm`, `set_state_operational` | Web |
| tenant structure | `invite_tenant_user`, `upsert_zone`, `upsert_territory`, `upsert_area`, `set_territory_coverage`, `set_territory_web_warehouse`, `set_web_defaults`, `set_brand_approval_policy`, `set_tenant_operational_state` | Web |
| contact reports | `file_contact_report`, `review_contact_report`, `attach_contact_report_hard_copy` | Web |
| catalogue | `upsert_catalogue_product`, `upsert_tenant_skus` | Web |
| stock | `post_opening_stock`, `record_stock_receipt`, `record_stock_transfer`, `record_stock_adjustment`, `record_order_return` | Web (LM may also use App for returns, Spec C) |
| web referral (POS) | `upsert_web_referral_code`, `set_web_pos_venue`, `pos_order_lookup` | App (POS agent, ZSM) |
| field (Spec C) | `place_trade_order` | App |
| support (A3/A5) | `claim_ticket`, `reply_ticket`, `update_ticket_status`, `set_ticket_priority`, `assign_ticket`, `redact_ticket_customer_data` | App, Web |
| tenant tickets (A7) | `open_tenant_ticket`, `reply_tenant_ticket`, `claim_tenant_ticket`, `release_tenant_ticket`, `assign_tenant_ticket`, `update_tenant_ticket_status` | Web |
| chat (A4) | `list_my_chat_channels`, `get_or_create_direct_channel`, `post_chat_message`, `mark_chat_read`, `hide_chat_message` | App |
| monvelo, field agents and agents | `upsert_area` (ZSA/ASA scope), `nominate_monvelo_agent`, `close_monvelo_nomination`, `withdraw_monvelo_shop_consent`, `withdraw_monvelo_shop_policy`, `set_monvelo_supply_day`, `pledge_monvelo_funds`, `monvelo_supply_days_near`, `monvelo_agents_near`, `monvelo_today`, `request_monvelo_financing`, `approve_monvelo_financing`, `cancel_monvelo_financing`, `claim_monvelo_financing`, `monvelo_open_offers`, `monvelo_order_financing_status`, `get_monvelo_offer_cover`, `get_monvelo_agent_exposure`, `get_lender_reconciliation_summary`, `list_monvelo_claim_holds`, `get_monvelo_claim_hold`, `decide_monvelo_claim_hold`, `dispatch_monvelo_financing`, `reject_monvelo_repayment`, `report_monvelo_loss`, `add_monvelo_member`, `accept_monvelo_agent_terms` | App |
| monvelo, tenant side | `propose_monvelo_brand_terms`, `approve_monvelo_brand_terms`, `withdraw_monvelo_brand_terms`, `set_monvelo_tenant_settings`, `record_monvelo_fee_terms`, `accept_monvelo_tenant_terms` | Web |
| monvelo, platform staff | `approve_monvelo_agent`, `suspend_monvelo_agent`, `set_monvelo_agent_caps`, `approve_monvelo_settlement_change`, `review_monvelo_flag`, `review_monvelo_shop_policy`, `register_monvelo_insurer`, `set_monvelo_insurer_status`, `propose_monvelo_insurance_product`, `approve_monvelo_insurance_product`, `withdraw_monvelo_insurance_product`, `file_monvelo_insurance_claim`, `set_monvelo_claim_status`, `record_monvelo_claim_settlement`, `close_monvelo_insurance_claim`, `record_monvelo_declaration_outcome`, `record_monvelo_premium_paid`, `record_monvelo_topup_paid` | Web |

**Gateway-only, never called directly**, even though `authenticated` holds
EXECUTE. The rule is that an RPC behind a gateway goes through the gateway.
Several of them also demand the Vault gateway proof, so a direct call fails
closed:
`issue_otp`, `verify_otp`, `mark_order_dispatched`, `mark_order_delivered`,
`resend_delivery_pin`, `mark_delivery_pin_sent`, `request_delivery_photo`,
`get_order_dispute_evidence`, `request_staff_ticket_attachment`,
`request_contact_report_hard_copy`, `register_monvelo_agent`,
`monvelo_agent_register_preflight`, `request_monvelo_settlement_change`,
`start_monvelo_consent`, `enrol_monvelo_shop`,
`start_monvelo_policy_consent`, `submit_monvelo_shop_policy`,
`start_monvelo_funding`, `record_monvelo_checkout`, `start_monvelo_delivery`,
`confirm_monvelo_delivery`, `record_monvelo_repayment`,
`confirm_monvelo_repayment`, `can_upload_monvelo_cover`.

**RLS helpers, not features:** the `my_*` functions, `is_*`, `jwt_tenant_id`,
`tenant_role`, `sees_shared_network` and the `state_*` and `tenant_state_*`
checks. The database uses them in policies. The client never calls them.

A unit test in B1 (`rpc-map.test.ts`) reads the generated
`database.types.ts` and fails if a function exists that this section does not
name, so the map cannot silently go stale.

## 7. Write path and the error contract

Two write paths, both under the user's JWT, both in `src/shared/network/`:

```ts
rpc<N extends RpcName>(name: N, args: RpcArgs<N>): Promise<Result<RpcReturn<N>>>;      // supabase.rpc
gateway<G extends GatewayName>(name: G, body: GatewayBody<G>): Promise<Result<GatewayReply<G>>>; // functions.invoke
```

The names and argument types come from `database.types.ts`
(`pnpm exec supabase gen types typescript --local`) and a hand-written
`gateways.ts` that mirrors each gateway's Zod schema. Every write takes a
UUID v4 `p_idempotency_key` (or `idempotency_key` in a gateway body) first.
The client never sends a tenant id (`set_active_tenant` excepted), a
`tenantId` header or the service key.

**`errors.ts` normalises by SQLSTATE, not by HTTP status.** Gateways already
map §3.5 to HTTP. PostgREST does not (it returns `P0001` as 400, `40001` as
500 and `TF001` as 400), so a direct RPC error is classified from its `code`:

| Code | Class | Queue |
|---|---|---|
| `P0001` (422) | business rule | terminal → Needs attention |
| `42501` (403) | forbidden | terminal |
| `23505`, `TF001`, `TF002` (409) | conflict, stock (with `{sku_code, available, requested}`), key reuse | terminal |
| `40001`, `55P03` (503), 5xx, network, timeout | transient | retry, same key |
| 401 / expired JWT | session | refresh once, then retry; if the refresh fails, sign out |

The normalised shape is `{ code, http, message, details, terminal }`, as Spec
A's `{ error: { code, message, details } }`. Messages are database copy and
are shown as written.

## 8. The offline queue (Spec A §7, made concrete)

```ts
type QueuedMutation = {
  id: string;              // UUID v4, IS the idempotency key, made at enqueue
  kind: "rpc" | "gateway";
  operation: string;       // an RPC or gateway name from §6
  payload: unknown;        // Zod-validated at enqueue
  userId: string;          // who enqueued it
  tenantId: string | null; // the active tenant at enqueue
  dependsOn?: string;      // the id it must follow
  attempts: number;
  nextAttemptAt: number;
  enqueuedAt: number;      // device time, display only
  lastError?: { code: string; message: string; terminal: boolean };
  status: "PENDING" | "IN_FLIGHT" | "TERMINAL" | "DONE";
};
```

- **Enqueue:** each queueable operation registers a Zod schema in its
  feature's `services/`. An invalid payload throws in the user's hands and
  is never queued.
- **Drain:** FIFO within a `dependsOn` chain, parallel across chains (at most
  4 in flight). Backoff runs from 2 s to 5 min (doubling, with jitter). Only
  entries whose `userId` and `tenantId` match the live session are sent,
  because the server takes the tenant from the JWT. A terminal error moves the
  entry and everything that depends on it to Needs attention. The user can
  retry it (same key), edit and resend it (new key) or discard it.
- **Queueable:** field writes Spec C marks offline-safe (Spec A §7.4: the
  retail pickup path and its kin), chat posts, `mark_chat_read`.
- **Online only, never queued, a fresh key per attempt:** anything with a PIN
  or a code (`change_tenant_pin`, `set_tenant_pin`, delivery and owner codes,
  OTP), Paystack (`monvelo-fund`), upload slots, `accept_tenant_invitation`,
  `decline_tenant_invitation`, `set_active_tenant`, `approve_*` and
  `decide_*`. A wrong PIN or code comes back as data (`changed:false`,
  `WRONG_PIN`), and the stored request omits the secret, so reusing a key
  would replay the first answer.

## 9. Auth, invitations, tenancy and the PIN

1. **Sign-in (email first):** `signInWithOtp({ email, options: { shouldCreateUser: false } })`.
   The hook sends a 6-digit code (never a link) only to a known person
   (otherwise the hook's 403 is shown as "This email has no Teafair access").
   Then `verifyOtp({ email, token, type: "email" })`. Resend after 60 s.
2. **Claims are hints.** `decodeClaims(access_token)` reads `app_metadata`
   (`tenant_ids`, `active_tenant_id`, `tenant_role`, `platform_role`) to pick a
   route. It never authorises anything; the database re-checks every call.
3. **Routing:**
   - `active_tenant_id` set → the PIN gate → the role shell (§10).
   - No tenant, but invitations → onboarding. `list_my_invitations()` shows
     tenant name and code, role and place. Accept runs
     `accept_tenant_invitation(key, tenant_user_id)` → `refreshSession()`
     (the reply says `refresh_session: true`). Decline runs
     `decline_tenant_invitation(key, tenant_user_id)`.
   - No tenant, no invitation, but a Monvelo agent membership → the Monvelo
     agent shell.
   - Only a platform role → "Use TeafairWeb" (operators and finance work
     there).
   - Nothing → "No access yet".
4. **Tenant switch:** the tenant switcher lists `tenant_ids` (names from
   `tenants` under RLS). It runs `set_active_tenant(key, tenant_id)` →
   `refreshSession()` → `runResets("tenant")` (§5).
5. **The PIN gate:** `get_my_pin_status()` → `{tenant_user_id, pin_set, locked_until}`.
   - Without a PIN, the user enters 4 digits twice (Tier 3). The client
     pre-checks the server's rule (`pin_policy_refusal`: not one digit
     repeated such as `7777`, not a run up or down such as `1234` or `6543`),
     then calls `set_tenant_pin(key, new_pin)`.
   - Change: `change_tenant_pin(key, current_pin, new_pin)` with a **fresh
     UUID v4 key on every attempt**. `{changed:false, attempts_remaining, locked_until}`
     is shown, not thrown. Five wrong attempts lock for 15 minutes.
   - Each membership has its own PIN, so a tenant switch re-runs the gate. A
     forgotten PIN has no reset path yet (a backend gap; the screen says to
     ask the ZSM).

## 10. Role shells

| Shell | Roles | Home |
|---|---|---|
| Field manager | `ZSM`, `ASM`, `TM`, `DSM` | team, territories, approvals, chat |
| Field agent | `DSA`, `ZSA`, `ASA` | today's route, shops, orders; ZSA/ASA also Monvelo holds and nominations |
| Logistics | `LOGISTICS_MANAGER` | dispatch queue, deliveries |
| Shop | `RETAIL_SHOP_OWNER` | my shops, pickups to confirm, Monvelo consent |
| POS | `POS_AGENT` | referral codes, order lookup |
| Monvelo agent | agent members (no tenant needed) | offers, pledges, fundings, repayments, exposure meter |
| Read-only | `CLIENT_SERVICE_MANAGER`, `TENANT_ADMIN` | a summary and a link to TeafairWeb, where their work is |

B3 builds each shell's navigation, header (tenant chip, switcher, sync
status, Needs attention count) and empty states. Spec C and D fill them.

## 11. Slices, each verified with Playwright

Playwright runs the **Expo web build** of the app (`pnpm exec expo export -p web`,
served statically) against the local Supabase stack, in two projects:
`phone` (390×844) and `tablet` (768×1024). Config: `playwright.app.config.ts`;
tests: `tests/app/`. They run from VS Code (Playwright Test extension) or
`pnpm test:app`. The existing API run (`playwright.config.ts`, `tests/api/`)
is unchanged. Sign-in codes in tests come from the local stack's test
helper (Admin API in the test process, never in `src/`).

On web, `secure.ts` keeps the session in memory and MMKV uses its web
backend. Playwright therefore proves layout, navigation, flows and the
queue's logic, not the native storage. Each slice also has Jest unit tests
(`jest-expo`) and a short device check on one iOS and one Android device
before it closes.

| Slice | Builds | Playwright proves (phone and tablet) |
|---|---|---|
| **B1** Scaffold | the pnpm app package and Expo Router; `database.types.ts`; `tokens/` and the NativeWind preset; `secure.ts`, `mmkv.ts`, the reset registry; `rpc()`, `gateway()`, `errors.ts`; `decodeClaims`; `log`/`scrub`; `shared/ui/` primitives on a gallery route; the guards (`tokens.guard`, `rpc-map`, the import rules) | the primitives gallery renders at both sizes with no horizontal scroll and visible safe areas; screenshots match baselines; the gallery's colours are the `FIGMA.md` values (read from computed styles) |
| **B2** Auth and onboarding | email OTP screens, invitation list (accept/decline), PIN set and change | an invited user signs in with a code, accepts, and lands on the PIN gate; a weak PIN (`7777`, `1234`, `6543`) is refused before sending; a wrong current PIN shows the attempts left; a decline leaves "No access yet"; an unknown email sees the access message |
| **B3** Tenancy and shells | tenant switcher, every shell of §10, the header | a user with two memberships switches and the previous tenant's lists are gone; each role lands on its shell; tablet shows two columns where the shell has a list and a detail; the switch is refused while the queue holds entries |
| **B4** Queue, A5 and realtime | the queue and Needs attention; the fulfilment wrappers (`order-dispatch`, `order-delivery-pin`, `order-delivery-photo`, `order-delivery-confirm`); the Monvelo funding wrapper (`monvelo-fund`, `MONVELO_CHECKOUT_LOST`); the realtime client | offline (context set offline) a chat post queues, then lands once with the same key when back online; a `P0001` lands in Needs attention with the database copy; a dependent entry waits for its parent; a wrong delivery code shows 422 copy and the next entry uses a new key; a chat message from a second user appears live; after a tenant switch no event from the old tenant arrives |

**Realtime:** subscribe to `chat_messages` with `channel_id=eq.<id>` and to
`chat_channels` with `tenant_id=eq.<active tenant>` (every post updates
`chat_channels`). Ticket headers are tenant-wide (A3), so filter
`support_tickets` by `tenant_id=eq.` too. RLS still decides delivery. The
client unsubscribes everything through the reset registry.

**A5 in the app.** Delivery is confirmed only through `order-delivery-confirm`
(422 for a wrong or locked code), with a fresh key per code entry. A
delivery photo needs a slot (`order-delivery-photo`), then the upload to the
signed URL, then the confirm that names it. A staff photo on a ticket needs
the slot (`support-staff-attachment`), the upload, then `reply_ticket` with
the attachment ids. The buyer's flow belongs to TeafairWeb's storefront: open
the ticket, request the attachment, upload, then post the message. So does
verified checkout: `checkout-phone-verify-start`, then `-confirm`, then
`web-checkout` with the single-use token, which lasts 30 minutes.

## 12. Out of scope

Spec C screens (orders, requisitions, pickups, routes), Spec D money screens,
push delivery (beyond `register_device`), the Windows HQ client, a PIN
reset, re-inviting a decliner, and TeafairWeb itself (its own repository;
§2 and §6 are its contract).
