import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { DEFAULT_FROM, EmailDeliveryError, resendSender, senderFrom } from "./resend.ts";

const EMAIL = { to: "owner@example.com", subject: "s", html: "<p>h</p>", text: "t" };

Deno.test("senderFrom falls back to the Resend sandbox sender when unset or blank", () => {
  assertEquals(DEFAULT_FROM, "Teafair <onboarding@resend.dev>");
  assertEquals(senderFrom(undefined), DEFAULT_FROM);
  assertEquals(senderFrom(null), DEFAULT_FROM);
  assertEquals(senderFrom(""), DEFAULT_FROM);
  assertEquals(senderFrom("   "), DEFAULT_FROM);
  assertEquals(senderFrom(" Teafair <auth@teafair.ng> "), "Teafair <auth@teafair.ng>");
});

Deno.test("resendSender posts to /emails with a 10 s abort signal, the sender and the idempotency key", async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fake = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as unknown as typeof fetch;

  await resendSender({ apiKey: "re_test", from: senderFrom(undefined) }, fake)({ ...EMAIL, idempotencyKey: "k1" });

  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://api.resend.com/emails");
  assert(calls[0].init.signal instanceof AbortSignal, "the call carries an abort signal");
  const headers = calls[0].init.headers as Record<string, string>;
  assertEquals(headers.Authorization, "Bearer re_test");
  assertEquals(headers["Idempotency-Key"], "k1");
  const body = JSON.parse(calls[0].init.body as string);
  assertEquals(body.from, DEFAULT_FROM);
  assertEquals(body.to, ["owner@example.com"]);
});

Deno.test("resendSender honours RESEND_API_URL and keeps the key and address out of errors", async () => {
  let seen = "";
  const fake = ((url: string) => {
    seen = url;
    return Promise.resolve(new Response("nope", { status: 403 }));
  }) as unknown as typeof fetch;

  const err = await assertRejects(
    () => resendSender({ apiKey: "re_secret", from: DEFAULT_FROM, apiUrl: "http://fake:9/" }, fake)(EMAIL),
    EmailDeliveryError,
  );
  assertEquals(seen, "http://fake:9/emails");
  assertEquals(err.status, 403);
  assert(!err.message.includes("re_secret") && !err.message.includes("owner@example.com"));
});
