// Auth email copy. Fixed text only: nothing a user typed (name, email) is
// rendered, so there is nothing to escape but the link we build ourselves.
export type EmailKind = "recovery" | "signup" | "invite" | "email_change_current" | "email_change_new";

const COPY: Record<EmailKind, { subject: string; heading: string; body: string; button: string }> = {
  recovery: {
    subject: "Reset your Teafair password",
    heading: "Reset your password",
    body: "Someone asked to reset the password on your Teafair account. If it was you, choose a new password below. If not, ignore this email: your password stays the same.",
    button: "Choose a new password",
  },
  signup: {
    subject: "Confirm your Teafair email",
    heading: "Confirm your email",
    body: "Confirm this email address to finish setting up your Teafair account.",
    button: "Confirm email",
  },
  invite: {
    subject: "You have been invited to Teafair",
    heading: "Join Teafair",
    body: "You have been invited to a Teafair team. Accept the invitation to set up your account.",
    button: "Accept invitation",
  },
  email_change_current: {
    subject: "Confirm your Teafair email change",
    heading: "Confirm the change",
    body: "Someone asked to move your Teafair account to a new email address. Confirm only if it was you. Both addresses must confirm before the change takes effect.",
    button: "Confirm the change",
  },
  email_change_new: {
    subject: "Confirm your new Teafair email",
    heading: "Confirm your new email",
    body: "Confirm this address to make it the email on your Teafair account.",
    button: "Confirm new email",
  },
};

const escapeHtml = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export function renderEmail(kind: EmailKind, link: string): { subject: string; html: string; text: string } {
  const c = COPY[kind];
  const href = escapeHtml(link);
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${c.subject}</title></head>
<body style="margin:0;padding:0;background:#f6f6f4;font-family:Helvetica,Arial,sans-serif;color:#1f2a1f">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f6f4;padding:24px 12px">
<tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:8px;padding:32px 24px">
<tr><td style="font-size:20px;font-weight:bold;padding-bottom:16px">${c.heading}</td></tr>
<tr><td style="font-size:15px;line-height:22px;padding-bottom:24px">${c.body}</td></tr>
<tr><td align="center" style="padding-bottom:24px">
<a href="${href}" style="display:inline-block;background:#2f5d34;color:#ffffff;text-decoration:none;font-size:15px;font-weight:bold;padding:12px 24px;border-radius:6px">${c.button}</a>
</td></tr>
<tr><td style="font-size:12px;line-height:18px;color:#5b665b">The link works once and expires soon. Teafair will never ask for your password, PIN or codes.</td></tr>
</table></td></tr></table></body></html>`;
  const text = `${c.heading}\n\n${c.body}\n\n${c.button}: ${link}\n\nThe link works once and expires soon. Teafair will never ask for your password, PIN or codes.`;
  return { subject: c.subject, html, text };
}
