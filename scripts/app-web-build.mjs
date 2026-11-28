// Builds the Expo web export (dist-web) for the Playwright app run against the
// local Supabase stack (Spec B §11). It passes only the stack's URL and its
// publishable key to the build, the two values the app may hold (Spec B §4.4,
// Ruling 46), and writes no env file. It prints no value.
import { execSync } from "node:child_process";

const status = execSync("supabase status -o env", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
const env = Object.fromEntries(
  status
    .split(/\r?\n/)
    .map((l) => l.match(/^([A-Z_]+)="?(.*?)"?$/))
    .filter(Boolean)
    .map((m) => [m[1], m[2]]),
);
const url = env.API_URL;
const key = env.PUBLISHABLE_KEY || env.ANON_KEY;
if (!url || !key) throw new Error("supabase status gave no API_URL or publishable key: is the local stack running?");

execSync("pnpm exec expo export -p web --output-dir dist-web", {
  stdio: "inherit",

  env: { ...process.env, EXPO_PUBLIC_SUPABASE_URL: url, EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY: key },
});
console.log("built dist-web against the local stack");
