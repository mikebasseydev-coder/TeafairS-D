import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { generateOtpCode, maskPhone } from "./code.ts";

Deno.test("codes are six digits, leading zeros kept", () => {
  for (let i = 0; i < 500; i++) assertMatch(generateOtpCode(), /^\d{6}$/);
});

Deno.test("codes vary", () => {
  assertEquals(new Set(Array.from({ length: 50 }, generateOtpCode)).size > 40, true);
});

Deno.test("the destination is masked for the agent's screen", () => {
  assertEquals(maskPhone("+2348012345678"), "+234******5678");
});
