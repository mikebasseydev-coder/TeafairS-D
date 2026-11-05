import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { observe } from "../_shared/core/observability.ts";
import { resendSender } from "../_shared/messaging/resend.ts";
import { createEmailOutboxSendHandler } from "./handler.ts";

// system-flavoured (§3.4): invoked by pg_cron via pg_net with x-cron-secret
const cronSecret = requireEnv("CRON_SECRET");

Deno.serve(observe("email-outbox-send", createEmailOutboxSendHandler({
  cronSecret,
  rpc: serviceRpc(),
  sendEmail: resendSender({
    apiKey: requireEnv("RESEND_API_KEY"),
    from: requireEnv("SUPPORT_EMAIL_FROM"),
    apiUrl: Deno.env.get("RESEND_API_URL") || undefined,
  }),
  // unset: buyer emails wait (RETRY) and the run logs it once
  ticketUrl: Deno.env.get("WEB_SUPPORT_TICKET_URL") || undefined,
})));
