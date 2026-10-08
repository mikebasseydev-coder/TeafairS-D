import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { Rpc } from "../core/db.ts";
import { GatewayError } from "../core/errors.ts";
import { pinSchema, requirePin } from "./pin.ts";

const answering = (verdict: unknown, calls: unknown[] = []): Rpc => <T>(fn: string, args: Record<string, unknown>) => {
  calls.push([fn, args]);
  return Promise.resolve(verdict as T);
};

Deno.test("a passing PIN resolves, via verify_pin with the caller's own client", async () => {
  const calls: unknown[] = [];
  await requirePin(answering({ ok: true, attempts_left: 5, locked_until: null }, calls), "1234");
  assertEquals(calls, [["verify_pin", { p_pin: "1234" }]]);
});

Deno.test("a wrong PIN is 403 PIN_INVALID with attempts left", async () => {
  const e = await assertRejects(
    () => requirePin(answering({ ok: false, attempts_left: 3, locked_until: null }), "0000"),
    GatewayError,
  );
  assertEquals([e.status, e.code, e.details], [403, "PIN_INVALID", { attempts_left: 3 }]);
});

Deno.test("a locked membership is 423 PIN_LOCKED with the unlock time", async () => {
  const until = "2026-10-07T12:15:00+00:00";
  const e = await assertRejects(
    () => requirePin(answering({ ok: false, attempts_left: 0, locked_until: until }), "0000"),
    GatewayError,
  );
  assertEquals([e.status, e.code, e.details], [423, "PIN_LOCKED", { locked_until: until }]);
});

Deno.test("pinSchema accepts exactly four digits", () => {
  assertEquals(["1234", "123", "12345", "12a4"].map((p) => pinSchema.safeParse(p).success), [true, false, false, false]);
});
