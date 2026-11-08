import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import type { Rpc } from "../_shared/core/db.ts";
import { createMonveloCoverUploadHandler } from "./handler.ts";

const SHOP = "71000000-0000-0000-0000-000000000001";
const FIN = "f1000000-0000-0000-0000-000000000001";

function setup(allowed = true) {
  const auths: string[] = [];
  const calls: Array<[string, Record<string, unknown>]> = [];
  const signed: Array<[string, string]> = [];
  const rpc: Rpc = <T>(fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve(allowed as T);
  };
  const handler = createMonveloCoverUploadHandler({
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

const post = (h: (r: Request) => Promise<Response>, b: unknown) =>
  h(new Request("http://x", { method: "POST", body: JSON.stringify(b), headers: { Authorization: "Bearer tok" } }));

Deno.test("a shop policy certificate: checked on the caller's JWT, signed under the shop's folder", async () => {
  const s = setup();
  const res = await post(s.handler, { purpose: "SHOP_POLICY", subject_id: SHOP, content_type: "application/pdf", byte_length: 204800 });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(s.auths, ["Bearer tok"]);
  assertEquals(s.calls, [["can_upload_monvelo_cover", { p_purpose: "SHOP_POLICY", p_subject_id: SHOP }]]);
  assertEquals(s.signed.length, 1);
  assertEquals(s.signed[0][0], "monvelo-shop-policies");
  assertMatch(s.signed[0][1], new RegExp(`^${SHOP}/[0-9a-f-]{36}\\.pdf$`));
  assertEquals(body, { bucket: "monvelo-shop-policies", path: s.signed[0][1], upload_url: "https://s/upload?token=t" });
});

Deno.test("loss evidence is signed under the financing's folder", async () => {
  const s = setup();
  const res = await post(s.handler, { purpose: "CLAIM_EVIDENCE", subject_id: FIN, content_type: "image/jpeg", byte_length: 1000 });
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(s.signed[0][0], "monvelo-claim-evidence");
  assertMatch(s.signed[0][1], new RegExp(`^${FIN}/[0-9a-f-]{36}\\.jpg$`));
});

Deno.test("a caller the database refuses gets 403 and nothing is signed", async () => {
  const s = setup(false);
  const res = await post(s.handler, { purpose: "SHOP_POLICY", subject_id: SHOP, content_type: "image/png", byte_length: 10 });
  assertEquals(res.status, 403);
  await res.body?.cancel();
  assertEquals(s.signed.length, 0);
});

Deno.test("a wrong type, an empty or oversized file, or an unknown purpose is 400 before any rpc", async () => {
  const bad = [
    { purpose: "SHOP_POLICY", subject_id: SHOP, content_type: "image/gif", byte_length: 10 },
    { purpose: "SHOP_POLICY", subject_id: SHOP, content_type: "application/pdf", byte_length: 10_485_761 },
    { purpose: "SHOP_POLICY", subject_id: SHOP, content_type: "application/pdf", byte_length: 0 },
    { purpose: "OTHER", subject_id: SHOP, content_type: "application/pdf", byte_length: 10 },
    { purpose: "SHOP_POLICY", subject_id: "not-a-uuid", content_type: "application/pdf", byte_length: 10 },
  ];
  for (const b of bad) {
    const s = setup();
    const res = await post(s.handler, b);
    assertEquals(res.status, 400, JSON.stringify(b));
    await res.body?.cancel();
    assertEquals(s.calls.length + s.signed.length, 0);
  }
});
