import { assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import { sha256Hex, ticketSecretFor } from "./secret.ts";

const SERVER_KEY = "test-server-key";
const KEY_A = "c0000000-0000-0000-0000-000000000001";
const KEY_B = "c0000000-0000-0000-0000-000000000002";

Deno.test("same key and idempotency key give the same secret", async () => {
  assertEquals(await ticketSecretFor(SERVER_KEY, KEY_A), await ticketSecretFor(SERVER_KEY, KEY_A));
});

Deno.test("different idempotency keys differ", async () => {
  assertNotEquals(await ticketSecretFor(SERVER_KEY, KEY_A), await ticketSecretFor(SERVER_KEY, KEY_B));
});

Deno.test("a different server key gives a different secret", async () => {
  assertNotEquals(await ticketSecretFor(SERVER_KEY, KEY_A), await ticketSecretFor("another-server-key", KEY_A));
});

Deno.test("ticketSecretFor is 43 url-safe characters", async () => {
  assertMatch(await ticketSecretFor(SERVER_KEY, KEY_A), /^[A-Za-z0-9_-]{43}$/);
});

// computed once with: printf '%s' "$KEY_A" | openssl dgst -sha256 -hmac "$SERVER_KEY" -binary | base64url
Deno.test("ticketSecretFor matches a known HMAC-SHA256 vector", async () => {
  assertEquals(await ticketSecretFor(SERVER_KEY, KEY_A), "7gVF22VgdsTm150o32xFczcy94OwGIyZA2ahqPVIH00");
});

Deno.test("sha256Hex matches a known vector", async () => {
  assertEquals(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});
