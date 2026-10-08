import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { kudiSmsSender, smsSenderFromEnv } from "./sms.ts";

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
