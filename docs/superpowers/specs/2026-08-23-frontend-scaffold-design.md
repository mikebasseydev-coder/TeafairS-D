# Teafair Frontend Scaffold — Design

## Status
Approved 2026-08-23 (revised same day: added Windows target, Zustand,
dropped Redux/Vercel/NextJS). Scaffold only — no business logic.

## Context
Teafair's client is now a multi-target React Native product: an Android app
(Expo, dev-client) and a Windows desktop app (`react-native-windows`),
sharing one platform-agnostic core logic layer. There is no web app
(Vercel/Next.js was considered and dropped). Backend architecture
(NestJS vs. Supabase) is undecided and out of scope for this spec — this
spec covers only scaffolding `frontend/` to the point where the Android
target builds and runs as a development build, with the Windows target's
files scaffolded (build validation deferred — see Prerequisites).

## Goal
`npx expo run:android` (run from `frontend/mobile`) builds and installs a
debug dev-client APK on the connected device, the app launches, and
bottom-tab navigation reaches one placeholder screen per feature module
without crashing. The `frontend/windows` app exists with the same
placeholder screens wired up via `react-native-windows-init`, importing
its logic from `core`, but is not build-validated in this phase.

## Architecture

```
frontend/                   npm workspaces root
├── package.json            workspaces: ["core", "mobile", "windows"]
├── core/                   platform-agnostic logic — NO react-native imports
│   └── src/
│       ├── api/            fetch clients, one per feature
│       ├── features/       auth, catalog, orders, gamification, aggregator
│       │                   — pure logic + Zustand stores, no UI
│       ├── storage/        Storage interface (get/set/remove); no
│       │                   implementation — each app injects its own adapter
│       └── index.ts
├── mobile/                 Expo app — Android dev-client target
│   └── src/
│       ├── components/     Button, InputField (real, native RN primitives)
│       ├── features/*/screens/   placeholder screens per feature
│       ├── navigation/     AppNavigator.tsx, RootStackParams.ts
│       │                   (React Navigation: native-stack + bottom-tabs)
│       └── storage/secureStore.ts   expo-secure-store adapter for core's
│                                    Storage interface
└── windows/                 bare RN + react-native-windows target
    └── src/
        ├── components/
        ├── features/*/screens/
        ├── navigation/
        └── storage/asyncStorage.ts  @react-native-async-storage/async-storage
                                     adapter for core's Storage interface
```

## Decisions
- **Monorepo**: npm workspaces at `frontend/`, packages `core`, `mobile`,
  `windows`. `mobile` and `windows` both depend on `core` via workspace
  reference.
- **Core package**: contains all data-fetching and business logic, and
  Zustand stores. Must not import `react-native` or any platform-specific
  package — enforced by convention (no native/Expo deps in `core/package.json`).
- **Mobile app**: Expo managed workflow + `expo-dev-client`, TypeScript,
  npm. App identity `com.teafair.app`. Local build via `npx expo run:android`
  (Android SDK, JDK 17, and a connected device confirmed present).
- **Windows app**: bare React Native, scaffolded with
  `npx react-native-windows-init` (or equivalent) targeting the same RN
  version as `mobile`. Not build-validated in this phase.
- **Navigation**: React Navigation (`native-stack` + `bottom-tabs`) in both
  apps, each with its own `AppNavigator.tsx`/`RootStackParams.ts` — screens
  render placeholder content and import logic from `core`.
- **State**: Zustand, defined in `core/src/features/*` so both apps share
  the same store logic.
- **Storage**: `core` defines a `Storage` interface; `mobile` implements it
  with `expo-secure-store`, `windows` implements it with
  `@react-native-async-storage/async-storage`. Feature code in `core` only
  ever depends on the interface.
- **Styling**: NativeWind (Tailwind for RN) in `mobile`. Deferred/TBD for
  `windows` (react-native-windows NativeWind support is less mature — will
  revisit when the Windows target is actually built out). No
  `react-native-web` in either app — native primitives only, no `<div>`,
  `<h1>`, etc.
- **Feature modules**: `auth`, `catalog`, `orders`, `gamification`,
  `aggregator`. Logic (`api.ts`, `store.ts` types) lives in `core/src/features/*`;
  each app has its own thin `features/*/screens/` and `components/` for
  UI only.
- **Backend**: out of scope entirely — no `backend/` folder, no decision
  yet between NestJS+Prisma+Supabase-as-Postgres vs. Supabase-direct. To
  be brainstormed as its own spec later.
- **Version control**: git repo at `Teafair/` root (already initialized).

## Prerequisites / known gaps
- **Windows build toolchain missing**: `vswhere` finds no registered
  Visual Studio installation on this machine (Build Tools folder exists
  but isn't functional), and none of the C++/UWP workloads
  `react-native-windows` requires are present. The `windows/` app will be
  scaffolded (files generated) but `npx react-native run-windows` will NOT
  be attempted until these workloads are installed — that's a separate,
  user-driven prerequisite step, not part of this plan.

## Out of scope (explicitly deferred)
- Any real authentication, KYC, catalog, order, payout, gamification, or
  aggregator business logic (screens/stores are structural placeholders)
- WhatsApp AI / LangChain integration
- Backend of any kind (NestJS, Supabase, Prisma, Docker, KrakenD) —
  separate future spec
- Windows build validation (blocked on VS toolchain installation)
- EAS cloud builds, app store config, CI/CD
- Automated test setup (unit/e2e) — added when there's real logic to test
- Any web app / Next.js / Vercel deployment (explicitly dropped)

## Validation
Manual: from `frontend/mobile`, run `npx expo run:android`, confirm the
app installs and launches on the connected device, and each bottom-tab
route renders its placeholder screen without a crash or red-box error.
`frontend/windows` is checked for successful `react-native-windows-init`
scaffolding only (files present, `npm install` succeeds) — no build/run
validation this phase.
