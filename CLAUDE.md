# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Teafair's client: a multi-target React Native app (Android via Expo dev-client today; Windows via `react-native-windows` and web via Next.js + `react-native-web` planned) sharing one platform-agnostic core logic package and a shared `ui` component package. The flagship feature is a Route-to-Market omni-channel sales-aggregation platform ("HQ Aggregation platform") built on field-rep data captured in `mobile`. Backend is Supabase (Postgres + Auth) — Prisma + Docker are local-only schema-development tooling, never a runtime; see `docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md` for the full architecture. Only `frontend/` is scaffolded today; `backend/` (Prisma/Docker sandbox — see `backend/CLAUDE.md`) and `supabase/` (CLI-managed migrations) are planned but not yet created.

## Commands

All work happens inside `frontend/`, an npm-workspaces root (workspaces: `core`, `mobile`).

Install once: `cd frontend && npm install`

### core (`frontend/core` — `@teafair/core`)
- Run all tests: `cd frontend/core && npx jest`
- Run a single test file: `npx jest src/lib/profiles.test.ts` (from `frontend/core`)
- Typecheck: `cd frontend/core && npx tsc --noEmit`

### mobile (`frontend/mobile` — Expo/Android dev-client target)
- No test runner is configured for `mobile`; verify changes with: `cd frontend/mobile && npx tsc --noEmit`
- Start Metro: `npx expo start` (from `frontend/mobile`)
- Build and install a debug dev-client APK on a connected Android device: `npx expo run:android` (requires Android SDK, JDK 17, and a connected device)
- `npx expo start --web` works for quick sanity checks only — the app uses native RN primitives (no `react-native-web`), so it isn't representative of real layout.

No lint is configured in either package.

## Architecture

### Monorepo layout
`frontend/` is an npm-workspaces root with packages `core` (platform-agnostic logic) and `mobile` (Expo app). Three more packages are planned but not yet scaffolded: `ui` (shared RN + NativeWind components, consumed by every app target), `web` (Next.js + `react-native-web`, the HQ Aggregation platform's primary UI), and `windows` (bare RN + `react-native-windows`) — see `docs/superpowers/specs/2026-08-23-frontend-scaffold-design.md` for the original frontend layout rationale and `docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md` for `ui`/`web` and the backend. At the repo root, `backend/` (Prisma + Docker local schema-dev sandbox — see `backend/CLAUDE.md`) and `supabase/` (Supabase-CLI-managed migrations, the production source of truth) are likewise planned but not yet scaffolded.

### `core` — shared logic, zero platform imports
- `core` must never import `react-native`, Expo, or any other platform-specific package — enforced by convention (no native/Expo deps in `core/package.json`), not tooling.
- One directory per feature under `src/features/{auth,catalog,orders,products,brands,territories,alerts,gamification,aggregator}/`, each exporting `api.ts` and `store.ts` (a Zustand store) through a barrel `index.ts`. Except for `auth`, every module is still a structural placeholder: `api.ts` exports `create<Feature>ApiClient(baseUrl)` returning `{ baseUrl }`, and `store.ts` exports an empty `use<Feature>Store`. New placeholder modules get one shared test — add them to the `features` array in `src/features/features.test.ts` rather than writing a dedicated test file.
- `auth` is the one feature module with real logic: it's wired directly to Supabase Auth, not a generic REST client. `src/features/auth/api.ts` exports `signUpWithEmail`, `signInWithEmail`, `signOut`, and `getSession`, each taking a `SupabaseClient` as a parameter (same injectable convention as `fetchProfiles`) and unwrapping results through `unwrapSupabaseResult`. `src/features/auth/store.ts`'s `useAuthStore` holds `session`/`user` plus `setSession`/`clear` actions. `core` itself never calls `setSession`/`clear` — that's the calling app's job: `mobile` does it both directly (after a successful `signInWithEmail`/`signUpWithEmail`/`signOut` call in `AuthScreen`) and via a global `supabase.auth.onAuthStateChange` listener (`mobile/src/lib/useAuthBootstrap.ts`) that rehydrates the store from persisted storage on app start.
- `src/storage/types.ts` defines a `Storage` interface (`getItem`/`setItem`/`removeItem`) with no implementation in `core` — each app supplies its own adapter (mobile: `expo-secure-store`, see `mobile/src/storage/secureStore.ts`; windows, once built: `@react-native-async-storage/async-storage`). Note: `expo-secure-store` has historically had a ~2048-byte per-value limit on Android — if a Supabase session JWT ever fails to persist, that's the first thing to check.
- `src/lib/supabaseClient.ts` exports `createSupabaseClient(url, anonKey, options?)` — an injectable factory, never a module-level singleton, and it never reads `process.env` itself. The optional third argument is `@supabase/supabase-js`'s own `SupabaseClientOptions` (not RN-specific), which is how `mobile` injects its `auth.storage` adapter and `persistSession`/`autoRefreshToken` config without `core` knowing anything about the platform. Anything that touches Supabase (e.g. `src/lib/profiles.ts`'s `fetchProfiles`) takes the client as a parameter instead of importing a shared instance, so the calling app owns env-var reads and client lifetime. Supabase result/error handling goes through the shared `src/lib/unwrapSupabaseResult.ts` helper — don't duplicate that unwrap logic in new query functions.
- Everything is re-exported through `src/index.ts`; app code should only ever import from `@teafair/core`, not reach into `core/src/*` directly.

