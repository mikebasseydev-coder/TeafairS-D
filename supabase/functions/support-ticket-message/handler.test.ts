import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { createSupportTicketMessageHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const KEY = "c0000000-0000-0000-0000-000000000001";
const SECRET = "s".repeat(43);

function setup(result: unknown = { message_id: "m1", status: "OPEN" }) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result as T);
  };
  return { handler: createSupportTicketMessageHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}

const body = { idempotency_key: KEY, public_reference: "tk-7k3q9x", secret: SECRET, message: " Any update? " };
const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x/support-ticket-message", { method: "POST", headers: { Origin: ORIGIN }, body: JSON.stringify(b) }));

Deno.test("a message is forwarded and the reply passes through", async () => {
  const { handler, calls } = setup();
  const res = await post(handler, body);
  assertEquals([res.status, await res.json()], [200, { message_id: "m1", status: "OPEN" }]);
  assertEquals(calls, [["add_ticket_message", {
    p_idempotency_key: KEY, p_public_reference: "TK-7K3Q9X", p_secret: SECRET, p_message: "Any update?",
  }]]);
});

Deno.test("NOT_FOUND is 404", async () => {
  const { handler } = setup(new GatewayError(422, "BUSINESS_RULE", "NOT_FOUND"));
  const res = await post(handler, body);
  const e = (await res.json()).error;
  assertEquals([res.status, e.code, e.message], [404, "NOT_FOUND", "We couldn't find that conversation."]);
});

Deno.test("closed copy is 422", async () => {
  const copy = "This conversation is closed. Please open a new one.";
  const { handler } = setup(new GatewayError(422, "BUSINESS_RULE", copy));
  const res = await post(handler, body);
  assertEquals([res.status, (await res.json()).error.message], [422, copy]);
});

Deno.test("throttle copy is 422", async () => {
  const copy = "Too many messages. Please wait a few minutes.";
  const { handler } = setup(new GatewayError(422, "BUSINESS_RULE", copy));
  const res = await post(handler, body);
  assertEquals([res.status, (await res.json()).error.message], [422, copy]);
});
