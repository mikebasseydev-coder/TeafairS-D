# Spec B — The Client (Teafair RTM app shell)

**Status:** draft under review, not approved. `src/` stays frozen; slices
B1–B4 (§11) wait on approval. The Monvelo rulings of 2026-11-27 are built
(A6 §23, local) and §6 follows them.
**Authority:** Spec A
(`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`)
and its addenda A1–A8 (A6 through §23) still govern the backend. Where this spec and Spec A
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
│   ├── tokens/               primitives.ts (the emblem palette, the only hex values), semantic.ts, themes, the NativeWind preset (§4.2)
│   ├── ui/                   primitives and skeletons, exported by ui/index.ts (§4.3)
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

### 4.1 Visual direction

Two layouts, chosen by what the screen is for. Every screen still follows
`.claude/awards-mobile-workflow.md` (references, three concepts, the 8/10
critique), within these rules.

- **Swiss Minimal: queues, ledgers, lists and forms.** This covers the
  offline queue and Needs attention, orders, shops, financings, holds,
  repayments, invitations, the PIN and every form.
  - A 4-point grid with 8-point rhythm, and left-aligned text.
  - One type family: the platform system font, so nothing loads.
  - A fixed scale of 12, 14, 16, 20, 24 and 32. Money and counts use
    tabular numerals.
  - Hierarchy comes from size, weight and spacing, not colour. One accent
    per screen, used for its primary action or its live state.
  - 1-pixel hairlines and plain fills. **No shadows, blurs, gradients or
    translucent layers on these screens**, so they stay fast on mid-range
    Android phones.
- **Bento Grid: dashboards and multi-metric overviews.** This covers the
  ZSA/ASA field dashboard (`get_monvelo_field_dashboard`), the TM oversight
  read (`get_monvelo_tm_oversight`), the Monvelo agent's exposure and
  reconciliation, and the field manager's home.
  - **Tile sizes:** 1×1, 2×1 and 2×2.
  - **Phone (390×844):** a 2-column grid; 2×2 tiles span the width.
  - **Tablet (768×1024 and wider):** a 4-column grid; landscape keeps the
    grid and adds a detail pane.
  - **Each tile is isolated.** It owns its query, loading state, error and
    empty state, so one failing read shows its own retry and every other
    tile renders. Financial tiles follow §5: they show "Unavailable
    offline", never a cached figure.
  - Gaps are 12. Tiles are surface fills with a hairline border, never
    shadows.
- **Workflows stay utilitarian.** Monvelo requests, claims, funding, delivery
  and repayment codes, and the fulfilment screens (dispatch, delivery code,
  delivery photo) are step lists and forms in the Swiss rules.
  - No decoration and no illustration.
  - The state of each step is in words and a tone (§4.2), never colour alone.
  - The cutoff (§6.2) is shown as a time, "Requests close 15:00 Lagos".
  - The owner's code entry follows §5 Tier 3.
- **Brand moments are few.** The FIGMA.md gradients and the emblem appear
  only on the sign-in screen, the splash and empty states; the emblem also
  appears small in the shell header. Never in a list, a form or a workflow.
- **The emblem is an asset, not a drawing.** `assets/branding/teafair-logo.png`
  is canonical. Its marks are a scalloped green seal, a thin inner ring, a
  white field, and a leaf rising from the black `TF` monogram. The
  `Emblem` component in `shared/ui` renders that artwork (through its
  transparent master, §4.6) at fixed sizes (24 dp tab bar, 32 dp or more
  elsewhere) with clear space of one eighth of its diameter. It is never
  recoloured, redrawn in code, stretched or cropped. The rules and the
  sampled colours are in FIGMA.md §0.

### 4.2 Tokens: primitives, then semantics

Two layers in `src/shared/tokens/`, and **the only hex values in the app**:

