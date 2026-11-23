import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { idempotencyKeyV4, parseJsonBody, stripTenantKeys } from "./validate.ts";

const post = (body: string) => new Request("http://x", { method: "POST", body });

Deno.test("tenant keys are stripped at every depth (decision 4)", () => {
  assertEquals(
    stripTenantKeys({ tenantId: "t", tenant_id: "t", p_tenant_id: "t", a: [{ tenantId: "t", b: 1 }], c: { tenant_id: "t" } }),
    { a: [{ b: 1 }], c: {} },
  );
});

Deno.test("a body that is not JSON is 400 INVALID_JSON", async () => {
  const e = await assertRejects(() => parseJsonBody(post("{nope"), z.object({})), GatewayError);
  assertEquals([e.status, e.code], [400, "INVALID_JSON"]);
});

Deno.test("a body that fails the schema is 400 VALIDATION_FAILED with field errors", async () => {
  const e = await assertRejects(
    () => parseJsonBody(post('{"n":"x"}'), z.object({ n: z.number() })),
    GatewayError,
  );
  assertEquals([e.status, e.code], [400, "VALIDATION_FAILED"]);
  assertEquals(Object.keys((e.details as { fieldErrors: object }).fieldErrors), ["n"]);
});

Deno.test("a client-supplied tenant never reaches the handler, even if the schema names it", async () => {
  const body = await parseJsonBody(post('{"tenant_id":"evil","n":1}'), z.object({ n: z.number(), tenant_id: z.string().optional() }));
  assertEquals(body, { n: 1 });
});

Deno.test("idempotencyKeyV4 takes a v4 UUID only (version 4, RFC 4122 variant)", () => {
  for (const ok of [crypto.randomUUID(), "3f2b8c1e-9d4a-4b7e-8c21-5a6f0e9d1b23", "3F2B8C1E-9D4A-4B7E-AC21-5A6F0E9D1B23"]) {
    assertEquals(idempotencyKeyV4.safeParse(ok).success, true, ok);
  }
  for (const bad of [
    "6ba7b810-9dad-11d1-80b4-00c04fd430c8", // v1
    "01890a5d-ac96-774b-bcce-b302099a8057", // v7
    "3f2b8c1e-9d4a-4b7e-cc21-5a6f0e9d1b23", // version 4, variant c (not RFC 4122)
    "00000000-0000-0000-0000-000000000000", // nil
    "3f2b8c1e9d4a4b7e8c215a6f0e9d1b23",     // no hyphens
    "not-a-uuid", "",
  ]) {
    assertEquals(idempotencyKeyV4.safeParse(bad).success, false, bad);
  }
});
