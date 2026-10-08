import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { z } from "./deps.ts";
import { GatewayError } from "./errors.ts";
import { parseJsonBody, stripTenantKeys } from "./validate.ts";

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
