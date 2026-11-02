import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { PaystackDuplicateReference, paystackInitializer, paystackVerifier } from "./paystack.ts";

function fakeFetch(body: unknown, status = 200, seen: Request[] = []): typeof fetch {
  return (input, init) => {
    seen.push(new Request(input as string, init));
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
}

const verified = {
  status: true,
  message: "Verification successful",
  data: { id: 2009945086, status: "success", reference: "ref/1", amount: 250000, currency: "NGN", paid_at: "2026-10-07T12:00:00.000Z" },
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

const splitData = (extra: Record<string, unknown>) => ({
  status: true,
  data: {
    id: 2009945086, status: "success", reference: "TFW-1", amount: 250000, currency: "NGN",
    customer: { email: "buyer@example.com" }, authorization: { last4: "4081" }, ...extra,
  },
});

Deno.test("verify returns the transaction id and split", async () => {
  const body = splitData({
    subaccount: { subaccount_code: "ACCT_grace01" },
    fees_split: { paystack: 100, integration: 0, subaccount: 3750, params: { bearer: "account", transaction_charge: "1000", percentage_charge: "0" } },
  });
  const tx = await paystackVerifier({ secretKey: "k", fetchFn: fakeFetch(body) })("TFW-1");
  assertEquals(tx.transactionId, "2009945086");
  assertEquals(tx.split, { subaccountCode: "ACCT_grace01", shareMinor: 3750 });
});

Deno.test("verify without a split has split null", async () => {
  const body = splitData({ subaccount: {}, fees_split: null });
  const tx = await paystackVerifier({ secretKey: "k", fetchFn: fakeFetch(body) })("TFW-1");
  assertEquals(tx.transactionId, "2009945086");
  assertEquals(tx.split, null);
});

Deno.test("a malformed data block is an error", async () => {
  const verify = paystackVerifier({ secretKey: "k", fetchFn: fakeFetch({ status: true, data: { status: "success" } }) });
  await assertRejects(() => verify("r"));
});

const initialized = {
  status: true,
  message: "Authorization URL created",
  data: { authorization_url: "https://checkout.paystack.com/ac_9", access_code: "ac_9", reference: "TFW-1" },
};

Deno.test("Initialize posts the amount, split and callback with the secret key", async () => {
  const seen: Request[] = [];
  const init = paystackInitializer({ secretKey: "sk_test_x", fetchFn: fakeFetch(initialized, 200, seen) });
  const tx = await init({
    reference: "TFW-1", amountMinor: 558000, currency: "NGN", email: "ada@example.com",
    callbackUrl: "https://teafairweb.com/checkout/complete", metadata: { agent_code: "GRACE-01" },
    split: { subaccount: "ACCT_grace01", transactionChargeMinor: 549630 },
  });
  assertEquals(seen[0].url, "https://api.paystack.co/transaction/initialize");
  assertEquals(seen[0].headers.get("Authorization"), "Bearer sk_test_x");
  assertEquals(await seen[0].json(), {
    reference: "TFW-1", amount: 558000, currency: "NGN", email: "ada@example.com",
    callback_url: "https://teafairweb.com/checkout/complete", metadata: { agent_code: "GRACE-01" },
    subaccount: "ACCT_grace01", transaction_charge: 549630, bearer: "account",
  });
  assertEquals(tx, { reference: "TFW-1", accessCode: "ac_9", authorizationUrl: "https://checkout.paystack.com/ac_9" });
});

Deno.test("Initialize without a split sends no subaccount fields", async () => {
  const seen: Request[] = [];
  await paystackInitializer({ secretKey: "k", fetchFn: fakeFetch(initialized, 200, seen) })({
    reference: "TFW-1", amountMinor: 120000, currency: "NGN", email: "e@x.com", callbackUrl: "https://t/c", metadata: {},
  });
  const body = await seen[0].json();
  assertEquals(["subaccount" in body, "transaction_charge" in body, "bearer" in body], [false, false, false]);
});

Deno.test("Initialize status:false is an error", async () => {
  const init = paystackInitializer({ secretKey: "k", fetchFn: fakeFetch({ status: false, message: "Duplicate Transaction Reference" }, 400) });
  await assertRejects(
    () => init({ reference: "r", amountMinor: 1, currency: "NGN", email: "e@x.com", callbackUrl: "https://t/c", metadata: {} }),
    Error, "Duplicate Transaction Reference");
});

Deno.test("a duplicate reference is its own error; other refusals are not", async () => {
  const dup = paystackInitializer({ secretKey: "k", fetchFn: fakeFetch({ status: false, message: "Duplicate Transaction Reference" }, 400) });
  await assertRejects(
    () => dup({ reference: "r", amountMinor: 1, currency: "NGN", email: "e@x.com", metadata: {} }),
    PaystackDuplicateReference);
  const other = paystackInitializer({ secretKey: "k", fetchFn: fakeFetch({ status: false, message: "Invalid key" }, 401) });
  const e = await assertRejects(() => other({ reference: "r", amountMinor: 1, currency: "NGN", email: "e@x.com", metadata: {} }));
  assertEquals(e instanceof PaystackDuplicateReference, false);
});

Deno.test("a hung Initialize call is aborted by the timeout", async () => {
  const hang: typeof fetch = (_i, init) =>
    new Promise((_res, rej) => {
      init?.signal?.addEventListener("abort", () => rej(init.signal!.reason));
    });
  const init = paystackInitializer({ secretKey: "sk", fetchFn: hang, timeoutMs: 10 });
  await assertRejects(() =>
    init({ reference: "r", amountMinor: 100, currency: "NGN", email: "a@b.co", callbackUrl: "https://x.test/cb", metadata: {} })
  );
});

Deno.test("a hung Verify call is aborted by the timeout", async () => {
  let aborted = false;
  const hang: typeof fetch = (_i, init) =>
    new Promise((_res, rej) => {
      init?.signal?.addEventListener("abort", () => {
        aborted = true;
        rej(init.signal!.reason);
      });
    });
  const verify = paystackVerifier({ secretKey: "sk", fetchFn: hang, timeoutMs: 10 });
  await assertRejects(() => verify("TFW-1"));
  assertEquals(aborted, true);
});

Deno.test("Initialize sends channels when set and omits callback_url when unset", async () => {
  const seen: Request[] = [];
  await paystackInitializer({ secretKey: "k", fetchFn: fakeFetch(initialized, 200, seen) })({
    reference: "MV-1", amountMinor: 100, currency: "NGN", email: "e@x.com", channels: ["bank_transfer"], metadata: {},
  });
  const sent = await seen[0].json();
  assertEquals(sent.channels, ["bank_transfer"]);
  assertEquals("callback_url" in sent, false);
});

Deno.test("Initialize omits channels when unset", async () => {
  const seen: Request[] = [];
  await paystackInitializer({ secretKey: "k", fetchFn: fakeFetch(initialized, 200, seen) })({
    reference: "TFW-1", amountMinor: 100, currency: "NGN", email: "e@x.com", callbackUrl: "https://t/c", metadata: {},
  });
  assertEquals("channels" in await seen[0].json(), false);
});
