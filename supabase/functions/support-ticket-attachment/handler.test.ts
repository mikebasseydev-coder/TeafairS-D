import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { createSupportTicketAttachmentHandler } from "./handler.ts";

const ORIGIN = "https://teafairweb.com";
const KEY = "c0000000-0000-0000-0000-000000000001";
const SECRET = "s".repeat(43);
const PATH = "tenant/ticket/file.jpg";

function setup(result: unknown = { attachment_id: "a1", storage_path: PATH }) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const signed: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return result instanceof Error ? Promise.reject(result) : Promise.resolve(result as T);
  };
  const handler = createSupportTicketAttachmentHandler({
    rpc,
    allowedOrigins: [ORIGIN],
    signUpload: (bucket, path) => {
      signed.push([bucket, path]);
      return Promise.resolve("https://s/upload?token=t");
    },
  });
  return { handler, calls, signed };
}

const body = {
  idempotency_key: KEY,
  public_reference: "tk-7k3q9x",
  secret: SECRET,
  mime_type: "image/jpeg",
  size_bytes: 1000,
};
const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x/a", { method: "POST", headers: { Origin: ORIGIN }, body: JSON.stringify(b) }));

Deno.test("public attachment gateway never returns the storage path", async () => {
  const { handler, calls, signed } = setup();
  const res = await post(handler, body);
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(JSON.parse(text), { attachment_id: "a1", upload_url: "https://s/upload?token=t" });
  assertEquals(text.includes(PATH), false);
  assertEquals(signed, [["support-attachments", PATH]]);
  assertEquals(calls, [["request_ticket_attachment", {
    p_idempotency_key: KEY,
    p_public_reference: "TK-7K3Q9X",
    p_secret: SECRET,
    p_mime_type: "image/jpeg",
    p_size_bytes: 1000,
  }]]);
});

Deno.test("NOT_FOUND is 404", async () => {
  const { handler } = setup(new GatewayError(422, "BUSINESS_RULE", "NOT_FOUND"));
  const res = await post(handler, body);
  assertEquals([res.status, (await res.json()).error.code], [404, "NOT_FOUND"]);
});

Deno.test("bad mime or oversize is 400 before any RPC", async () => {
  for (const b of [{ ...body, mime_type: "image/gif" }, { ...body, size_bytes: 5242881 }, { ...body, size_bytes: 0 }]) {
    const { handler, calls } = setup();
    const res = await post(handler, b);
    assertEquals([res.status, calls.length], [400, 0]);
    await res.body?.cancel();
  }
});
