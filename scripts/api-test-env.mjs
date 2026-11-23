// Writes supabase/functions/.env.api.local (gitignored by `.env*.local`) for
// `pnpm functions:serve:api`: a copy of supabase/functions/.env with Sentry
// switched off, so the API tests never report to a live Sentry project, and
// the WhatsApp settings dropped, so codes go to the local SMS log provider
// instead of the integration fake. It prints key names only, never values.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "supabase", "functions");
const src = readFileSync(path.join(dir, ".env"), "utf8").split(/\r?\n/);

const dropped = [];
const kept = src.filter((line) => {
  const key = line.match(/^\s*([A-Z0-9_]+)\s*=/)?.[1];
  if (key && (key.startsWith("SENTRY_") || key.startsWith("WHATSAPP_"))) {
    dropped.push(key);
    return false;
  }
  return true;
});

const smsLine = kept.find((l) => /^\s*SMS_PROVIDER\s*=/.test(l));
if (!smsLine || !/=\s*log\s*$/.test(smsLine)) {
  throw new Error("supabase/functions/.env must set SMS_PROVIDER=log for local API tests");
}

kept.push("", "# api tests: Sentry off (empty DSN disables it in _shared/core/observability.ts)", "SENTRY_DSN=");
writeFileSync(path.join(dir, ".env.api.local"), kept.join("\n") + "\n", { mode: 0o600 });
console.log(`wrote supabase/functions/.env.api.local (removed: ${[...new Set(dropped)].join(", ") || "none"}; SENTRY_DSN empty)`);
