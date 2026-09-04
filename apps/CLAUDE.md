# CLAUDE.md (apps)

## Status

**Not yet scaffolded.** Target conventions from the platform spec
(`2026-09-03-serverless-rtm-platform-design.md`) and the architecture spec
(`2026-09-04-architecture-and-scaffold-design.md` — framework, `packages/`,
build, migration). The `apps/` directory currently holds only this file.

## The two apps

| App | Runtime | Users | Nav |
|---|---|---|---|
| `apps/mobile-android` | **Expo** (prebuild/CNG) + React Native | FIELD_AGENT, INFORMAL_REP, WAREHOUSE_MANAGER, FINTECH_AGENT + `REGIONAL_MANAGER` / `COMPLIANCE_OFFICER` (HQ-on-the-go subset) | bottom-tabs, tab set chosen by role tier |
| `apps/desktop-windows` | **bare RN + `react-native-windows`** | all 5 HQ roles (full workstation) | left sidebar + stack |

RN version is pinned to `react-native-windows` compatibility with the matching
Expo SDK — both apps upgrade together (architecture spec §3).

There is **no web target**. `packages/shared-*` holds cross-app code; both apps
import only from `@teafair/*` packages, never each other.

## Rules

- **Every mutation is `supabase.rpc('<name>', …)`** — never `.from(t).insert/update/delete`,
  never `functions.invoke` for business logic. Reads go through PostgREST
  (`.from(t).select(…)`) under RLS.
- Every write RPC takes a **client-generated `p_idempotency_key` (uuid)** — one
  per user action, persisted with the pending action so an offline retry replays
  the same key.
- Types are **generated** (`supabase gen types typescript`) into
  `packages/shared-types` — never hand-written `Row`/`Insert`/`Update`.
- The Supabase client is created once per app from an injectable factory (the
  pattern carried over from the legacy `core`); env vars are read in the app, not
  in a shared package. `.env` gitignored.
- Session tokens go in **platform-secure storage** (`react-native-keychain` on
  Android; the Windows credential store) — never plain `AsyncStorage`.
- **Realtime:** exactly one subscription in the whole system — a `FINTECH_AGENT`
  to their own `invoice_financings` rows. Everything else refetches on screen
  focus.
- **Notifications:** the `notifications` inbox is **polled** (on foreground +
  ~60–120 s while active) via a shell notification centre (bell + unread count,
  `ACTION_REQUIRED` badged). No per-user realtime.
- Verification captures (GPS fix when available, cell id best-effort, photo,
  signature) are bundled and submitted to the RPC; the **server** decides the
  risk tier — the client never scores its own risk.
- Verification / depot heartbeat features exist **only in `mobile-android`** —
  HQ users are never in the field.
- `mobile-android` **field roles** are offline-capable: a persistent client cache
  (agent's outlets, catalogue, open orders, …) + a write queue keyed by
  `p_idempotency_key`, delta-synced on reconnect (`packages/shared-sync`).
  **HQ-mobile roles and `desktop-windows` are online-only** — approving against
  stale state makes no sense. Queued actions flush through the same RPCs with
  live re-validation — offline never relaxes validation. See platform spec §3.8
  and `docs/features/client-cache-and-offline.md`.
- Screens stay presentational: state and logic come from `packages/shared-*`.
- `apps/mobile-android` — check the pinned framework's versioned docs before
  writing platform code (see its own `CLAUDE.md` once scaffolded).

## Per-feature detail

`docs/features/` — screens by role, RPC list, and data sources for each feature.
