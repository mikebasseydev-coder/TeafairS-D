import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createSupportStaffAttachmentHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const TICKET = "d0000000-0000-0000-0000-000000000001";
const PATH = "tenant/ticket/file.png";

function setup() {
  const auths: string[] = [];
  const calls: Array<[string, Record<string, unknown>]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve({ attachment_id: "a1", storage_path: PATH } as T);
  };
  const handler = createSupportStaffAttachmentHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: (authorization) => {
      auths.push(authorization);
      return rpc;
    },
    signUpload: () => Promise.resolve("https://s/upload?token=t"),
  });
  return { handler, auths, calls };
}

const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(b), headers: { Authorization: "Bearer tok" } }));

Deno.test("staff attachment gateway forwards the caller's JWT and hides the path", async () => {
  const { handler, auths, calls } = setup();
  const res = await post(handler, { idempotency_key: KEY, ticket_id: TICKET, mime_type: "image/png", size_bytes: 10 });
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(JSON.parse(text), { attachment_id: "a1", upload_url: "https://s/upload?token=t" });
  assertEquals(text.includes(PATH), false);
  assertEquals(auths, ["Bearer tok"]);
  assertEquals(calls, [["request_staff_ticket_attachment", {
    p_idempotency_key: KEY,
    p_ticket_id: TICKET,
    p_mime_type: "image/png",
    p_size_bytes: 10,
  }]]);
});

Deno.test("oversize is 400 and a missing token is 401, with no RPC", async () => {
  const { handler, calls } = setup();
  const bad = await post(handler, {
    idempotency_key: KEY,
    ticket_id: TICKET,
    mime_type: "image/png",
    size_bytes: 5242881,
  });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  const none = await handler(new Request("http://x", { method: "POST", body: "{}" }));
  assertEquals(none.status, 401);
  await none.body?.cancel();
  assertEquals(calls.length, 0);
});
