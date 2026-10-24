import { assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import { derivedKey, generateDeliveryPin } from "./code.ts";

Deno.test("delivery pins are always 4 digits", () => {
  for (let i = 0; i < 500; i++) assertMatch(generateDeliveryPin(), /^\d{4}$/);
});

Deno.test("derived keys are stable uuids that differ from the source", async () => {
  const k = "c0000000-0000-0000-0000-000000000001";
  const a = await derivedKey(k, "pin-sent");
  assertMatch(a, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assertEquals(a, await derivedKey(k, "pin-sent"));
  assertNotEquals(a, k);
});
