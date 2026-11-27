// The app run (Spec B §11): the Expo web export, served statically, in two
// projects, phone (390x844) and tablet (768x1024). Build first with
// `pnpm export:web`; `pnpm test:app` then serves dist-web itself. The API run
// (playwright.config.ts, tests/api) is separate and unchanged.
import { defineConfig, devices } from "@playwright/test";

const PORT = 8099;

export default defineConfig({
  testDir: "./tests/app",
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
    { name: "phone", use: { ...devices["Desktop Chrome"], viewport: { width: 390, height: 844 }, isMobile: false } },
    { name: "tablet", use: { ...devices["Desktop Chrome"], viewport: { width: 768, height: 1024 }, isMobile: false } },
  ],
  webServer: {
    command: `node scripts/serve-web.mjs`,
    url: `http://127.0.0.1:${PORT}/`,
    env: { PORT: String(PORT) },
    reuseExistingServer: !process.env.CI,
  },
});
