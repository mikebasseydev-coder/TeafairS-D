import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { assertSafeSmsProvider, kudiSmsSender, smsSenderFromEnv } from "./sms.ts";

function fakeFetch(response: unknown, status = 200, seen: Request[] = []): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(response), { status }));
  };
}

Deno.test("KudiSMS receives the token, sender, recipient without '+', and message as a form", async () => {
  const seen: Request[] = [];
  const send = kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({ error_code: "000" }, 200, seen) });
  await send("+2348000000005", "Your code is 123456");
  assertEquals(seen[0].method, "POST");
  assertEquals(seen[0].url, "https://my.kudisms.net/api/sms");
  const form = new URLSearchParams(await seen[0].text());
  assertEquals(
    [form.get("token"), form.get("senderID"), form.get("recipients"), form.get("message")],
    ["tok", "Teafair", "2348000000005", "Your code is 123456"],
  );
});

Deno.test("a KudiSMS error code is a failed send", async () => {
  const send = kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({ error_code: "100", msg: "Token provided is invalid" }) });
  await assertRejects(() => send("+2348000000005", "x"), Error, "Token provided is invalid");
});

Deno.test("an HTTP failure is a failed send", async () => {
  const send = kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({}, 500) });
  await assertRejects(() => send("+2348000000005", "x"));
});

Deno.test("there is no default SMS provider", () => {
  Deno.env.delete("SMS_PROVIDER");
  let threw = false;
  try {
    smsSenderFromEnv();
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});

Deno.test("no gateway field is sent unless KUDISMS_GATEWAY is set", async () => {
  const seen: Request[] = [];
  await kudiSmsSender({ token: "tok", senderId: "Teafair", fetchFn: fakeFetch({ error_code: "000" }, 200, seen) })("+2348000000005", "x");
  await kudiSmsSender({ token: "tok", senderId: "Teafair", gateway: "2", fetchFn: fakeFetch({ error_code: "000" }, 200, seen) })("+2348000000005", "x");
  assertEquals(new URLSearchParams(await seen[0].text()).has("gateway"), false);
  assertEquals(new URLSearchParams(await seen[1].text()).get("gateway"), "2");
});

Deno.test("the console provider runs on the local stack only (audit L1)", () => {
  for (const url of ["http://kong:8000", "http://127.0.0.1:54321", "http://localhost:54321"]) {
    assertSafeSmsProvider("log", url);
  }
  for (const url of ["https://vwmjyfjdwrohfizljxrq.supabase.co", "https://kong.example.com", "", undefined, "not a url"]) {
    assertThrows(() => assertSafeSmsProvider("log", url), Error, "local stack only");
  }
  assertSafeSmsProvider("kudisms", "https://vwmjyfjdwrohfizljxrq.supabase.co");
});

Deno.test("smsSenderFromEnv refuses SMS_PROVIDER=log on a hosted project", () => {
  const before = Deno.env.get("SUPABASE_URL");
  Deno.env.set("SMS_PROVIDER", "log");
  Deno.env.set("SUPABASE_URL", "https://example.supabase.co");
  try {
    assertThrows(() => smsSenderFromEnv(), Error, "local stack only");
  } finally {
    Deno.env.delete("SMS_PROVIDER");
    if (before === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", before);
  }
});
