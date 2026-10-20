import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createWebOrderStatusHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const REF = "TFW-c0000000-0000-0000-0000-000000000001";

function setup(result: unknown) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve(result as T);
  };
  return { handler: createWebOrderStatusHandler({ rpc, allowedOrigins: [ORIGIN] }), calls };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/web-order-status", { method: "POST", headers: { Origin: ORIGIN }, body: JSON.stringify(body) }));

Deno.test("a mismatched pair is 404 NOT_FOUND", async () => {
  const { handler } = setup(null);
  const res = await post(handler, { public_reference: "TF-7K3Q9X", paystack_reference: REF });
  const body = await res.json();
  assertEquals([res.status, body.error.code, body.error.message], [404, "NOT_FOUND", "We couldn't find that order."]);
});

Deno.test("a missing order is the same 404", async () => {
  const { handler } = setup(null);
  const res = await post(handler, { public_reference: "TF-AAAAAA", paystack_reference: REF });
  assertEquals([res.status, (await res.json()).error.code], [404, "NOT_FOUND"]);
});

Deno.test("a malformed public reference is 400", async () => {
  const { handler, calls } = setup({});
  const res = await post(handler, { public_reference: "TF-7K3Q9U", paystack_reference: REF });
  assertEquals([res.status, calls.length], [400, 0]);
  await res.body?.cancel();
});

Deno.test("returns the status payload as is", async () => {
  const status = { status: "PAID", total: 5580 };
  const { handler, calls } = setup(status);
  const res = await post(handler, { public_reference: " tf-7k3q9x ", paystack_reference: ` ${REF} ` });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), status);
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(calls, [["web_order_status", { p_public_reference: "TF-7K3Q9X", p_paystack_reference: REF }]]);
});