- **`primitives.ts`, the Teafair emblem palette.** Fixed names, no meaning:

  | Primitive | Hex | Note |
  |---|---|---|
  | `teafair-leaf` | `#629E28` | primary leaf green |
  | `teafair-botanical` | `#1B3624` | secondary botanical dark |
  | `teafair-amber` | `#D97706` | accent |
  | `teafair-canvas` | `#F4F6F9` | app background |
  | `teafair-white` | `#FFFFFF` | surfaces |
  | `teafair-scrim` | `#111827` at 35% | modal and sheet overlay |
  | `teafair-ink` | `#0F172A` | primary text |
  | `teafair-slate` | `#64748B` | secondary text |
  | `teafair-mist` | `#E2E8F0` | hairlines |
  | `teafair-red` / `teafair-red-soft` / `teafair-red-tint` | `#B91C1C` / `#F87171` / `#FEF2F2` | danger (light / dark / subtle background) |
  | `teafair-blue` / `teafair-sky` / `teafair-blue-tint` | `#0369A1` / `#38BDF8` / `#F0F9FF` | info (light / dark / subtle background) |

  `FIGMA.md` is the single source of these values, with the full contrast
  table, the semantic table per theme and the tone table. This section is
  the contract that uses them.

- **`semantic.ts`, what components use.** Each semantic token resolves to a
  primitive per theme. The NativeWind preset exposes them as CSS variables,
  so a theme switch is a variable swap, not a re-render of every class:
  - `bg-canvas`, `bg-surface`, `bg-scrim`;
  - `text-ink`, `text-ink-muted`, `text-on-action`;
  - `border-hairline`, `border-control`;
  - `bg-action`, `bg-action-strong`, `ring-focus`;
  - and one family per tone: `bg-tone-<tone>`, `bg-tone-<tone>-subtle`,
    `text-tone-<tone>`, `border-tone-<tone>`.

**`SemanticTone`** is `"neutral" | "brand" | "success" | "warning" |
"danger" | "info" | "pending"`. Components take a tone, never a colour:
`<Badge tone="warning">`, `<Banner tone="danger">`. **Domain statuses reach
a tone only through a typed adapter** that lives in the feature that owns
the status. Each adapter is an exhaustive `Record<Status, SemanticTone>`, so
a new database status breaks the type check until someone maps it:

```ts
// src/features/monvelo/components/financing-tone.ts
export const financingTone: Record<FinancingStatus, SemanticTone> = {
  REQUESTED: "pending", AWAITING_APPROVAL: "pending", OFFERED: "info", HELD: "warning",
  CLAIMED: "brand", FUNDED: "brand", DELIVERED: "brand", REPAID_WITHIN_WINDOW: "success",
  REPAID_LATE: "warning", DEFAULTED_WITH_LATE_CHARGE: "danger", REFUND_DUE: "danger",
  CLOSED_BY_CLAIM: "neutral", EXPIRED: "neutral", CANCELLED: "neutral",
};
```

`FinancingStatus` comes from the database CHECK, through the generated types
or a Zod enum checked against them. The queue has `queueTone`
(PENDING → pending, IN_FLIGHT → info, TERMINAL → danger, DONE → success).
Orders, tickets and holds get theirs in Spec C and D.

**Contrast rules.** These are measured WCAG 2.1 ratios, and the semantic
layer encodes them so a component cannot break them:

- **Body text** is `text-ink` (`#0F172A`: 17.85:1 on white, 16.49:1 on
  canvas).
- **`text-ink-muted`** (`#64748B`) is 4.76:1 on surfaces but 4.40:1 on the
  canvas. On the canvas, muted text is 14 px semibold or larger, or uses
  `text-ink`.
- **Leaf green (`#629E28`) is a fill and an indicator, not small text.**
  White on it is 3.26:1, enough only for large text and non-text marks
  (3:1). So `bg-action` (leaf) carries `text-on-action` = ink (5.48:1).
  `bg-action-strong` (botanical `#1B3624`, white text 13.13:1) is the
  default primary button. A leaf CTA with a white label is allowed only at
  18 px bold or larger.
- **Amber (`#D97706`)** carries ink, never white: ink 5.60:1, white 3.19:1.
- **`border-hairline`** (mist, 1.23:1) only separates. **Input boundaries,
  checkboxes and focus use `border-control` and `ring-focus`** (slate,
  4.76:1), which meet the 3:1 non-text rule.
