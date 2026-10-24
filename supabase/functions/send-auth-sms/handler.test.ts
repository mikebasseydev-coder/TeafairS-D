import { assertEquals } from "jsr:@std/assert@1";
import { hookResultCode } from "../_shared/auth/hook.ts";
import { MessageDeliveryError, type OutboundMessage } from "../_shared/messaging/router.ts";
import { createSendAuthSmsHandler } from "./handler.ts";

const USER = "20000000-0000-0000-0000-000000000003";
const event = (over: Record<string, unknown> = {}) => ({
  user: { id: USER, phone: "2348031234567", phone_change: "", ...over },
  sms: { otp: "482913" },
});

function setup(opts: { allowed?: boolean; badSignature?: boolean; sendFails?: boolean; smsFallback?: boolean } = {}) {
  const sent: Array<[string, OutboundMessage]> = [];
  const checked: Array<[string, string]> = [];
  const handler = createSendAuthSmsHandler({
    verifyHook: (payload) => {
      if (opts.badSignature) throw new Error("bad signature");
      return JSON.parse(payload);
    },
    isAllowed: (userId, phone) => {
      checked.push([userId, phone]);
      return Promise.resolve(opts.allowed ?? true);
    },
    sendMessage: (to, msg) => {
      if (opts.sendFails) return Promise.reject(new MessageDeliveryError("down"));
      sent.push([to, msg]);
      return Promise.resolve({ channel: "WHATSAPP", sent: true });
    },
    smsFallback: opts.smsFallback ?? false,
  });
  return { handler, sent, checked };
}

const post = (body: unknown) => new Request("http://x", { method: "POST", body: JSON.stringify(body) });

Deno.test("an allowed member's sign-in code goes out on WhatsApp only, by default", async () => {
  const { handler, sent, checked } = setup();
  const res = await handler(post(event()));
  assertEquals([res.status, await res.json()], [200, {}]);
  assertEquals(checked, [[USER, "+2348031234567"]]);
  assertEquals(sent.length, 1);
  assertEquals(sent[0][0], "+2348031234567");
  assertEquals(sent[0][1].purpose, "AUTH_OTP");
  assertEquals(sent[0][1].template, { name: "teafair_otp", language: "en", params: ["482913"], kind: "authentication" });
  assertEquals(sent[0][1].smsText.includes("482913"), true);
  assertEquals(sent[0][1].tenantId, undefined); // platform-level: no tenant reads the log
  assertEquals(sent[0][1].whatsappOnly, true); // user decision: no SMS fallback by default
});

Deno.test("AUTH_OTP_SMS_FALLBACK lets the router fall back to SMS", async () => {
  const { handler, sent } = setup({ smsFallback: true });
  await handler(post(event()));
  assertEquals(sent[0][1].whatsappOnly, false);
});

Deno.test("Nigerian numbers in every form become E.164", async () => {
  for (const phone of ["2348031234567", "+2348031234567", "08031234567"]) {
    const { handler, sent } = setup();
    await handler(post(event({ phone })));
    assertEquals(sent[0][0], "+2348031234567", phone);
  }
});

Deno.test("an unsigned or forged call is 401 and sends nothing", async () => {
  const { handler, sent } = setup({ badSignature: true });
  assertEquals(await hookResultCode(await handler(post(event()))), 401);
  assertEquals(sent, []);
});

Deno.test("a number with no Teafair access gets no code", async () => {
  const { handler, sent } = setup({ allowed: false });
  const res = await handler(post(event()));
  assertEquals(await hookResultCode(res), 403);
  assertEquals(sent, []);
});

Deno.test("a phone change is refused before any lookup", async () => {
  const { handler, sent, checked } = setup();
  const res = await handler(post(event({ phone_change: "2348099999999" })));
  assertEquals([await hookResultCode(res), checked.length, sent.length], [403, 0, 0]);
});

Deno.test("a malformed payload or number is 400", async () => {
  const { handler } = setup();
  assertEquals(await hookResultCode(await handler(post({ user: { id: USER } }))), 400);
  assertEquals(await hookResultCode(await handler(post(event({ phone: "12" })))), 400);
});

Deno.test("failing every channel is 502, and the reply never echoes the phone or the code", async () => {
  const { handler } = setup({ sendFails: true });
  const res = await handler(post(event()));
  assertEquals(await hookResultCode(res), 502);
  const text = await res.text();
  assertEquals(text.includes("482913") || text.includes("8031234567"), false);
});
