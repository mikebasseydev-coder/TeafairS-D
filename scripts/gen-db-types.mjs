// Regenerates the client's view of the database from the local stack:
//   src/shared/network/database.types.ts   (supabase gen types)
//   src/shared/network/callable-functions.json  (public functions `authenticated` may EXECUTE)
// rpc-map.test.ts holds Spec B §6 against both. Run: pnpm gen:db
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import postgres from "postgres";

const root = fileURLToPath(new URL("..", import.meta.url));
const out = (p) => fileURLToPath(new URL(`../src/shared/network/${p}`, import.meta.url));
const shell = process.platform === "win32";

const types = execFileSync("pnpm", ["exec", "supabase", "gen", "types", "typescript", "--local"], {
  cwd: root,
  encoding: "utf8",
  shell,
  maxBuffer: 64 * 1024 * 1024,
});
// pnpm may print its own status lines first; the file starts at the first export.
const start = types.indexOf("export type Json");
if (start < 0) throw new Error("supabase gen types gave no output");
writeFileSync(out("database.types.ts"), types.slice(start).replace(/\r\n/g, "\n"));

const env = execFileSync("pnpm", ["exec", "supabase", "status", "-o", "env"], { cwd: root, encoding: "utf8", shell });
const dbUrl = /^DB_URL="?([^"\n]+)"?/m.exec(env)?.[1];
if (!dbUrl) throw new Error("supabase status gave no DB_URL; is the local stack running?");

const sql = postgres(dbUrl, { max: 1 });
try {
  const rows = await sql`
    select distinct p.proname as name
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and p.prorettype <> 'trigger'::regtype
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     order by 1`;
  writeFileSync(out("callable-functions.json"), JSON.stringify(rows.map((r) => r.name), null, 2) + "\n");
  console.log(`database.types.ts written; ${rows.length} functions callable by authenticated`);
} finally {
  await sql.end();
}
