import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { hookResultCode } from "../_shared/auth/hook.ts";
import { type AuthEmailContext, createSendAuthEmailHandler, safeRedirect } from "./handler.ts";
import { type Email, EmailDeliveryError, resendSender } from "../_shared/messaging/resend.ts";

const USER = "20000000-0000-0000-0000-000000000003";
const SITE = "https://teafair.example";
const config = {
  linkBase: "https://ref.supabase.co",
  redirectAllowlist: [SITE, `${SITE}/reset-password`],
  defaultRedirect: SITE,
  recoveryRedirect: `${SITE}/reset-password`,
};

function setup(opts: {
  badSignature?: boolean;
  sendFails?: boolean;
  context?: { allowed: boolean; audience: string };
  contextFails?: boolean;
} = {}) {
  const sent: Email[] = [];
  const asked: string[] = [];
  const handler = createSendAuthEmailHandler({
    verifyHook: (payload) => {
      if (opts.badSignature) throw new Error("bad signature");
      return JSON.parse(payload);
    },
    emailContext: (userId) => {
      asked.push(userId);
      if (opts.contextFails) return Promise.reject(new Error("db down"));
      return Promise.resolve((opts.context ?? { allowed: true, audience: "TEAM" }) as AuthEmailContext);
    },
    sendEmail: (email) => {
      if (opts.sendFails) return Promise.reject(new EmailDeliveryError(422));
      sent.push(email);
      return Promise.resolve();
    },
    config,
  });
  return { handler, sent, asked };
}

const event = (action: string, data: Record<string, unknown> = {}, user: Record<string, unknown> = {}) => ({
  user: { id: USER, email: "ada@example.com", new_email: "", ...user },
  email_data: { email_action_type: action, token: "123456", token_hash: "hash-abc", token_new: "", token_hash_new: "",
    redirect_to: "", site_url: SITE, ...data },
});
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("http://x", { method: "POST", body: JSON.stringify(body), headers });

const linkOf = (email: Email) => new URL(/href="([^"]+)"/.exec(email.html)![1].replaceAll("&amp;", "&"));

Deno.test("a recovery email links to Supabase Auth's verify with the token hash and the reset page", async () => {
  const { handler, sent } = setup();
  const res = await handler(post(event("recovery"), { "webhook-id": "msg_1" }));
  assertEquals([res.status, await res.json()], [200, {}]);
  assertEquals(sent.length, 1);
  assertEquals([sent[0].to, sent[0].subject], ["ada@example.com", "Reset your Teafair password"]);
  const link = linkOf(sent[0]);
  assertEquals(`${link.origin}${link.pathname}`, "https://ref.supabase.co/auth/v1/verify");
  assertEquals(link.searchParams.get("token"), "hash-abc");
  assertEquals(link.searchParams.get("type"), "recovery");
  assertEquals(link.searchParams.get("redirect_to"), `${SITE}/reset-password`);
  assertEquals(sent[0].idempotencyKey, "msg_1:recovery");
  assert(sent[0].text.includes(link.toString()));
});

Deno.test("the raw OTP token never appears in an email", async () => {
  for (const action of ["recovery", "signup", "invite"]) {
    const { handler, sent } = setup();
    await handler(post(event(action)));
    assertEquals(sent[0].html.includes("123456") || sent[0].text.includes("123456"), false, action);
  }
});

Deno.test("signup and invite links carry their own type", async () => {
  for (const action of ["signup", "invite"]) {
    const { handler, sent } = setup();
    await handler(post(event(action)));
    assertEquals(linkOf(sent[0]).searchParams.get("type"), action);
    assertEquals(linkOf(sent[0]).searchParams.get("redirect_to"), SITE);
  }
});

Deno.test("a secure email change mails both addresses, each with its own (crossed) token hash", async () => {
  const { handler, sent } = setup();
  await handler(post(event("email_change", { token_hash: "hash-new-addr", token_hash_new: "hash-current-addr" },
    { new_email: "ada.new@example.com" })));
  assertEquals(sent.map((e) => [e.to, linkOf(e).searchParams.get("token"), linkOf(e).searchParams.get("type")]), [
    ["ada@example.com", "hash-current-addr", "email_change"],
    ["ada.new@example.com", "hash-new-addr", "email_change"],
  ]);
});

Deno.test("a single-confirmation email change mails only the new address", async () => {
  const { handler, sent } = setup();
  await handler(post(event("email_change", { token_hash: "hash-new-addr" }, { new_email: "ada.new@example.com" })));
  assertEquals(sent.map((e) => e.to), ["ada.new@example.com"]);
});

Deno.test("reauthentication is refused", async () => {
  const { handler, sent } = setup();
  assertEquals(await hookResultCode(await handler(post(event("reauthentication")))), 400);
  assertEquals(sent, []);
});

