// The app run (Spec B §11): the Expo web export, served statically, in two
// projects, phone (390x844) and tablet (768x1024). Build first with
// `pnpm export:web`; `pnpm test:app` then serves dist-web itself. The API run
// (playwright.config.ts, tests/api) is separate and unchanged. B2 also needs
// the local stack: `supabase start`, `pnpm functions:serve:app`, and the
// build from `pnpm export:web:local`.
import { defineConfig, devices } from "@playwright/test";

const PORT = 8099;
const FAKE_RESEND_PORT = 8097;
const AUTH_SPECS = /b2-auth\.spec\.ts/;
const PHONE = { ...devices["Desktop Chrome"], viewport: { width: 390, height: 844 }, isMobile: false };
const TABLET = { ...devices["Desktop Chrome"], viewport: { width: 768, height: 1024 }, isMobile: false };

export default defineConfig({
  testDir: "./tests/app",
  // B2: boots the local Auth hooks' workers once, before any project runs
  globalSetup: "./tests/app/support/global-setup.ts",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 60_000,
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report/app" }]],
  outputDir: "test-results/app",
  expect: { toHaveScreenshot: { maxDiffPixelRatio: 0.01, animations: "disabled" } },
  snapshotPathTemplate: "{testDir}/__screenshots__/{projectName}/{arg}{ext}",
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    // skeletons stop animating under reduced motion, which keeps screenshots stable
    reducedMotion: "reduce",
    trace: "retain-on-failure",
  },
  projects: [
    { name: "phone", testIgnore: AUTH_SPECS, use: PHONE },
    { name: "tablet", testIgnore: AUTH_SPECS, use: TABLET },
    // The sign-in specs run against the local Auth hooks, which share one edge
    // runtime: Auth waits 5 s for a hook, and two projects booting workers at
    // once overran it on a busy machine. So the tablet run follows the phone run.
    { name: "phone-auth", testMatch: AUTH_SPECS, use: PHONE },
    { name: "tablet-auth", testMatch: AUTH_SPECS, use: TABLET, dependencies: ["phone-auth"] },
  ],
  webServer: [
    {
      command: `node scripts/serve-web.mjs`,
      url: `http://127.0.0.1:${PORT}/`,
      env: { PORT: String(PORT) },
      reuseExistingServer: !process.env.CI,
    },
    {
      // B2: the sign-in hook sends to this fake; the tests read the code back
      command: `node scripts/fake-resend.mjs`,
      url: `http://127.0.0.1:${FAKE_RESEND_PORT}/`,
      env: { FAKE_RESEND_PORT: String(FAKE_RESEND_PORT) },
      reuseExistingServer: !process.env.CI,
    },
  ],
});
