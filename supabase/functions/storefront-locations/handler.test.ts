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

const get = (handler: (r: Request) => Promise<Response>, query: string) =>
  handler(new Request(`http://x/storefront-locations${query}`, { headers: { Origin: ORIGIN } }));

Deno.test("returns the RPC reply with an hour's public cache", async () => {
  const { handler, calls } = setup();
  const res = await get(handler, "?code=grace-01");
  assertEquals(res.status, 200);
  assertEquals(calls, [["storefront_locations", { p_code: "grace-01" }]]);
  assertEquals(res.headers.get("cache-control"), "public, max-age=3600");
  assertEquals(await res.json(), REPLY);
});

Deno.test("code is optional", async () => {
  const { handler, calls } = setup();
  const res = await get(handler, "");
  assertEquals(res.status, 200);
  assertEquals(calls, [["storefront_locations", { p_code: null }]]);
  await res.body?.cancel();
});

Deno.test("POST is 405: a POST reply is never cached by a CDN", async () => {
  const { handler, calls } = setup();
  const res = await handler(new Request("http://x/storefront-locations", {
    method: "POST", headers: { Origin: ORIGIN, "content-type": "application/json" }, body: "{}",
  }));
  assertEquals(res.status, 405);
  assertEquals(calls.length, 0);
  await res.body?.cancel();
});
