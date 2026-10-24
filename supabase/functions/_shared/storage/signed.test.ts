import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { createSignedDownloadUrl, createSignedUploadUrl, removeObjects, storageConfigFromEnv } from "./signed.ts";

type Call = { url: string; init: RequestInit };
function fake(status: number, payload: unknown) {
  const calls: Call[] = [];
  const fetch = (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return Promise.resolve(new Response(JSON.stringify(payload), { status }));
  };
  return { cfg: { url: "http://kong:8000", serviceKey: "svc-key", fetch: fetch as typeof globalThis.fetch }, calls };
}

Deno.test("signed upload URL uses the upload/sign endpoint with the service key, without upsert", async () => {
  const { cfg, calls } = fake(200, { url: "/object/upload/sign/support-attachments/t/a.jpg?token=abc" });
  const url = await createSignedUploadUrl(cfg, "support-attachments", "t/a.jpg");
  assertEquals(url, "http://kong:8000/storage/v1/object/upload/sign/support-attachments/t/a.jpg?token=abc");
  assertEquals(calls[0].url, "http://kong:8000/storage/v1/object/upload/sign/support-attachments/t/a.jpg");
  assertEquals(calls[0].init.method, "POST");
  const h = new Headers(calls[0].init.headers);
  assertEquals([h.get("authorization"), h.get("apikey"), h.get("x-upsert")], ["Bearer svc-key", "svc-key", null]);
});

Deno.test("download URL expires in 600 seconds", async () => {
  const { cfg, calls } = fake(200, { signedURL: "/object/sign/support-attachments/t/a.jpg?token=xyz" });
  const url = await createSignedDownloadUrl(cfg, "support-attachments", "t/a.jpg");
  assertEquals(url, "http://kong:8000/storage/v1/object/sign/support-attachments/t/a.jpg?token=xyz");
  assertEquals(JSON.parse(String(calls[0].init.body)), { expiresIn: 600 });
});

Deno.test("an already-prefixed relative URL is not prefixed twice", async () => {
  const { cfg } = fake(200, { signedURL: "/storage/v1/object/sign/b/p?token=1" });
  assertEquals(await createSignedDownloadUrl(cfg, "b", "p"), "http://kong:8000/storage/v1/object/sign/b/p?token=1");
});

Deno.test("a non-2xx response throws without echoing the path", async () => {
  const { cfg } = fake(404, { error: "x" });
  const e = await assertRejects(() => createSignedDownloadUrl(cfg, "b", "secret/path.jpg"));
  assertEquals(String((e as Error).message).includes("secret/path.jpg"), false);
  await assertRejects(() => createSignedUploadUrl(fake(500, {}).cfg, "b", "p"));
});

Deno.test("removeObjects sends the prefixes as a DELETE body", async () => {
  const { cfg, calls } = fake(200, [{ name: "a" }]);
  await removeObjects(cfg, "support-attachments", ["a", "b"]);
  assertEquals(calls[0].url, "http://kong:8000/storage/v1/object/support-attachments");
  assertEquals(calls[0].init.method, "DELETE");
  assertEquals(JSON.parse(String(calls[0].init.body)), { prefixes: ["a", "b"] });
  await assertRejects(() => removeObjects(fake(500, {}).cfg, "b", ["a"]));
});

Deno.test("storageConfigFromEnv reads the two variables", () => {
  Deno.env.set("SUPABASE_URL", "http://u");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "k");
  const c = storageConfigFromEnv();
  assertEquals([c.url, c.serviceKey], ["http://u", "k"]);
});
