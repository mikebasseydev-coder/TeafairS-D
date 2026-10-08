import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { authenticate } from "./jwt.ts";
import { GatewayError } from "./errors.ts";

const req = (authorization?: string) =>
  new Request("http://x", { method: "POST", headers: authorization ? { Authorization: authorization } : {} });
const verifying = (claims: Record<string, unknown> | null) => () => Promise.resolve(claims);

const user = {
  sub: "20000000-0000-0000-0000-000000000003",
  role: "authenticated",
  app_metadata: { active_tenant_id: "10000000-0000-0000-0000-000000000001", tenant_role: "DSA", platform_role: null },
};

Deno.test("a missing Authorization header is 401", async () => {
  const e = await assertRejects(() => authenticate(req(), verifying(user)), GatewayError);
  assertEquals([e.status, e.code], [401, "UNAUTHENTICATED"]);
});

Deno.test("a non-Bearer header is 401", async () => {
  await assertRejects(() => authenticate(req("Basic abc"), verifying(user)), GatewayError);
});

Deno.test("a token the verifier rejects is 401", async () => {
  await assertRejects(() => authenticate(req("Bearer bad"), verifying(null)), GatewayError);
});

Deno.test("the anon key is not a user (§3.1 step 1)", async () => {
  await assertRejects(() => authenticate(req("Bearer anon"), verifying({ role: "anon" })), GatewayError);
});

Deno.test("anonymous sign-ins are rejected", async () => {
  await assertRejects(
    () => authenticate(req("Bearer t"), verifying({ ...user, is_anonymous: true })),
    GatewayError,
  );
});

Deno.test("a verified user yields the caller and the claims it proposes", async () => {
  const caller = await authenticate(req("Bearer tok"), verifying(user));
  assertEquals(caller, {
    userId: user.sub,
    authorization: "Bearer tok",
    activeTenantId: "10000000-0000-0000-0000-000000000001",
    tenantRole: "DSA",
    platformRole: null,
  });
});
