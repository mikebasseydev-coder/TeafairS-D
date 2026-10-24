// Supabase Auth's Send Email hook. Every email Supabase Auth would send comes
// here, signed with Standard Webhooks, and goes out through Resend.
//
// Supported: recovery (password reset), signup, invite and email_change.
// Anything else (magic links, email OTPs, reauthentication) is refused:
// passwordless email is not a Teafair sign-in route.
//
// Links point at Supabase Auth's /auth/v1/verify with the token hash, never
// the raw token. redirect_to is used only when it matches an allowed URL
// exactly (origin and path; query and fragment dropped), else the default:
// Supabase Auth checks it too, this is the second lock against open redirects.
//
// Sentry sees the user id only; never an address, token or link.
import { hookError, type HookVerifier } from "../_shared/auth/hook.ts";
import { z } from "../_shared/core/deps.ts";
import { GatewayError } from "../_shared/core/errors.ts";
import { json } from "../_shared/core/http.ts";
import { reportError, tagRequest, tagUserId } from "../_shared/core/observability.ts";
import type { EmailSender } from "./resend.ts";
import { type EmailKind, renderEmail } from "./templates.ts";

export type SendAuthEmailConfig = {
  /** Public base URL of Supabase Auth, e.g. https://<ref>.supabase.co (no /auth/v1). */
  linkBase: string;
  /** Exact URLs a link may return to. */
  redirectAllowlist: string[];
  /** Where a link returns when redirect_to is missing or not allowed. */
  defaultRedirect: string;
  /** The password-reset page (recovery links). */
  recoveryRedirect: string;
};

export type SendAuthEmailDeps = {
  verifyHook: HookVerifier;
  sendEmail: EmailSender;
  config: SendAuthEmailConfig;
};

const SUPPORTED = ["recovery", "signup", "invite", "email_change"] as const;

const hookEvent = z.object({
  user: z.object({
    id: z.string().uuid(),
    email: z.string().email().optional().nullable(),
    new_email: z.string().email().optional().nullable().or(z.literal("")),
  }).passthrough(),
  email_data: z.object({
    email_action_type: z.string(),
    token_hash: z.string().optional().nullable(),
    token_hash_new: z.string().optional().nullable(),
    redirect_to: z.string().optional().nullable(),
  }).passthrough(),
}).passthrough();

/** origin + pathname of a parseable http(s) URL, else null. */
function canonical(url: string): string | null {
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    return `${u.origin}${u.pathname}`;
  } catch {
    return null;
  }
}

export function safeRedirect(candidate: string | null | undefined, allowlist: string[], fallback: string): string {
  const c = candidate ? canonical(candidate) : null;
  if (!c) return fallback;
  return allowlist.some((a) => canonical(a) === c) ? c : fallback;
}

function verifyLink(base: string, tokenHash: string, type: string, redirect: string): string {
  const u = new URL(`${base.replace(/\/$/, "")}/auth/v1/verify`);
  u.searchParams.set("token", tokenHash);
  u.searchParams.set("type", type);
  u.searchParams.set("redirect_to", redirect);
  return u.toString();
}

type Outgoing = { to: string; kind: EmailKind; tokenHash: string };

export function createSendAuthEmailHandler(deps: SendAuthEmailDeps): (req: Request) => Promise<Response> {
  const { config } = deps;
  return async (req) => {
    tagRequest({ gateway: "auth-hook" });
    const payload = await req.text();

    let signed: unknown;
    try {
      signed = deps.verifyHook(payload, Object.fromEntries(req.headers));
    } catch {
      return hookError(401, "invalid hook signature");
    }
    const event = hookEvent.safeParse(signed);
    if (!event.success) return hookError(400, "unexpected hook payload");

    const { user, email_data: data } = event.data;
    tagUserId(user.id);
    const action = data.email_action_type;
    if (!(SUPPORTED as readonly string[]).includes(action)) {
      return hookError(400, "This kind of email is not available.");
    }

    const out: Outgoing[] = [];
    if (action === "email_change") {
      // Supabase's naming is crossed: with secure email change, token_hash_new
      // confirms from the CURRENT address and token_hash from the NEW one.
      if (data.token_hash_new && user.email) {
        out.push({ to: user.email, kind: "email_change_current", tokenHash: data.token_hash_new });
      }
      if (data.token_hash && user.new_email) {
        out.push({ to: user.new_email, kind: "email_change_new", tokenHash: data.token_hash });
      }
    } else if (data.token_hash && user.email) {
      out.push({ to: user.email, kind: action as EmailKind, tokenHash: data.token_hash });
    }
    if (out.length === 0) return hookError(400, "unexpected hook payload");

    const redirect = safeRedirect(
      data.redirect_to,
      config.redirectAllowlist,
      action === "recovery" ? config.recoveryRedirect : config.defaultRedirect,
    );
    const hookId = req.headers.get("webhook-id");

    try {
      for (const o of out) {
        const link = verifyLink(config.linkBase, o.tokenHash, action, redirect);
        await deps.sendEmail({
          to: o.to,
          ...renderEmail(o.kind, link),
          ...(hookId ? { idempotencyKey: `${hookId}:${o.kind}` } : {}),
        });
      }
    } catch (e) {
      // EmailDeliveryError carries the HTTP status only; anything else is replaced
      const status = (e as { status?: unknown }).status;
      reportError(new GatewayError(502, "EMAIL_DELIVERY_FAILED",
        `auth email (${action}) not sent${typeof status === "number" ? `: HTTP ${status}` : ""}`));
      return hookError(502, "The email could not be sent. Try again.");
    }
    return json(200, {});
  };
}
