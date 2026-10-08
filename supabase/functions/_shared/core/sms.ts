// SMS delivery for OTPs (Spec A §6.11). KudiSMS in every real environment;
// `log` only for the local stack. There is deliberately no default, so a
// misconfigured deployment fails loudly instead of logging codes.
import { requireEnv } from "./env.ts";

export type SmsSender = (to: string, message: string) => Promise<void>;

export function kudiSmsSender(opts: {
  token: string;
  senderId: string;
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

export function smsSenderFromEnv(): SmsSender {
  const provider = requireEnv("SMS_PROVIDER");
  if (provider === "kudisms") {
    return kudiSmsSender({ token: requireEnv("KUDISMS_TOKEN"), senderId: requireEnv("KUDISMS_SENDER_ID") });
  }
  if (provider === "log") return logSmsSender();
  throw new Error(`unknown SMS_PROVIDER ${provider}`);
}
