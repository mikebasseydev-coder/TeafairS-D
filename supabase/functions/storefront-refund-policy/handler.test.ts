import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createStorefrontRefundPolicyHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const POLICY = {
  version_tag: "v2.0-food-cosmetics",
  title: "Refunds",
  content: "...",
  categories: ["FOOD"],
  published_at: "2026-10-23T00:00:00Z",
};

function setup(result: unknown) {
  const calls: string[] = [];
  const rpc: Rpc = <T>(fn: string) => {
    calls.push(fn);
    return Promise.resolve(result as T);
  };
  return { handler: createStorefrontRefundPolicyHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}
const get = (h: (r: Request) => Promise<Response>) =>
  h(new Request("http://x/storefront-refund-policy", { headers: { Origin: ORIGIN } }));

Deno.test("null is 404", async () => {
  const { handler } = setup(null);
  const res = await get(handler);
  assertEquals([res.status, (await res.json()).error.code], [404, "NOT_FOUND"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("cached for 5 minutes", async () => {
  const { handler, calls } = setup(POLICY);
  const res = await get(handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), POLICY);
  assertEquals(res.headers.get("cache-control"), "public, max-age=300");
  assertEquals(calls, ["web_active_refund_policy"]);
});
