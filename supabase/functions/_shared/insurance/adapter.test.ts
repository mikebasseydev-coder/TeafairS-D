import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { createMockAdapter, signMockWebhook } from "./mock.ts";
import { manualAdapter } from "./manual.ts";
import { adapterFor } from "./registry.ts";

const SECRET = "mock-insurer-secret";
const NOW = 1_800_000_000_000; // a fixed clock (ms)
const mock = createMockAdapter({ secret: SECRET, now: () => NOW });

Deno.test("mock accepts a declaration and returns an insurer reference", async () => {
  const r = await mock.send("STORAGE_DECLARE", { financing_reference: "MV-ABCDEFGH" }, "decl-1");
  assertEquals(r.outcome, "ACCEPTED");
  if (r.outcome === "ACCEPTED") assertEquals(r.insurerReference.length > 0, true);
});

Deno.test("mock rejects a financing reference ending in REJ", async () => {
  const r = await mock.send("STORAGE_DECLARE", { financing_reference: "MV-ABCDEREJ" }, "decl-2");
  assertEquals(r.outcome, "REJECTED");
});

Deno.test("mock asks to retry a financing reference ending in RTY", async () => {
  const r = await mock.send("GIT_DECLARE", { financing_reference: "MV-ABCDERTY" }, "decl-3");
  assertEquals(r.outcome, "RETRY");
});

const req = (body: string, sig: string, ts: string) =>
  new Request("http://x/monvelo-insurance-webhook?insurer=MOCK", {
    method: "POST",
    body,
    headers: { "x-insurer-signature": sig, "x-insurer-timestamp": ts },
  });

Deno.test("mock verifies a valid signature", async () => {
  const body = JSON.stringify({ event_id: "e1", type: "claim.settled" });
  const ts = String(Math.floor(NOW / 1000));
  const sig = await signMockWebhook(SECRET, ts, body);
  assertEquals(await mock.verifyWebhook(req(body, sig, ts), body), true);
});

Deno.test("mock refuses a tampered body", async () => {
  const body = JSON.stringify({ event_id: "e1", type: "claim.settled" });
  const ts = String(Math.floor(NOW / 1000));
  const sig = await signMockWebhook(SECRET, ts, body);
  const tampered = body.replace("e1", "e2");
  assertEquals(await mock.verifyWebhook(req(tampered, sig, ts), tampered), false);
});

Deno.test("mock refuses a timestamp older than 5 minutes, and a signature over another timestamp", async () => {
  const body = JSON.stringify({ event_id: "e1", type: "claim.settled" });
  const stale = String(Math.floor(NOW / 1000) - 301);
  assertEquals(await mock.verifyWebhook(req(body, await signMockWebhook(SECRET, stale, body), stale), body), false);
  const ts = String(Math.floor(NOW / 1000));
  assertEquals(await mock.verifyWebhook(req(body, await signMockWebhook(SECRET, stale, body), ts), body), false);
});

Deno.test("mock refuses everything without a secret", async () => {
  const empty = createMockAdapter({ secret: "", now: () => NOW });
  const body = "{}";
  const ts = String(Math.floor(NOW / 1000));
  assertEquals(await empty.verifyWebhook(req(body, await signMockWebhook("any-key", ts, body), ts), body), false);
});

Deno.test("mock parses an event", () => {
  const e = mock.parseEvent(JSON.stringify({
    event_id: "e9", type: "claim.settled", claim_reference: "IC-ABCDEFGH",
    settled_amount: "36000.00", payout_reference: "PO-1",
  }));
  assertEquals(e, {
    eventId: "e9", type: "claim.settled", claimReference: "IC-ABCDEFGH",
    settledAmount: "36000.00", payoutReference: "PO-1",
  });
});

Deno.test("manual queues every declaration and never verifies a webhook", async () => {
  assertEquals(await manualAdapter.send("CLAIM_FILE", {}, "d"), { outcome: "QUEUED_MANUAL" });
  assertEquals(await manualAdapter.verifyWebhook(req("{}", "x", "1"), "{}"), false);
});

Deno.test("the registry has MOCK and MANUAL only", () => {
  assertEquals(typeof adapterFor("MOCK", { mockSecret: SECRET }).send, "function");
  assertEquals(adapterFor("MANUAL"), manualAdapter);
  assertThrows(() => adapterFor("MYCOVER" as never));
});
