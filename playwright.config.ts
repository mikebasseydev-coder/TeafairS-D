// API-only Playwright run against the local Supabase stack (no browser).
// Before `pnpm test:api`: `supabase start`, `pnpm db:seed`, and the Edge
// Functions served with `pnpm functions:serve:api` (Sentry off).
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/api",
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 60_000,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: "http://127.0.0.1:54321",
    extraHTTPHeaders: { Accept: "application/json" },
  },
});
