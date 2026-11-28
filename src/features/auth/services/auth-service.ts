// Email-first sign-in (Spec B §9.1): a 6-digit code sent by the Send Email
// hook to a known person only. No SMS, no WhatsApp, no magic link. These
// functions talk to Supabase Auth and nothing else; they hold no state.
import type { AuthError, Session } from "@supabase/supabase-js";
import { supabase } from "@/shared/network/supabase";
import { runResets } from "@/shared/storage/reset-registry";
import { forgetOpenStores } from "@/shared/storage/mmkv";
import { log } from "@/shared/observability/log";

export type AuthFailureKind = "no_access" | "invalid_code" | "rate_limited" | "busy" | "network" | "unknown";
export type AuthFailure = { kind: AuthFailureKind; message: string };
export type AuthResult = { ok: true } | { ok: false; failure: AuthFailure };

export const AUTH_COPY: Record<AuthFailureKind, string> = {
  no_access: "This email has no Teafair access.",
  invalid_code: "That code is wrong or has expired. Check the latest email, or send a new code.",
  rate_limited: "Too many attempts. Wait a minute, then try again.",
  busy: "Sign-in is busy. Try again in a moment.",
  network: "No connection. Check your network and try again.",
  unknown: "Sign-in failed. Try again.",
};

const fail = (kind: AuthFailureKind): AuthResult => ({ ok: false, failure: { kind, message: AUTH_COPY[kind] } });

/** Classifies a Supabase Auth error. The hook refuses an unknown person with 403. */
export function classifyAuthError(error: Pick<AuthError, "status" | "code"> | null, step: "request" | "verify"): AuthFailureKind {
  if (!error) return "unknown";
  const code = error.code ?? "";
  if (error.status === 429 || code.startsWith("over_")) return "rate_limited";
  // a hook that did not answer in time (Auth gives it 5 s) is not a refusal
  if (code === "hook_timeout" || code === "hook_payload_over_size_limit") return "busy";
  if (step === "verify" && (code === "otp_expired" || error.status === 403 || error.status === 401)) return "invalid_code";
  // unknown email: Auth refuses before the hook (422 otp_disabled); a known person
  // without access: the hook refuses (403)
  if (step === "request" && (error.status === 403 || code === "otp_disabled" || code === "user_not_found")) return "no_access";
  if (!error.status) return "network";
  return "unknown";
}

export async function requestCode(email: string): Promise<AuthResult> {
  try {
    const { error } = await supabase().auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
    if (!error) return { ok: true };
    log.warn("auth.request_code_refused", { status: error.status, code: error.code });
    return fail(classifyAuthError(error, "request"));
  } catch {
    return fail("network");
  }
}

export async function verifyCode(email: string, token: string): Promise<AuthResult> {
  try {
    const { error } = await supabase().auth.verifyOtp({ email, token, type: "email" });
    if (!error) return { ok: true };
    log.warn("auth.verify_code_refused", { status: error.status, code: error.code });
    return fail(classifyAuthError(error, "verify"));
  } catch {
    return fail("network");
  }
}

/** After accept_tenant_invitation or set_active_tenant: the new token carries the new claims. */
export async function refreshSession(): Promise<Session | null> {
  const { data, error } = await supabase().auth.refreshSession();
  if (error) log.warn("auth.refresh_failed", { status: error.status, code: error.code });
  return data.session;
}

export async function currentSession(): Promise<Session | null> {
  const { data } = await supabase().auth.getSession();
  return data.session;
}

export function onSessionChange(listener: (session: Session | null) => void): () => void {
  const { data } = supabase().auth.onAuthStateChange((_event, session) => listener(session));
  return () => data.subscription.unsubscribe();
}

/**
 * Sign-out (Spec B §5): every store resets ("session" runs "tenant" first),
 * then Auth drops the session from Tier 1. The user's MMKV namespaces stay,
 * encrypted. The queue check before this arrives with the queue (B4).
 */
export async function signOut(): Promise<void> {
  try {
    await runResets("session");
  } finally {
    forgetOpenStores();
    await supabase().auth.signOut({ scope: "local" });
  }
}

export type OwnProfile = { id: string; fullName: string | null; email: string | null };

export async function readOwnProfile(userId: string): Promise<OwnProfile | null> {
  const { data, error } = await supabase().from("profiles").select("id, full_name, email").eq("id", userId).maybeSingle();
  if (error || !data) return null;
  return { id: data.id, fullName: data.full_name, email: data.email };
}
