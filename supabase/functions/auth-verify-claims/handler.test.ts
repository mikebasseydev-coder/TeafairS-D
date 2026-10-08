import { assertEquals } from "jsr:@std/assert@1";
import { createAuthHookHandler } from "./handler.ts";

const event = {
  user_id: "20000000-0000-0000-0000-000000000003",
  claims: { sub: "20000000-0000-0000-0000-000000000003", role: "authenticated", app_metadata: { provider: "email" } },
  authentication_method: "password",
};
const tenantClaims = {
  tenant_ids: ["10000000-0000-0000-0000-000000000001"],
  active_tenant_id: "10000000-0000-0000-0000-000000000001",
  tenant_role: "DSA",
  platform_role: null,
};
const post = (body: unknown) => new Request("http://x", { method: "POST", body: JSON.stringify(body) });

Deno.test("an unsigned or forged hook call is refused", async () => {
  const handler = createAuthHookHandler({
    verifyHook: () => {
      throw new Error("bad signature");
    },
    claimsFor: () => Promise.resolve(tenantClaims),
  });
  const res = await handler(post(event));
  assertEquals(res.status, 401);
});

Deno.test("tenant claims are merged into app_metadata, keeping every existing claim", async () => {
  const seen: string[] = [];
  const handler = createAuthHookHandler({
    verifyHook: (payload) => JSON.parse(payload),
    claimsFor: (id) => {
      seen.push(id);
      return Promise.resolve(tenantClaims);
    },
  });
  const res = await handler(post(event));
  assertEquals(res.status, 200);
  assertEquals(seen, [event.user_id]);
  assertEquals(await res.json(), {
    claims: { ...event.claims, app_metadata: { provider: "email", ...tenantClaims } },
  });
});

Deno.test("a signed payload of the wrong shape is 400", async () => {
  const handler = createAuthHookHandler({
    verifyHook: () => ({ nope: true }),
    claimsFor: () => Promise.resolve(tenantClaims),
  });
  assertEquals((await handler(post({}))).status, 400);
});

Deno.test("a database failure fails the sign-in closed, in the hook error shape", async () => {
  const handler = createAuthHookHandler({
    verifyHook: (payload) => JSON.parse(payload),
    claimsFor: () => Promise.reject(new Error("db down")),
  });
  const res = await handler(post(event));
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error.http_code, 500);
});
