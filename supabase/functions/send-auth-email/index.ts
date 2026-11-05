import { hookVerifierFromEnv } from "../_shared/auth/hook.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { createSendAuthEmailHandler } from "./handler.ts";
import { resendSender } from "../_shared/messaging/resend.ts";

const verifyHook = hookVerifierFromEnv("SEND_EMAIL_HOOK_SECRET");
const siteUrl = requireEnv("AUTH_SITE_URL").replace(/\/$/, "");
const recoveryRedirect = `${siteUrl}/reset-password`;
const extra = (Deno.env.get("AUTH_EMAIL_REDIRECT_URLS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);

Deno.serve(observe("send-auth-email", createSendAuthEmailHandler({
  verifyHook,
  sendEmail: resendSender({
    apiKey: requireEnv("RESEND_API_KEY"),
    from: requireEnv("AUTH_EMAIL_FROM"),
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
