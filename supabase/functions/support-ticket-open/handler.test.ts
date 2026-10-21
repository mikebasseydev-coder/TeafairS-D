import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { sha256Hex } from "../_shared/support/secret.ts";
import { createSupportTicketOpenHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const KEY = "c0000000-0000-0000-0000-000000000001";
const LGA = "d0000000-0000-0000-0000-000000000009";
const SECRET = "s".repeat(43);
const PAYSTACK = "TFW-123e4567-e89b-12d3-a456-426614174000";
const OPENED = { ticket_id: "t1", public_reference: "TK-7K3Q9X", status: "OPEN" };

function setup(opts: { human?: boolean; rpcError?: Error } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return opts.rpcError ? Promise.reject(opts.rpcError) : Promise.resolve(OPENED as T);
  };
  const handler = createSupportTicketOpenHandler({
    rpc,
    allowedOrigins: [ORIGIN],
    verifyTurnstile: () => Promise.resolve(opts.human ?? true),
    newSecret: () => SECRET,
  });
  return { handler, rpcCalls };
}

const body = (over: Record<string, unknown> = {}) => ({
  idempotency_key: KEY,
  turnstile_token: "tok",
  category: "PAYMENT",
  message: "  My payment went through twice  ",
  customer: { name: "Ada Obi", phone: "0803 123 4567", email: "Ada@Example.com" },
  order: { public_reference: "tf-7k3q9x", paystack_reference: PAYSTACK },
  ...over,
});

const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x/support-ticket-open", {
    method: "POST",
    headers: { Origin: ORIGIN, "cf-connecting-ip": "1.2.3.4" },
    body: JSON.stringify(b),
  }));

Deno.test("a failed bot check is 403 and calls nothing", async () => {
  const { handler, rpcCalls } = setup({ human: false });
  const res = await post(handler, body());
  assertEquals([res.status, (await res.json()).error.code, rpcCalls.length], [403, "BOT_CHECK_FAILED", 0]);
});

Deno.test("order ticket sends the pair and only the secret's hash", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, body());
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(rpcCalls.length, 1);
  const [fn, args] = rpcCalls[0];
  assertEquals(fn, "open_support_ticket");
  assertEquals(args, {
    p_idempotency_key: KEY,
    p_kind: "ORDER",
    p_category: "PAYMENT",
    p_message: "My payment went through twice",
    p_customer: { name: "Ada Obi", phone: "+2348031234567", email: "ada@example.com" },
    p_order_public_reference: "TF-7K3Q9X",
    p_order_paystack_reference: PAYSTACK,
    p_lga_id: null,
    p_secret_hash: await sha256Hex(SECRET),
  });
  assertEquals(JSON.stringify(args).includes(SECRET), false);
});

Deno.test("location ticket is PRE_PURCHASE", async () => {
  const { handler, rpcCalls } = setup();
  const b = body({ location: { lga_id: LGA } });
  delete (b as Record<string, unknown>).order;
  const res = await post(handler, b);
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals([rpcCalls[0][1].p_kind, rpcCalls[0][1].p_lga_id, rpcCalls[0][1].p_order_public_reference], ["PRE_PURCHASE", LGA, null]);
});

Deno.test("reply includes the secret once", async () => {
  const { handler } = setup();
  const res = await post(handler, body());
  assertEquals(await res.json(), { public_reference: "TK-7K3Q9X", secret: SECRET, status: "OPEN" });
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("both order and location is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, body({ location: { lga_id: LGA } }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("neither order nor location is 400", async () => {
  const { handler, rpcCalls } = setup();
  const b = body();
  delete (b as Record<string, unknown>).order;
  const res = await post(handler, b);
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("NOT_FOUND from the RPC is 404", async () => {
  const { handler } = setup({ rpcError: new GatewayError(422, "BUSINESS_RULE", "NOT_FOUND") });
  const res = await post(handler, body());
  const e = (await res.json()).error;
  assertEquals([res.status, e.code, e.message], [404, "NOT_FOUND", "We couldn't find that order."]);
});

Deno.test("other business errors stay 422", async () => {
  const { handler } = setup({ rpcError: new GatewayError(422, "BUSINESS_RULE", "Too many messages. Please wait a few minutes.") });
  const res = await post(handler, body());
  assertEquals([res.status, (await res.json()).error.message], [422, "Too many messages. Please wait a few minutes."]);
});

Deno.test("message over 2000 characters is 400", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, body({ message: "x".repeat(2001) }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("an unusable phone is 400 before any RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, body({ customer: { name: "Ada", phone: "12345" } }));
  assertEquals([res.status, rpcCalls.length], [400, 0]);
  await res.body?.cancel();
});
