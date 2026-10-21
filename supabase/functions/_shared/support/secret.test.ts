import { assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import { newTicketSecret, sha256Hex } from "./secret.ts";

Deno.test("newTicketSecret is 43 url-safe characters and differs each call", () => {
  const a = newTicketSecret();
  const b = newTicketSecret();
  assertMatch(a, /^[A-Za-z0-9_-]{43}$/);
  assertNotEquals(a, b);
});

Deno.test("sha256Hex matches a known vector", async () => {
  assertEquals(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});
