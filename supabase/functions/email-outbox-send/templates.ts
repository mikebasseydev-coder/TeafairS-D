// Addendum A7 §5.4 — the ticket email copy. Only the reference, the status
// and (for tenants) the subject and category are rendered: never a message
// body or a ticket secret, whatever else the payload holds. The buyer reads
// their messages on the ticket page with the code they were given at open.
export type OutboxRow = { template: string; payload: Record<string, unknown> };
export type RenderConfig = { ticketUrl?: string };
export type Rendered = { subject: string; html: string; text: string };

// A buyer template is due but WEB_SUPPORT_TICKET_URL is not set: the row is
// retried rather than sent without its link.
export class MissingConfigError extends Error {
  constructor() {
    super("WEB_SUPPORT_TICKET_URL is not set");
    this.name = "MissingConfigError";
  }
}

const esc = (s: string) =>
  s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

const str = (v: unknown) => (typeof v === "string" ? v : "");
const statusWord = (v: unknown) => (v === "CLOSED" ? "closed" : "resolved");

const CODE_LINE = "To read the messages, enter the ticket code you were given when you opened the ticket.";
const APP_LINE = "Sign in to the Teafair app to read and reply.";

const CATEGORY: Record<string, string> = {
  TENANT_SETTLEMENT_DISCREPANCY: "Settlement discrepancy",
  TENANT_STOCK_SHORTAGE: "Stock shortage",
  TENANT_ONBOARDING_ISSUE: "Onboarding issue",
  TENANT_GENERAL_INQUIRY: "General inquiry",
};

function page(paragraphs: string[]): string {
  return `<!doctype html><html><body style="font-family:Arial,sans-serif;line-height:1.5">${
    paragraphs.map((p) => `<p>${p}</p>`).join("")
  }<p>Teafair Support</p></body></html>`;
}

function buyer(ref: string, subject: string, lead: string, cfg: RenderConfig): Rendered {
  if (!cfg.ticketUrl) throw new MissingConfigError();
  const link = `${cfg.ticketUrl.replace(/\/$/, "")}?ref=${encodeURIComponent(ref)}`;
  return {
    subject,
    html: page([esc(lead), `<a href="${esc(link)}">View ticket ${esc(ref)}</a>`, esc(CODE_LINE)]),
    text: `${lead}\n\nView ticket ${ref}: ${link}\n\n${CODE_LINE}\n\nTeafair Support\n`,
  };
}

function tenant(p: Record<string, unknown>, subject: string, lead: string): Rendered {
  const lines = [lead, `Subject: ${str(p.subject)}`, `Category: ${CATEGORY[str(p.category)] ?? str(p.category)}`, APP_LINE];
  return {
    subject,
    html: page(lines.map(esc)),
    text: `${lines.join("\n\n")}\n\nTeafair Support\n`,
  };
}

export function renderEmail(row: OutboxRow, cfg: RenderConfig): Rendered {
  const p = row.payload ?? {};
  const ref = str(p.public_reference);
  switch (row.template) {
    case "BUYER_TICKET_OPENED":
      return buyer(ref, `We've received your support request ${ref}`,
        `Thank you for contacting Teafair. Your support request ${ref} is open and our team will reply soon.`, cfg);
    case "BUYER_TICKET_REPLY":
      return buyer(ref, `New update on your support ticket ${ref}`,
        `There is a new reply from Teafair on your support ticket ${ref}.`, cfg);
    case "BUYER_TICKET_STATUS": {
      const w = statusWord(p.status);
      return buyer(ref, `Your support ticket ${ref} is ${w}`, `Your support ticket ${ref} is now ${w}.`, cfg);
    }
    case "TENANT_TICKET_OPENED":
      return tenant(p, `Support ticket ${ref} received`,
        `We have received your support ticket ${ref}. Your Client Service Manager will reply soon.`);
    case "TENANT_TICKET_REPLY":
      return tenant(p, `New reply on support ticket ${ref}`, `Teafair has replied on your support ticket ${ref}.`);
    case "TENANT_TICKET_STATUS": {
      const w = statusWord(p.status);
      return tenant(p, `Support ticket ${ref} is ${w}`, `Your support ticket ${ref} is now ${w}.`);
    }
    case "MONVELO_SHOP_COVER_EXPIRING": {
      // A8 §7.1: the shop and the date only; never a policy number or a sum insured
      const shop = str(p.shop_name).replace(/[\r\n]+/g, " ");
      const lead = `The fire and burglary policy for ${shop} expires on ${str(p.expires_on)}. Ask the shop owner for ` +
        `the renewed certificate and add it in the app before then, or the shop's agents will pay the auto-policy premium.`;
      return { subject: `Shop cover expiring: ${shop}`, html: page([esc(lead)]), text: `${lead}\n\nTeafair Support\n` };
    }
    default:
      throw new Error(`unknown email template ${row.template}`);
  }
}
