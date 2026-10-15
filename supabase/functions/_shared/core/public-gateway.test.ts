import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "./db.ts";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { publicGateway } from "./public-gateway.ts";

const ORIGIN = "https://teafairweb.com";
const rpc: Rpc = <T>() => Promise.resolve({} as T);
const deps = { rpc, allowedOrigins: [ORIGIN] };

const getRoute = publicGateway(
  { method: "GET", schema: z.object({ code: z.string().min(4) }), cacheControl: "public, max-age=60" },
  ({ body }) => Promise.resolve({ code: body.code }),
  deps,
);
const postRoute = publicGateway(
  { method: "POST", schema: z.object({ n: z.number() }).passthrough() },
  ({ body }) => {
    if (body.n < 0) throw new GatewayError(422, "BUSINESS_RULE", "negative");
    return Promise.resolve({ keys: Object.keys(body).sort() });
  },
  deps,
);

const req = (method: string, url: string, opts: { origin?: string; body?: unknown } = {}) =>
  new Request(url, {
    method,
    headers: opts.origin ? { Origin: opts.origin } : {},
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });

Deno.test("a preflight from the storefront is answered with CORS headers", async () => {
  const res = await getRoute(req("OPTIONS", "http://x/", { origin: ORIGIN }));
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("a preflight from any other origin is refused", async () => {
  const res = await getRoute(req("OPTIONS", "http://x/", { origin: "https://evil.example" }));
  assertEquals(res.status, 403);
  assertEquals(res.headers.get("access-control-allow-origin"), null);
});

Deno.test("a GET from the storefront validates the query and sets cache headers", async () => {
  const res = await getRoute(req("GET", "http://x/?code=GRACE-01", { origin: ORIGIN }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { code: "GRACE-01" });
  assertEquals(res.headers.get("cache-control"), "public, max-age=60");
  assertEquals(res.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("a request from another origin is 403", async () => {
  const res = await getRoute(req("GET", "http://x/?code=GRACE-01", { origin: "https://evil.example" }));
  assertEquals([res.status, (await res.json()).error.code], [403, "ORIGIN_NOT_ALLOWED"]);
});

Deno.test("a server-side request with no Origin is served without CORS headers", async () => {
  const res = await getRoute(req("GET", "http://x/?code=GRACE-01"));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("access-control-allow-origin"), null);
  await res.body?.cancel();
});

Deno.test("errors are never cached", async () => {
  const res = await getRoute(req("GET", "http://x/?code=ab", { origin: ORIGIN }));
  assertEquals([res.status, (await res.json()).error.code], [400, "VALIDATION_FAILED"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(res.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("the wrong method is 405", async () => {
  const res = await getRoute(req("POST", "http://x/", { origin: ORIGIN, body: {} }));
  assertEquals(res.status, 405);
  await res.body?.cancel();
});

Deno.test("a POST body has tenant keys stripped before validation", async () => {
  const res = await postRoute(req("POST", "http://x/", { origin: ORIGIN, body: { n: 1, tenant_id: "evil", tenantId: "evil" } }));
  assertEquals(await res.json(), { keys: ["n"] });
});

Deno.test("business errors keep the §3.5 shape and no-store", async () => {
  const res = await postRoute(req("POST", "http://x/", { origin: ORIGIN, body: { n: -1 } }));
  assertEquals([res.status, (await res.json()).error.code], [422, "BUSINESS_RULE"]);
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("every response carries Vary: Origin, with or without an Origin", async () => {
  const ok = await getRoute(req("GET", "http://x/?code=GRACE-01", { origin: ORIGIN }));
  assertEquals(ok.headers.get("vary"), "Origin");
  await ok.body?.cancel();

  const noOrigin = await getRoute(req("GET", "http://x/?code=GRACE-01"));
  assertEquals(noOrigin.headers.get("vary"), "Origin");
  await noOrigin.body?.cancel();

  const denied = await getRoute(req("GET", "http://x/?code=GRACE-01", { origin: "https://evil.example" }));
  assertEquals([denied.status, denied.headers.get("vary")], [403, "Origin"]);
  await denied.body?.cancel();

  const pre = await getRoute(req("OPTIONS", "http://x/", { origin: ORIGIN }));
  assertEquals([pre.status, pre.headers.get("vary"), pre.headers.get("cache-control")], [204, "Origin", "no-store"]);

  const preDenied = await getRoute(req("OPTIONS", "http://x/", { origin: "https://evil.example" }));
  assertEquals([preDenied.status, preDenied.headers.get("vary"), preDenied.headers.get("cache-control")], [403, "Origin", "no-store"]);
});
