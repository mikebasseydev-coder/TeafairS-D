import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { Webhook } from "../core/deps.ts";
import { hookVerifierFromEnv, normalizeHookSecret } from "./hook.ts";

const KEY = btoa("0123456789abcdef0123456789abcdef");
const SECRET = `v1,whsec_${KEY}`;
const ENV = "TEST_HOOK_SECRET_NORMALIZE";

const withEnv = <T>(value: string | undefined, fn: () => T): T => {
  if (value === undefined) Deno.env.delete(ENV);
  else Deno.env.set(ENV, value);
  try {
    return fn();
  } finally {
    Deno.env.delete(ENV);
  }
};

Deno.test("normalizeHookSecret strips the v1,whsec_ prefix", () => {
  assertEquals(normalizeHookSecret(SECRET), KEY);
  assertEquals(normalizeHookSecret(`whsec_${KEY}`), KEY);
  assertEquals(normalizeHookSecret(KEY), KEY);
});

Deno.test("normalizeHookSecret forgives whitespace, CR/LF and one pair of quotes", () => {
  for (
    const mangled of [
      ` ${SECRET} `,
      `${SECRET}\n`,
      `${SECRET}\r\n`,
      `\t${SECRET}\r`,
      `"${SECRET}"`,
      `'${SECRET}'`,
      `"${SECRET}"\r\n`,
      `" ${SECRET} "`,
    ]
  ) assertEquals(normalizeHookSecret(mangled), KEY, JSON.stringify(mangled));
});

Deno.test("normalizeHookSecret leaves an unmatched quote for the decoder to refuse", () => {
  assertEquals(normalizeHookSecret(`"${SECRET}`), `"${SECRET}`);
});

Deno.test("a mangled secret still verifies a genuinely signed payload", () => {
  const id = "msg_1";
  const at = new Date();
  const payload = JSON.stringify({ hello: "world" });
  const signature = new Webhook(KEY).sign(id, at, payload);
  const headers = {
    "webhook-id": id,
    "webhook-timestamp": String(Math.floor(at.getTime() / 1000)),
    "webhook-signature": signature,
  };
  const verify = withEnv(`"${SECRET}"\r\n`, () => hookVerifierFromEnv(ENV));
  assertEquals(verify(payload, headers), { hello: "world" });
});

Deno.test("an undecodable secret fails at boot naming the variable, never the value", () => {
  const bad = "v1,whsec_not*base64!";
  const e = assertThrows(() => withEnv(bad, () => hookVerifierFromEnv(ENV)), Error);
  assertEquals(e.message, `${ENV} is not a valid hook secret (expected v1,whsec_<base64>)`);
  assertEquals(e.message.includes("not*base64"), false);
});

Deno.test("a missing secret still fails at boot as a missing variable", () => {
  assertThrows(() => withEnv(undefined, () => hookVerifierFromEnv(ENV)), Error, `missing environment variable ${ENV}`);
});
