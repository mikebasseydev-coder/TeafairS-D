import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import type { InitializeRequest } from "../_shared/payments/paystack.ts";
import { createMonveloFundHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const FIN = "e0000000-0000-0000-0000-000000000003";
const AGENT = "d0000000-0000-0000-0000-000000000002";
const REF = "MV-ABCDEFGH-1";

function setup(opts: { rpcError?: Error; paystackError?: Error } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const inits: InitializeRequest[] = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    if (opts.rpcError) return Promise.reject(opts.rpcError);
    return Promise.resolve(
      { payment_id: "p1", reference: REF, amount_minor: 4500000, currency: "NGN", claim_expires_at: "2026-11-01T00:00:00Z" } as T,
    );
  };
  const handler = createMonveloFundHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
    initializeTransaction: (req) => {
      inits.push(req);
      if (opts.paystackError) return Promise.reject(opts.paystackError);
      return Promise.resolve({ reference: req.reference, accessCode: "ac_SECRET", authorizationUrl: "https://checkout.paystack.com/ac_SECRET" });
    },
  });
  return { handler, rpcCalls, inits };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/monvelo-fund", { method: "POST", headers: { Authorization: "Bearer tok" }, body: JSON.stringify(body) }));

const body = (over: Record<string, unknown> = {}) => ({ idempotency_key: KEY, financing_id: FIN, agent_id: AGENT, ...over });

Deno.test("happy path: RPC first, then Paystack with bank_transfer, the synthetic email and Monvelo metadata", async () => {
  const { handler, rpcCalls, inits } = setup();
  const res = await post(handler, body());
  assertEquals(res.status, 200);
  assertEquals(rpcCalls, [["start_monvelo_funding", { p_idempotency_key: KEY, p_financing_id: FIN, p_agent_id: AGENT }]]);
  assertEquals(inits, [{
    reference: REF,
    amountMinor: 4500000,
    currency: "NGN",
    email: "monvelo-mv-abcdefgh-1@pay.teafairweb.com",
    channels: ["bank_transfer"],
    metadata: { kind: "monvelo", financing_id: FIN },
  }]);
  assertEquals(await res.json(), {
    reference: REF, authorization_url: "https://checkout.paystack.com/ac_SECRET", access_code: "ac_SECRET",
  });
});

Deno.test("an RPC refusal (42501) is 403 and Paystack is never called", async () => {
  const { handler, inits } = setup({ rpcError: new GatewayError(403, "FORBIDDEN", "not your agent") });
  const res = await post(handler, body());
  assertEquals(res.status, 403);
  assertEquals(inits.length, 0);
});

Deno.test("a Paystack failure is 502 PAYSTACK_UNAVAILABLE and leaks nothing", async () => {
  const { handler } = setup({ paystackError: new Error("Paystack initialize failed: sk_live_LEAK") });
  const res = await post(handler, body());
  const text = await res.text();
  assertEquals(res.status, 502);
  assertEquals(JSON.parse(text).error.code, "PAYSTACK_UNAVAILABLE");
  assertEquals(text.includes("sk_live_LEAK"), false);
});

Deno.test("a bad body is 400", async () => {
  const { handler, rpcCalls } = setup();
  assertEquals((await post(handler, body({ financing_id: "nope" }))).status, 400);
  assertEquals((await post(handler, { idempotency_key: KEY })).status, 400);
  assertEquals(rpcCalls.length, 0);
});
