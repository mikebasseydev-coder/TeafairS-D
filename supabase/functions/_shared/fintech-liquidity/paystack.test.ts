import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { paystackVerifier } from "./paystack.ts";

function fakeFetch(body: unknown, status = 200, seen: Request[] = []): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
}

const verified = {
  status: true,
  message: "Verification successful",
  data: { status: "success", reference: "ref/1", amount: 250000, currency: "NGN", paid_at: "2026-10-07T12:00:00.000Z" },
};

Deno.test("the Verify API is called with the secret key and an encoded reference", async () => {
  const seen: Request[] = [];
  const verify = paystackVerifier({ secretKey: "sk_test_x", fetchFn: fakeFetch(verified, 200, seen) });
  const tx = await verify("ref/1");
  assertEquals(seen[0].url, "https://api.paystack.co/transaction/verify/ref%2F1");
  assertEquals(seen[0].headers.get("Authorization"), "Bearer sk_test_x");
  assertEquals([tx.status, tx.reference, tx.amountMinor, tx.currency], ["success", "ref/1", 250000, "NGN"]);
  assertEquals(tx.raw, verified.data);
});

Deno.test("a base URL override is honoured (local fake Paystack)", async () => {
  const seen: Request[] = [];
  await paystackVerifier({ secretKey: "k", baseUrl: "http://host.docker.internal:54399", fetchFn: fakeFetch(verified, 200, seen) })("r");
  assertEquals(seen[0].url, "http://host.docker.internal:54399/transaction/verify/r");
});

Deno.test("status:false is an error, never a settlement", async () => {
  const verify = paystackVerifier({ secretKey: "k", fetchFn: fakeFetch({ status: false, message: "Transaction reference not found" }, 400) });
  await assertRejects(() => verify("r"), Error, "Transaction reference not found");
});

Deno.test("a malformed data block is an error", async () => {
  const verify = paystackVerifier({ secretKey: "k", fetchFn: fakeFetch({ status: true, data: { status: "success" } }) });
  await assertRejects(() => verify("r"));
});
