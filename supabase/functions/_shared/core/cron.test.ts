import { assertEquals } from "jsr:@std/assert@1";
import { cronAuthorized } from "./cron.ts";

const req = (secret?: string) =>
  new Request("http://x/", { method: "POST", headers: secret === undefined ? {} : { "x-cron-secret": secret } });

Deno.test("the right secret is authorized", () => assertEquals(cronAuthorized(req("s3cret"), "s3cret"), true));
Deno.test("a wrong secret is refused", () => {
  assertEquals(cronAuthorized(req("s3creT"), "s3cret"), false);
  assertEquals(cronAuthorized(req("s3cret-longer"), "s3cret"), false);
});
Deno.test("a missing header is refused", () => assertEquals(cronAuthorized(req(), "s3cret"), false));
Deno.test("an empty configured secret is refused", () => {
  assertEquals(cronAuthorized(req(""), ""), false);
  assertEquals(cronAuthorized(req("x"), ""), false);
});
