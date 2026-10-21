import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createSupportTicketReadHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const SECRET = "s".repeat(43);

function setup(reply: unknown) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve(reply as T);
  };
  return { handler: createSupportTicketReadHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}

const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x/support-ticket-read", { method: "POST", headers: { Origin: ORIGIN }, body: JSON.stringify(b) }));

Deno.test("null is 404 NOT_FOUND", async () => {
  const { handler } = setup(null);
  const res = await post(handler, { public_reference: "TK-7K3Q9X", secret: SECRET });
  const e = (await res.json()).error;
  assertEquals([res.status, e.code, e.message], [404, "NOT_FOUND", "We couldn't find that conversation."]);
});

Deno.test("malformed reference is 400", async () => {
  const { handler, calls } = setup({});
  const res = await post(handler, { public_reference: "TK-7K3Q9U", secret: SECRET });
  assertEquals([res.status, calls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("reply passes through and is no-store", async () => {
  const reply = { public_reference: "TK-7K3Q9X", status: "OPEN", messages: [] };
  const { handler, calls } = setup(reply);
  const res = await post(handler, { public_reference: " tk-7k3q9x ", secret: SECRET });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), reply);
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(calls, [["read_support_ticket", { p_public_reference: "TK-7K3Q9X", p_secret: SECRET }]]);
});