- **Danger and info (ruling 2026-11-27).** On light themes, `danger` text is
  red (`#B91C1C`: 6.47:1 on white, 5.98:1 on canvas, and white on red is
  6.47:1). `info` text is blue (`#0369A1`: 5.93:1 and 5.48:1, and white on
  blue is 5.93:1). Red and blue fail on the dark surfaces (2.03–3.01:1), so
  the `dark` theme uses red-soft (`#F87171`, 4.75:1 on botanical) and sky
  (`#38BDF8`, 6.13:1). Success and brand text is botanical, and warning
  text is ink: their colour is carried by the icon and border.
- **Status is never colour alone.** `Badge` and `Banner` require a tone, a
  label in words and an icon, and there is no colour-only variant. Each tone
  has a fixed icon (FIGMA.md §3): neutral a dot, brand a leaf, success a
  check, warning an exclamation triangle, danger an exclamation octagon,
  info an "i" in a circle, pending a clock. `StatusDot`-style indicators
  without text are not part of `shared/ui`.

**Themes** (`usePrefsStore.theme`, Tier 2 at the user level, §5):

- **`standard`:** canvas, white surfaces, ink. The default for the
  operational and tenant roles (ZSM, ASM, DSM, DSA, LOGISTICS_MANAGER,
  CLIENT_SERVICE_MANAGER, TENANT_ADMIN) and for Monvelo agent members.
- **`daylight`:** high contrast for outdoor field work. The default for ZSA,
  ASA, TM, RETAIL_SHOP_OWNER and POS_AGENT.
  - Surfaces and canvas are white.
  - `text-ink-muted` resolves to ink, and hierarchy comes from weight alone.
  - `border-hairline` resolves to slate.
  - Tone fills use their strong values, and touch targets stay at 48 px.
- **`dark`:** for analytical views (dashboards, ledgers, reconciliation), by
  the user's choice. Canvas is ink, surfaces are botanical, text is canvas,
  and muted text is mist (14.48:1 on ink, 10.65:1 on botanical); `border-control` resolves to mist, because slate on botanical is 2.76:1. Leaf stays the action colour: ink
  on leaf is 5.48:1. The FIGMA.md dark gradient is used only in brand
  moments.

**The role default applies until the user picks a theme** (ruling
2026-11-27). The default is taken from the active membership's role. Any
choice is saved in `usePrefsStore` (user level, Tier 2) and wins over the
default in every tenant. Clearing it returns to the role default. The shell
header has a quick toggle, and analytical views offer `dark` without
changing the saved choice for the rest of the app. Every primitive pair a theme uses is listed in
`tokens/contrast.test.ts` with its minimum ratio. The test fails on any pair
below 4.5:1 for text, or below 3:1 for non-text.

**Zero raw colour in components.** There are no hex, `rgb()` or `hsl()`
literals, and no stock palette classes (`emerald-500`, `slate-900`, …),
anywhere outside `src/shared/tokens/`. Components and screens use semantic
classes only. A `teafair-*` primitive class appears only in `tokens/` and in
the emblem component. ESLint and `tokens.guard.test.ts` enforce it; the
guard scans `src/` for `#[0-9a-fA-F]{3,8}\b`, colour functions, stock
palette names and primitive classes outside the allowed files.

**FIGMA.md and this section agree** (§4.5, ruling 1). A change to a value is
made in FIGMA.md and `src/shared/tokens/` together, with `contrast.test.ts`
updated in the same commit.

### 4.3 Components and skeleton loading

**`src/shared/ui/`** holds the primitives, all exported through
`src/shared/ui/index.ts`:

- `Button`, `Field`, `PinPad`, `OtpInput`, `Card`, `Banner`, `Badge`,
  `Sheet`, `ListRow`, `EmptyState`, `SyncIndicator`;
- `BentoGrid` and `BentoTile`;
- the skeleton primitives: `Skeleton` (one block), `SkeletonText` (lines),
  `SkeletonListRow` (the `ListRow` footprint) and `SkeletonTile` (the
  `BentoTile` footprint). Each takes `variant: "pulse" | "shimmer"`.

