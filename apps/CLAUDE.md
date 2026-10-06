# CLAUDE.md (apps)

## Status: superseded

This directory described the two-app `apps/` + `packages/` pnpm monorepo
(an Expo Android app and a `react-native-windows` HQ app) from the 2026-09-04
architecture spec. **That layout is superseded.**

Spec A
(`docs/superpowers/specs/2026-10-05-multi-tenant-rtm-foundation-design.md`,
§13) replaces it with a single React Native (Expo) Android app in a flat
`src/` tree. The Windows HQ client is deferred (decision 11). The app shell
itself is defined by Spec B, which is not yet written.

Do not scaffold anything here. This directory is removed when the Spec B
scaffold lands.

## What carries over to the new app

From Spec A, binding on whatever Spec B builds:

- **No direct writes.** The app never calls `.from(t).insert/update/delete`.
  Mutations go through Edge Function gateways, which call RPCs (§3.1).
- **Never send a tenant id.** The active tenant lives in the JWT; switching
  calls `set_active_tenant` and then refreshes the session (§4.4).
- **Offline queue (§7):** MMKV storage; each `QueuedMutation.id` is a UUIDv4
  generated **at enqueue** and *is* the `p_idempotency_key`; Zod-validate at
  enqueue; FIFO within a `dependsOn` chain; backoff 2 s → 5 min; retry on 503
  and network failure, stop on 403/409/422 and show "Needs attention" (§3.5).
- PIN-gated actions need connectivity, except `log_retail_pickup`, which lands
  as `PENDING_CONFIRMATION` and escalates to the DSM after 24 hours (§7.4).
- Reads persist to MMKV with per-class TTLs; money is never served stale
  (§7.5). Server timestamps are authoritative; the device clock is recorded,
  never trusted.
- `.env` is gitignored; never hardcode Supabase URLs or keys. Tokens go in
  secure storage, never plain AsyncStorage.
