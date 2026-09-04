# CLAUDE.md (frontend — LEGACY)

## Status

**Legacy. Do not build new features here.**

`frontend/` is the original npm-workspaces scaffold (`core` + `mobile` Expo
dev-client, ~24 commits, auth wired to Supabase, 39 passing tests). It predates
the 2026-09-03 serverless pivot
(`docs/superpowers/specs/2026-09-03-serverless-rtm-platform-design.md`).

Under the new architecture this is replaced by `apps/mobile-android` +
`apps/desktop-windows` + `packages/shared-*` with `pnpm`. This directory is kept
only as a **reference during migration** and will be removed once the new layout
is scaffolded and the auth flow is ported.

## What carries over (patterns, not code)

- The injectable `createSupabaseClient(url, anonKey, options?)` factory — never a
  module-level singleton, never reads `process.env` itself.
- `unwrapSupabaseResult` for uniform Supabase result/error handling.
- The `Storage` interface + per-app adapter pattern (mobile used
  `expo-secure-store`; the new apps use `react-native-keychain` /
  the Windows credential store).
- The auth-store shape (`session` / `user` + `setSession` / `clear`), with the
  app — not shared code — owning `onAuthStateChange` and bootstrap.
- Env vars read in the app, not in shared packages; `.env` gitignored.

## What does NOT carry over

- npm workspaces → `pnpm`.
- Expo → per the scaffold spec (Android target; Windows via
  `react-native-windows`).
- The generic `create<Feature>ApiClient(baseUrl)` placeholder modules — the new
  data layer is Supabase RPC calls, not a REST client.
- `frontend/core` → split into `packages/shared-*`.
- Next.js / `react-native-web` / any web target — dropped entirely.

## Historical detail

`frontend/mobile/CLAUDE.md` → `AGENTS.md` (versioned Expo docs note). The
original scaffold rationale is in
`docs/superpowers/specs/2026-08-23-frontend-scaffold-design.md`.