Feature-specific skeletons, such as `FinancingCardSkeleton` or
`HoldListSkeleton`, live in `src/features/<feature>/components/`. They are
built from those primitives and exported through the feature's `index.ts`.

**The two variants:**

- **`pulse`** (the default) is a NativeWind opacity pulse on a plain block,
  no gradient. It is used for dense and high-frequency lists (queues,
  orders, shops, holds, ledgers), where many rows animate at once on
  mid-range Android. List skeletons render 4–6 placeholder rows, never a
  full screen of them.
- **`shimmer`** uses `moti` (`moti/skeleton`, already a dependency; it runs
  on `react-native-reanimated`, pinned with the Expo SDK at B1). It is used
  only for one-off hero, header and detail surfaces: a financing's header,
  a dashboard's hero tile, a shop's profile. **At most one shimmer region
  per screen.**
- **Both** use the semantic skeleton tokens (`bg-skeleton`,
  `bg-skeleton-highlight`, per theme). Both stop animating when the OS
  reduce-motion setting is on, and are hidden from screen readers. The
  region announces "Loading" once.

**When a skeleton shows** is decided by explicit fetch state, never by
`data == null`:

- Each query hook returns `{ status, isLoading, isRefreshing, isHydrated, items, error }`.
  A list shows its skeleton only while `isLoading && items.length === 0`. A
  tile or detail shows it only while `isLoading && !hasData`.
- **Pull-to-refresh and background sync keep the visible items.** The
  platform refresh control shows progress and the content never blanks.
- **Cached or offline data is shown, not blocked.** The `SyncIndicator` in
  the header (or on the tile) says "Offline, showing data from 10:42", or
  "Syncing". Financial figures are the §5 exception: they show
  "Unavailable offline".
- **Skeletons and spinners never mix on one surface.** A spinner appears
  only inside a pressed button while its write is in flight.
- **Skeletons match the final layout's dimensions** (row height, tile span,
  text line widths), so nothing shifts when the data arrives. Each skeleton
  sits next to its component and shares its size constants.
- **An error or an empty result replaces the skeleton** with the component's
  own `Banner` or `EmptyState`, in the same footprint.

### 4.4 Security in the client (Ruling 46)

- The app holds only `EXPO_PUBLIC_SUPABASE_URL` and
  `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (the `sb_publishable_` key, or the
  anon key until it is retired). No secret, ever. The existing
  `secret-scoping` test already scans `src/`.
- `log.ts` is the only logger. It runs every message and context object
  through `scrub.ts`, which follows `_shared/core/scrub.ts`. Values under
  sensitive keys are dropped (pin, otp, code, token, secret, phone, email,
  address, hash, `p_` parameters). Strings are scrubbed of JWTs, emails and
  phone numbers. It never logs a queued payload.
- No PIN, OTP, owner code, token or checkout URL is ever written to MMKV, to
  a Zustand `persist` store, to a log or to an error report. §5 says where
  each one lives.

### 4.5 Rulings on the open items (2026-11-27)

1. **FIGMA.md follows the emblem palette.** It was rewritten to the §4.2
   primitives and the semantic contract, and is now the single source of
   the values. The old names (`teafair-emerald`, `-lime`, `-forest`,
   `-black`, `-surface`, `-darkSurfaceEnd`) are retired.
2. **Danger and info have their own accessible primitives** (red and blue,
   plus dark-theme and subtle variants). Every badge and banner carries a
   label in words and an icon.
3. **Theme defaults:** `daylight` for ZSA, ASA, TM, RETAIL_SHOP_OWNER and
   POS_AGENT; `standard` for the operational and tenant roles; `dark` on
   request for analytical views. The user's preference always overrides.
4. **The emblem asset** is `assets/branding/teafair-logo.png` (FIGMA.md §0).
   Its greens (leaf `#70B123`, seal `#52801D`) stay in the artwork: the
   leaf is 2.62:1 on white, so the UI keeps `teafair-leaf` `#629E28`.

### 4.6 Open item before B1

