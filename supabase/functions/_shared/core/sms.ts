// SMS delivery for OTPs (Spec A §6.11). KudiSMS in every real environment;
// `log` only for the local stack. There is deliberately no default, so a
// misconfigured deployment fails loudly instead of logging codes, and `log`
// refuses to start anywhere but the local stack (auth audit L1).
import { requireEnv } from "./env.ts";

export type SmsSender = (to: string, message: string) => Promise<void>;

export function kudiSmsSender(opts: {
  token: string;
  senderId: string;
  /** KudiSMS route selector, sent as `gateway` only when set (KUDISMS_GATEWAY). */
  gateway?: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
}): SmsSender {
  const fetchFn = opts.fetchFn ?? fetch;
  const baseUrl = opts.baseUrl ?? "https://my.kudisms.net";
  return async (to, message) => {
    const res = await fetchFn(`${baseUrl}/api/sms`, {
      method: "POST",
      body: new URLSearchParams({
        token: opts.token,
        senderID: opts.senderId,
        recipients: to.replace(/^\+/, ""),
        message,
        ...(opts.gateway ? { gateway: opts.gateway } : {}),
      }),
    });
    const payload = await res.json().catch(() => null) as { error_code?: string; msg?: string } | null;
    if (!res.ok || payload?.error_code !== "000") {
      throw new Error(`KudiSMS rejected the message: ${payload?.msg ?? `HTTP ${res.status}`}`);
    }
  };
}

export function logSmsSender(): SmsSender {
  return (to, message) => {
    console.log(`[sms:log] to ${to}: ${message}`);
    return Promise.resolve();
  };
}

// Hostnames the local stack's edge runtime sees for SUPABASE_URL.
const LOCAL_HOSTS = new Set(["kong", "localhost", "127.0.0.1", "host.docker.internal"]);

/** Throws unless `provider` may run where `supabaseUrl` points; `log` is local-only. */
export function assertSafeSmsProvider(provider: string, supabaseUrl: string | undefined): void {
  if (provider !== "log") return;
  let host = "";
  try {
    host = new URL(supabaseUrl ?? "").hostname;
  } catch {
    // no or unparsable URL: not provably local
  }
  if (!LOCAL_HOSTS.has(host)) {
    throw new Error("SMS_PROVIDER=log prints codes to the console and runs on the local stack only");
  }
}

export function smsSenderFromEnv(): SmsSender {
  const provider = requireEnv("SMS_PROVIDER");
  assertSafeSmsProvider(provider, Deno.env.get("SUPABASE_URL"));
  if (provider === "kudisms") {
    return kudiSmsSender({
      token: requireEnv("KUDISMS_TOKEN"),
      senderId: requireEnv("KUDISMS_SENDER_ID"),
      gateway: Deno.env.get("KUDISMS_GATEWAY") || undefined,
    });
  }
  if (provider === "log") return logSmsSender();
  throw new Error(`unknown SMS_PROVIDER ${provider}`);
}
