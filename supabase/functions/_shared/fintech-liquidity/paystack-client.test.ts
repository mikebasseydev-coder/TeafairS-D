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

Deno.test("paystackPages refuses more than 50 pages", async () => {
  let calls = 0;
  const fetchFn: typeof fetch = () => {
    calls++;
    return Promise.resolve(new Response(JSON.stringify({ status: true, data: [{ n: 1 }], meta: { pageCount: 51 } })));
  };
  await assertRejects(
    () => paystackPages({ secretKey: "k", fetchFn }, "/refund", {}, z.object({ n: z.number() })),
    Error,
    "Paystack /refund failed: more than 5000 results",
  );
  assertEquals(calls, 1);
});

Deno.test("a bad shape names the field path but not its value", async () => {
  const fetchFn: typeof fetch = () => Promise.resolve(new Response(JSON.stringify({ status: true, data: { id: "secret-value" } })));
  const err = await assertRejects(
    () => paystackGet({ secretKey: "k", fetchFn }, "/p", {}, z.object({ data: z.object({ id: z.number() }) })),
    Error,
    "data.id",
  );
  assertEquals(err.message.includes("secret-value"), false);
});