**A transparent emblem master.** The canonical PNG is 24-bit with opaque
black outside the seal, so on any light background it shows as a black
square. B1's `Emblem` component, the splash and the app icon need
`assets/branding/teafair-logo.svg` (preferred) or a transparent PNG of 1024 px
or more, cut from the same artwork. Until it exists, the gallery shows the
emblem only on the `dark` theme.

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
| `usePrefsStore` | shell | 2 (user level) | theme (`standard`, `daylight`, `dark`; the role default until chosen, §4.2), list density, tabs |
| `useMonveloCheckoutStore` | monvelo | 3 | the funding checkout of the open financing |

## 6. RPC and gateway map

**Surfaces:** App = Teafair RTM; Web = TeafairWeb; GW = only through the
named gateway (never call the RPC directly); Sys = cron, webhook or service
role, never a client. The map follows the migrations to `20261127130300`
(A6 §23, 2026-11-27).

**Scope words used below** (the database checks each one live; the client
only uses them to decide what to show):

- **ZSA scope:** every area of the zone in the ZSA's own `tenant_users.zone_id`.
- **ASA scope:** the ASA's own `tenant_users.area_id`.
- **TM scope:** the TM's own territory.
- **Agent member:** an ACTIVE row in `monvelo_agent_members`. It needs no
  tenant.
- **Platform roles:** `MONVELO_OPERATOR`, `MONVELO_FINANCE` and
  `PLATFORM_SUPER_ADMIN`, read live from `profiles.platform_role`.
- **Decision:** `p_decision_id`, a citable contact-report decision of the
  named subject (A6 §16.4; pgTAP 049 fails any guarded writer without one).
- **No Monvelo RPC accepts ASM** (A6 §23.1). The ASM reads no Monvelo
  financing, and the client shows ASM no Monvelo screen.

### 6.1 User gateways (all 15), the app's or the admin portal's

| Gateway | RPCs behind it | Feature | Surface | Notes |
|---|---|---|---|---|
| `otp-issue` | `issue_otp` | field | App | shop-owner OTP (pickup, POS settlement), to the owner's verified phone |
| `otp-verify` | `verify_otp` | field | App | |
| `order-dispatch` | `mark_order_dispatched`, `mark_delivery_pin_sent` | fulfilment | App | LM or ZSM |
| `order-delivery-pin` | `resend_delivery_pin`, `mark_delivery_pin_sent` | fulfilment | App | |
| `order-delivery-photo` | `request_delivery_photo` | fulfilment | App | slot → upload → confirm |
| `order-delivery-confirm` | `mark_order_delivered` | fulfilment | App | fresh key per code entry; 422 `WRONG_PIN`/`LOCKED` |
| `order-dispute-evidence` | `get_order_dispute_evidence` | support | Web | ZSM; audited view |
| `support-staff-attachment` | `request_staff_ticket_attachment` | support | App, Web | slot, upload, then `reply_ticket` |
| `contact-report-upload` | `request_contact_report_hard_copy` | (admin) | Web | CSM |
| `monvelo-agent-register` | `monvelo_agent_register_preflight`, `register_monvelo_agent`, `request_monvelo_settlement_change` | monvelo | App | ZSA or ASA; Paystack account check. The body may carry `partner_kind` (`LIQUIDITY_PARTNER`, the default, or `RETAIL_INDEPENDENT_PARTNER`); the reply carries the platform `partner_code` |
| `monvelo-shop-consent` | `start_monvelo_consent`, `enrol_monvelo_shop`, `start_monvelo_policy_consent`, `submit_monvelo_shop_policy` | monvelo | App | ZSA (scope) or ASA (scope); **the owner's code by email** |
| `monvelo-fund` | `start_monvelo_funding`, `record_monvelo_checkout` | monvelo | App | the claimant's agent member; 409 `MONVELO_CHECKOUT_LOST` → new key, start again |
| `monvelo-confirm-delivery` | `start_monvelo_delivery`, `confirm_monvelo_delivery` | monvelo | App | a delivery-path holder of the order (R20); **the owner's code by email**; fresh key per entry |
| `monvelo-confirm-repayment` | `record_monvelo_repayment`, `confirm_monvelo_repayment` | monvelo | App | the funder's agent member who recorded it (R32); **the owner's code by email**; fresh key per entry |
| `monvelo-cover-upload` | `can_upload_monvelo_cover` | monvelo | App, Web | ZSA/ASA, LM, CSM; policy and claim evidence uploads |

