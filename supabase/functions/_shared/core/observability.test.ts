import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { rpcFrom } from "./db.ts";
import { type SupabaseClient, Sentry, z } from "./deps.ts";
import { userGateway } from "./gateway.ts";
import { initObservability, observe, resetObservabilityForTests } from "./observability.ts";

// A Sentry transport that keeps every envelope it is handed.
const bodies: string[] = [];
const recordingTransport = (options: Parameters<typeof Sentry.createTransport>[0]) =>
  Sentry.createTransport(options, (request) => {
    bodies.push(typeof request.body === "string" ? request.body : new TextDecoder().decode(request.body));
    return Promise.resolve({ statusCode: 200 });
  });

type Item = { type: string; payload: Record<string, unknown> };
function items(): Item[] {
  const out: Item[] = [];
  for (const body of bodies) {
    const lines = body.split("\n").filter(Boolean);
    for (let i = 1; i + 1 < lines.length; i += 2) {
      out.push({ type: JSON.parse(lines[i]).type, payload: JSON.parse(lines[i + 1]) });
    }
  }
  return out;
}

const TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736";
const PARENT_SPAN = "00f067aa0ba902b7";
const opts = { sanitizeOps: false, sanitizeResources: false };

// A user gateway whose one RPC is refused by the database, as the Sureach guard would.
function refusingGateway() {
  const client = {
    rpc: () =>
      Promise.resolve({
        data: null,
        error: { code: "P0001", message: "Tenant is not authorized to sell products in category TELECOM." },
      }),
  } as unknown as SupabaseClient;
  return userGateway(
    z.object({ phone: z.string() }),
    ({ rpc }) => rpc("set_product_category", { p_phone: "+2348031234567" }),
    {
      verifyToken: () =>
        Promise.resolve({
          sub: "11111111-1111-4111-8111-111111111111",
          role: "authenticated",
          app_metadata: { active_tenant_id: "7eaf0000-0000-4000-8000-000000000001", tenant_role: "DSA" },
        }),
      rpcFor: () => rpcFrom(client),
    },
  );
}

Deno.test({
  name: "a database refusal is a warning on the caller's trace, tagged with tenant and role, with no PII",
  ...opts,
  fn: async () => {
    resetObservabilityForTests();
    bodies.length = 0;
    assert(initObservability({ dsn: "https://public@o0.ingest.sentry.io/1", transport: recordingTransport, tracesSampleRate: 1 }));
    const handler = observe("order-dispatch", refusingGateway());
    const res = await handler(
      new Request("http://localhost/functions/v1/order-dispatch?phone=08031234567", {
        method: "POST",
        headers: {
          authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
          "sentry-trace": `${TRACE_ID}-${PARENT_SPAN}-1`,
          baggage: `sentry-trace_id=${TRACE_ID},sentry-sample_rate=1,sentry-sampled=true`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ phone: "+2348031234567" }),
      }),
    );
    assertEquals(res.status, 422);
    await Sentry.flush(2000);

    const event = items().find((i) => i.type === "event")!.payload;
    assertEquals(event.level, "warning");
    const tags = event.tags as Record<string, string>;
    assertEquals(tags.function, "order-dispatch");
    assertEquals(tags.gateway, "user");
    assertEquals(tags.tenant_id, "7eaf0000-0000-4000-8000-000000000001");
    assertEquals(tags.tenant_role, "DSA");
    assertEquals(tags["db.sqlstate"], "P0001");
    assertEquals(tags["rpc.function"], "set_product_category");
    assertEquals(tags.error_code, "BUSINESS_RULE");
    assertEquals(event.user, { id: "11111111-1111-4111-8111-111111111111" });
    assertEquals(event.fingerprint, [
      "db-refusal", "set_product_category", "P0001", "Tenant is not authorized to sell products in category TELECOM.",
    ]);
    assertEquals((event.contexts as { trace: { trace_id: string } }).trace.trace_id, TRACE_ID);

    const tx = items().find((i) => i.type === "transaction")!.payload;
    const trace = (tx.contexts as { trace: { trace_id: string; parent_span_id: string; op: string; status: string } }).trace;
    assertEquals([trace.trace_id, trace.parent_span_id, trace.op], [TRACE_ID, PARENT_SPAN, "http.server"]);
    assertEquals(tx.transaction, "POST /order-dispatch");
    const spans = tx.spans as Array<{ op: string; description: string; data: Record<string, unknown> }>;
    const rpcSpan = spans.find((s) => s.op === "db.rpc")!;
    assertEquals(rpcSpan.description, "rpc set_product_category");
    assertEquals(rpcSpan.data["db.sqlstate"], "P0001");

    const all = bodies.join("\n");
    assert(!all.includes("8031234567"), "no phone number leaves the runtime");
    assert(!all.includes("eyJhbGci"), "no token leaves the runtime");
  },
});

Deno.test({
  name: "an unexpected throw is an error event and still propagates",
  ...opts,
  fn: async () => {
    resetObservabilityForTests();
    bodies.length = 0;
    initObservability({ dsn: "https://public@o0.ingest.sentry.io/1", transport: recordingTransport, tracesSampleRate: 1 });
    const handler = observe("storage-purge", () => {
      throw new Error("boom");
    });
    await assertRejects(() => handler(new Request("http://localhost/", { method: "POST" })), Error, "boom");
    await Sentry.flush(2000);
    const event = items().find((i) => i.type === "event")!.payload;
    assertEquals(event.level, "error");
    assertEquals((event.tags as Record<string, string>)["http.status_code"], "500");
  },
});

Deno.test({
  name: "a validation failure sends no event",
  ...opts,
  fn: async () => {
    resetObservabilityForTests();
    bodies.length = 0;
    initObservability({ dsn: "https://public@o0.ingest.sentry.io/1", transport: recordingTransport, tracesSampleRate: 1 });
    const res = await observe("order-dispatch", refusingGateway())(
      new Request("http://localhost/", {
        method: "POST",
        headers: { authorization: "Bearer x", "content-type": "application/json" },
        body: "{}",
      }),
    );
    assertEquals(res.status, 400);
    await Sentry.flush(2000);
    assertEquals(items().filter((i) => i.type === "event").length, 0);
  },
});

Deno.test({
  name: "with no DSN the wrapper is a plain pass-through",
  ...opts,
  fn: async () => {
    resetObservabilityForTests();
    bodies.length = 0;
    assertEquals(initObservability({ dsn: "" }), false);
    const res = await observe("x", () => new Response("ok"))(new Request("http://localhost/"));
    assertEquals(await res.text(), "ok");
    assertEquals(bodies.length, 0);
  },
});
