import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { GatewayError } from "../core/errors.ts";
import { resolveAccount } from "./paystack-resolve.ts";

function fake(status: number, payload: unknown) {
  const urls: string[] = [];
  const auth: Array<string | null> = [];
  const fetchFn: typeof fetch = (input, init) => {
    urls.push(String(input));
    auth.push(new Headers(init?.headers).get("authorization"));
    return Promise.resolve(Response.json(payload, { status }));
  };
  return { fetchFn, urls, auth };
}

const OK = {
  status: true,
  message: "Account number resolved",
  data: { account_number: "0123456789", account_name: "ADA OBI STORES", bank_id: 9 },
};

Deno.test("resolveAccount calls /bank/resolve and returns Paystack's account name", async () => {
  const f = fake(200, OK);
  const r = await resolveAccount({ secretKey: "sk_test_x", baseUrl: "https://ps.test", fetchFn: f.fetchFn }, "0123456789", "058");
  assertEquals(r, { accountName: "ADA OBI STORES" });
  assertEquals(f.urls, ["https://ps.test/bank/resolve?account_number=0123456789&bank_code=058"]);
  assertEquals(f.auth, ["Bearer sk_test_x"]);
});

Deno.test("an unresolvable account (HTTP 422, status:false) is 422 ACCOUNT_NOT_RESOLVED without Paystack's text", async () => {
  const f = fake(422, { status: false, message: "Could not resolve account name. Check parameters or try again." });
  const err = await assertRejects(
    () => resolveAccount({ secretKey: "k", fetchFn: f.fetchFn }, "0123456789", "058"),
    GatewayError,
  );
  assertEquals([err.status, err.code, err.message], [422, "ACCOUNT_NOT_RESOLVED", "That bank account could not be verified."]);
});

Deno.test("status:false on HTTP 200 is also 422 ACCOUNT_NOT_RESOLVED", async () => {
  const f = fake(200, { status: false, message: "nope" });
  const err = await assertRejects(() => resolveAccount({ secretKey: "k", fetchFn: f.fetchFn }, "0123456789", "058"), GatewayError);
  assertEquals([err.status, err.code], [422, "ACCOUNT_NOT_RESOLVED"]);
});

Deno.test("a Paystack outage, bad key or network failure is 502 BANK_VERIFICATION_UNAVAILABLE", async () => {
  for (const status of [401, 429, 500, 503]) {
    const f = fake(status, { status: false, message: "secret detail" });
    const err = await assertRejects(() => resolveAccount({ secretKey: "k", fetchFn: f.fetchFn }, "0123456789", "058"), GatewayError);
    assertEquals([err.status, err.code, err.message.includes("secret")], [502, "BANK_VERIFICATION_UNAVAILABLE", false]);
  }
  const down: typeof fetch = () => Promise.reject(new TypeError("connection refused"));
  const err = await assertRejects(() => resolveAccount({ secretKey: "k", fetchFn: down }, "0123456789", "058"), GatewayError);
  assertEquals([err.status, err.code], [502, "BANK_VERIFICATION_UNAVAILABLE"]);
});

Deno.test("a 200 with an unexpected shape is 502, not a crash", async () => {
  const f = fake(200, { status: true, data: {} });
  const err = await assertRejects(() => resolveAccount({ secretKey: "k", fetchFn: f.fetchFn }, "0123456789", "058"), GatewayError);
  assertEquals(err.status, 502);
});
