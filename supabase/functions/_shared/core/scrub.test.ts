import { assert, assertEquals } from "jsr:@std/assert@1";
import { isSensitiveKey, scrubBreadcrumb, scrubEvent, scrubString, scrubValue } from "./scrub.ts";

Deno.test("phone numbers are removed in every common Nigerian form", () => {
  assertEquals(scrubString("call +2348031234567 now"), "call [phone] now");
  assertEquals(scrubString("call 2348031234567"), "call [phone]");
  assertEquals(scrubString("call 08031234567"), "call [phone]");
  assertEquals(scrubString("call +447700900123"), "call [phone]");
});

Deno.test("PINs and codes next to their label are removed", () => {
  assertEquals(scrubString("delivery pin 4821 rejected"), "delivery pin [Filtered] rejected");
  assertEquals(scrubString("your code is 123456"), "your code is [Filtered]");
  assertEquals(scrubString("OTP: 0042"), "OTP: [Filtered]");
});

Deno.test("business messages with small numbers survive", () => {
  const msg = "Purerigin Coconut Oil - 200ml sells to the trade in packs of 3 units; 4 is not a whole number of packs.";
  assertEquals(scrubString(msg), msg);
  assertEquals(scrubString("Tenant is not authorized to sell products in category TELECOM."),
    "Tenant is not authorized to sell products in category TELECOM.");
});

Deno.test("tokens, keys, emails, IPs and signed URLs are removed", () => {
  const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
  assertEquals(scrubString(`token ${jwt}`), "token [jwt]");
  assertEquals(scrubString("Authorization: Bearer abc.def"), "Authorization: Bearer [Filtered]");
  assertEquals(scrubString("key sk_test_abc123"), "key [paystack-key]");
  assertEquals(scrubString("mail ada@example.com"), "mail [email]");
  assertEquals(scrubString("from 102.89.3.14"), "from [ip]");
  assertEquals(scrubString("from 2001:db8:85a3:0:0:8a2e:370:7334"), "from [ip]");
  assertEquals(
    scrubString("see https://x.supabase.co/storage/v1/object/sign/a/b.jpg?token=abc"),
    "see [signed-url]",
  );
});

Deno.test("sensitive keys are dropped whatever they hold", () => {
  for (const k of ["pin", "otp", "code", "delivery_code", "phone", "customer_phone", "email", "delivery_address",
    "authorization", "access_token", "phone_verification_token", "gateway_secret", "client_ip", "token_hash",
    "x-paystack-signature", "storage_path", "authorization_url", "p_pin", "p_code", "p_gateway_proof"]) {
    assert(isSensitiveKey(k), k);
  }
  for (const k of ["error_code", "db.sqlstate", "tenant_id", "function", "status", "sku_code_count"]) {
    assert(!isSensitiveKey(k), k);
  }
  assertEquals(scrubValue({ order: { pin: "1234", customer_phone: "+2348031234567", qty: 3 } }),
    { order: { pin: "[Filtered]", customer_phone: "[Filtered]", qty: 3 } });
});

Deno.test("an event keeps only the method and path of its request, and the user id", () => {
  const event: Record<string, unknown> = scrubEvent<Record<string, unknown>>({
    request: {
      method: "POST", url: "https://x.supabase.co/functions/v1/web-checkout?phone=08031234567",
      headers: { authorization: "Bearer eyJ...", cookie: "a=b" }, data: { pin: "1234" },
      query_string: "phone=08031234567",
    },
    user: { id: "u-1", ip_address: "102.89.3.14", email: "ada@example.com" },
    message: "failed for +2348031234567",
    tags: { tenant_id: "t-1", phone: "+2348031234567" },
    extra: { body: { delivery_pin: "4821" } },
    exception: { values: [{ type: "Error", value: "pin 4821 for 08031234567",
      stacktrace: { frames: [{ filename: "a.ts", lineno: 3, vars: { pin: "4821" } }] } }] },
  });
  assertEquals(event.request, { method: "POST", url: "https://x.supabase.co/functions/v1/web-checkout" });
  assertEquals(event.user, { id: "u-1" });
  assertEquals(event.message, "failed for [phone]");
  assertEquals(event.tags, { tenant_id: "t-1", phone: "[Filtered]" });
  assertEquals(event.extra, { body: { delivery_pin: "[Filtered]" } });
  const ex = (event.exception as { values: Array<{ value: string; stacktrace: { frames: unknown[] } }> }).values[0];
  assertEquals(ex.value, "pin [Filtered] for [phone]");
  assertEquals(ex.stacktrace.frames, [{ filename: "a.ts", lineno: 3 }]);
  assert(!JSON.stringify(event).includes("4821"));
  assert(!JSON.stringify(event).includes("8031234567"));
});

Deno.test("transaction spans are scrubbed too", () => {
  const event = scrubEvent({
    type: "transaction", transaction: "POST /order-dispatch",
    spans: [{ op: "db.rpc", description: "rpc mark_order_dispatched", data: { p_gateway_proof: "s3cret", phone: "x" } }],
  });
  assertEquals((event.spans as Array<{ data: unknown }>)[0].data, { p_gateway_proof: "[Filtered]", phone: "[Filtered]" });
});

Deno.test("breadcrumbs are scrubbed", () => {
  assertEquals(scrubBreadcrumb({ message: "sent to +2348031234567", data: { otp: "1234" } }),
    { message: "sent to [phone]", data: { otp: "[Filtered]" } });
});
