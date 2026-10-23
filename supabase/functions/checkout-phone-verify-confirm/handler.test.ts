import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { sha256Hex } from "../_shared/support/secret.ts";
import { createCheckoutPhoneVerifyConfirmHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const VID = "a0000000-0000-0000-0000-000000000001";

function setup(opts: { result?: unknown; rpcError?: Error } = {}) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return opts.rpcError ? Promise.reject(opts.rpcError) : Promise.resolve((opts.result ?? { verified: true }) as T);
  };
  return { handler: createCheckoutPhoneVerifyConfirmHandler({ rpc, allowedOrigins: [ORIGIN] }), rpcCalls };
}

const post = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x/checkout-phone-verify-confirm", {
    method: "POST",
    headers: { Origin: ORIGIN },
    body: JSON.stringify(body),
  }));

Deno.test("malformed code is 400", async () => {
  for (const code of ["12345", "1234567", "12345a", ""]) {
    const { handler, rpcCalls } = setup();
    const res = await post(handler, { verification_id: VID, code });
    assertEquals([res.status, rpcCalls.length], [400, 0]);
    await res.body?.cancel();
  }
});

Deno.test("returns a 43-char token and sends only its hash to the RPC", async () => {
  const { handler, rpcCalls } = setup();
  const res = await post(handler, { verification_id: VID, code: "482913" });
  const out = await res.json();
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(Object.keys(out), ["verification_token"]);
  assertMatch(out.verification_token, /^[A-Za-z0-9_-]{43}$/);
  const [fn, args] = rpcCalls[0];
  assertEquals(fn, "confirm_web_phone_verification");
  assertEquals(args, { p_verification_id: VID, p_code: "482913", p_token_hash: await sha256Hex(out.verification_token) });
});

Deno.test("a wrong code (verified:false) is 422 carrying the database copy", async () => {
  const { handler } = setup({ result: { verified: false, error: "That code is not right.", attempts_left: 2 } });
  const res = await post(handler, { verification_id: VID, code: "000000" });
  const out = await res.json();
  assertEquals(res.status, 422);
  assertEquals(out.error.message, "That code is not right.");
  assertEquals(JSON.stringify(out).includes("verification_token"), false);
});

Deno.test("P0001 from the database stays 422 with its copy", async () => {
  const { handler } = setup({ rpcError: new GatewayError(422, "BUSINESS_RULE", "Please verify your WhatsApp number again.") });
  const res = await post(handler, { verification_id: VID, code: "482913" });
  assertEquals([res.status, (await res.json()).error.message], [422, "Please verify your WhatsApp number again."]);
});
