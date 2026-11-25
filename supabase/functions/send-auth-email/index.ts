import { hookVerifierFromEnv } from "../_shared/auth/hook.ts";
import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { type AuthEmailContext, createSendAuthEmailHandler } from "./handler.ts";
import { resendSender, senderFrom } from "../_shared/messaging/resend.ts";

// system-flavoured (§3.4): Supabase Auth calls this before any session exists,
// so the sign-in gate (auth_email_context) runs with the service-role key,
// after the hook signature.
const verifyHook = hookVerifierFromEnv("SEND_EMAIL_HOOK_SECRET");
const rpc = serviceRpc();
const siteUrl = requireEnv("AUTH_SITE_URL").replace(/\/$/, "");
const recoveryRedirect = `${siteUrl}/reset-password`;
const extra = (Deno.env.get("AUTH_EMAIL_REDIRECT_URLS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);

Deno.serve(observe("send-auth-email", createSendAuthEmailHandler({
  verifyHook,
  emailContext: (userId) => rpc<AuthEmailContext>("auth_email_context", { p_user_id: userId }),
  sendEmail: resendSender({
    apiKey: requireEnv("RESEND_API_KEY"),
    // unset: Resend's sandbox sender, which delivers only to the account owner
    from: senderFrom(Deno.env.get("AUTH_EMAIL_FROM")),
    apiUrl: Deno.env.get("RESEND_API_URL") || undefined,
  }),
  config: {
    // the public Auth URL: inside the local edge runtime SUPABASE_URL is http://kong:8000
    linkBase: Deno.env.get("AUTH_EMAIL_LINK_BASE") || requireEnv("SUPABASE_URL"),
    redirectAllowlist: [siteUrl, recoveryRedirect, ...extra],
    defaultRedirect: siteUrl,
    recoveryRedirect,
  },
})));
