import { serviceRpc } from "../_shared/core/db.ts";
import { requireEnv } from "../_shared/core/env.ts";
import { allowedOriginsFromEnv } from "../_shared/core/public-gateway.ts";
import { turnstileVerifier } from "../_shared/commerce/turnstile.ts";
import { ticketSecretFor } from "../_shared/support/secret.ts";
import { createSupportTicketOpenHandler } from "./handler.ts";
import { observe } from "../_shared/core/observability.ts";

// public-flavoured (A1 §5): anonymous callers, gated by Turnstile; the RPC is service_role only.
// Fail closed: without SUPPORT_TICKET_SECRET_KEY every request is 503 (the
// handler maps a failed secretFor to RETRY) and no ticket is opened. Read once
// here, like web-checkout's TURNSTILE_SECRET_KEY; not thrown at boot, because
// the edge runtime answers a boot failure with a 500.
// A key shorter than 32 characters counts as missing.
const rawTicketSecretKey = Deno.env.get("SUPPORT_TICKET_SECRET_KEY") ?? "";
const ticketSecretKey = rawTicketSecretKey.length >= 32 ? rawTicketSecretKey : "";
if (!ticketSecretKey) console.error("SUPPORT_TICKET_SECRET_KEY is missing or shorter than 32 characters");

Deno.serve(observe("support-ticket-open", createSupportTicketOpenHandler({
  rpc: serviceRpc(),
  allowedOrigins: allowedOriginsFromEnv(),
  verifyTurnstile: turnstileVerifier({
    secretKey: requireEnv("TURNSTILE_SECRET_KEY"),
    url: Deno.env.get("TURNSTILE_VERIFY_URL") || undefined,
  }),
  secretFor: (idempotencyKey) =>
    ticketSecretKey
      ? ticketSecretFor(ticketSecretKey, idempotencyKey)
      : Promise.reject(new Error("SUPPORT_TICKET_SECRET_KEY is not usable")),
})));