Deno.test("a sign-in code (magiclink or email) goes to an allowed person as the code only, no link", async () => {
  for (const action of ["magiclink", "email"]) {
    const { handler, sent, asked } = setup();
    const res = await handler(post(event(action), { "webhook-id": "msg_9" }));
    assertEquals([res.status, await res.json()], [200, {}], action);
    assertEquals(asked, [USER]);
    assertEquals(sent.length, 1);
    assertEquals([sent[0].to, sent[0].subject], ["ada@example.com", "Your Teafair sign-in code"]);
    assert(sent[0].html.includes("123456") && sent[0].text.includes("123456"));
    assert(!/href=|https?:\/\//.test(sent[0].html), "no link in a sign-in code email");
    assert(!sent[0].text.includes("hash-abc"));
    assertEquals(sent[0].idempotencyKey, "msg_9:sign_in");
  }
});

Deno.test("the sign-in copy follows the audience", async () => {
  for (const [audience, subject] of [
    ["TEAM", "Your Teafair sign-in code"],
    ["TRADE", "Your Teafair trade sign-in code"],
    ["MONVELO", "Your Monvelo sign-in code"],
    ["SOMETHING_ELSE", "Your Teafair sign-in code"],
  ]) {
    const { handler, sent } = setup({ context: { allowed: true, audience } });
    await handler(post(event("magiclink")));
    assertEquals(sent[0].subject, subject, audience);
  }
});

Deno.test("a sign-in code is refused (403) to a person auth_email_context does not allow", async () => {
  const { handler, sent } = setup({ context: { allowed: false, audience: "TEAM" } });
  assertEquals(await hookResultCode(await handler(post(event("magiclink")))), 403);
  assertEquals(sent, []);
});

Deno.test("the sign-in gate failing is a 503 and sends nothing", async () => {
  const { handler, sent } = setup({ contextFails: true });
  assertEquals(await hookResultCode(await handler(post(event("email")))), 503);
  assertEquals(sent, []);
});

Deno.test("a sign-in event without a numeric code or an address is 400", async () => {
  for (const [data, user] of [[{ token: "" }, {}], [{ token: "abc123" }, {}], [{}, { email: null }]]) {
    const { handler, sent, asked } = setup();
    assertEquals(await hookResultCode(await handler(post(event("magiclink", data, user)))), 400);
    assertEquals([sent, asked], [[], []]);
  }
});

Deno.test("a sign-in code is never asked about before the signature holds", async () => {
  const { handler, asked } = setup({ badSignature: true });
  assertEquals(await hookResultCode(await handler(post(event("magiclink")))), 401);
  assertEquals(asked, []);
});

Deno.test("an unsigned or forged call is 401 and sends nothing", async () => {
  const { handler, sent } = setup({ badSignature: true });
  assertEquals(await hookResultCode(await handler(post(event("recovery")))), 401);
  assertEquals(sent, []);
});

Deno.test("a Resend failure is 502 and the reply names no address", async () => {
  const { handler } = setup({ sendFails: true });
  const res = await handler(post(event("recovery")));
  assertEquals(await hookResultCode(res), 502);
  assertEquals((await res.text()).includes("ada@"), false);
});

Deno.test("redirect_to: exact allowed URLs only, never another host", () => {
  const fallback = `${SITE}/reset-password`;
  const allow = config.redirectAllowlist;
  assertEquals(safeRedirect(`${SITE}/reset-password`, allow, fallback), `${SITE}/reset-password`);
  assertEquals(safeRedirect(`${SITE}/reset-password?next=//evil.example#x`, allow, fallback), `${SITE}/reset-password`);
  for (const bad of ["https://evil.example/reset-password", `${SITE}.evil.example/`, `${SITE}/admin`,
    "javascript:alert(1)", "//evil.example", "not a url", "", null]) {
    assertEquals(safeRedirect(bad, allow, fallback), fallback, String(bad));
  }
});

Deno.test("a hostile redirect_to in the hook payload falls back to the reset page", async () => {
  const { handler, sent } = setup();
  await handler(post(event("recovery", { redirect_to: "https://evil.example/steal" })));
  assertEquals(linkOf(sent[0]).searchParams.get("redirect_to"), `${SITE}/reset-password`);
});

Deno.test("Resend gets the key, sender, recipient and idempotency key; errors carry only the status", async () => {
  const seen: Request[] = [];
  const send = resendSender({ apiKey: "re_test_key", from: "Teafair <auth@teafair.example>", apiUrl: "http://fake" },
    (input, init) => {
      seen.push(new Request(input as string, init));
      return Promise.resolve(new Response("{}", { status: seen.length === 1 ? 200 : 422 }));
    });
  await send({ to: "ada@example.com", subject: "s", html: "<p>h</p>", text: "t", idempotencyKey: "msg_1:recovery" });
  assertEquals(seen[0].url, "http://fake/emails");
  assertEquals(seen[0].headers.get("authorization"), "Bearer re_test_key");
  assertEquals(seen[0].headers.get("idempotency-key"), "msg_1:recovery");
  const body = await seen[0].json();
  assertEquals([body.from, body.to], ["Teafair <auth@teafair.example>", ["ada@example.com"]]);
  const err = await assertRejects(() => send({ to: "ada@example.com", subject: "s", html: "h", text: "t" }), EmailDeliveryError);
  assertEquals(err.message.includes("ada@") || err.message.includes("re_test_key"), false);
});
