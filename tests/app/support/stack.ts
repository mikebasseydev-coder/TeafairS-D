// The local stack for the Playwright app run (Spec B §11). Test process only:
// it reads the stack's keys from `supabase status` and makes its own fixtures
// with the Admin API and SQL. Nothing here reaches src/. No key, code or
// address is printed.
import { execSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import postgres from "postgres";

export const TEAFAIR_TENANT_ID = "7eaf0000-0000-4000-8000-000000000001";
const FAKE_RESEND = `http://127.0.0.1:${process.env.FAKE_RESEND_PORT ?? 8097}`;

let cached: Record<string, string> | null = null;
function stackEnv(): Record<string, string> {
  if (cached) return cached;
  const out = execSync("supabase status -o env", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  cached = Object.fromEntries(
    out
      .split(/\r?\n/)
      .map((l) => l.match(/^([A-Z_]+)="?(.*?)"?$/))
      .filter((m): m is RegExpMatchArray => !!m)
      .map((m) => [m[1], m[2]]),
  );
  return cached;
}

function admin() {
  const env = stackEnv();
  return createClient(env.API_URL, env.SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
}

function sql() {
  return postgres(stackEnv().DB_URL, { max: 1, onnotice: () => {} });
}

/** A fresh, confirmed account that has never signed in. */
export async function createPerson(label: string): Promise<{ id: string; email: string }> {
  const email = `b2-${label}-${randomUUID().slice(0, 8)}@rtm.local`;
  const { data, error } = await admin().auth.admin.createUser({ email, email_confirm: true });
  if (error || !data.user) throw new Error(`createUser failed: ${error?.message}`);
  return { id: data.user.id, email };
}

/** An INVITED membership: TENANT_ADMIN needs no zone, territory or manager. */
export async function invite(profileId: string, tenantId = TEAFAIR_TENANT_ID): Promise<string> {
  const db = sql();
  try {
    const [row] = await db<{ id: string }[]>`
      insert into public.tenant_users (tenant_id, profile_id, role, is_primary, status)
      values (${tenantId}, ${profileId}, 'TENANT_ADMIN', false, 'INVITED')
      returning id`;
    return row.id;
  } finally {
    await db.end();
  }
}

/** The six-digit code of the newest sign-in email the hook sent to this address. */
export async function latestCode(email: string, after = 0): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`${FAKE_RESEND}/__emails?to=${encodeURIComponent(email)}`);
    const mails = (await res.json()) as { text: string; at: number }[];
    const fresh = mails.filter((m) => m.at > after).at(-1);
    const code = fresh?.text.match(/\b(\d{6})\b/)?.[1];
    if (code) return code;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("no sign-in email arrived at the fake Resend");
}

/**
 * Boots the two Auth hooks' workers before the run. Locally Auth waits 5 s
 * for a hook, and a cold edge-runtime worker can take longer; unsigned calls
 * are refused by the hooks, but they start the workers.
 */
export async function warmAuthHooks(workers = 3): Promise<void> {
  const base = `${stackEnv().API_URL}/functions/v1`;
  // concurrent calls, so the runtime boots one worker per parallel project
  const calls = ["auth-verify-claims", "send-auth-email"].flatMap((fn) =>
    Array.from({ length: workers }, () => fetch(`${base}/${fn}`, { method: "POST", body: "{}" }).catch(() => undefined)),
  );
  await Promise.all(calls);
}
