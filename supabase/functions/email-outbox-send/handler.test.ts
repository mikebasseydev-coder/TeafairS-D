import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { type Email, EmailDeliveryError, type EmailSender } from "../_shared/messaging/resend.ts";
import { createEmailOutboxSendHandler } from "./handler.ts";

const SECRET = "cron_secret";
const row = (id: string, to = `${id}@example.com`) => ({
  id,
  template: "BUYER_TICKET_REPLY",
  to_email: to,
  payload: { public_reference: "TK-ABC123" },
});

function setup(send: (e: Email) => Promise<void>, rows = [row("r1")], ticketUrl: string | undefined = "http://x/t") {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const sent: Email[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve((fn === "claim_email_outbox" ? rows : null) as T);
  };
  const sendEmail: EmailSender = async (e) => {
    sent.push(e);
    await send(e);
  };
  const handler = createEmailOutboxSendHandler({ cronSecret: SECRET, rpc, sendEmail, ticketUrl });
  const completions = () => calls.filter(([fn]) => fn === "complete_email_outbox").map(([, a]) => `${a.p_id}:${a.p_result}`);
  return { handler, calls, sent, completions };
}

const post = (handler: (r: Request) => Promise<Response>, secret = SECRET) =>
  handler(new Request("http://x", { method: "POST", body: "{}", headers: { "x-cron-secret": secret } }));

Deno.test("401 without the cron secret, and no rpc call", async () => {
  const s = setup(() => Promise.resolve());
  const res = await post(s.handler, "wrong");
  assertEquals(res.status, 401);
  await res.body?.cancel();
  assertEquals(s.calls.length, 0);
});

Deno.test("claims a batch of 50 and sends with the row id as the idempotency key", async () => {
  const s = setup(() => Promise.resolve());
  const res = await post(s.handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { claimed: 1, sent: 1, retried: 0, failed: 0 });
  assertEquals(s.calls[0], ["claim_email_outbox", { p_limit: 50 }]);
  assertEquals(s.sent[0].idempotencyKey, "r1");
  assertEquals(s.sent[0].to, "r1@example.com");
  assertEquals(s.completions(), ["r1:SENT"]);
});

Deno.test("Resend 400, 403 and 422 are permanent", async () => {
  for (const status of [400, 403, 422]) {
    const s = setup(() => Promise.reject(new EmailDeliveryError(status)));
    await (await post(s.handler)).body?.cancel();
    assertEquals(s.completions(), ["r1:PERMANENT"], `status ${status}`);
  }
});

Deno.test("Resend 429, a 5xx and a network error are retried", async () => {
  for (const err of [new EmailDeliveryError(429), new EmailDeliveryError(500), new TypeError("network")]) {
    const s = setup(() => Promise.reject(err));
    await (await post(s.handler)).body?.cancel();
    assertEquals(s.completions(), ["r1:RETRY"]);
  }
});

Deno.test("one failure doesn't stop the batch, and the counts say so", async () => {
  const s = setup((e) => e.to.startsWith("r2") ? Promise.reject(new EmailDeliveryError(422)) : Promise.resolve(),
    [row("r1"), row("r2"), row("r3")]);
  const res = await post(s.handler);
  assertEquals(await res.json(), { claimed: 3, sent: 2, retried: 0, failed: 1 });
  assertEquals(s.completions(), ["r1:SENT", "r2:PERMANENT", "r3:SENT"]);
});

Deno.test("a buyer email with no ticket URL is deferred, not sent", async () => {
  const s = setup(() => Promise.resolve(), [row("r1")], "");
  const res = await post(s.handler);
  assertEquals(await res.json(), { claimed: 1, sent: 0, retried: 1, failed: 0 });
  assertEquals(s.sent.length, 0);
  assertEquals(s.completions(), ["r1:DEFER"]);
});

Deno.test("no recipient address in any log line", async () => {
  const logged: unknown[][] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => logged.push(a);
  try {
    const s = setup(() => Promise.reject(new EmailDeliveryError(500)), [row("r1", "secret.person@example.com")]);
    await (await post(s.handler)).body?.cancel();
    const s2 = setup(() => Promise.resolve(), [row("r2", "other.person@example.com")], "");
    await (await post(s2.handler)).body?.cancel();
  } finally {
    console.error = orig;
  }
  assertEquals(logged.length > 0, true);
  assertEquals(logged.some((a) => a.map(String).join(" ").includes("person@example.com")), false);
});
