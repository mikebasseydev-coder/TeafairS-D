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
