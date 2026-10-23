import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { createMessageRouter, MessageDeliveryError, type OutboundMessage } from "./router.ts";
import { type WhatsAppConfig, WhatsAppError } from "./whatsapp.ts";

const CFG: WhatsAppConfig = { token: "wa-secret-token", phoneNumberId: "123", apiVersion: "v21.0" };
const PHONE = "+2348012345678";
const CODE = "042917";

const msg = (over: Partial<OutboundMessage> = {}): OutboundMessage => ({
  purpose: "OTP",
  template: { name: "teafair_otp", language: "en", params: [CODE] },
  smsText: `Your Teafair code is ${CODE}.`,
  tenantId: "10000000-0000-0000-0000-000000000001",
  relatedId: "60000000-0000-0000-0000-000000000001",
  ...over,
});

function setup(opts: {
  whatsapp?: WhatsAppConfig | null;
  wa?: (signal: AbortSignal) => Promise<void>;
  smsFails?: boolean;
  timeoutMs?: number;
} = {}) {
  const sms: Array<[string, string]> = [];
  const logs: Array<Record<string, unknown>> = [];
  const waCalls: string[] = [];
  const send = createMessageRouter({
    whatsapp: opts.whatsapp === undefined ? CFG : opts.whatsapp,
    sendWhatsApp: async (_cfg, to, _tpl, signal) => {
      waCalls.push(to);
      await (opts.wa ?? (() => Promise.resolve()))(signal);
    },
    sms: (to, text) => {
      if (opts.smsFails) return Promise.reject(new Error("KudiSMS down"));
      sms.push([to, text]);
      return Promise.resolve();
    },
    log: (entry) => {
      logs.push(entry as unknown as Record<string, unknown>);
      return Promise.resolve();
    },
    timeoutMs: opts.timeoutMs,
  });
  return { send, sms, logs, waCalls };
}

const summary = (logs: Array<Record<string, unknown>>) => logs.map((l) => `${l.channel}/${l.status}`);

Deno.test("WhatsApp success sends no SMS and logs WHATSAPP/SENT", async () => {
  const { send, sms, logs } = setup();
  assertEquals(await send(PHONE, msg()), { channel: "WHATSAPP", sent: true });
  assertEquals(sms, []);
  assertEquals(summary(logs), ["WHATSAPP/SENT"]);
});

Deno.test("WhatsApp non-2xx falls back to SMS and logs both", async () => {
  const { send, sms, logs } = setup({ wa: () => Promise.reject(new WhatsAppError("WhatsApp send failed: HTTP 400 (code 131026)", "131026")) });
  assertEquals(await send(PHONE, msg()), { channel: "SMS", sent: true });
  assertEquals(sms.length, 1);
  assertEquals(summary(logs), ["WHATSAPP/FAILED", "SMS/SENT"]);
  assertEquals(logs[0].whatsappError, "131026");
});

Deno.test("WhatsApp slower than the timeout falls back to SMS", async () => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const { send, sms } = setup({
    timeoutMs: 50,
    // ignores the abort signal and resolves after 200 ms; cleared below so no timer leaks
    wa: () => new Promise<void>((resolve) => { timer = setTimeout(resolve, 200); }),
  });
  const result = await send(PHONE, msg());
  clearTimeout(timer);
  assertEquals(result.channel, "SMS");
  assertEquals(sms.length, 1);
});

Deno.test("WhatsApp that honours the abort signal also falls back to SMS", async () => {
  const { send, sms } = setup({
    timeoutMs: 50,
    wa: (signal) => new Promise<void>((resolve, reject) => {
      const t = setTimeout(resolve, 200);
      signal.addEventListener("abort", () => { clearTimeout(t); reject(signal.reason); });
    }),
  });
  assertEquals((await send(PHONE, msg())).channel, "SMS");
  assertEquals(sms.length, 1);
});

Deno.test("no WhatsApp config goes straight to SMS", async () => {
  const { send, sms, logs, waCalls } = setup({ whatsapp: null });
  assertEquals(await send(PHONE, msg()), { channel: "SMS", sent: true });
  assertEquals([waCalls.length, sms.length], [0, 1]);
  assertEquals(summary(logs), ["SMS/SENT"]);
});

Deno.test("whatsappOnly never sends SMS and throws when WhatsApp fails", async () => {
  const { send, sms, logs } = setup({ wa: () => Promise.reject(new Error("boom")) });
  await assertRejects(() => send(PHONE, msg({ whatsappOnly: true })), MessageDeliveryError);
  assertEquals(sms, []);
  assertEquals(summary(logs), ["WHATSAPP/FAILED"]);
});

Deno.test("whatsappOnly with no config throws without sending", async () => {
  const { send, sms } = setup({ whatsapp: null });
  await assertRejects(() => send(PHONE, msg({ whatsappOnly: true })), MessageDeliveryError);
  assertEquals(sms, []);
});

Deno.test("both channels failing throws MessageDeliveryError", async () => {
  const { send, logs } = setup({ wa: () => Promise.reject(new Error("boom")), smsFails: true });
  await assertRejects(() => send(PHONE, msg()), MessageDeliveryError);
  assertEquals(summary(logs), ["WHATSAPP/FAILED", "SMS/FAILED"]);
});

Deno.test("a failing log never makes a successful send look failed", async () => {
  const send = createMessageRouter({
    whatsapp: CFG,
    sendWhatsApp: () => Promise.resolve(),
    sms: () => Promise.resolve(),
    log: () => Promise.reject(new Error("db down")),
  });
  assertEquals(await send(PHONE, msg()), { channel: "WHATSAPP", sent: true });
});

Deno.test("log entries never contain the code or the full phone", async () => {
  const { send, logs } = setup({ wa: () => Promise.reject(new Error(`rejected ${PHONE} code ${CODE}`)) });
  await send(PHONE, msg());
  const text = JSON.stringify(logs);
  assert(!text.includes(CODE));
  assert(!text.includes(PHONE));
  assert(!text.includes("2348012345678"));
  assert(!text.includes("wa-secret-token"));
});
