import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { z } from "../core/deps.ts";
import { paystackGet, paystackPages } from "./paystack-client.ts";

Deno.test("paystackPages follows pageCount", async () => {
  const urls: string[] = [];
  const fetchFn: typeof fetch = (input) => {
    urls.push(String(input));
    const page = Number(new URL(String(input)).searchParams.get("page"));
    return Promise.resolve(new Response(JSON.stringify({
      status: true, data: [{ n: page }], meta: { pageCount: 3 },
    })));
  };
  const items = await paystackPages({ secretKey: "k", fetchFn }, "/refund", { reference: "TFW-1" }, z.object({ n: z.number() }));
  assertEquals(items, [{ n: 1 }, { n: 2 }, { n: 3 }]);
  assertEquals(urls, [1, 2, 3].map((p) => `https://api.paystack.co/refund?reference=TFW-1&perPage=100&page=${p}`));
});

Deno.test("paystackGet throws on status false", async () => {
  const fetchFn: typeof fetch = () => Promise.resolve(new Response(JSON.stringify({ status: false, message: "nope" }), { status: 200 }));
  await assertRejects(
    () => paystackGet({ secretKey: "k", fetchFn }, "/subaccount/x", {}, z.object({ status: z.literal(true) })),
    Error,
    "Paystack /subaccount/x failed",
  );
});

Deno.test("paystackGet sends the bearer key and skips undefined query values", async () => {
  const seen: Request[] = [];
  const fetchFn: typeof fetch = (i, init) => {
    seen.push(new Request(String(i), init));
    return Promise.resolve(new Response(JSON.stringify({ status: true })));
  };
  await paystackGet({ secretKey: "sk", baseUrl: "http://h", fetchFn }, "/p", { a: 1, b: undefined }, z.object({ status: z.literal(true) }));
  assertEquals(seen[0].url, "http://h/p?a=1");
  assertEquals(seen[0].headers.get("Authorization"), "Bearer sk");
});
