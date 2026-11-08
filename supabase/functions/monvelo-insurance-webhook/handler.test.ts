import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createMockAdapter, signMockWebhook } from "../_shared/insurance/mock.ts";
import { manualAdapter } from "../_shared/insurance/manual.ts";
import type { ApiProvider } from "../_shared/insurance/adapter.ts";
import { createMonveloInsuranceWebhookHandler } from "./handler.ts";

const SECRET = "mock-insurer-secret";
const NOW = 1_800_000_000_000;
const TS = String(Math.floor(NOW / 1000));

function setup(opts: { provider?: string | null; duplicate?: boolean } = {}) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    if (fn === "get_monvelo_insurer_provider") {
      return Promise.resolve((opts.provider === undefined ? "MOCK" : opts.provider) as T);
    }
    return Promise.resolve((opts.duplicate ? { duplicate: true } : { applied: true }) as T);
  };
  const handler = createMonveloInsuranceWebhookHandler({
    rpc,
    adapterFor: (p: ApiProvider) => {
      if (p === "MOCK") return createMockAdapter({ secret: SECRET, now: () => NOW });
      if (p === "MANUAL") return manualAdapter;
      throw new Error("no adapter");
    },
  });
  return { handler, calls, applied: () => calls.filter(([fn]) => fn === "apply_monvelo_insurer_event") };
}

async function post(h: (r: Request) => Promise<Response>, body: unknown, o: { ts?: string; sig?: string; query?: string } = {}) {
  const raw = typeof body === "string" ? body : JSON.stringify(body);
  const ts = o.ts ?? TS;
  const sig = o.sig ?? await signMockWebhook(SECRET, ts, raw);
  return h(new Request(`http://x/monvelo-insurance-webhook${o.query ?? "?insurer=MOCK"}`, {
    method: "POST", body: raw, headers: { "x-insurer-signature": sig, "x-insurer-timestamp": ts },
  }));
}

const settled = {
  event_id: "evt-1", type: "claim.settled", claim_reference: "IC-ABCDEFGH",
  settled_amount: "36000.00", payout_reference: "PO-1",
};

Deno.test("a bad signature is 401, and only the insurer lookup ran", async () => {
  const s = setup();
  const res = await post(s.handler, settled, { sig: "00".repeat(32) });
  assertEquals(res.status, 401);
  await res.body?.cancel();
  assertEquals(s.calls.map(([fn]) => fn), ["get_monvelo_insurer_provider"]);
});

Deno.test("a stale timestamp is 401", async () => {
  const s = setup();
  const stale = String(Number(TS) - 301);
  const res = await post(s.handler, settled, { ts: stale });
  assertEquals(res.status, 401);
  await res.body?.cancel();
  assertEquals(s.applied().length, 0);
});

Deno.test("an unknown insurer and a MANUAL insurer are 401", async () => {
  for (const provider of [null, "MANUAL", "MYCOVER"]) {
    const s = setup({ provider });
    const res = await post(s.handler, settled);
    assertEquals(res.status, 401, String(provider));
    await res.body?.cancel();
    assertEquals(s.applied().length, 0);
  }
});

Deno.test("a missing or malformed ?insurer= is 400 and calls nothing", async () => {
  for (const query of ["", "?insurer=", "?insurer=mock;drop"]) {
    const s = setup();
    const res = await post(s.handler, settled, { query });
    assertEquals(res.status, 400, query);
    await res.body?.cancel();
    assertEquals(s.calls.length, 0);
  }
});

Deno.test("claim.settled is applied with the amount as a decimal string", async () => {
  const s = setup();
  const res = await post(s.handler, settled);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { applied: true });
  assertEquals(s.applied().map(([, a]) => a), [{
    p_insurer_code: "MOCK", p_event_id: "evt-1", p_type: "claim.settled",
    p_event: { claim_reference: "IC-ABCDEFGH", settled_amount: "36000.00", payout_reference: "PO-1" },
  }]);
});

Deno.test("a duplicate event is 200 with duplicate: true", async () => {
  const s = setup({ duplicate: true });
  const res = await post(s.handler, settled);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { duplicate: true });
});

Deno.test("a malformed amount, a missing claim reference or bad JSON is 400 and nothing is applied", async () => {
  const bodies: unknown[] = [
    { ...settled, settled_amount: "36000" },
    { ...settled, settled_amount: "1e5.00" },
    { event_id: "evt-2", type: "claim.settled", settled_amount: "1.00", payout_reference: "P" },
    { event_id: "evt-3", type: "declaration.accepted" },
    "{not json",
  ];
  for (const b of bodies) {
    const s = setup();
    const res = await post(s.handler, b);
    assertEquals(res.status, 400, JSON.stringify(b));
    await res.body?.cancel();
    assertEquals(s.applied().length, 0);
  }
});

Deno.test("a declaration event carries its declaration id; an unknown type is still passed for recording", async () => {
  const s = setup();
  const id = "5b0d3c1e-7a0e-4f7e-9d7e-2f1b6c0f9a11";
  await (await post(s.handler, { event_id: "e4", type: "declaration.accepted", declaration_id: id, insurer_reference: "POL-9" }))
    .body?.cancel();
  await (await post(s.handler, { event_id: "e5", type: "policy.renewed" })).body?.cancel();
  assertEquals(s.applied().map(([, a]) => [a.p_type, a.p_event]), [
    ["declaration.accepted", { declaration_id: id, insurer_reference: "POL-9" }],
    ["policy.renewed", {}],
  ]);
});
