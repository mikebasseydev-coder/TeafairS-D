import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { createStorefrontCatalogueHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";

function setup(result: unknown | Error = { code: "GRACE-01", products: [] }) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result as T);
  };
  return { handler: createStorefrontCatalogueHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}

const get = (handler: (r: Request) => Promise<Response>, query: string) =>
  handler(new Request(`http://x/storefront-catalogue${query}`, { headers: { Origin: ORIGIN } }));

Deno.test("the code goes to storefront_catalogue and the reply is CDN-cacheable", async () => {
  const { handler, calls } = setup();
  const res = await get(handler, "?code=grace-01");
  assertEquals(res.status, 200);
  assertEquals(calls, [["storefront_catalogue", { p_code: "grace-01" }]]);
  assertEquals(res.headers.get("cache-control"), "public, max-age=60, s-maxage=300");
  assertEquals(await res.json(), { code: "GRACE-01", products: [] });
});

Deno.test("a missing code is 400 and calls nothing", async () => {
  const { handler, calls } = setup();
  const res = await get(handler, "");
  assertEquals([res.status, calls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("an invalid link is 422 and never cached", async () => {
  const { handler } = setup(new GatewayError(422, "BUSINESS_RULE", "This link is no longer valid"));
  const res = await get(handler, "?code=OFF-01");
  const body = await res.json();
  assertEquals([res.status, body.error.message], [422, "This link is no longer valid"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
});
