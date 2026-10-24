import { assertEquals } from "jsr:@std/assert@1";
import { clientIp, parseIpLiteral } from "./client-ip.ts";

const req = (headers: Record<string, string>) => new Request("http://x", { headers });

Deno.test("IPv4 and IPv6 literals pass", () => {
  for (const ip of ["1.2.3.4", "255.255.255.255", "0.0.0.0", "2001:db8::1", "::1", "::ffff:192.0.2.1", "fe80::a:b:c:d"]) {
    assertEquals(parseIpLiteral(ip), ip);
  }
  assertEquals(parseIpLiteral("  10.0.0.1 "), "10.0.0.1");
});

Deno.test("anything that is not an IP literal is null", () => {
  for (
    const v of [
      "unknown",
      "",
      "   ",
      "localhost",
      "256.1.1.1",
      "01.2.3.4",
      "1.2.3",
      "0x7f.0.0.1",
      "1:2:3:4:5:6:7:8:9",
      "2001:db8::1%eth0",
      "1::]/x[",
      "[::1]",
      "1.2.3.4:8080",
      null,
      undefined,
    ]
  ) {
    assertEquals(parseIpLiteral(v), null, String(v));
  }
});

Deno.test("clientIp reads cf-connecting-ip, else the first x-forwarded-for hop", () => {
  assertEquals(clientIp(req({ "cf-connecting-ip": "1.2.3.4", "x-forwarded-for": "5.6.7.8" })), "1.2.3.4");
  assertEquals(clientIp(req({ "x-forwarded-for": "2001:db8::7, 10.0.0.1" })), "2001:db8::7");
  assertEquals(clientIp(req({})), null);
});

Deno.test("a non-IP header value gives null, not a fallback to another header", () => {
  assertEquals(clientIp(req({ "cf-connecting-ip": "unknown" })), null);
  assertEquals(clientIp(req({ "cf-connecting-ip": "unknown", "x-forwarded-for": "5.6.7.8" })), null);
  assertEquals(clientIp(req({ "x-forwarded-for": "unknown, 1.2.3.4" })), null);
});
