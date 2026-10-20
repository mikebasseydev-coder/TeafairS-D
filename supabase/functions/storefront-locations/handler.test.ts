import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createStorefrontLocationsHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const REPLY = { states: [] };

function setup() {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve(REPLY as T);
  };
  return { handler: createStorefrontLocationsHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/storefront-locations", { method: "POST", headers: { Origin: ORIGIN }, body: JSON.stringify(body) }));

Deno.test("returns the RPC reply with an hour's public cache", async () => {
  const { handler, calls } = setup();
  const res = await post(handler, { code: "grace-01" });
  assertEquals(res.status, 200);
  assertEquals(calls, [["storefront_locations", { p_code: "grace-01" }]]);
  assertEquals(res.headers.get("cache-control"), "public, max-age=3600");
  assertEquals(await res.json(), REPLY);
});

Deno.test("code is optional", async () => {
  const { handler, calls } = setup();
  const res = await post(handler, {});
  assertEquals(res.status, 200);
  assertEquals(calls, [["storefront_locations", { p_code: null }]]);
  await res.body?.cancel();
});