### `mobile` — Expo app, UI only
- Screens live at `src/features/*/screens/`, one per feature module, wired into a single bottom-tab navigator (`src/navigation/AppNavigator.tsx` + `RootStackParams.ts`, React Navigation `bottom-tabs`). Screens pull state/logic from `@teafair/core` and stay presentational otherwise.
- Shared UI primitives (`Button`, `InputField`) live in `src/components/`, styled with NativeWind (Tailwind for RN). When a component accepts a caller-supplied `className`, merge it with the component's own default classes rather than letting the spread silently overwrite them.
- `src/lib/supabaseClient.ts` is where `EXPO_PUBLIC_SUPABASE_URL`/`EXPO_PUBLIC_SUPABASE_ANON_KEY` are actually read from `process.env` and passed into `core`'s `createSupabaseClient`, along with the `secureStoreAdapter` (`src/storage/secureStore.ts`) as the auth storage and `persistSession`/`autoRefreshToken: true`. This lives in `mobile`'s own source root (not in `core`) so Metro's `EXPO_PUBLIC_*` inlining applies to it, and so `core` stays env-agnostic. `.env`/`.env*.local` are gitignored — never hardcode Supabase URLs/keys in source. The same file also wires `AppState` to call `supabase.auth.startAutoRefresh()`/`stopAutoRefresh()` on foreground/background — Supabase's refresh timer doesn't run in the background on its own, so without this a session can come back stale after the app is backgrounded.
- `App.tsx` calls `useAuthBootstrap()` (`src/lib/useAuthBootstrap.ts`) once at the root: it calls `getSession` to hydrate `useAuthStore` from persisted storage on launch, then subscribes to `supabase.auth.onAuthStateChange` for the lifetime of the app so sign-in/sign-out/token-refresh events anywhere stay reflected in the store.
- `frontend/mobile` has its own `CLAUDE.md` pointing to `AGENTS.md`, which instructs checking the versioned Expo docs (https://docs.expo.dev/versions/v57.0.0/) before writing Expo-related code — this repo pins Expo ~57.0.15.

### `backend` and `supabase` — Supabase is the source of truth
- Supabase (Postgres + Auth) is the actual production backend; `backend/` is local-only Prisma/Docker tooling for fast schema iteration and is never deployed. `backend/CLAUDE.md` has the full workflow.
- `supabase/` (Supabase-CLI-managed: `migrations/`, `config.toml`) is where validated schema changes land before being applied to the hosted project.
- The data model centers on the Route-to-Market aggregation platform: RBAC via a central `profiles` table linked to Supabase Auth (not per-table auth columns), an append-only `inventory_movements` ledger (never a balance column), and `aggregated_sales` / `current_inventory_balance` as precomputed caches (function-populated table / materialized view respectively) so aggregator reads never recompute live from raw `orders`/`inventory_movements`. Full rationale in `docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md`.

### Design/spec docs
`docs/superpowers/specs/2026-08-23-frontend-scaffold-design.md` is the source of truth for the original scaffold's architecture decisions (monorepo layout, why Zustand/NativeWind, why no Redux/web/Vercel, the storage-adapter pattern). `docs/superpowers/specs/2026-08-25-backend-aggregator-platform-design.md` is the source of truth for the backend, `ui`/`web` targets, and the Route-to-Market data model. `docs/superpowers/plans/` holds the implementation plans that built and then fixed this scaffold — useful background for conventions like the injectable-Supabase-client pattern above.
