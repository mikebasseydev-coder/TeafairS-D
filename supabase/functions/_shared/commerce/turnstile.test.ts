import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { turnstileVerifier } from "./turnstile.ts";

function fakeFetch(body: unknown, seen: Request[] = [], status = 200): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
}

Deno.test("a passing token is verified with the secret, token and IP", async () => {
  const seen: Request[] = [];
  const verify = turnstileVerifier({ secretKey: "s3cret", fetchFn: fakeFetch({ success: true }, seen) });
  assertEquals(await verify("tok", "1.2.3.4"), true);
  assertEquals(seen[0].url, "https://challenges.cloudflare.com/turnstile/v0/siteverify");
  const form = await seen[0].formData();
  assertEquals([form.get("secret"), form.get("response"), form.get("remoteip")], ["s3cret", "tok", "1.2.3.4"]);
});

Deno.test("a failed check is false", async () => {
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: fakeFetch({ success: false, "error-codes": ["invalid-input-response"] }) });
  assertEquals(await verify("bad", null), false);
});

Deno.test("a URL override is honoured (local fake)", async () => {
  const seen: Request[] = [];
  await turnstileVerifier({ secretKey: "s", url: "http://host.docker.internal:54399/turnstile/v0/siteverify", fetchFn: fakeFetch({ success: true }, seen) })("t", null);
  assertEquals(seen[0].url, "http://host.docker.internal:54399/turnstile/v0/siteverify");
});

Deno.test("a network failure throws, so the gateway can answer 503", async () => {
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: () => Promise.reject(new TypeError("network down")) });
  await assertRejects(() => verify("t", null), TypeError);
});

function rawFetch(body: string, status = 200): typeof fetch {
  return () => Promise.resolve(new Response(body, { status }));
}

Deno.test("an HTTP error is an outage, not a failed check", async () => {
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: rawFetch(JSON.stringify({ success: false }), 500) });
  await assertRejects(() => verify("t", null), Error, "HTTP 500");
});

Deno.test("an HTTP error names Cloudflare's error codes, never the secret", async () => {
  const verify = turnstileVerifier({
    secretKey: "s3cret-value",
    fetchFn: rawFetch(JSON.stringify({ success: false, "error-codes": ["invalid-input-secret"] }), 400),
  });
  const err = await assertRejects(() => verify("t", null), Error, "HTTP 400 (invalid-input-secret)");
  assertEquals(err.message.includes("s3cret-value"), false);
});

Deno.test("operator error codes throw and never leak the secret", async () => {
  for (const code of ["invalid-input-secret", "missing-input-secret", "internal-error"]) {
    const verify = turnstileVerifier({
      secretKey: "s3cret-value",
      fetchFn: rawFetch(JSON.stringify({ success: false, "error-codes": [code] })),
    });
    const err = await assertRejects(() => verify("t", null), Error, code);
    assertEquals(err.message.includes("s3cret-value"), false);
  }
});

Deno.test("an internal-error body without success still throws", async () => {
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: rawFetch(JSON.stringify({ "error-codes": ["internal-error"] })) });
  await assertRejects(() => verify("t", null), Error, "internal-error");
});

Deno.test("a null or non-JSON body throws", async () => {
  await assertRejects(() => turnstileVerifier({ secretKey: "s", fetchFn: rawFetch("null") })("t", null), Error);
  await assertRejects(() => turnstileVerifier({ secretKey: "s", fetchFn: rawFetch("<html>oops</html>") })("t", null), Error);
});

Deno.test("a replayed token is a plain false", async () => {
  const verify = turnstileVerifier({
    secretKey: "s",
    fetchFn: rawFetch(JSON.stringify({ success: false, "error-codes": ["timeout-or-duplicate"] })),
  });
  assertEquals(await verify("t", null), false);
});

Deno.test("a hung siteverify call is aborted by the timeout", async () => {
  const hang: typeof fetch = (_i, init) =>
    new Promise((_res, rej) => {
      init?.signal?.addEventListener("abort", () => rej(init.signal!.reason));
    });
  const verify = turnstileVerifier({ secretKey: "s", fetchFn: hang, timeoutMs: 10 });
  await assertRejects(() => verify("t", null));
});
