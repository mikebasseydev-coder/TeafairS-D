import { assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { MissingConfigError, renderEmail } from "./templates.ts";

const cfg = { ticketUrl: "http://x/support/ticket" };
const buyer = (template: string, extra: Record<string, unknown> = {}) =>
  renderEmail({ template, payload: { public_reference: "TK-ABC123", ...extra } }, cfg);
const tenant = (template: string, extra: Record<string, unknown> = {}) =>
  renderEmail({
    template,
    payload: { public_reference: "TS-XYZ789", category: "TENANT_STOCK_SHORTAGE", subject: "Short on 100ml", ...extra },
  }, {});

Deno.test("buyer link pre-fills the reference in html and text", () => {
  const e = buyer("BUYER_TICKET_REPLY");
  assertStringIncludes(e.html, "http://x/support/ticket?ref=TK-ABC123");
  assertStringIncludes(e.text, "http://x/support/ticket?ref=TK-ABC123");
  assertStringIncludes(e.text, "To read the messages, enter the ticket code you were given when you opened the ticket.");
});

Deno.test("no secret and no body ever reach an email", () => {
  for (const t of ["BUYER_TICKET_OPENED", "BUYER_TICKET_REPLY", "BUYER_TICKET_STATUS"]) {
    const e = buyer(t, { status: "CLOSED", body: "BODY-LEAK", secret: "SECRET-LEAK" });
    for (const part of [e.subject, e.html, e.text]) {
      assertEquals(part.includes("BODY-LEAK"), false);
      assertEquals(part.includes("SECRET-LEAK"), false);
    }
  }
  const e = tenant("TENANT_TICKET_REPLY", { body: "BODY-LEAK" });
  assertEquals(e.html.includes("BODY-LEAK") || e.text.includes("BODY-LEAK"), false);
});

Deno.test("the tenant's subject is escaped in html", () => {
  const e = tenant("TENANT_TICKET_OPENED", { subject: `<script>&"` });
  assertStringIncludes(e.html, "&lt;script&gt;&amp;&quot;");
  assertEquals(e.html.includes("<script>"), false);
  assertStringIncludes(e.text, `<script>&"`);
});

Deno.test("a buyer template without the ticket URL fails closed", () => {
  assertThrows(() => renderEmail({ template: "BUYER_TICKET_OPENED", payload: { public_reference: "TK-ABC123" } }, {}),
    MissingConfigError);
});

Deno.test("a tenant template needs no URL and carries no link", () => {
  const e = tenant("TENANT_TICKET_REPLY");
  assertStringIncludes(e.text, "Sign in to the Teafair app to read and reply.");
  assertEquals(e.html.includes("href"), false);
});

Deno.test("an unknown template throws", () => {
  assertThrows(() => renderEmail({ template: "NOPE", payload: {} }, cfg));
});

Deno.test("every subject line", () => {
  assertEquals(buyer("BUYER_TICKET_OPENED").subject, "We've received your support request TK-ABC123");
  assertEquals(buyer("BUYER_TICKET_REPLY").subject, "New update on your support ticket TK-ABC123");
  assertEquals(buyer("BUYER_TICKET_STATUS", { status: "RESOLVED" }).subject, "Your support ticket TK-ABC123 is resolved");
  assertEquals(buyer("BUYER_TICKET_STATUS", { status: "CLOSED" }).subject, "Your support ticket TK-ABC123 is closed");
  assertEquals(tenant("TENANT_TICKET_OPENED").subject, "Support ticket TS-XYZ789 received");
  assertEquals(tenant("TENANT_TICKET_REPLY").subject, "New reply on support ticket TS-XYZ789");
  assertEquals(tenant("TENANT_TICKET_STATUS", { status: "RESOLVED" }).subject, "Support ticket TS-XYZ789 is resolved");
  assertEquals(tenant("TENANT_TICKET_STATUS", { status: "CLOSED" }).subject, "Support ticket TS-XYZ789 is closed");
});
