// Spec B §6 cannot silently go stale: every function `authenticated` may
// execute must be named there (or be an RLS helper), and the app's own lists
// must agree with §6 and with the generated types. Refresh the inputs with
// `pnpm gen:db` after a migration.
import * as fs from "fs";
import * as path from "path";
import callable from "./callable-functions.json";
import { GATEWAY_NAMES } from "./gateways";
import { APP_RPCS } from "./rpc-map";

const ROOT = path.resolve(__dirname, "../../..");
const spec = fs.readFileSync(path.join(ROOT, "docs/spec-b-client.md"), "utf8").replace(/\r\n/g, "\n");
const section6 = spec.slice(spec.indexOf("## 6. RPC and gateway map"), spec.indexOf("## 7. "));
const named = new Set([...section6.matchAll(/`([a-z][a-z0-9_]*)\b/g)].map((m) => m[1]));
const types = fs.readFileSync(path.join(__dirname, "database.types.ts"), "utf8");
// graphql_public comes first; the public schema's Functions block is the last one
const fnStart = types.lastIndexOf("Functions: {");
const functionsBlock = types.slice(fnStart, types.indexOf("Enums: {", fnStart));

/** §6: "RLS helpers, not features". */
const HELPER = /^(my_.*|is_.*|jwt_tenant_id|tenant_role|sees_shared_network|state_.*|tenant_state_.*)$/;

const gatewayOnly = (() => {
  const i = section6.indexOf("**Gateway-only, never called directly**");
  const para = section6.slice(i, section6.indexOf("\n\n", section6.indexOf("closed:", i)));
  return new Set([...para.matchAll(/`([a-z][a-z0-9_]*)`/g)].map((m) => m[1]));
})();

const appRows = (() => {
  const t = section6.slice(section6.indexOf("### 6.2"), section6.indexOf("**What §23 adds"));
  const out = new Set<string>();
  for (const line of t.split("\n")) {
    const cells = line.split("|");
    // the surface cell must start with App ("Web (LM may also use App …)" is Web)
    if (cells.length < 5 || !/^\s*App\b/.test(cells[cells.length - 2])) continue;
    for (const m of cells[2].matchAll(/`([a-z][a-z0-9_]*)`/g)) out.add(m[1]);
  }
  return out;
})();

describe("rpc-map (Spec B §6)", () => {
  it("names every function authenticated may execute", () => {
    const missing = (callable as string[]).filter((f) => !named.has(f) && !HELPER.test(f));
    expect(missing).toEqual([]);
  });

  it("each App RPC exists, is callable, and has an App row in §6.2", () => {
    for (const name of APP_RPCS) {
      expect({ name, callable: (callable as string[]).includes(name) }).toEqual({ name, callable: true });
      const typed = functionsBlock.includes(`"${name}":`) || new RegExp(`\\b${name}: \\{`).test(functionsBlock);
      expect({ name, typed }).toEqual({ name, typed: true });
      expect({ name, inApp: appRows.has(name) }).toEqual({ name, inApp: true });
    }
  });

  it("lists every App RPC of §6.2", () => {
    const listed = new Set<string>(APP_RPCS);
    expect([...appRows].filter((r) => !listed.has(r))).toEqual([]);
  });

  it("never lets the app call a gateway-only RPC directly", () => {
    expect(gatewayOnly.size).toBeGreaterThan(20);
    expect(APP_RPCS.filter((r) => gatewayOnly.has(r))).toEqual([]);
  });

  it("knows only gateways §6.1 names, each with an App surface", () => {
    const table = section6.slice(section6.indexOf("### 6.1"), section6.indexOf("**The owner's Monvelo codes"));
    for (const g of GATEWAY_NAMES) {
      const row = table.split("\n").find((l) => l.startsWith(`| \`${g}\` |`));
      expect({ g, row: !!row }).toEqual({ g, row: true });
      expect({ g, app: /\|\s*App(, Web)?\s*\|/.test(row ?? "") }).toEqual({ g, app: true });
    }
  });
});
