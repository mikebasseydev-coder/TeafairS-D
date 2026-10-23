import { assertEquals, assertMatch, assertStringIncludes } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { MessageDeliveryError, type OutboundMessage } from "../_shared/messaging/router.ts";
import { createCheckoutPhoneVerifyStartHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const STARTED = { verification_id: "a0000000-0000-0000-0000-000000000001", expires_at: "2026-10-23T10:10:00Z" };

function setup(opts: { human?: boolean; sendError?: Error; rpcError?: Error } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const sent: Array<[string, OutboundMessage]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return opts.rpcError ? Promise.reject(opts.rpcError) : Promise.resolve(STARTED as T);
  };
  const handler = createCheckoutPhoneVerifyStartHandler({
    rpc,
    allowedOrigins: [ORIGIN],
    verifyTurnstile: () => Promise.resolve(opts.human ?? true),
    generateCode: () => "482913",
    sendMessage: (to, msg) => {
      sent.push([to, msg]);
      return opts.sendError ? Promise.reject(opts.sendError) : Promise.resolve({ channel: "WHATSAPP", sent: true });
    },
  });
  return { handler, rpcCalls, sent };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/checkout-phone-verify-start", {
    method: "POST",
    headers: { Origin: ORIGIN, "cf-connecting-ip": "1.2.3.4" },
    body: JSON.stringify(body),
  }));

const body = (over: Record<string, unknown> = {}) => ({ turnstile_token: "tok", phone: "0803 123 4567", ...over });

Deno.test("bot check failure is 403 and sends nothing", async () => {
  const { handler, rpcCalls, sent } = setup({ human: false });
  const res = await post(handler, body());
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length, sent.length], [403, "BOT_CHECK_FAILED", 0, 0]);
});

Deno.test("an unusable phone is 400 before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, body({ phone: "12345" }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("WhatsApp failure is 503 WHATSAPP_UNAVAILABLE and never falls back to SMS", async () => {
  const { handler, sent } = setup({ sendError: new MessageDeliveryError() });
  const res = await post(handler, body());
  const err = (await res.json()).error;
  assertEquals([res.status, err.code], [503, "WHATSAPP_UNAVAILABLE"]);
  assertEquals(err.message, "We couldn't reach WhatsApp. Please try again in a few minutes.");
  assertEquals(sent[0][1].whatsappOnly, true);
});

Deno.test("sends the code only to WhatsApp and never returns it", async () => {
  const { handler, rpcCalls, sent } = setup();
  const res = await post(handler, body());
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(JSON.parse(text), STARTED);
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(rpcCalls, [[
    "start_web_phone_verification",
    { p_phone: "+2348031234567", p_code: "482913", p_client_ip: "1.2.3.4" },
  ]]);
  const [to, msg] = sent[0];
  assertEquals([to, msg.purpose, msg.whatsappOnly, msg.template.params], ["+2348031234567", "PHONE_VERIFY", true, ["482913"]]);
  assertEquals(msg.template.kind, "authentication");
  assertEquals(msg.smsText.includes("482913"), false);
  assertEquals(text.includes("482913"), false);
  assertMatch(msg.relatedId ?? "", /^a0000000/);
});

Deno.test("the throttle (P0001) reaches the buyer as 422 with its copy and nothing is sent", async () => {
  const { handler, sent } = setup({
    rpcError: new GatewayError(422, "BUSINESS_RULE", "Too many messages. Please wait a few minutes."),
  });
  const res = await post(handler, body());
  assertEquals([res.status, sent.length], [422, 0]);
  assertStringIncludes((await res.json()).error.message, "Too many messages");
});
