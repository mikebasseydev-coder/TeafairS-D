// R46, rule 3: no secret reaches a client bundle. Scans the whole repository
// (gitignored local env files, .git and node_modules excepted) for
//   1. a client-prefixed variable naming a secret (EXPO_PUBLIC_*SECRET*, …);
//   2. a literal new-format secret key;
//   3. a committed legacy service_role JWT;
//   4. any server key name inside a client app tree (Spec B's flat `src/`, or
//      `app/`, `apps/`, `frontend/`, `web/` should one appear).
// teafairweb lives in its own repository and needs the same check there.
//
// Run with --allow-read.
import { assertEquals } from "jsr:@std/assert@1";

const repo = new URL("../../../", import.meta.url);
const SELF = "supabase/functions/_tests/secret-scoping.test.ts";

const SKIP_DIRS = new Set([".git", "node_modules", ".claude", ".superpowers", ".temp", ".branches"]);
const TEXT = /\.(ts|tsx|js|jsx|mjs|cjs|json|jsonc|toml|ya?ml|md|sql|sh|ps1|env|example|txt|html|css)$|^\.env/;
// Local env files are gitignored and are where real keys belong.
const LOCAL_ENV = /^\.env(\.(?!example$)[^/]+)?$|\.local$/;
const CLIENT_TREES = ["src/", "app/", "apps/", "frontend/", "web/"];

const CLIENT_PREFIXED_SECRET =
  /\b(?:EXPO_PUBLIC|NEXT_PUBLIC|VITE|REACT_APP|PUBLIC)_[A-Z0-9_]*(?:SECRET|SERVICE_ROLE|SERVICE_KEY|PRIVATE)[A-Z0-9_]*/;
const SECRET_LITERAL = /\bsb_secret_[A-Za-z0-9_-]{20,}/;
const JWT = /\beyJ[A-Za-z0-9_-]{10,}\.(eyJ[A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{10,}/g;
const SERVER_KEY_NAME = /SUPABASE_(?:SERVICE_ROLE_KEY|SECRET_KEYS?)\b|\bsb_secret_|\bserviceRpc\b/;

function files(dir: URL, rel = "", out: { path: string; name: string }[] = []) {
  for (const e of Deno.readDirSync(dir)) {
    if (e.isDirectory) {
      if (!SKIP_DIRS.has(e.name)) files(new URL(`${e.name}/`, dir), `${rel}${e.name}/`, out);
    } else if (e.isFile && TEXT.test(e.name) && !LOCAL_ENV.test(e.name)) {
      out.push({ path: rel + e.name, name: e.name });
    }
  }
  return out;
}

function isServiceRoleJwt(payload: string): boolean {
  try {
    const json = atob(payload.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(payload.length / 4) * 4, "="));
    return JSON.parse(json)?.role === "service_role";
  } catch {
    return false;
  }
}

Deno.test("R46: no secret is exposed under a client prefix, committed, or used in a client tree", () => {
  const problems: string[] = [];
  for (const f of files(repo)) {
    if (f.path === SELF) continue;
    const text = Deno.readTextFileSync(new URL(f.path, repo));
    text.split(/\r?\n/).forEach((line, i) => {
      const at = `${f.path}:${i + 1}`;
      if (CLIENT_PREFIXED_SECRET.test(line)) problems.push(`${at} client-prefixed secret name`);
      if (SECRET_LITERAL.test(line)) problems.push(`${at} literal sb_secret_ key`);
      for (const m of line.matchAll(JWT)) if (isServiceRoleJwt(m[1])) problems.push(`${at} service_role JWT`);
      if (CLIENT_TREES.some((t) => f.path.startsWith(t)) && SERVER_KEY_NAME.test(line)) {
        problems.push(`${at} server key in a client tree`);
      }
    });
  }
  // Never print the matching line: it may hold the secret.
  assertEquals(problems, []);
});

Deno.test("R46: the scanner catches what it claims to", () => {
  assertEquals(CLIENT_PREFIXED_SECRET.test("EXPO_PUBLIC_SUPABASE_SECRET_KEY=x"), true);
  assertEquals(CLIENT_PREFIXED_SECRET.test("NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY"), true);
  assertEquals(CLIENT_PREFIXED_SECRET.test("EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY"), false);
  assertEquals(SECRET_LITERAL.test("sb_secret_" + "a".repeat(32)), true);
  assertEquals(SECRET_LITERAL.test("sb_secret_aaa"), false);
  const payload = btoa(JSON.stringify({ role: "service_role", iss: "supabase" })).replace(/=+$/, "");
  assertEquals(isServiceRoleJwt(payload), true);
  assertEquals(isServiceRoleJwt(btoa(JSON.stringify({ role: "anon" })).replace(/=+$/, "")), false);
  assertEquals(LOCAL_ENV.test(".env"), true);
  assertEquals(LOCAL_ENV.test(".env.test.local"), true);
  assertEquals(LOCAL_ENV.test(".env.example"), false);
});
