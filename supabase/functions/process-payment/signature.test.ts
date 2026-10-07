import { assertEquals } from "jsr:@std/assert@1";
import { paystackSignatureValid } from "./signature.ts";

// HMAC-SHA512('sk_test_secret', '{"event":"charge.success"}'), computed independently
const body = '{"event":"charge.success"}';
const expected =
  "d2c20958e71984927bee0613f77fa295c3fa82f681cebac2f292d603fbc0ec52d7302b91f7beb43b3e289b0cee9b9867daf70f7a5b1af70eb4d8da1909b5fd36";

Deno.test("a correct HMAC-SHA512 of the raw body is valid", async () => {
  assertEquals(await paystackSignatureValid(body, expected, "sk_test_secret"), true);
});

Deno.test("hex case does not matter", async () => {
  assertEquals(await paystackSignatureValid(body, expected.toUpperCase(), "sk_test_secret"), true);
});

Deno.test("a re-serialised body (whitespace changed) is invalid: hash the raw bytes", async () => {
  assertEquals(await paystackSignatureValid('{"event": "charge.success"}', expected, "sk_test_secret"), false);
});

Deno.test("a wrong key, missing header or truncated signature is invalid", async () => {
  assertEquals(await paystackSignatureValid(body, expected, "sk_test_other"), false);
  assertEquals(await paystackSignatureValid(body, null, "sk_test_secret"), false);
  assertEquals(await paystackSignatureValid(body, expected.slice(0, 64), "sk_test_secret"), false);
});
