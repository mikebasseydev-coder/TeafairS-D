import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import type { Email } from "../messaging/resend.ts";
import { maskEmail, monveloCodeEmail, monveloCodeSender } from "./code-email.ts";

Deno.test("each purpose has its own fixed subject, and the body carries the code", () => {
  for (const [purpose, word] of [["CONSENT", "consent"], ["POLICY_CONSENT", "policy"], ["DELIVERY", "delivery"],
                                 ["REPAYMENT", "repayment"]] as const) {
    const e = monveloCodeEmail("a@b.co", purpose, "042917", "k");
    assertEquals(e.subject.toLowerCase().includes(word), true);
    assertEquals(e.subject.includes("042917"), false);
    assertEquals(e.text.includes("042917") && e.html.includes("042917"), true);
  }
});

Deno.test("only a six-digit code is ever worded", () => {
  assertThrows(() => monveloCodeEmail("a@b.co", "CONSENT", "<b>1</b>", "k"));
});

Deno.test("the sender keys each email on its challenge, so a retry never sends twice", async () => {
  const sent: Email[] = [];
  const send = monveloCodeSender((e) => {
    sent.push(e);
    return Promise.resolve();
  });
  await send("owner@example.com", "DELIVERY", "123456", "c1");
  assertEquals([sent.length, sent[0].to, sent[0].idempotencyKey], [1, "owner@example.com", "monvelo-code:c1"]);
});

Deno.test("an address is masked to its first letters", () => {
  assertEquals(maskEmail("owner.one@example.com"), "o***@e***.com");
  assertEquals(maskEmail("x@localhost"), "x***@l***");
  assertEquals(maskEmail("broken"), "***");
});
