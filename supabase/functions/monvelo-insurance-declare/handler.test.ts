import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import type { InsurerAdapter, SendResult } from "../_shared/insurance/adapter.ts";
import { createMonveloInsuranceDeclareHandler } from "./handler.ts";

const SECRET = "cron_secret";
type Row = { id: string; kind: string; insurer_code: string; api_provider: string; payload: Record<string, unknown> };
const row = (id: string, api_provider = "MOCK", ref = "MV-AAAAAAAA"): Row => ({
  id, kind: "STORAGE_DECLARE", insurer_code: api_provider, api_provider, payload: { financing_reference: ref },
});

function fakeAdapter(fn: (payload: Record<string, unknown>) => Promise<SendResult>): InsurerAdapter {
  return {
    send: (_k, payload) => fn(payload),
    verifyWebhook: () => Promise.resolve(false),
    parseEvent: () => ({ eventId: "x", type: "x" }),
  };
}

function setup(rows: Row[], adapters: Record<string, InsurerAdapter>) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve((fn === "claim_monvelo_declarations" ? rows : {}) as T);
  };
  const handler = createMonveloInsuranceDeclareHandler({
    cronSecret: SECRET,
    rpc,
    adapterFor: (p) => {
      const a = adapters[p];
      if (!a) throw new Error(`no adapter for ${p}`);
      return a;
    },
  });
  const completions = () =>
    calls.filter(([fn]) => fn === "complete_monvelo_declaration").map(([, a]) => `${a.p_id}:${a.p_outcome}`);
  return { handler, calls, completions };
}

const post = (h: (r: Request) => Promise<Response>, secret: string | null = SECRET) =>
  h(new Request("http://x", { method: "POST", body: "{}", headers: secret === null ? {} : { "x-cron-secret": secret } }));

Deno.test("401 without the cron secret or with a wrong one, and no rpc call", async () => {
  for (const secret of [null, "wrong"]) {
    const s = setup([row("r1")], {});
    const res = await post(s.handler, secret);
    assertEquals(res.status, 401);
    await res.body?.cancel();
    assertEquals(s.calls.length, 0);
  }
});

Deno.test("a mixed batch: one completion per row with the adapter's outcome", async () => {
  const mock = fakeAdapter((p) => {
    const ref = String(p.financing_reference);
    if (ref.endsWith("REJ")) return Promise.resolve({ outcome: "REJECTED", insurerReference: null, error: "no" });
    if (ref.endsWith("RTY")) return Promise.resolve({ outcome: "RETRY", error: "busy" });
    return Promise.resolve({ outcome: "ACCEPTED", insurerReference: "POL-1" });
  });
  const manual = fakeAdapter(() => Promise.resolve({ outcome: "QUEUED_MANUAL" }));
  const s = setup([row("a"), row("b", "MOCK", "MV-AAAAAREJ"), row("c", "MOCK", "MV-AAAAARTY"), row("d", "MANUAL")],
    { MOCK: mock, MANUAL: manual });
  const res = await post(s.handler);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { claimed: 4, accepted: 1, rejected: 1, retried: 1, manual: 1 });
  assertEquals(s.calls[0], ["claim_monvelo_declarations", { p_limit: 20 }]);
  assertEquals(s.completions(), ["a:ACCEPTED", "b:REJECTED", "c:RETRY", "d:MANUAL"]);
  const accepted = s.calls.find(([fn, a]) => fn === "complete_monvelo_declaration" && a.p_id === "a")!;
  assertEquals(accepted[1], { p_id: "a", p_outcome: "ACCEPTED", p_insurer_reference: "POL-1", p_error: null });
});

Deno.test("an adapter throwing on one row retries that row; the others complete", async () => {
  const mock = fakeAdapter((p) =>
    String(p.financing_reference).endsWith("BOOM")
      ? Promise.reject(new Error("socket hang up"))
      : Promise.resolve({ outcome: "ACCEPTED", insurerReference: "POL" })
  );
  const s = setup([row("a"), row("b", "MOCK", "MV-AAAABOOM"), row("c")], { MOCK: mock });
  const res = await post(s.handler);
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(s.completions(), ["a:ACCEPTED", "b:RETRY", "c:ACCEPTED"]);
});

Deno.test("an unknown adapter is retried, not thrown", async () => {
  const s = setup([row("a", "MYCOVER")], {});
  const res = await post(s.handler);
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(s.completions(), ["a:RETRY"]);
});