**The owner's Monvelo codes go by email (A6 §23.6).** The four codes go to
the owner's verified sign-in email (`auth.users.email`, confirmed): consent,
policy consent, delivery and repayment. The gateway sends them through
Resend (`RESEND_API_KEY` required; `MONVELO_EMAIL_FROM` optional, else
`AUTH_EMAIL_FROM`, else the sandbox sender). They never go by WhatsApp or SMS, and never to the shop's contact details.

- **The reply** carries `challenge_id`, `expires_at` and a masked
  `destination` (`o***@e***.com`), never the code. The app shows "Ask the
  owner to read the code from their email".
- **A failed send** is 502 `MESSAGE_DELIVERY_FAILED`: start again with a new
  key.
- **A replayed start** sends nothing.
- **An owner without a verified email** is refused before any code: P0001
  "the shop owner has no verified email".
- **Unchanged:** `otp-issue` and the A5 web delivery PIN.

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

| Feature | RPCs | Who (checked live) | Surface |
|---|---|---|---|
| auth / tenant (B2–B3) | `list_my_invitations`, `accept_tenant_invitation`, `decline_tenant_invitation`, `set_active_tenant`, `get_my_pin_status`, `set_tenant_pin`, `change_tenant_pin`, `verify_pin` (guard, no key) | the signed-in person | App, Web |
| notifications | `register_device` | the signed-in person | App |
| platform admin | `provision_tenant`, `appoint_client_service_manager`, `appoint_zone_manager`, `create_zone`, `set_zone_zsm`, `set_state_operational` | `PLATFORM_SUPER_ADMIN` | Web |
| tenant structure | `invite_tenant_user`, `upsert_zone`, `upsert_territory`, `upsert_area`, `set_territory_coverage`, `set_territory_web_warehouse`, `set_web_defaults`, `set_brand_approval_policy`, `set_tenant_operational_state` | ZSM in reach (§18.3); `upsert_area` also the TM of its territory; `set_tenant_operational_state` cites a DISTRIBUTION decision | Web |
| contact reports | `file_contact_report`, `review_contact_report`, `attach_contact_report_hard_copy` | CSM files and attaches; a ZSM reviews (an operator while the tenant has no ZSM) | Web |
| catalogue | `upsert_catalogue_product`, `upsert_tenant_skus` | CSM + CATALOGUE decision | Web |
| stock | `post_opening_stock`, `record_stock_receipt`, `record_stock_transfer`, `record_stock_adjustment`, `record_order_return` | CSM or LM + STOCK decision (`record_order_return` cites the order) | Web (LM may also use App for returns, Spec C) |
| web referral (POS) | `upsert_web_referral_code`, `set_web_pos_venue`, `pos_order_lookup` | POS agent, ZSM | App |
| field (Spec C) | `place_trade_order` | ZSA, ASA or TM, on their beat | App |
| support (A3/A5) | `claim_ticket`, `reply_ticket`, `update_ticket_status`, `set_ticket_priority`, `assign_ticket`, `redact_ticket_customer_data` | the ticket's handlers (A3) | App, Web |
| tenant tickets (A7) | `open_tenant_ticket`, `reply_tenant_ticket`, `claim_tenant_ticket`, `release_tenant_ticket`, `assign_tenant_ticket`, `update_tenant_ticket_status` | TENANT_ADMIN, CSM, `MONVELO_OPERATOR` | Web |
| chat (A4) | `list_my_chat_channels`, `get_or_create_direct_channel`, `post_chat_message`, `mark_chat_read`, `hide_chat_message` | staff; ZSM moderates | App |
| monvelo, field activation (ZSA scope, ASA scope) | `get_monvelo_field_dashboard`, `monvelo_field_partners_near`, `pair_monvelo_shop_agent`, `unpair_monvelo_shop_agent`, `nominate_monvelo_agent`, `close_monvelo_nomination`, `request_monvelo_financing`, `cancel_monvelo_financing`, `list_monvelo_claim_holds`, `get_monvelo_claim_hold`, `decide_monvelo_claim_hold`, `get_lender_reconciliation_summary`, `report_monvelo_loss` | ZSA, ASA (see the notes below); `report_monvelo_loss` also the LM or CSM for GIT; never ASM | App |
| monvelo, TM (TM scope) | `get_monvelo_tm_oversight`, `set_monvelo_supply_day`, `approve_monvelo_financing`, `request_monvelo_financing`, `cancel_monvelo_financing` | the territory's TM | App |
| monvelo, agent members | `pledge_monvelo_funds`, `monvelo_supply_days_near`, `monvelo_open_offers`, `get_monvelo_offer_cover`, `claim_monvelo_financing`, `get_monvelo_agent_exposure`, `get_lender_reconciliation_summary`, `accept_monvelo_agent_terms` | ACTIVE members of the agent (liquidity partners for pledges, so for everything that follows) | App |
| monvelo, shop owner | `nominate_monvelo_agent`, `withdraw_monvelo_shop_consent`, `reject_monvelo_repayment` | the shop's owner (RETAIL_SHOP_OWNER) | App |
| monvelo, fulfilment | `dispatch_monvelo_financing` | whoever passes `fulfilment_can_dispatch` (LM and kin) | App |
| monvelo, shared reads | `monvelo_today`, `monvelo_request_supply_date`, `monvelo_order_cutoff_at`; `monvelo_order_financing_status` (a tenant member; an owner sees only their shops' orders) | any signed-in person | App, Web |
| monvelo, tenant side | `propose_monvelo_brand_terms`, `approve_monvelo_brand_terms`, `withdraw_monvelo_brand_terms`, `set_monvelo_tenant_settings`, `accept_monvelo_tenant_terms` | ZSM proposes; CSM (ZSM while no CSM) approves, withdraws and sets, + BRAND_TERMS or MONVELO_SETTINGS decision | Web |
| monvelo, platform staff | `approve_monvelo_agent`, `suspend_monvelo_agent`, `set_monvelo_agent_caps`, `add_monvelo_member`, `approve_monvelo_settlement_change`, `review_monvelo_flag`, `review_monvelo_shop_policy`, `withdraw_monvelo_shop_policy`, `monvelo_agents_near`, `record_monvelo_fee_terms` (+ FEES decision), `register_monvelo_insurer`, `set_monvelo_insurer_status`, `propose_monvelo_insurance_product`, `approve_monvelo_insurance_product`, `withdraw_monvelo_insurance_product`, `file_monvelo_insurance_claim`, `set_monvelo_claim_status`, `record_monvelo_claim_settlement`, `close_monvelo_insurance_claim`, `record_monvelo_declaration_outcome`, `report_monvelo_loss` | `MONVELO_OPERATOR`; `record_monvelo_premium_paid` and `record_monvelo_topup_paid` are `MONVELO_FINANCE` | Web |

**What §23 adds for the field (A6 §23.1, §23.4):**

- **The dashboard.** `get_monvelo_field_dashboard()` is a read, so it takes
  no key. It covers the caller's scope in the active tenant: enrolled, paired
  and unpaired shops; open nominations; the pipeline by status; pledged funds
  through the next supply date with its cutoff; holds awaiting the caller;
  their own recruits with code, kind and status; and their pairing activity.
- **Partners.** Under RLS a ZSA or ASA now reads only the partners in their
  scope (paired with a shop enrolled there, or pledged to it) and their own
  recruits, not every agent on the platform. They read every financing in
  their scope, not only those they raised.
- **Pairing.** `monvelo_field_partners_near(shop, radius_m)` lists the ACTIVE
  liquidity partners near a shop in scope (default 1,000 m, at most
  5,000 m). `pair_monvelo_shop_agent(key, shop, agent)` refuses:
  - a shop outside the caller's scope (42501);
  - a partner the caller belongs to (42501);
  - a retail independent partner (42501);
  - a shop already paired (P0001: unpair it first).

  `unpair_monvelo_shop_agent(key, shop, reason)` needs a reason of 10 to 500
  characters and opens the shop's live offers to every partner at once. A
  RECRUITED nomination also pairs the shop.
- **TM oversight.** `get_monvelo_tm_oversight(p_days 1..366)` is the TM's
  read over the territory's ASAs and the zone's ZSAs. Per field agent it
  counts shops enrolled, partners recruited, pairings made and undone, holds
  allowed and declined, and financings raised. It names no partner, and the
  TM reads no pairing row.
- **Partner kinds (A6 §23.2).** Every agent has an immutable `partner_code`
  (`MP-` plus 8 base32 characters, platform-wide, not a `web_referral_codes`
  row) and a `partner_kind`. Only a `LIQUIDITY_PARTNER` pledges, claims,
  funds and is paired. A `RETAIL_INDEPENDENT_PARTNER` has no action yet
  beyond registration and its code. The client shows it, but offers it no
  lending screen.

**The financing flow the client follows (A6 §23.3, §23.5):**

1. **Raise before the cutoff.** A request raised on Lagos day D is for supply
   date D + 1 (`monvelo_request_supply_date()`), and only before 15:00
   Africa/Lagos on D (`monvelo_order_cutoff_at(supply_date)`). After that:
   P0001 "today's Monvelo order cutoff (15:00 Lagos) has passed; raise the
   request tomorrow before the cutoff". The cutoff and the one-day lead are
   platform-wide. The supply date must be a supply day for the area.
2. **The owner must have a verified email.** Without one the request is
   refused (P0001 "the shop owner has no verified email").
3. **The TM approves above the limit, before the same cutoff.** After it:
   P0001 "the Monvelo order cutoff for this supply date has passed". A
   request left AWAITING_APPROVAL stays until the end-of-supply-day sweep
   expires it. The app shows it as waiting, not failed.
4. **The paired partner gets 10 minutes.** If it has pledged room for the
   supply date, the offer is exclusive to it (`preferred_window_ends_at`).
   After that, any liquidity partner within **200 m** of the shop may claim.
   The paired partner is exempt from the distance.
5. **Claim, fund, deliver, repay** run against the supply date's pledges
   until that day ends. Funding is settled by the Paystack webhook with the
   payer binding; the client never records a receipt. The financed order's
   stock is held through its supply date.

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

**RLS helpers, not features:** the `my_*` functions (including
`my_monvelo_field_area_ids` and `my_monvelo_field_agent_ids`), `is_*`,
`jwt_tenant_id`, `tenant_role`, `sees_shared_network` and the `state_*` and
`tenant_state_*` checks. The database uses them in policies. The client never
calls them.

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
| Field manager | `ZSM`, `ASM`, `TM`, `DSM` | team, territories, approvals, chat; the TM also Monvelo approvals, supply days and the oversight read (§6.2); ASM has no Monvelo screen |
| Field agent | `DSA`, `ZSA`, `ASA` | today's route, shops, orders; ZSA/ASA also the Monvelo field dashboard, pairing, nominations, requests and holds |
| Logistics | `LOGISTICS_MANAGER` | dispatch queue, deliveries |
| Shop | `RETAIL_SHOP_OWNER` | my shops, pickups to confirm, Monvelo consent (codes arrive by email) |
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
| **B1** Scaffold | the pnpm app package and Expo Router; `database.types.ts`; `tokens/` and the NativeWind preset; `secure.ts`, `mmkv.ts`, the reset registry; `rpc()`, `gateway()`, `errors.ts`; `decodeClaims`; `log`/`scrub`; `shared/ui/` primitives, skeletons (`pulse`, `shimmer`), `BentoGrid` and `Emblem` on a gallery route, in all three themes; the guards (`tokens.guard`, `contrast.test`, `rpc-map`, the import rules) | the primitives gallery renders at both sizes with no horizontal scroll and visible safe areas; screenshots match baselines in each theme; the gallery's colours are the §4.2 primitives through the semantic tokens (read from computed styles); a Bento tile in error leaves its neighbours rendered; a list skeleton has 4–6 rows and the same height as the loaded list |
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
