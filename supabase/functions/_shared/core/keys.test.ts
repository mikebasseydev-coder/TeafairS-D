import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { isOpaqueKey, publishableKey, secretKey, secretKeyHeaders } from "./keys.ts";

const envOf = (vars: Record<string, string>) => (name: string) => vars[name];

Deno.test("secretKey reads the default sb_secret_ key from SUPABASE_SECRET_KEYS", () => {
  const env = envOf({
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_aaa", gateway: "sb_secret_bbb" }),
    SUPABASE_SERVICE_ROLE_KEY: "legacy",
  });
  assertEquals(secretKey(env), "sb_secret_aaa");
});

Deno.test("TEAFAIR_SECRET_KEY_NAME picks a named key (a label for revocation, not a scope)", () => {
  const env = envOf({
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_aaa", gateway: "sb_secret_bbb" }),
    TEAFAIR_SECRET_KEY_NAME: "gateway",
  });
  assertEquals(secretKey(env), "sb_secret_bbb");
});

Deno.test("without the dictionary the legacy service_role key is the fallback", () => {
  assertEquals(secretKey(envOf({ SUPABASE_SERVICE_ROLE_KEY: "legacy-jwt" })), "legacy-jwt");
  assertThrows(() => secretKey(envOf({})), Error, "SUPABASE_SERVICE_ROLE_KEY");
});

Deno.test("a dictionary without the named key fails closed, never falling back", () => {
  const env = envOf({
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_aaa" }),
    TEAFAIR_SECRET_KEY_NAME: "gateway",
    SUPABASE_SERVICE_ROLE_KEY: "legacy",
  });
  assertThrows(() => secretKey(env), Error, 'no key named "gateway"');
});

Deno.test("a malformed dictionary or a wrong-prefix value is refused without echoing it", () => {
  assertThrows(() => secretKey(envOf({ SUPABASE_SECRET_KEYS: "{nope" })), Error, "not valid JSON");
  const e = assertThrows(() => secretKey(envOf({ SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_publishable_x" }) })));
  assertEquals((e as Error).message.includes("sb_publishable_x"), false);
});

Deno.test("publishableKey mirrors secretKey with the anon fallback", () => {
  assertEquals(publishableKey(envOf({ SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_p" }) })), "sb_publishable_p");
  assertEquals(publishableKey(envOf({ SUPABASE_ANON_KEY: "anon-jwt" })), "anon-jwt");
});

Deno.test("new-format keys travel on apikey only; legacy JWTs also as Bearer", () => {
  assertEquals(isOpaqueKey("sb_secret_x"), true);
  assertEquals(isOpaqueKey("eyJhbGciOi"), false);
  assertEquals(secretKeyHeaders("sb_secret_x"), { apikey: "sb_secret_x" });
  assertEquals(secretKeyHeaders("eyJ.legacy"), { apikey: "eyJ.legacy", authorization: "Bearer eyJ.legacy" });
});
