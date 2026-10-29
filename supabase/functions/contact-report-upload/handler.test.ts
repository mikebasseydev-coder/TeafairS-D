import { assertEquals } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createContactReportUploadHandler } from "./handler.ts";

const KEY = "c0000000-0000-0000-0000-000000000001";
const REPORT = "d0000000-0000-0000-0000-000000000001";
const PATH = "contact-reports/report/copy.pdf";

function setup() {
  const auths: string[] = [];
  const calls: Array<[string, Record<string, unknown>]> = [];
  const signed: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve({ hard_copy_id: "h1", storage_path: PATH } as T);
  };
  const handler = createContactReportUploadHandler({
    verifyToken: () => Promise.resolve({ sub: "u1", role: "authenticated", app_metadata: {} }),
    rpcFor: (authorization) => {
      auths.push(authorization);
      return rpc;
    },
    signUpload: (bucket, path) => {
      signed.push([bucket, path]);
      return Promise.resolve("https://s/upload?token=t");
    },
  });
  return { handler, auths, calls, signed };
}

const post = (handler: (r: Request) => Promise<Response>, b: unknown) =>
  handler(new Request("http://x", { method: "POST", body: JSON.stringify(b), headers: { Authorization: "Bearer tok" } }));

Deno.test("hard copy gateway forwards the caller's JWT, signs the path and hides it", async () => {
  const { handler, auths, calls, signed } = setup();
  const res = await post(handler, { idempotency_key: KEY, report_id: REPORT, mime_type: "application/pdf", size_bytes: 204800 });
  const text = await res.text();
  assertEquals(res.status, 200);
  assertEquals(JSON.parse(text), { hard_copy_id: "h1", upload_url: "https://s/upload?token=t" });
  assertEquals(text.includes(PATH), false);
  assertEquals(auths, ["Bearer tok"]);
  assertEquals(signed, [["contact-reports", PATH]]);
  assertEquals(calls, [["request_contact_report_hard_copy", {
    p_idempotency_key: KEY,
    p_report_id: REPORT,
    p_mime_type: "application/pdf",
    p_size_bytes: 204800,
  }]]);
});

Deno.test("a bad type, an oversize file or a missing token is refused with no RPC", async () => {
  const { handler, calls } = setup();
  const badType = await post(handler, { idempotency_key: KEY, report_id: REPORT, mime_type: "text/plain", size_bytes: 10 });
  assertEquals(badType.status, 400);
  await badType.body?.cancel();
  const big = await post(handler, { idempotency_key: KEY, report_id: REPORT, mime_type: "application/pdf", size_bytes: 10485761 });
  assertEquals(big.status, 400);
  await big.body?.cancel();
  const none = await handler(new Request("http://x", { method: "POST", body: "{}" }));
  assertEquals(none.status, 401);
  await none.body?.cancel();
  assertEquals(calls.length, 0);
});
