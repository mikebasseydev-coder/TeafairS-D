# Teafair Frontend Scaffold — Design

## Status
Approved 2026-08-23. Scaffold only — no business logic.

## Context
Teafair is a planned two-part product: a React Native/Expo client app and a
NestJS backend (auth, orders, payouts, gamification, aggregator ingestion,
WhatsApp AI). The target directory structure for both was reviewed and
approved (see conversation history — not reproduced here). This spec covers
only the first concrete step: scaffolding the `frontend/` app to the point
where it builds and runs as a development build on a physical Android
device, with the approved folder structure in place as stubs. Backend work,
and all real business logic, are separate future efforts.

## Goal
`npx expo run:android` builds and installs a debug dev-client APK on the
connected device, the app launches, and bottom-tab navigation reaches one
placeholder screen per feature module without crashing.

## Decisions
- **Location**: `Teafair/frontend/`
- **Workflow**: Expo managed workflow + `expo-dev-client` (not bare)
- **Build method**: local build via `npx expo run:android` (Android SDK,
  JDK 17, and a connected device are already present in this environment;
  no EAS account needed for this phase)
- **Language**: TypeScript (Expo's default TS template)
- **Package manager**: npm
- **App identity**: Android `applicationId` / iOS `bundleIdentifier` =
  `com.teafair.app`
- **Navigation**: React Navigation — `@react-navigation/native-stack` for
  screen stacks, `@react-navigation/bottom-tabs` for the five top-level
  features, wired in `src/navigation/AppNavigator.tsx` with types in
  `src/navigation/RootStackParams.ts`
- **State/data**: Redux Toolkit + RTK Query. `src/store/store.ts` configures
  the store with RTK Query middleware; `src/api/baseQuery.ts` is stubbed
  (signature in place for Azure auth header injection, not implemented)
- **Styling**: NativeWind (Tailwind for RN) — `tailwind.config.js` plus
  Babel/Metro config; `Button.tsx` and `InputField.tsx` are built as real
  minimal components (genuinely reusable primitives, not placeholders)
- **Feature modules** (`src/features/{auth,catalog,orders,gamification,
  aggregator}/`): each gets `components/`, `hooks/`, `screens/`, `api.ts`,
  `slice.ts`, `index.ts` per the approved tree. Screens are placeholders
  that render their own feature name. `api.ts`/`slice.ts` are empty
  RTK Query/slice shells (no endpoints, no reducers) wired into the root
  store/reducer so the app compiles and features are structurally present.
- **Backend**: out of scope. `backend/` is not created in this phase.
- **Version control**: git repo initialized at `Teafair/` root; this spec
  and the scaffold are the first commits.

## Out of scope (explicitly deferred)
- Any real authentication, KYC, catalog, order, payout, gamification, or
  aggregator logic
- WhatsApp AI / LangChain integration
- Backend (NestJS/Prisma/KrakenD)
- EAS cloud builds, app store config, CI/CD
- Automated test setup (unit/e2e) — added when there's real logic to test

## Validation
Manual: run `npx expo run:android`, confirm the app installs and launches
on the connected device, and each bottom-tab route renders its placeholder
screen without a crash or red-box error.
