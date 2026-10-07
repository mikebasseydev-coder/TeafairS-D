import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createOtpVerifyHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const CHALLENGE = "60000000-0000-0000-0000-000000000001";

function setup(verdict: unknown) {
  const rpcCalls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    rpcCalls.push([fn, args]);
    return Promise.resolve(verdict as T);
  };
  const handler = createOtpVerifyHandler({
    verifyToken: () => Promise.resolve({ sub: "u3", role: "authenticated", app_metadata: {} }),
    rpcFor: () => rpc,
  });
  return { handler, rpcCalls };
}

const call = (handler: (r: Request) => Promise<Response>, body: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(body), headers: { Authorization: "Bearer tok" } }));

Deno.test("a verified code is 200", async () => {
  const { handler, rpcCalls } = setup({ verified: true, challenge_id: CHALLENGE, purpose: "POS_SETTLEMENT" });
  const res = await call(handler, { idempotency_key: KEY, challenge_id: CHALLENGE, code: "123456" });
  assertEquals([res.status, await res.json()], [200, { verified: true, challenge_id: CHALLENGE }]);
  assertEquals(rpcCalls, [["verify_otp", { p_idempotency_key: KEY, p_challenge_id: CHALLENGE, p_code: "123456" }]]);
});

for (const reason of ["INVALID", "EXPIRED", "LOCKED", "CONSUMED"]) {
  Deno.test(`a ${reason} verdict is 422 OTP_${reason}`, async () => {
    const { handler } = setup({ verified: false, reason, attempts_left: reason === "INVALID" ? 3 : undefined });
    const res = await call(handler, { idempotency_key: KEY, challenge_id: CHALLENGE, code: "000000" });
    const body = await res.json();
    assertEquals([res.status, body.error.code], [422, `OTP_${reason}`]);
    assertEquals(body.error.details, { attempts_left: reason === "INVALID" ? 3 : null });
  });
}

Deno.test("a malformed code is 400 and never reaches the database", async () => {
  const { handler, rpcCalls } = setup({ verified: true });
  const res = await call(handler, { idempotency_key: KEY, challenge_id: CHALLENGE, code: "12ab" });
  assertEquals([res.status, rpcCalls.length], [400, 0]);
});
