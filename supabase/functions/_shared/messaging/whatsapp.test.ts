import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { sendWhatsAppTemplate, type WhatsAppConfig, WhatsAppError, type WhatsAppTemplate } from "./whatsapp.ts";

const CFG: WhatsAppConfig = { token: "wa-secret-token", phoneNumberId: "555", apiVersion: "v21.0" };

function fakeFetch(status: number, body: unknown) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchFn = ((url: string, init: RequestInit) => {
    calls.push({ url, init });
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as unknown as typeof fetch;
  return { fetchFn, calls };
}

const send = (cfg: WhatsAppConfig, tpl: WhatsAppTemplate, fetchFn: typeof fetch) =>
  sendWhatsAppTemplate(cfg, "+2348012345678", tpl, new AbortController().signal, fetchFn);

Deno.test("posts to the versioned phone-number path with the bearer token and a bare number", async () => {
  const { fetchFn, calls } = fakeFetch(200, { messages: [{ id: "x" }] });
  await send(CFG, { name: "t", language: "en", params: ["A1"] }, fetchFn);
  assertEquals(calls[0].url, "https://graph.facebook.com/v21.0/555/messages");
  assertEquals((calls[0].init.headers as Record<string, string>).Authorization, "Bearer wa-secret-token");
  const body = JSON.parse(calls[0].init.body as string);
  assertEquals(body.to, "2348012345678");
  assertEquals(body.messaging_product, "whatsapp");
  assertEquals(body.template.name, "t");
  assertEquals(body.template.language, { code: "en" });
});

Deno.test("apiUrl overrides the Graph host", async () => {
  const { fetchFn, calls } = fakeFetch(200, {});
  await send({ ...CFG, apiUrl: "http://fake:1/" }, { name: "t", language: "en", params: [] }, fetchFn);
  assertEquals(calls[0].url, "http://fake:1/v21.0/555/messages");
});

Deno.test("a plain template has only a body component", async () => {
  const { fetchFn, calls } = fakeFetch(200, {});
  await send(CFG, { name: "t", language: "en", params: ["REF", "123456"] }, fetchFn);
  assertEquals(JSON.parse(calls[0].init.body as string).template.components, [
    { type: "body", parameters: [{ type: "text", text: "REF" }, { type: "text", text: "123456" }] },
  ]);
});

Deno.test("an authentication template adds the copy-code button whatever its name", async () => {
  const { fetchFn, calls } = fakeFetch(200, {});
  await send(CFG, { name: "custom_name", language: "en", params: ["123456"], kind: "authentication" }, fetchFn);
  assertEquals(JSON.parse(calls[0].init.body as string).template.components, [
    { type: "body", parameters: [{ type: "text", text: "123456" }] },
    { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: "123456" }] },
  ]);
});

Deno.test("a non-2xx answer throws with Meta's error.code and never the token", async () => {
  const { fetchFn } = fakeFetch(400, { error: { code: 131026, message: "undeliverable" } });
  const e = await assertRejects(() => send(CFG, { name: "t", language: "en", params: [] }, fetchFn), WhatsAppError);
  assertEquals(e.code, "131026");
  assertEquals(e.message, "WhatsApp send failed: HTTP 400 (code 131026)");
});

Deno.test("a non-2xx answer without a JSON body still throws", async () => {
  const fetchFn = (() => Promise.resolve(new Response("bad gateway", { status: 502 }))) as unknown as typeof fetch;
  const e = await assertRejects(() => send(CFG, { name: "t", language: "en", params: [] }, fetchFn), WhatsAppError);
  assertEquals([e.code, e.message], [undefined, "WhatsApp send failed: HTTP 502"]);
});
