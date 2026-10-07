import { assertEquals } from "jsr:@std/assert@1";
import { errorResponse, GatewayError, mapPostgresError } from "./errors.ts";

const contract: Array<[string, number, string]> = [
  ["P0001", 422, "BUSINESS_RULE"],
  ["42501", 403, "FORBIDDEN"],
  ["23505", 409, "CONFLICT"],
  ["TF001", 409, "INSUFFICIENT_STOCK"],
  ["TF002", 409, "IDEMPOTENCY_MISMATCH"],
  ["40001", 503, "RETRY"],
  ["55P03", 503, "RETRY"],
  ["PGRST301", 401, "UNAUTHENTICATED"], // plan amendment 4
];

for (const [pg, status, code] of contract) {
  Deno.test(`Spec A §3.5: ${pg} maps to ${status} ${code}`, () => {
    const e = mapPostgresError({ code: pg, message: "boom" });
    assertEquals([e.status, e.code], [status, code]);
  });
}

Deno.test("business messages reach the user; retry messages are generic", () => {
  assertEquals(mapPostgresError({ code: "P0001", message: "zone_name is required" }).message, "zone_name is required");
  assertEquals(mapPostgresError({ code: "40001", message: "request x is still in progress" }).message,
    "The server is busy. Please try again.");
});

Deno.test("an expired JWT asks the client to sign in again, not to retry", () => {
  assertEquals(mapPostgresError({ code: "PGRST301", message: "JWT expired" }).message, "Sign in to continue.");
});

Deno.test("TF001 carries structured detail parsed from the Postgres DETAIL", () => {
  const e = mapPostgresError({ code: "TF001", message: "insufficient stock", details: '{"sku_code":"MILO-400","available":2}' });
  assertEquals(e.details, { sku_code: "MILO-400", available: 2 });
});

Deno.test("an unknown code is a generic 500 that leaks nothing", () => {
  const e = mapPostgresError({ code: "XX000", message: "relation secret_table does not exist" });
  assertEquals([e.status, e.code, e.message], [500, "INTERNAL", "Something went wrong. Please try again."]);
});

Deno.test("errorResponse renders the client-facing shape", async () => {
  const res = errorResponse(new GatewayError(422, "BUSINESS_RULE", "nope", { field: "x" }));
  assertEquals(res.status, 422);
  assertEquals(await res.json(), { error: { code: "BUSINESS_RULE", message: "nope", details: { field: "x" } } });
});

Deno.test("errorResponse hides unexpected exceptions behind a 500", async () => {
  const res = errorResponse(new Error("stack trace with secrets"));
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error.code, "INTERNAL");
});
