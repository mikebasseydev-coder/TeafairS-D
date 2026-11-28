// Writes supabase/functions/.env.api.local (gitignored by `.env*.local`) for
// `pnpm functions:serve:api`: a copy of supabase/functions/.env with Sentry
// switched off, so the API tests never report to a live Sentry project, and
// the WhatsApp settings dropped, so codes go to the local SMS log provider
// instead of the integration fake. Every RESEND_* value is replaced with an
// inert key and a dead local URL, so no API test can reach live Resend even if
// .env holds the real key; the email functions still boot (they require
// RESEND_API_KEY) and every send fails locally. It prints key names only,
// never values.
//
// With --app it writes .env.app.local for the Playwright app run instead: the
// same, except that Resend points at scripts/fake-resend.mjs, so the sign-in
// hook really sends and the tests read the code (Spec B §11).
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "supabase", "functions");
const src = readFileSync(path.join(dir, ".env"), "utf8").split(/\r?\n/);

const dropped = [];
const kept = src.filter((line) => {
  const key = line.match(/^\s*([A-Z0-9_]+)\s*=/)?.[1];
  if (key && (key.startsWith("SENTRY_") || key.startsWith("WHATSAPP_") || key.startsWith("RESEND_"))) {
    dropped.push(key);
    return false;
  }
  return true;
});

const smsLine = kept.find((l) => /^\s*SMS_PROVIDER\s*=/.test(l));
if (!smsLine || !/=\s*log\s*$/.test(smsLine)) {
  throw new Error("supabase/functions/.env must set SMS_PROVIDER=log for local API tests");
}

const app = process.argv.includes("--app");
const fakePort = Number(process.env.FAKE_RESEND_PORT ?? 8097);
kept.push(
  "",
  "# api tests: Sentry off (empty DSN disables it in _shared/core/observability.ts)",
  "SENTRY_DSN=",
  app
    ? "# app tests: Resend is scripts/fake-resend.mjs on the host (inert key)"
    : "# api tests: Resend isolated (inert key; port 9 inside the edge runtime refuses at once)",
  "RESEND_API_KEY=re_api_test_inert",
  app ? `RESEND_API_URL=http://host.docker.internal:${fakePort}` : "RESEND_API_URL=http://127.0.0.1:9",
);
const out = app ? ".env.app.local" : ".env.api.local";
writeFileSync(path.join(dir, out), kept.join("\n") + "\n", { mode: 0o600 });
console.log(`wrote supabase/functions/${out} (removed: ${[...new Set(dropped)].join(", ") || "none"}; SENTRY_DSN empty; RESEND_* inert)`);
