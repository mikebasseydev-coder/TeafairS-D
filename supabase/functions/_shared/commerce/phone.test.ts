import { assertEquals } from "jsr:@std/assert@1";
import { normalizePhone } from "./phone.ts";

Deno.test("Nigerian local numbers become E.164", () => {
  assertEquals(normalizePhone("08031234567"), "+2348031234567");
  assertEquals(normalizePhone("0803 123 4567"), "+2348031234567");
  assertEquals(normalizePhone("0703-123-4567"), "+2347031234567");
});

Deno.test("international forms are accepted with or without +", () => {
  assertEquals(normalizePhone("+234 803-123-4567"), "+2348031234567");
  assertEquals(normalizePhone("2348031234567"), "+2348031234567");
  assertEquals(normalizePhone("(+234) 803 123 4567"), "+2348031234567");
  assertEquals(normalizePhone("+447700900123"), "+447700900123");
});

Deno.test("anything else is rejected", () => {
  assertEquals(normalizePhone("12345"), null);
  assertEquals(normalizePhone("0803123456"), null);
  assertEquals(normalizePhone("call me"), null);
  assertEquals(normalizePhone(""), null);
});
